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
//     - activate_device    : redeem an activation code on a device
//                            (one code = one business, UNLIMITED devices)
//     - list_devices       : DEPRECATED (410) — device management moved to
//                            the owner-authenticated `pos-api` actions
//     - deactivate_device  : DEPRECATED (410) — same
//     - redeem_voucher     : DEPRECATED (410) — seat vouchers are legacy;
//                            devices are unlimited so no seat expansion
//                            is ever needed
//
//   Activation is the ONLY live action here. It is rate-limited through the
//   durable `rate_limit_hit` RPC (database-backed, survives restarts and is
//   shared across instances) keyed by an HMAC digest of the activation code —
//   raw codes are never stored.
//
//   The signed license returned by activate_device is the same format the
//   Dart client already verifies (see lib/core/licensing/license_validator.dart),
//   just with `version: 2` and the extra `customer_id` / `device_fingerprint`
//   / `activation_code` fields.
//
//   The whole activation decision (revoked/expired checks, idempotent
//   fingerprint handling, reactivation, insert) runs inside the
//   `register_device` SECURITY DEFINER RPC under a license-row lock, so it
//   is atomic and safe under concurrent requests — including a revocation
//   racing an activation.

import { ed25519 } from "https://esm.sh/@noble/curves@1.4.0/ed25519";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

// A missing secret used to surface as a key of "undefined": every activation
// would then mint an unverifiable license. Fail at start-up instead of quietly
// serving an insecure function.
function requireEnv(name: string, minLength = 16): string {
  const v = Deno.env.get(name);
  if (!v || v.length < minLength) {
    throw new Error(`Env var ${name} missing or too short (min ${minLength}).`);
  }
  return v;
}

const SUPABASE_URL = requireEnv("SUPABASE_URL");
const SERVICE_KEY = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
const SEED_B64URL = requireEnv("LICENSE_SIGNING_SEED_B64URL", 32);

// Keyed hash for rate-limit bucket ids. HMAC-SHA256 with the service key (or
// an explicit override) means the bucket table never stores a value that can
// be reversed into an activation code, username, or IP.
const RATE_LIMIT_HASH_KEY = Deno.env.get("RATE_LIMIT_HASH_KEY") || SERVICE_KEY;

// Activation attempts per activation code per 10 minutes. Generous for a
// legitimate buyer re-activating a handful of devices, tight enough that
// code probing is impractical.
const ACTIVATE_LIMIT = 30;
const ACTIVATE_WINDOW_SECONDS = 600;
// Source-based bounds (Request 2 review): the per-code limit above does NOT
// stop an attacker rotating through many candidate codes, because every new
// code gets a fresh bucket. These two buckets close that hole:
//   * per-source — every activation attempt is charged against the address
//     the platform edge reports (see trustedSourceAddress), so one probing
//     host is bounded no matter how many codes it tries;
//   * global — a backstop that bounds total activation traffic even if the
//     source cannot be determined (or an attacker controls many addresses).
const ACTIVATE_SOURCE_LIMIT = 120;
const ACTIVATE_GLOBAL_LIMIT = 2000;
const ACTIVATE_SOURCE_WINDOW_SECONDS = 600;

// Input ceilings — the public endpoint must not accept unbounded strings.
const MAX_CODE_LEN = 128;
const MAX_FINGERPRINT_LEN = 256;
const MAX_DEVICE_NAME_LEN = 200;

// Fail loudly (not to the client) when the signing seed is malformed: every
// activation would otherwise mint a license that cannot verify.
{
  const seedBytes = SEED_B64URL
    ? base64UrlDecode(SEED_B64URL)
    : new Uint8Array();
  if (seedBytes.length !== 32) {
    throw new Error("LICENSE_SIGNING_SEED_B64URL is invalid.");
  }
}

export async function handleRequest(
  req: Request,
  db?: any,
): Promise<Response> {
  if (req.method !== "POST") {
    return json({ ok: false, error: "POST required" }, 405);
  }
  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "Invalid JSON" }, 400);
  }

  const client = db ??
    createClient(SUPABASE_URL, SERVICE_KEY, {
      auth: { persistSession: false },
    });
  // Trusted client address, resolved ONCE per request at the verified
  // platform boundary (see trustedSourceAddress). Only the activation
  // action consumes it today.
  const source = trustedSourceAddress(req);

  try {
    switch (body.action) {
      case "activate_device":
        return await activateDevice(client, body, source);
      case "list_devices":
      case "deactivate_device":
      case "redeem_voucher":
        return deprecatedAction(body.action);
      default:
        return json(
          { ok: false, error: `Unknown action: ${body.action}` },
          400,
        );
    }
  } catch (err) {
    // Never leak internal error text (SQL fragments, stack traces) to the client.
    console.error("licensing function error:", err);
    return json({ ok: false, error: "Internal error." }, 500);
  }
}

// Guarded so tests can import handleRequest without binding a port; the Edge
// Runtime loads this file as the main module, so the server still starts in
// production.
if (import.meta.main) {
  Deno.serve((req) => handleRequest(req));
}

