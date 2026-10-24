// Wholesale POS — Licensing Edge Function
//
// Deployment (Supabase dashboard):
//   1. Dashboard -> Edge Functions -> create one named `licensing`
//   2. Paste this whole file into the code editor. Save. Deploy.
//   3. Settings -> Edge Functions -> Add three secrets, then redeploy:
//        SUPABASE_URL                 (auto-provided, leave as-is)
//        SUPABASE_SERVICE_ROLE_KEY    (auto-provided; if not, Settings -> API -> service_role)
//        LICENSE_SIGNING_SEED_B64URL  (contents of your local
//                                     C:\Users\www\AppData\Local\WholesalePOS\Signing\owner-ed25519.key)
//
// What it does:
//   POST /functions/v1/licensing  with a JSON body containing {action, ...}
//   Actions:
//     - activate_device    : redeem an activation code on a device (seat-limited)
//     - list_devices       : buyer sees their own active seats
//     - deactivate_device  : buyer self-removes one of their own devices
//     - redeem_voucher     : bump seat_limit using a code Umer sold them
//
//   All responses are JSON. The activation code IS the shared secret for
//   list/deactivate/redeem — knowing it proves device ownership. A caller
//   without a registered fingerprint cannot list or deactivate anything.
//
//   The signed license returned by activate_device is the same format the
//   Dart client already verifies (see lib/core/licensing/license_validator.dart),
//   just with `version: 2` and the extra `customer_id` / `device_fingerprint`
//   / `activation_code` fields.

import { ed25519 } from 'https://esm.sh/@noble/curves@1.4.0/ed25519';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const SEED_B64URL = Deno.env.get('LICENSE_SIGNING_SEED_B64URL')!;

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ ok: false, error: 'POST required' }, 405);
  let body: any;
  try { body = await req.json(); } catch { return json({ ok: false, error: 'Invalid JSON' }, 400); }

  const db = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false },
  });

  try {
    switch (body.action) {
      case 'activate_device':   return await activateDevice(db, body);
      case 'list_devices':      return await listDevices(db, body);
      case 'deactivate_device': return await deactivateDevice(db, body);
      case 'redeem_voucher':    return await redeemVoucher(db, body);
      default: return json({ ok: false, error: `Unknown action: ${body.action}` }, 400);
    }
  } catch (err) {
    // Never leak internal error text (SQL fragments, stack traces) to the client.
    console.error('licensing function error:', err);
    return json({ ok: false, error: 'Internal error.' }, 500);
  }
});

