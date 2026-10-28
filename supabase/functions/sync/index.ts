// Wholesale POS — Sync Gateway Edge Function (Phase 18)
//
// The multi-tenant replacement for shipping a Supabase secret key inside a
// build. Clients present their SIGNED LICENSE (issued by the licensing
// function, Ed25519-verified here); the gateway checks it, then reads/writes
// the analytics mirror tables with the service role, stamping every row with
// the customer_id carved into the license. The client NEVER holds a key that
// can touch these tables directly (RLS + REVOKE lock them to service_role).
//
// Deployment (same pattern as the licensing function):
//   supabase functions deploy sync --no-verify-jwt
//   supabase secrets set SYNC_LICENSE_PUBLIC_KEY=<64-hex-char-public-key>
//
// Security model:
//   * Ed25519 signature over the canonical license payload — forged or
//     tampered licenses fail cryptographically. No shared secret to leak.
//   * expires_at must be in the future (license has a 1-year rolling life;
//     devices re-activate periodically, so an old license stops working).
//   * The license's (activation_code, device_fingerprint) pair must match an
//     ACTIVE seat registration — deactivating a device cuts its sync too.
//   * customer_id is taken ONLY from the verified license payload; a client
//     cannot write rows into another shop's partition, ever.
//   * A revocation check on the license row itself kills stolen licenses on
//     the next request, even before their embedded expiry.
//
// Actions (POST /functions/v1/sync):
//   { action: 'push', license: '<licenseCode>', entries: [outbox entries] }
//     -> { ok, applied: n, results: [{entityId, status, error?}] }
//   { action: 'pull', license: '<licenseCode>', since: '<iso>',
//     tables?: [], cursor?: {received_at, id}, limit?: n }
//     -> { ok, changes: { sales: [...], ... }, server_time, next_cursor,
//          has_more }
//   { action: 'ping', license: '<licenseCode>' }
//     -> { ok, customer_id, seats_active }  (cheap connectivity/auth probe)

import { ed25519 } from 'https://esm.sh/@noble/curves@1.4.0/ed25519';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
// Hex, exactly as tools/print_public_key.dart prints it and as the Dart app
// bakes into WHOLESALE_POS_LICENSE_PUBLIC_KEY.
const PUBLIC_KEY_HEX = Deno.env.get('SYNC_LICENSE_PUBLIC_KEY')!;

// Mirror tables the gateway knows. Anything else is refused.
const TABLES = ['sales', 'sale_items', 'shifts', 'cash_movements', 'void_requests'] as const;

// The client enqueues with the LOCAL entity vocabulary (SyncEntities in
// Dart: 'sale' | 'shift' | 'cash_movement' | 'void_request'); map to the
// cloud table names here, exactly like SupabaseSyncBackend._tableFor did.
const ENTITY_TABLE: Record<string, string> = {
  sale: 'sales',
  shift: 'shifts',
  cash_movement: 'cash_movements',
  void_request: 'void_requests',
};

// Max outbox entries accepted in one push batch (abuse guard).
const MAX_BATCH = 500;

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ ok: false, error: 'POST required' }, 405);
  let body: any;
  try { body = await req.json(); } catch { return json({ ok: false, error: 'Invalid JSON' }, 400); }

  const db = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false },
  });

  // Every action authenticates the same way: a valid signed license.
  let auth: { ok: true; customerId: string; code: string; fingerprint: string }
         | { ok: false; status: number; error: string };
  try {
    auth = await verifyLicense(db, String(body.license ?? ''));
  } catch (err) {
    console.error('sync auth error:', err);
    auth = { ok: false, status: 500, error: 'Internal error.' };
  }
  if (!auth.ok) return json({ ok: false, error: auth.error }, auth.status);

  try {
    switch (body.action) {
      case 'push': return await push(db, auth, body);
      case 'pull': return await pull(db, auth, body);
      case 'ping': return await ping(db, auth);
      default: return json({ ok: false, error: `Unknown action: ${body.action}` }, 400);
    }
  } catch (err) {
    console.error('sync function error:', err);
    return json({ ok: false, error: 'Internal error.' }, 500);
  }
});