// ---------------------------------------------------------------------------
// Durable rate limiting (shared by every public action on this function)
// ---------------------------------------------------------------------------
async function hmacHex(data: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(RATE_LIMIT_HASH_KEY),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(data),
  );
  return Array.from(new Uint8Array(sig))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/// Returns a 429 Response when the durable limiter refuses, else null.
/// Fails CLOSED: if the limiter itself is unreachable the activation cannot
/// be proven safe, so the request is rejected like any other internal error.
async function rateLimited(
  db: any,
  scope: string,
  subject: string,
  limit: number,
  windowSeconds: number,
): Promise<Response | null> {
  const key = await hmacHex(`${scope}|${subject}`);
  const { data, error } = await db.rpc("rate_limit_hit", {
    p_key: key,
    p_limit: limit,
    p_window_seconds: windowSeconds,
    p_charge: true,
  });
  if (error) {
    console.error("rate_limit_hit error:", error);
    return json({ ok: false, error: "Internal error." }, 500);
  }
  const r = data as any;
  if (r && r.allowed === false) {
    return json({
      ok: false,
      error: `Too many attempts. Retry in ${
        r.retry_after_seconds ?? windowSeconds
      }s.`,
      retry_after_seconds: r.retry_after_seconds ?? windowSeconds,
    }, 429);
  }
  return null;
}

// ---------------------------------------------------------------------------
// Trusted client address
// ---------------------------------------------------------------------------
// Supabase's edge gateway sits in front of this function and appends the
// verified peer address to X-Forwarded-For. A client CAN prepend its own
// forged entries, but it cannot append to the RIGHT of what the platform
// adds — so the rightmost entry is the only hop we can trust. Entries to
// its left are attacker-controlled and ignored. When the header is absent
// or the last entry is not an IP literal we return null and the caller
// falls back to the shared "unknown" + global buckets, which still bound
// the endpoint — fail-safe, never fail-open.
const IP_LITERAL = /^[0-9a-fA-F:.%[\]]{3,45}$/;
function trustedSourceAddress(req: Request): string | null {
  const xff = req.headers.get("x-forwarded-for");
  if (!xff) return null;
  const parts = xff.split(",").map((s) => s.trim()).filter((s) => s.length);
  const last = parts[parts.length - 1];
  if (!last || !IP_LITERAL.test(last)) return null;
  return last;
}

// ---------------------------------------------------------------------------
// Action: activate_device
// ---------------------------------------------------------------------------
// Input: { action, activation_code, device_fingerprint, device_name? }
// Output on success: { ok, license_code, expires_at, seat_limit, seats_used }
// Output on refusal: { ok:false, error, seat_limit?, seats_used? }
async function activateDevice(
  db: any,
  body: any,
  source: string | null,
): Promise<Response> {
  const code = str(body.activation_code);
  const fingerprint = str(body.device_fingerprint);
  const deviceName = str(body.device_name) || "Unknown device";
  if (!code || !fingerprint) {
    return json({ ok: false, error: "Missing fields" }, 400);
  }
  if (
    code.length > MAX_CODE_LEN || fingerprint.length > MAX_FINGERPRINT_LEN ||
    deviceName.length > MAX_DEVICE_NAME_LEN
  ) {
    return json({ ok: false, error: "Field too long." }, 400);
  }

  // Durable throttles BEFORE any license work. Three independent buckets,
  // all keyed by HMAC digests (raw codes and IPs are never stored):
  //   1. per-source — bounds code probing from one address regardless of
  //      how many distinct candidate codes are submitted;
  //   2. global — bounds total activation traffic even when no trustworthy
  //      source exists;
  //   3. per-code — the original bound on retries against one code.
  const srcLimited = await rateLimited(
    db,
    "lic:activate:src",
    source ?? "unknown",
    ACTIVATE_SOURCE_LIMIT,
    ACTIVATE_SOURCE_WINDOW_SECONDS,
  );
  if (srcLimited) return srcLimited;
  const globLimited = await rateLimited(
    db,
    "lic:activate:any",
    "*",
    ACTIVATE_GLOBAL_LIMIT,
    ACTIVATE_SOURCE_WINDOW_SECONDS,
  );
  if (globLimited) return globLimited;
  const limited = await rateLimited(
    db,
    "lic:activate",
    code,
    ACTIVATE_LIMIT,
    ACTIVATE_WINDOW_SECONDS,
  );
  if (limited) return limited;

  // The ENTIRE decision — code lookup, revoked/expired checks, idempotent
  // fingerprint refresh, safe reactivation, and the insert — happens inside
  // register_device under a license-row lock. There is deliberately no
  // check-then-insert fallback here anymore: that path was the non-atomic
  // seat bypass this request removes.
  const { data: res, error: rpcErr } = await db.rpc("register_device", {
    p_activation_code: code,
    p_device_fingerprint: fingerprint,
    p_device_name: deviceName,
  });
  if (rpcErr) {
    console.error("register_device error:", rpcErr);
    return json({ ok: false, error: "Internal error." }, 500);
  }
  const r = res as any;

  switch (r.status) {
    case "not_found":
      return json({ ok: false, error: "Invalid activation code." }, 404);
    case "revoked":
      return json({ ok: false, error: "License revoked." }, 403);
    case "expired":
      return json({ ok: false, error: "License expired." }, 403);
  }
  // activated | reactivated | refreshed -> mint a signed license for this device.
  if (r.status === "activated" || r.status === "reactivated") {
    await writeAudit(db, code, fingerprint, "activate", {
      device_name: deviceName,
    });
  }
  const seatsUsed: number = r.seats_used;

  // Build the license payload. Canonicalization matches Dart's
  // `jsonEncode(_canonicalize(payload))` byte-for-byte: keys sorted
  // recursively, no whitespace, UTF-8.
  const issued = new Date();
  // Cap at the license's own expiry if the customer is on a paid subscription;
  // otherwise default to a rolling 1-year device license (re-checkable on
  // next activation after expiry).
  const hardExpiry = r.expires_at ? new Date(r.expires_at) : null;
  const rolling = new Date(issued.getTime() + 365 * 24 * 3600 * 1000);
  const expires = hardExpiry && hardExpiry < rolling ? hardExpiry : rolling;

  const payload: Record<string, unknown> = {
    format: "wholesale-pos-license",
    version: 2,
    product: "wholesale_pos",
    entitlements: ["pos"],
    activation_code: code,
    customer_id: r.customer_id,
    device_fingerprint: fingerprint,
    issued_at: isoNoMillis(issued),
    expires_at: isoNoMillis(expires),
  };
  const canonicalBytes = new TextEncoder().encode(canonicalJson(payload));
  const seed = base64UrlDecode(SEED_B64URL);
  const signature = ed25519.sign(canonicalBytes, seed);
  const licenseCode = `${base64UrlEncode(canonicalBytes)}.${
    base64UrlEncode(signature)
  }`;

  return json({
    ok: true,
    license_code: licenseCode,
    expires_at: payload.expires_at,
    seat_limit: r.seat_limit,
    seats_used: seatsUsed,
  });
}