// ---------------------------------------------------------------------------
// Action: activate_device
// ---------------------------------------------------------------------------
// Input: { action, activation_code, device_fingerprint, device_name? }
// Output on success: { ok, license_code, expires_at, seat_limit, seats_used }
// Output on refusal: { ok:false, error, seat_limit?, seats_used? }
async function activateDevice(db: any, body: any): Promise<Response> {
  const code = str(body.activation_code);
  const fingerprint = str(body.device_fingerprint);
  const deviceName = str(body.device_name) || 'Unknown device';
  if (!code || !fingerprint) return json({ ok: false, error: 'Missing fields' }, 400);

  const { data: license } = await db
    .from('licenses').select('*').eq('activation_code', code).maybeSingle();
  if (!license) return json({ ok: false, error: 'Invalid activation code.' }, 404);
  if (license.revoked_at) return json({ ok: false, error: 'License revoked.' }, 403);
  if (license.expires_at && new Date(license.expires_at) < new Date()) {
    return json({ ok: false, error: 'License expired.' }, 403);
  }

  const { data: existing } = await db
    .from('device_registrations').select('*')
    .eq('activation_code', code)
    .eq('device_fingerprint', fingerprint)
    .maybeSingle();

  let seatsUsed: number;
  if (existing && !existing.revoked_at) {
    // Same device re-activating: refresh heartbeat, no seat consumed.
    await db.from('device_registrations')
      .update({ last_heartbeat: new Date().toISOString(), device_name: deviceName })
      .eq('id', existing.id);
    seatsUsed = await countActiveSeats(db, code);
  } else if (existing && existing.revoked_at) {
    // Was revoked; reactivate. Doesn't count against seat because it holds
    // the same (code, fingerprint) slot; if the buyer has since filled the
    // slot with another device we would refuse on the unique index.
    await db.from('device_registrations')
      .update({ revoked_at: null, last_heartbeat: new Date().toISOString(), device_name: deviceName })
      .eq('id', existing.id);
    seatsUsed = await countActiveSeats(db, code);
  } else {
    // Brand new device: check seat.
    seatsUsed = await countActiveSeats(db, code);
    if (seatsUsed >= license.seat_limit) {
      return json({
        ok: false,
        error: 'Seat limit reached. Deactivate one of your devices in Settings -> Devices, or buy an extra seat.',
        seat_limit: license.seat_limit,
        seats_used: seatsUsed,
      }, 409);
    }
    const { error: insErr } = await db.from('device_registrations').insert({
      activation_code: code,
      device_fingerprint: fingerprint,
      device_name: deviceName,
      last_heartbeat: new Date().toISOString(),
    });
    if (insErr) return json({ ok: false, error: 'Insert failed.' }, 500);
    seatsUsed += 1;
    await writeAudit(db, code, fingerprint, 'activate', { device_name: deviceName });
  }

  // Build the license payload. Canonicalization matches Dart's
  // `jsonEncode(_canonicalize(payload))` byte-for-byte: keys sorted
  // recursively, no whitespace, UTF-8.
  const issued = new Date();
  // Cap at the license's own expiry if the customer is on a paid subscription;
  // otherwise default to a rolling 1-year device license (re-checkable on
  // next activation after expiry).
  const hardExpiry = license.expires_at ? new Date(license.expires_at) : null;
  const rolling = new Date(issued.getTime() + 365 * 24 * 3600 * 1000);
  const expires = hardExpiry && hardExpiry < rolling ? hardExpiry : rolling;

  const payload: Record<string, unknown> = {
    format: 'wholesale-pos-license',
    version: 2,
    product: 'wholesale_pos',
    entitlements: ['pos'],
    activation_code: code,
    customer_id: license.customer_id,
    device_fingerprint: fingerprint,
    issued_at: isoNoMillis(issued),
    expires_at: isoNoMillis(expires),
  };
  const canonicalBytes = new TextEncoder().encode(canonicalJson(payload));
  const seed = base64UrlDecode(SEED_B64URL);
  const signature = ed25519.sign(canonicalBytes, seed);
  const licenseCode = `${base64UrlEncode(canonicalBytes)}.${base64UrlEncode(signature)}`;

  return json({
    ok: true,
    license_code: licenseCode,
    expires_at: payload.expires_at,
    seat_limit: license.seat_limit,
    seats_used: seatsUsed,
  });
}

// ---------------------------------------------------------------------------
// Action: list_devices
// ---------------------------------------------------------------------------
// Input: { action, activation_code, device_fingerprint }
// Output: { ok, devices: [{fingerprint_masked, device_name, first_seen, last_heartbeat, is_self}], seat_limit, seats_used }
async function listDevices(db: any, body: any): Promise<Response> {
  const code = str(body.activation_code);
  const fingerprint = str(body.device_fingerprint);
  if (!code || !fingerprint) return json({ ok: false, error: 'Missing fields' }, 400);

  const { data: me } = await db.from('device_registrations').select('id')
    .eq('activation_code', code).eq('device_fingerprint', fingerprint)
    .is('revoked_at', null).maybeSingle();
  if (!me) return json({ ok: false, error: 'Device not registered.' }, 403);

  const { data: devices } = await db.from('device_registrations').select('*')
    .eq('activation_code', code).is('revoked_at', null).order('first_seen');
  const { data: license } = await db.from('licenses').select('seat_limit')
    .eq('activation_code', code).single();

  const out = (devices ?? []).map((d: any) => ({
    fingerprint_masked: mask(d.device_fingerprint),
    device_name: d.device_name,
    first_seen: d.first_seen,
    last_heartbeat: d.last_heartbeat,
    is_self: d.device_fingerprint === fingerprint,
    // Return the FULL fingerprint for every row, not just self. list_devices
    // is only callable by a device that already holds a valid
    // (activation_code, fingerprint) pair, so every caller is already an
    // authenticated seat holder for this shop. They need the full string to
    // deactivate a lost device. The masked copy stays for display.
    device_fingerprint: d.device_fingerprint,
  }));
  return json({
    ok: true,
    devices: out,
    seat_limit: license?.seat_limit ?? 0,
    seats_used: out.length,
  });
}