// ---------------------------------------------------------------------------
// License verification — the entire security boundary of this function.
// ---------------------------------------------------------------------------
async function verifyLicense(db: any, licenseCode: string) {
  if (!licenseCode) return fail(401, 'Missing license.');
  const dot = licenseCode.indexOf('.');
  if (dot <= 0) return fail(401, 'Malformed license.');
  let payload: any;
  try {
    const payloadBytes = base64UrlDecode(licenseCode.slice(0, dot));
    const signature = base64UrlDecode(licenseCode.slice(dot + 1));
    // Cryptographic check first: tampering with any field breaks this.
    if (!ed25519.verify(signature, payloadBytes, hexToBytes(PUBLIC_KEY_HEX))) {
      return fail(401, 'License signature invalid.');
    }
    payload = JSON.parse(new TextDecoder().decode(payloadBytes));
  } catch {
    return fail(401, 'License could not be parsed.');
  }

  if (payload.format !== 'wholesale-pos-license' || payload.version !== 2) {
    return fail(401, 'License format not supported by sync.');
  }
  const code = String(payload.activation_code ?? '');
  const fingerprint = String(payload.device_fingerprint ?? '');
  const customerId = String(payload.customer_id ?? '');
  if (!code || !fingerprint || !customerId) return fail(401, 'License fields missing.');

  // Rolling expiry: an old, never-refreshed license must stop syncing.
  const expires = Date.parse(String(payload.expires_at ?? ''));
  if (!Number.isFinite(expires) || expires < Date.now()) {
    return fail(403, 'License expired. Re-activate the device.');
  }

  // Server-side revocation beats the license's embedded expiry.
  const { data: licRow } = await db
    .from('licenses').select('revoked_at').eq('activation_code', code).maybeSingle();
  if (!licRow) return fail(403, 'License not found.');
  if (licRow.revoked_at) return fail(403, 'License revoked.');

  // The presenting device must hold an ACTIVE seat — deactivation cuts sync.
  const { data: seat } = await db.from('device_registrations').select('id')
    .eq('activation_code', code).eq('device_fingerprint', fingerprint)
    .is('revoked_at', null).maybeSingle();
  if (!seat) return fail(403, 'Device seat not registered (or deactivated).');

  return { ok: true as const, customerId, code, fingerprint };
}

function fail(status: number, error: string) {
  return { ok: false as const, status, error };
}

// ---------------------------------------------------------------------------
// Action: push — drain a client outbox into the mirror.
// ---------------------------------------------------------------------------
// Entry shape (identical to the local SyncOutboxEntry jsonEncode):
//   { entityType, entityId, operation: 'upsert'|'delete', payload: {...}, ... }
// Payload sub-rows carry local columns only; customer_id is stamped HERE.
async function push(db: any, auth: { customerId: string }, body: any): Promise<Response> {
  const entries = Array.isArray(body.entries) ? body.entries : [];
  if (entries.length === 0) return json({ ok: true, applied: 0, results: [] });
  if (entries.length > MAX_BATCH) {
    return json({ ok: false, error: `Batch too large (max ${MAX_BATCH}).` }, 413);
  }

  // Stamp every applied row with the server's receive time. Previously
  // received_at defaulted only on INSERT, so an UPDATE left it stale and a
  // pull keyed on received_at never re-surfaced the change (audit #12).
  const receivedAt = new Date().toISOString();
  let applied = 0;
  const results: { entityId: string; status: string; error?: string }[] = [];

  for (const entry of entries) {
    const entityId = String(entry.entityId ?? '');
    // Accept both the local vocabulary ('sale') and the table name ('sales')
    // so older enqueued rows and hand-tested payloads keep working.
    const rawType = String(entry.entityType ?? '');
    const table = ENTITY_TABLE[rawType] ?? (TABLES.includes(rawType as any) ? rawType : '');
    // A non-empty entity type we do not recognise is a permanent rejection,
    // reported per-entry so the client can drop it instead of silently acking
    // un-processed data OR retrying it forever (audit #20).
    if (!table) {
      results.push({ entityId, status: 'rejected', error: `unknown entity type: ${rawType}` });
      continue;
    }

    try {
      if (String(entry.operation ?? '').toUpperCase() === 'DELETE') {
        const del = await db.from(table)
          .delete()
          .eq('customer_id', auth.customerId)
          .eq('id', entityId);
        if (del.error) throw new Error(`delete ${table}: ${del.error.message}`);
        // A deleted sale must also drop its orphaned line items.
        if (table === 'sales') {
          const delItems = await db.from('sale_items')
            .delete().eq('customer_id', auth.customerId)
            .eq('sale_id', entityId);
          if (delItems.error) throw new Error(`delete sale_items: ${delItems.error.message}`);
        }
        applied++;
        results.push({ entityId, status: 'applied' });
        continue;
      }

      // Collect the rows this entry writes: sale = header + items, rest = 1 row.
      const rows: { table: string; row: any }[] = [];
      const p = entry.payload ?? {};
      switch (table) {
        case 'sales':
          if (p.sale) rows.push({ table: 'sales', row: p.sale });
          for (const it of (Array.isArray(p.items) ? p.items : [])) {
            rows.push({ table: 'sale_items', row: it });
          }
          break;
        case 'shifts': if (p.shift) rows.push({ table: 'shifts', row: p.shift }); break;
        case 'cash_movements': if (p.cash_movement) rows.push({ table: 'cash_movements', row: p.cash_movement }); break;
        case 'void_requests': if (p.void_request) rows.push({ table: 'void_requests', row: p.void_request }); break;
      }

      for (const { table: t, row } of rows) {
        // Stamp, never trust: the license decides ownership, not the payload.
        const stamped = { ...row, customer_id: auth.customerId, received_at: receivedAt };
        const up = await db.from(t)
          .upsert(stamped, { onConflict: 'id,customer_id' });
        if (up.error) throw new Error(`upsert ${t}: ${up.error.message}`);
      }
      applied++;
      results.push({ entityId, status: 'applied' });
    } catch (err: any) {
      // A transient failure for ONE entry must not abort the batch or get the
      // entry acked; report 'failed' so the client leaves only it queued.
      results.push({ entityId, status: 'failed', error: String(err?.message ?? err) });
    }
  }
  // Transition safety: a batch with any transiently-'failed' entry reports
  // ok:false so BOTH the new per-entry-ack client and the older deployed tills
  // (which ack the whole batch on ok:true) retry rather than silently drop the
  // failed rows. Re-applied 'applied' rows are idempotent upserts, so the
  // retry is harmless. 'rejected' (unknown type) never counts as retryable.
  const anyFailed = results.some((r) => r.status === 'failed');
  return json({
    ok: !anyFailed,
    applied,
    results,
    error: anyFailed ? 'Some entries failed to apply.' : undefined,
  });
}