// ---------------------------------------------------------------------------
// Deprecated actions: list_devices / deactivate_device / redeem_voucher
// ---------------------------------------------------------------------------
// Device management moved behind the owner-authenticated `pos-api` surface
// (JWT + OWNER role + token-version check, tenant-scoped, masked
// fingerprints). Leaving these endpoints live would keep an
// unauthenticated path — a bare activation code plus a device fingerprint —
// into the same data, which is exactly the hole this request closes. Seat
// vouchers are deprecated outright: devices are unlimited, so there is
// nothing left to buy.
function deprecatedAction(action: string): Response {
  const messages: Record<string, string> = {
    list_devices:
      "Device listing moved to the owner sign-in on the Devices screen " +
      "(pos-api). Sign in as the shop owner to manage devices.",
    deactivate_device:
      "Device deactivation moved to the owner sign-in on the Devices " +
      "screen (pos-api). Sign in as the shop owner to manage devices.",
    redeem_voucher:
      "Seat vouchers are deprecated: one activation code now covers " +
      "unlimited devices, so there are no seats left to purchase.",
  };
  return json({
    ok: false,
    error: messages[action] ?? "This action is deprecated.",
    deprecated: true,
  }, 410);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
async function writeAudit(
  db: any,
  code: string,
  fp: string | null,
  event: string,
  detail: any,
) {
  const { error } = await db.from("license_audit").insert({
    activation_code: code,
    device_fingerprint: fp,
    event,
    detail,
  });
  if (error) {
    console.error("license_audit insert failed:", error.message, {
      event,
      code,
    });
    // Do not throw — a buyer whose activation succeeded must receive their
    // license even if the audit row failed to insert. The failure is logged
    // for operators; the license is returned normally.
  }
}

function str(v: unknown): string {
  return typeof v === "string" ? v.trim() : "";
}

function mask(fp: string): string {
  return fp.length <= 8 ? fp : `${fp.slice(0, 4)}…${fp.slice(-4)}`;
}

// Same shape Dart writes: no millisecond fraction, 'Z' suffix (parseable by
// DateTime.tryParse as UTC).
function isoNoMillis(d: Date): string {
  return d.toISOString().replace(/\.\d{3}Z$/, "Z");
}

// Recursive object-key sort, no whitespace. Matches Dart's _canonicalize().
function canonicalJson(value: unknown): string {
  return JSON.stringify(canonicalize(value));
}
function canonicalize(v: any): any {
  if (Array.isArray(v)) return v.map(canonicalize);
  if (v && typeof v === "object") {
    const keys = Object.keys(v).sort();
    const out: Record<string, unknown> = {};
    for (const k of keys) out[k] = canonicalize(v[k]);
    return out;
  }
  return v;
}

function base64UrlEncode(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function base64UrlDecode(str: string): Uint8Array {
  const pad = str.length % 4 === 0 ? "" : "=".repeat(4 - (str.length % 4));
  const b64 = str.replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(b64 + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