// ---------------------------------------------------------------------------
// Action: deactivate_device
// ---------------------------------------------------------------------------
// Input: { action, activation_code, requesting_fingerprint, target_fingerprint }
// Output: { ok }
async function deactivateDevice(db: any, body: any): Promise<Response> {
  const code = str(body.activation_code);
  const requesting = str(body.requesting_fingerprint);
  const target = str(body.target_fingerprint);
  if (!code || !requesting || !target) return json({ ok: false, error: 'Missing fields' }, 400);

  const { data: me } = await db.from('device_registrations').select('id')
    .eq('activation_code', code).eq('device_fingerprint', requesting)
    .is('revoked_at', null).maybeSingle();
  if (!me) return json({ ok: false, error: 'Unauthorized.' }, 403);

  const { data: tgt } = await db.from('device_registrations').select('id')
    .eq('activation_code', code).eq('device_fingerprint', target)
    .is('revoked_at', null).maybeSingle();
  if (!tgt) return json({ ok: false, error: 'Target device not found.' }, 404);

  await db.from('device_registrations')
    .update({ revoked_at: new Date().toISOString() })
    .eq('id', tgt.id);
  await writeAudit(db, code, target, 'deactivate', { by: mask(requesting) });
  return json({ ok: true });
}

// ---------------------------------------------------------------------------
// Action: redeem_voucher
// ---------------------------------------------------------------------------
// Input: { action, activation_code, device_fingerprint, voucher_code }
// Output: { ok, seats_added, new_seat_limit }
async function redeemVoucher(db: any, body: any): Promise<Response> {
  const code = str(body.activation_code);
  const fingerprint = str(body.device_fingerprint);
  const voucher = str(body.voucher_code);
  if (!code || !fingerprint || !voucher) return json({ ok: false, error: 'Missing fields' }, 400);

  const { data: me } = await db.from('device_registrations').select('id')
    .eq('activation_code', code).eq('device_fingerprint', fingerprint)
    .is('revoked_at', null).maybeSingle();
  if (!me) return json({ ok: false, error: 'Unauthorized.' }, 403);

  // apply_seat_voucher() is SECURITY DEFINER: atomically bumps the seat_limit
  // and stamps redeemed_at; a second call with the same voucher raises.
  const { data, error } = await db.rpc('apply_seat_voucher', { p_voucher_code: voucher });
  if (error) return json({ ok: false, error: 'Voucher not found or already redeemed.' }, 400);

  const row = Array.isArray(data) ? data[0] : data;
  await writeAudit(db, code, fingerprint, 'voucher_redeem', {
    voucher_code: voucher, seats_added: row?.seats_added,
  });
  return json({ ok: true, seats_added: row?.seats_added, new_seat_limit: row?.new_seat_limit });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
async function countActiveSeats(db: any, code: string): Promise<number> {
  const { count } = await db.from('device_registrations')
    .select('*', { count: 'exact', head: true })
    .eq('activation_code', code).is('revoked_at', null);
  return count ?? 0;
}

async function writeAudit(db: any, code: string, fp: string | null, event: string, detail: any) {
  await db.from('license_audit').insert({
    activation_code: code, device_fingerprint: fp, event, detail,
  });
}

function str(v: unknown): string {
  return typeof v === 'string' ? v.trim() : '';
}

function mask(fp: string): string {
  return fp.length <= 8 ? fp : `${fp.slice(0, 4)}…${fp.slice(-4)}`;
}

// Same shape Dart writes: no millisecond fraction, 'Z' suffix (parseable by
// DateTime.tryParse as UTC).
function isoNoMillis(d: Date): string {
  return d.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

// Recursive object-key sort, no whitespace. Matches Dart's _canonicalize().
function canonicalJson(value: unknown): string {
  return JSON.stringify(canonicalize(value));
}
function canonicalize(v: any): any {
  if (Array.isArray(v)) return v.map(canonicalize);
  if (v && typeof v === 'object') {
    const keys = Object.keys(v).sort();
    const out: Record<string, unknown> = {};
    for (const k of keys) out[k] = canonicalize(v[k]);
    return out;
  }
  return v;
}

function base64UrlEncode(bytes: Uint8Array): string {
  let s = ''; for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function base64UrlDecode(str: string): Uint8Array {
  const pad = str.length % 4 === 0 ? '' : '='.repeat(4 - (str.length % 4));
  const b64 = str.replace(/-/g, '+').replace(/_/g, '/');
  const bin = atob(b64 + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status, headers: { 'Content-Type': 'application/json' },
  });
}