// ---------------------------------------------------------------------------
// Action: pull — delta feed for future multi-register/devices (Phase 18 ships
// the endpoint; the till does not call it yet, phones/dashboard will).
// ---------------------------------------------------------------------------
async function pull(db: any, auth: { customerId: string }, body: any): Promise<Response> {
  // Cursor is either a keyset {received_at, id} (preferred, exact pagination)
  // or a bare `since` ISO timestamp (legacy first page). received_at alone is
  // ambiguous because a push stamps every row it applied with one timestamp, so
  // the id tiebreaker makes the walk strictly ordered and gap-free.
  const cursor = body.cursor && typeof body.cursor === 'object' ? body.cursor : null;
  const since = String(body.since ?? '');
  if (!cursor && (!since || Number.isNaN(Date.parse(since)))) {
    return json({ ok: false, error: 'since (ISO timestamp) or cursor required.' }, 400);
  }
  const wanted: string[] = Array.isArray(body.tables) && body.tables.length > 0
    ? body.tables.filter((t: string) => TABLES.includes(t as any))
    : [...TABLES];
  // Rows per table per page. Callers loop on has_more/next_cursor so a busy
  // tenant's backlog is delivered in full rather than silently truncated at a
  // hard cap (audit #12: skipped rows / no pagination).
  const pageLimit = Math.min(Math.max(Number(body.limit) || 1000, 1), 1000);

  const changes: Record<string, unknown[]> = {};
  let maxReceived = '';
  let maxId = '';
  let hasMore = false;
  for (const t of wanted) {
    let q = db.from(t).select('*').eq('customer_id', auth.customerId);
    if (cursor) {
      const cAt = String(cursor.received_at ?? '');
      const cId = String(cursor.id ?? '');
      q = q.or(`received_at.gt.${cAt},and(received_at.eq.${cAt},id.gt.${cId})`);
    } else {
      q = q.gt('received_at', since);
    }
    const { data, error } = await q
      .order('received_at', { ascending: true })
      .order('id', { ascending: true })
      .limit(pageLimit);
    if (error) throw new Error(`pull ${t}: ${error.message}`);
    const rows = data ?? [];
    changes[t] = rows;
    if (rows.length === pageLimit) hasMore = true;
    const last = rows[rows.length - 1];
    if (last && String(last.received_at) >= maxReceived) {
      maxReceived = String(last.received_at);
      maxId = String(last.id);
    }
  }
  const nextCursor = maxReceived
    ? { received_at: maxReceived, id: maxId }
    : null;
  return json({
    ok: true, changes, server_time: new Date().toISOString(),
    next_cursor: nextCursor, has_more: hasMore,
  });
}

// ---------------------------------------------------------------------------
// Action: ping — cheap "is my seat still valid / server reachable" probe.
// ---------------------------------------------------------------------------
async function ping(db: any, auth: { customerId: string; code: string }): Promise<Response> {
  const { count } = await db.from('device_registrations')
    .select('*', { count: 'exact', head: true })
    .eq('activation_code', auth.code).is('revoked_at', null);
  return json({ ok: true, customer_id: auth.customerId, seats_active: count ?? 0 });
}

// ---------------------------------------------------------------------------
// Helpers (base64url + hex; verification canonicalization already happened
// inside the signed bytes — we parse the payload as-is, the SIGNATURE is over
// the exact bytes the licensing function canonicalized, so re-encoding is
// never needed here.)
// ---------------------------------------------------------------------------
function base64UrlDecode(s: string): Uint8Array {
  const pad = s.length % 4 === 0 ? '' : '='.repeat(4 - (s.length % 4));
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/');
  const bin = atob(b64 + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function hexToBytes(hex: string): Uint8Array {
  const clean = hex.trim();
  const out = new Uint8Array(clean.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(clean.substring(i * 2, i * 2 + 2), 16);
  }
  return out;
}
function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status, headers: { 'Content-Type': 'application/json' },
  });
}
