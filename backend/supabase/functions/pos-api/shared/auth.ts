import type { Ctx } from "./types.ts";
import { audit, json, str, userStamp } from "./helpers.ts";
import { JWT_SECRET } from "./env.ts";
import { verifyStandaloneDeviceLicense } from "./license_proof.ts";

const PBKDF2_ITERATIONS = 210000;
const SESSION_TTL_SECONDS = 3650 * 24 * 3600; // ~10 years; matches SessionStore.defaultLifetime

// Verification accepts only these cost factors. A malformed or hostile stored
// value can no longer force an unbounded PBKDF2 run (CPU denial of service) or
// silently downgrade below the 10k floor. Legacy 210k hashes keep working.
const PBKDF2_SUPPORTED_ITERATIONS = new Set([10000, 210000, 300000]);

// Request/credential input bounds. These cap the work a single public request
// can ask for before any hashing or database lookup.
const MAX_PASSWORD_LENGTH = 256;
const MAX_USERNAME_LENGTH = 64;
const MAX_ACTIVATION_CODE_LENGTH = 128;
const MAX_LICENSE_LENGTH = 8192;

// Actor grants are delegated, device-bound credentials for the sync gateway.
// 30 days balances a shop till that may be offline for weeks against the value
// of an eventually stale token; the DB also invalidates on token_version.
const ACTOR_GRANT_TTL_SECONDS = 30 * 24 * 3600;

const OWNER = "OWNER";
const CASHIER = "CASHIER";

const FEATURE_KEYS = new Set([
  "dashboard",
  "pos",
  "register",
  "finance",
  "warehouse",
  "warehouse_fill",
  "history",
  "reports",
  "users",
  "audit",
  "register_history",
]);

const OWNER_ONLY = new Set([
  "void_sale",
  "approve_void",
  "reject_void",
  "list_void_requests",
  "reset_password",
  "set_user_active",
  "create_user",
  "set_user_permissions",
  "set_user_phone",
  "delete_user",
  "list_devices",
  "deactivate_device",
]);

const ACTION_FEATURES: Record<string, string[]> = {
  dashboard_summary: ["dashboard"],
  revenue_trend: ["dashboard"],
  list_products: ["pos"],
  save_product: ["pos"],
  update_product: ["pos"],
  deactivate_product: ["pos"],
  reactivate_product: ["pos"],
  next_receipt_number: ["pos"],
  insert_sale: ["pos"],
  get_shift: ["register"],
  ensure_shift: ["register"],
  register_snapshot: ["register"],
  open_shift: ["register"],
  close_shift: ["register"],
  add_cash_movement: ["register"],
  shift_summary: ["register"],
  finance_categories: ["finance"],
  finance_deleted_categories: ["finance"],
  finance_summaries: ["finance"],
  finance_create_category: ["finance"],
  finance_rename_category: ["finance"],
  finance_delete_category: ["finance"],
  finance_restore_category: ["finance"],
  finance_permanently_delete_category: ["finance"],
  finance_add_entry: ["finance"],
  finance_update_entry: ["finance"],
  finance_mark_completed: ["finance"],
  finance_delete_entry: ["finance"],
  finance_search_entries: ["finance"],
  finance_person_totals: ["finance"],
  list_picklists: ["warehouse", "warehouse_fill"],
  get_picklist_items: ["warehouse", "warehouse_fill"],
  create_picklist: ["warehouse"],
  update_picklist_items: ["warehouse"],
  update_picklist_item: ["warehouse", "warehouse_fill"],
  delete_picklist_item: ["warehouse", "warehouse_fill"],
  delete_picklist: ["warehouse", "warehouse_fill"],
  get_customers: ["warehouse"],
  add_customer: ["warehouse"],
  toggle_picklist_item: ["warehouse", "warehouse_fill"],
  search_sales: ["history", "register_history"],
  request_void: ["pos", "history", "register_history"],
  report_summary: ["reports"],
  list_users: ["users"],
  list_audit: ["audit"],
  shift_history: ["register_history"],
  list_cash_movements: ["register_history"],
};

// --- Durable login throttle (audit #14, Request 2) -------------------------
// The old limiter was an in-memory Map: every cold start (and every extra
// function instance) reset it, so it never actually bounded a distributed
// attacker. Limits now live in `rate_limit_buckets` behind the atomic
// `rate_limit_hit` / `rate_limit_reset` RPCs — they survive restarts,
// concurrent hits cannot bypass them, and bucket keys are HMAC-SHA256
// digests so no raw username, activation code, or IP is stored.
const LOGIN_MAX_ATTEMPTS = 10;
const LOGIN_WINDOW_SECONDS = 60;
// Public-endpoint probing bound: every unauthenticated action is also
// throttled per activation code BEFORE the license lookup, so enumerating
// valid codes is bounded even when the code itself is wrong.
const PROBE_LIMIT = 60;
const PROBE_WINDOW_SECONDS = 60;
const SETUP_LIMIT = 5;
const SETUP_WINDOW_SECONDS = 300;
// Source-hint bound for the UNAUTHENTICATED actions (login, setup_owner,
// has_users). The per-code probe limit cannot stop an attacker rotating
// through many activation codes or usernames from one address; this bucket
// adds a bound keyed on a best-effort XFF hint (see
// bestEffortSourceAddress — the hosted ingress contract is unverified, so
// this is NOT a trusted identity and a header-forging client can rotate
// buckets). The global bucket is the actual backstop and applies whether or
// not a usable hint exists.
const PUBLIC_SOURCE_LIMIT = 240;
const PUBLIC_GLOBAL_LIMIT = 5000;
const PUBLIC_WINDOW_SECONDS = 60;

// The global bucket is sharded so every unauthenticated request in the fleet
// does not contend on one `rate_limit_buckets` row. The total ceiling is still
// PUBLIC_GLOBAL_LIMIT per window; each shard carries an equal share. Residual:
// a caller that rotates its source hint spreads across shards, so this bounds
// a single shard rather than the whole fleet in one counter. The per-source
// and per-code limits remain the tighter, identity-keyed bounds.
const PUBLIC_GLOBAL_SHARDS = 8;
const PUBLIC_GLOBAL_LIMIT_PER_SHARD = Math.ceil(
  PUBLIC_GLOBAL_LIMIT / PUBLIC_GLOBAL_SHARDS,
);

/// Stable, non-cryptographic shard pick. Only distributes load; it is not an
/// identity or a security boundary.
function shardOf(value: string, shards: number): number {
  let h = 0;
  for (let i = 0; i < value.length; i++) {
    h = (h * 31 + value.charCodeAt(i)) >>> 0;
  }
  return h % shards;
}

async function rateLimitKey(scope: string, subject: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(JWT_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`${scope}|${subject}`),
  );
  return Array.from(new Uint8Array(sig))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function rateLimitAllow(
  db: any,
  scope: string,
  subject: string,
  limit: number,
  windowSeconds: number,
  charge: boolean,
): Promise<{ allowed: boolean; retryAfter: number }> {
  const { data, error } = await db.rpc("rate_limit_hit", {
    p_key: await rateLimitKey(scope, subject),
    p_limit: limit,
    p_window_seconds: windowSeconds,
    p_charge: charge,
  });
  if (error) throw new Error(error.message);
  const r = (data ?? {}) as Record<string, unknown>;
  return {
    allowed: r.allowed !== false,
    retryAfter: Number(r.retry_after_seconds ?? windowSeconds),
  };
}

async function rateLimitClear(db: any, scope: string, subject: string) {
  try {
    await db.rpc("rate_limit_reset", {
      p_key: await rateLimitKey(scope, subject),
    });
  } catch { /* a stale bucket is harmless */ }
}

function tooManyAttempts(retryAfter: number): Response {
  return json({
    ok: false,
    error: `Too many attempts. Retry in ${retryAfter}s.`,
    retry_after_seconds: retryAfter,
  }, 429);
}

// Durable per-source-hint + global throttle applied to every
// unauthenticated action BEFORE dispatch. Charged on each call; the
// per-code probe limits inside the handlers still apply on top. The source
// bucket is best-effort (unverified XFF hint) — the global bucket is the
// guarantee.
async function publicSourceAllowed(
  db: any,
  source: string | null,
): Promise<Response | null> {
  const src = await rateLimitAllow(
    db,
    "posapi:pubsrc",
    source ?? "unknown",
    PUBLIC_SOURCE_LIMIT,
    PUBLIC_WINDOW_SECONDS,
    true,
  );
  if (!src.allowed) return tooManyAttempts(src.retryAfter);
  const shard = shardOf(source ?? "unknown", PUBLIC_GLOBAL_SHARDS);
  const glob = await rateLimitAllow(
    db,
    `posapi:pubany:${shard}`,
    "*",
    PUBLIC_GLOBAL_LIMIT_PER_SHARD,
    PUBLIC_WINDOW_SECONDS,
    true,
  );
  if (!glob.allowed) return tooManyAttempts(glob.retryAfter);
  return null;
}

// Probe bound applied BEFORE the license lookup on every unauthenticated
// action: bounds activation-code enumeration regardless of whether the code
// resolves. Every call is charged — these endpoints are rare in legitimate
// use, so the per-code ceiling is the enumeration bound.
async function probeAllowed(
  db: any,
  scope: string,
  activationCode: string,
): Promise<Response | null> {
  const chk = await rateLimitAllow(
    db,
    scope,
    activationCode,
    PROBE_LIMIT,
    PROBE_WINDOW_SECONDS,
    true,
  );
  return chk.allowed ? null : tooManyAttempts(chk.retryAfter);
}

// --- Phone-number identity ---------------------------------------------------
const PHONE_RE = /^0[79]\d{8}$/;
export const PHONE_INVALID =
  "Enter a valid phone number, for example 0912345678.";
function normalizePhone(raw: string): string | null {
  let n = raw.trim().replace(/[\s\-()]/g, "");
  if (n.startsWith("+251")) n = "0" + n.slice(4);
  else if (n.startsWith("251") && n.length === 12) n = "0" + n.slice(3);
  else if (/^[79]\d{8}$/.test(n)) n = "0" + n;
  return PHONE_RE.test(n) ? n : null;
}
function loginIdentifier(raw: string): string {
  const trimmed = raw.trim();
  if (trimmed.toLowerCase() === "demo") return "demo";
  return normalizePhone(trimmed) ?? trimmed;
}

// --- Crypto helpers (base64, URL-safe base64, timing-safe comparison) -------
function b64(bytes: Uint8Array): string {
  let s = "";
  for (const x of bytes) s += String.fromCharCode(x);
  return btoa(s);
}
function unB64(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function b64u(bytes: Uint8Array): string {
  return b64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function b64uStr(s: string): string {
  return b64u(new TextEncoder().encode(s));
}
function b64uToB64(s: string): string {
  return s.replace(/-/g, "+").replace(/_/g, "/") +
    "=".repeat((4 - (s.length % 4)) % 4);
}
function timingSafeEqualStr(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// --- Password hashing (PBKDF2) ----------------------------------------------
async function hashPassword(
  password: string,
): Promise<{ salt: string; hash: string }> {
  const saltBytes = new Uint8Array(16);
  crypto.getRandomValues(saltBytes);
  const salt = b64(saltBytes);
  const derived = await derive(password, saltBytes, PBKDF2_ITERATIONS);
  return { salt, hash: `${PBKDF2_ITERATIONS}$${b64(derived)}` };
}

async function verifyPassword(
  password: string,
  salt: string,
  stored: string,
): Promise<boolean> {
  // Bound the input before doing any work. A multi-megabyte password would
  // otherwise be fed straight into PBKDF2.
  if (typeof password !== "string" || password.length > MAX_PASSWORD_LENGTH) {
    return false;
  }
  if (typeof salt !== "string" || typeof stored !== "string") return false;
  // Exact legacy format: `<iterations>$<base64-hash>`. Anything else is a
  // malformed credential, not a reason to guess an iteration count.
  const match = /^(\d{1,7})\$([A-Za-z0-9+/]+={0,2})$/.exec(stored);
  if (!match) return false;
  const iterations = Number(match[1]);
  if (!PBKDF2_SUPPORTED_ITERATIONS.has(iterations)) return false;
  const expected = match[2];
  if (expected.length > 128) return false;
  let saltBytes: Uint8Array;
  try {
    saltBytes = unB64(salt);
  } catch {
    return false;
  }
  if (saltBytes.length === 0 || saltBytes.length > 64) return false;
  let derived: Uint8Array;
  try {
    derived = await derive(password, saltBytes, iterations);
  } catch {
    return false;
  }
  return timingSafeEqualStr(b64(derived), expected);
}

async function derive(
  password: string,
  salt: Uint8Array,
  iterations: number,
): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(password),
    "PBKDF2",
    false,
    ["deriveBits"],
  );
  const bits = await crypto.subtle.deriveBits(
    {
      name: "PBKDF2",
      salt: salt as unknown as ArrayBuffer,
      iterations,
      hash: "SHA-256",
    },
    key,
    256,
  );
  return new Uint8Array(bits);
}

// --- JWT signing/verification -------------------------------------------------
async function signJwt(
  claims: { sub: string; cid: string; role: string; tv: number },
): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "HS256", typ: "JWT" };
  const payload = { ...claims, iat: now, exp: now + SESSION_TTL_SECONDS };
  const head = b64uStr(JSON.stringify(header));
  const body = b64uStr(JSON.stringify(payload));
  const sig = await hmac(`${head}.${body}`);
  return `${head}.${body}.${sig}`;
}

async function verifyJwt(
  token: string,
): Promise<{ userId: string; customerId: string; tv: number } | null> {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  const expectSig = await hmac(`${parts[0]}.${parts[1]}`);
  if (!timingSafeEqualStr(expectSig, parts[2])) return null;
  let payload: any;
  try {
    payload = JSON.parse(atob(b64uToB64(parts[1])));
  } catch {
    return null;
  }
  if (
    !payload || typeof payload.exp !== "number" ||
    payload.exp * 1000 < Date.now()
  ) return null;
  if (!payload.sub || !payload.cid) return null;
  return {
    userId: String(payload.sub),
    customerId: String(payload.cid),
    tv: Number(payload.tv ?? 0),
  };
}

async function hmac(data: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(JWT_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(data),
  );
  return b64u(new Uint8Array(sig));
}

export interface Actor {
  role: string;
  tokenVersion: number;
  permissions: string[];
}
async function loadActiveUser(
  db: any,
  customerId: string,
  userId: string,
): Promise<Actor | null> {
  const { data } = await db.from("pos_users").select(
    "role, active, token_version, permissions",
  )
    .eq("customer_id", customerId).eq("id", userId).eq("active", true).is(
      "deleted_at",
      null,
    ).maybeSingle();
  if (!data) return null;
  const permissions = Array.isArray(data.permissions)
    ? data.permissions.map(String)
    : [];
  return {
    role: data.role,
    tokenVersion: Number(data.token_version ?? 0),
    permissions,
  };
}

// --- License checking ---------------------------------------------------------
type LicenseCheck =
  | { ok: true; customerId: string }
  | { ok: false; error: string };

async function licenseForActivationCode(
  db: any,
  code: string,
): Promise<LicenseCheck> {
  if (!code) return { ok: false, error: "Invalid activation code." };
  const { data, error } = await db
    .from("licenses").select("customer_id, revoked_at, expires_at")
    .eq("activation_code", code).maybeSingle();
  if (error) throw new Error(error.message);
  if (!data) return { ok: false, error: "Invalid activation code." };
  if (data.revoked_at) {
    return { ok: false, error: "This licence has been revoked." };
  }
  if (data.expires_at && Date.parse(String(data.expires_at)) < Date.now()) {
    return {
      ok: false,
      error:
        "This licence has expired. Check the expiry date on the Devices screen.",
    };
  }
  return { ok: true, customerId: String(data.customer_id) };
}

// --- Demo user seeding --------------------------------------------------------
const DEMO_PW_VERSION = "2";
const DEMO_ALPHABET = "abcdefghijkmnpqrstuvwxyz23456789";
function randomDemoPassword(): string {
  const bytes = new Uint8Array(14);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => DEMO_ALPHABET[b % DEMO_ALPHABET.length]).join(
    "",
  );
}

async function demoVersionMarked(
  db: any,
  customerId: string,
): Promise<boolean> {
  const { data, error } = await db.from("pos_settings").select("value")
    .eq("customer_id", customerId).eq("key", "demo_pw_version").maybeSingle();
  if (error) throw new Error(error.message);
  return data?.value === DEMO_PW_VERSION;
}

async function markDemoVersion(db: any, customerId: string): Promise<void> {
  const up = await db.from("pos_settings").upsert(
    { customer_id: customerId, key: "demo_pw_version", value: DEMO_PW_VERSION },
    { onConflict: "customer_id,key" },
  );
  if (up.error) throw new Error(up.error.message);
}

async function ensureDemoUser(
  db: any,
  customerId: string,
  ownerSession: boolean,
): Promise<string | null> {
  if (!ownerSession) return null;
  const marked = await demoVersionMarked(db, customerId);
  const { data: existing, error: readErr } = await db.from("pos_users").select(
    "id, pw_salt, pw_hash",
  )
    .eq("customer_id", customerId).eq("is_demo", true).maybeSingle();
  if (readErr) throw new Error(readErr.message);

  if (existing) {
    if (marked) return null;
    if (
      !(await verifyPassword("demo1234", existing.pw_salt, existing.pw_hash))
    ) {
      await markDemoVersion(db, customerId);
      return null;
    }
    const password = randomDemoPassword();
    const { salt, hash } = await hashPassword(password);
    const up = await db.from("pos_users").update(
      userStamp({ pw_salt: salt, pw_hash: hash }),
    )
      .eq("customer_id", customerId).eq("id", existing.id).select("id");
    if (up.error) throw new Error(up.error.message);
    if (!Array.isArray(up.data) || up.data.length !== 1) {
      throw new Error("Demo account could not be rotated.");
    }
    await markDemoVersion(db, customerId);
    return password;
  }

  const password = randomDemoPassword();
  const { salt, hash } = await hashPassword(password);
  const { data: byName, error: nameErr } = await db.from("pos_users").select(
    "id",
  )
    .eq("customer_id", customerId).ilike("username", "demo").maybeSingle();
  if (nameErr) throw new Error(nameErr.message);
  if (byName) {
    const up = await db.from("pos_users").update(
      userStamp({ is_demo: true, pw_salt: salt, pw_hash: hash }),
    )
      .eq("customer_id", customerId).eq("id", byName.id).select("id");
    if (up.error) throw new Error(up.error.message);
    if (!Array.isArray(up.data) || up.data.length !== 1) {
      throw new Error("Demo account could not be adopted.");
    }
  } else {
    const ins = await db.from("pos_users").insert({
      id: crypto.randomUUID(),
      customer_id: customerId,
      username: "demo",
      role: CASHIER,
      pw_salt: salt,
      pw_hash: hash,
      active: true,
      is_demo: true,
      permissions: ["pos", "register", "reports"],
    });
    if (ins.error) throw new Error(ins.error.message);
  }
  await markDemoVersion(db, customerId);
  return password;
}

// --- Has users check (unauthenticated) ---------------------------------------
async function hasUsers(db: any, body: any): Promise<Response> {
  const code = str(body.activation_code);
  if (code.length > MAX_ACTIVATION_CODE_LENGTH) {
    return json({ ok: false, error: "Invalid activation code." }, 400);
  }
  const blocked = await probeAllowed(db, "posapi:hasusers", code);
  if (blocked) return blocked;
  const lic = await licenseForActivationCode(db, code);
  if (!lic.ok) return json({ ok: false, error: lic.error }, 403);
  const customerId = lic.customerId;
  const { count } = await db.from("pos_users")
    .select("*", { count: "exact", head: true }).eq("customer_id", customerId)
    .is("deleted_at", null);
  return json({ ok: true, has_users: (count ?? 0) > 0 });
}

// --- Login (unauthenticated) -------------------------------------------------
async function login(db: any, body: any): Promise<Response> {
  const code = str(body.activation_code);
  const username = loginIdentifier(str(body.username));
  const password = String(body.password ?? "");
  if (!code || !username || !password) {
    return json({ ok: false, error: "Missing fields" }, 400);
  }
  if (
    code.length > MAX_ACTIVATION_CODE_LENGTH ||
    username.length > MAX_USERNAME_LENGTH ||
    password.length > MAX_PASSWORD_LENGTH
  ) {
    return json({ ok: false, error: "Invalid credentials." }, 400);
  }
  const blocked = await probeAllowed(db, "posapi:login", code);
  if (blocked) return blocked;
  const lic = await licenseForActivationCode(db, code);
  if (!lic.ok) return json({ ok: false, error: lic.error }, 403);
  const customerId = lic.customerId;

  const tkey = `${customerId}|${username.toLowerCase()}`;
  const pre = await rateLimitAllow(
    db,
    "posapi:loginfail",
    tkey,
    LOGIN_MAX_ATTEMPTS,
    LOGIN_WINDOW_SECONDS,
    false,
  );
  if (!pre.allowed) return tooManyAttempts(pre.retryAfter);

  const needle = username.toLowerCase().replace(/[%_]/g, "");
  const { data: user } = await db.from("pos_users")
    .select("*").eq("customer_id", customerId).ilike("username", needle)
    .eq("active", true).is("deleted_at", null).maybeSingle();
  if (!user) {
    await verifyPassword(
      password,
      "AAAAAAAAAAAAAAAAAAAAAA==",
      "210000$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    );
    await rateLimitAllow(
      db,
      "posapi:loginfail",
      tkey,
      LOGIN_MAX_ATTEMPTS,
      LOGIN_WINDOW_SECONDS,
      true,
    );
    return json({ ok: false, error: "Invalid credentials." }, 401);
  }

  const ok = await verifyPassword(password, user.pw_salt, user.pw_hash);
  if (!ok) {
    await rateLimitAllow(
      db,
      "posapi:loginfail",
      tkey,
      LOGIN_MAX_ATTEMPTS,
      LOGIN_WINDOW_SECONDS,
      true,
    );
    return json({ ok: false, error: "Invalid credentials." }, 401);
  }
  await rateLimitClear(db, "posapi:loginfail", tkey);

  let demoPassword: string | null = null;
  try {
    demoPassword = await ensureDemoUser(db, customerId, user.role === OWNER);
  } catch { /* non-fatal */ }

  const token = await signJwt({
    sub: user.id,
    cid: customerId,
    role: user.role,
    tv: Number(user.token_version ?? 0),
  });
  return json({
    ok: true,
    token,
    user_id: user.id,
    username: user.username,
    role: user.role,
    permissions: Array.isArray(user.permissions) ? user.permissions : [],
    customer_id: customerId,
    ...(user.role === OWNER && demoPassword
      ? { demo_password: demoPassword }
      : {}),
    expires_at: new Date(Date.now() + SESSION_TTL_SECONDS * 1000).toISOString(),
  });
}

// --- Actor grants (delegated sync credentials) ------------------------------
// A device licence proves the DEVICE, never the person. The sync gateway
// therefore refuses to attribute a staged sale/cash/finance row to a payload
// `cashier_id`/`created_by`. Instead the native client signs in with a
// password and asks for an opaque grant bound to (tenant, user, device); only
// its SHA-256 digest is stored. This action is the sole mint.
async function issueActorGrant(db: any, body: any): Promise<Response> {
  const license = String(body.license ?? "");
  const username = loginIdentifier(str(body.username));
  const password = String(body.password ?? "");
  if (!license || !username || !password) {
    return json({ ok: false, error: "Missing fields" }, 400);
  }
  if (
    license.length > MAX_LICENSE_LENGTH ||
    username.length > MAX_USERNAME_LENGTH ||
    password.length > MAX_PASSWORD_LENGTH
  ) {
    return json({ ok: false, error: "Invalid credentials." }, 400);
  }

  // The signed licence is verified end-to-end (signature, expiry, licence row,
  // active seat). A copied licence is a bearer document, but the PASSWORD is
  // still required below, so a stolen file alone cannot mint an actor grant.
  let proof;
  try {
    proof = await verifyStandaloneDeviceLicense(db, license);
  } catch (err) {
    console.error("grant licence verification error:", err);
    return json({ ok: false, error: "Internal error." }, 500);
  }
  if (!proof.ok) return json({ ok: false, error: proof.error }, proof.status);
  const customerId = proof.customerId;

  const blocked = await probeAllowed(db, "posapi:grant", proof.activationCode);
  if (blocked) return blocked;

  const tkey =
    `${customerId}|${proof.deviceFingerprint}|${username.toLowerCase()}`;
  const pre = await rateLimitAllow(
    db,
    "posapi:grantfail",
    tkey,
    LOGIN_MAX_ATTEMPTS,
    LOGIN_WINDOW_SECONDS,
    false,
  );
  if (!pre.allowed) return tooManyAttempts(pre.retryAfter);

  const needle = username.toLowerCase().replace(/[%_]/g, "");
  const { data: user } = await db.from("pos_users")
    .select("*").eq("customer_id", customerId).ilike("username", needle)
    .eq("active", true).is("deleted_at", null).maybeSingle();
  if (!user) {
    // Same constant-work dummy verify as login: a missing account and a wrong
    // password must not be distinguishable by timing.
    await verifyPassword(
      password,
      "AAAAAAAAAAAAAAAAAAAAAA==",
      "210000$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    );
    await rateLimitAllow(
      db,
      "posapi:grantfail",
      tkey,
      LOGIN_MAX_ATTEMPTS,
      LOGIN_WINDOW_SECONDS,
      true,
    );
    return json({ ok: false, error: "Invalid credentials." }, 401);
  }

  const ok = await verifyPassword(password, user.pw_salt, user.pw_hash);
  if (!ok) {
    await rateLimitAllow(
      db,
      "posapi:grantfail",
      tkey,
      LOGIN_MAX_ATTEMPTS,
      LOGIN_WINDOW_SECONDS,
      true,
    );
    return json({ ok: false, error: "Invalid credentials." }, 401);
  }
  await rateLimitClear(db, "posapi:grantfail", tkey);

  const rpc = await db.rpc("pos_issue_actor_grant", {
    p_customer: customerId,
    p_user: user.id,
    p_device_fingerprint: proof.deviceFingerprint,
    p_ttl_seconds: ACTOR_GRANT_TTL_SECONDS,
  });
  if (rpc.error) throw new Error(rpc.error.message);
  const data = (rpc.data ?? {}) as Record<string, unknown>;
  if (!data.grant) throw new Error("Grant was not issued.");
  await audit(
    db,
    customerId,
    user.id,
    "ACTOR_GRANT_ISSUED",
    `Sync actor grant issued for device ${
      proof.deviceFingerprint.slice(0, 8)
    }…`,
  );
  return json({
    ok: true,
    grant: data.grant,
    expires_at: data.expires_at,
    user_id: user.id,
    role: user.role,
    customer_id: customerId,
  });
}

/// Best-effort grant revocation. Token-version bumps already invalidate grants
/// for credential/status changes; this reclaims the rows and covers device
/// deactivation, which does not change token_version.
async function revokeActorGrants(
  db: any,
  customerId: string,
  userId: string | null,
  deviceFingerprint: string | null,
): Promise<void> {
  try {
    const { error } = await db.rpc("pos_revoke_actor_grants", {
      p_customer: customerId,
      p_user: userId,
      p_device_fingerprint: deviceFingerprint,
    });
    if (error) console.error("actor grant revoke failed:", error.message);
  } catch (err) {
    console.error("actor grant revoke threw:", err);
  }
}

// --- Owner bootstrap (unauthenticated) ---------------------------------------
async function setupOwner(db: any, body: any): Promise<Response> {
  const code = str(body.activation_code);
  const rawName = str(body.username);
  const password = String(body.password ?? "");
  if (!code || !rawName || !password) {
    return json({ ok: false, error: "Missing fields" }, 400);
  }
  if (
    code.length > MAX_ACTIVATION_CODE_LENGTH ||
    rawName.length > MAX_USERNAME_LENGTH ||
    password.length > MAX_PASSWORD_LENGTH
  ) {
    return json({ ok: false, error: "Invalid account details." }, 400);
  }
  const username = normalizePhone(rawName);
  if (!username) return json({ ok: false, error: PHONE_INVALID }, 400);
  // A native till bootstraps its first owner OFFLINE and reconciles later: it
  // already minted a local user id and a cloud-format credential, so it sends
  // `user_id` + `pw_salt`/`pw_hash` instead of a plaintext password. The id
  // keeps local SQLite and cloud identity identical; the hash path is no
  // weaker than the password path (a caller who can supply a hash can supply
  // the password it was derived from). Everything is still gated by the
  // activation code + the one-owner policy inside pos_setup_owner.
  const requestedId = str(body.user_id);
  if (requestedId && !/^[0-9a-fA-F-]{16,64}$/.test(requestedId)) {
    return json({ ok: false, error: "Invalid account details." }, 400);
  }
  const preSalt = str(body.pw_salt);
  const preHash = str(body.pw_hash);
  const hasPreHashed = preSalt !== "" && preHash !== "";
  if (!hasPreHashed && !password) {
    return json({ ok: false, error: "Missing fields" }, 400);
  }
  const blocked = await probeAllowed(db, "posapi:setup", code);
  if (blocked) return blocked;
  const lic = await licenseForActivationCode(db, code);
  if (!lic.ok) return json({ ok: false, error: lic.error }, 403);
  const customerId = lic.customerId;

  let salt: string;
  let hash: string;
  if (hasPreHashed) {
    // Accept only the exact `<iterations>$<base64>` cloud credential format
    // pos-api itself issues, with a supported cost factor and a decodable
    // salt — anything else is refused rather than stored verbatim.
    const m = /^(\d{1,7})\$([A-Za-z0-9+/]+={0,2})$/.exec(preHash);
    const iterations = m ? Number(m[1]) : 0;
    let saltBytes: Uint8Array | null = null;
    try {
      saltBytes = unB64(preSalt);
    } catch { /* fall through to refusal */ }
    if (
      !m || !PBKDF2_SUPPORTED_ITERATIONS.has(iterations) ||
      m[2].length > 128 || !saltBytes || saltBytes.length === 0 ||
      saltBytes.length > 64
    ) {
      return json({ ok: false, error: "Invalid account details." }, 400);
    }
    salt = preSalt;
    hash = preHash;
  } else {
    const minLen = 12;
    if (password.length < minLen) {
      return json({
        ok: false,
        error: `Password must be at least ${minLen} characters.`,
      }, 400);
    }
    const hashed = await hashPassword(password);
    salt = hashed.salt;
    hash = hashed.hash;
  }
  // Owner bootstrap is the highest-value public action: a tight per-code
  // ceiling on top of the generic probe bound.
  const setupChk = await rateLimitAllow(
    db,
    "posapi:setupowner",
    code,
    SETUP_LIMIT,
    SETUP_WINDOW_SECONDS,
    true,
  );
  if (!setupChk.allowed) return tooManyAttempts(setupChk.retryAfter);
  const id = requestedId || crypto.randomUUID();
  const rpc = await db.rpc("pos_setup_owner", {
    p_customer: customerId,
    p_id: id,
    p_username: username,
    p_pw_salt: salt,
    p_pw_hash: hash,
  });
  if (rpc.error) {
    if (/already exists/i.test(rpc.error.message)) {
      // Tell the caller WHO the existing owner is so a native till can tell
      // "my own bootstrap already landed" (same id -> done) apart from a real
      // second-owner conflict. The activation code is already a tenant-wide
      // credential, so this reveals nothing a code-holder could not pull.
      const { data: existing } = await db.from("pos_users")
        .select("id, username").eq("customer_id", customerId)
        .eq("role", OWNER).is("deleted_at", null).maybeSingle();
      return json({
        ok: false,
        error: "Owner already exists.",
        owner_id: existing?.id ?? null,
        owner_username: existing?.username ?? null,
      }, 409);
    }
    throw new Error(rpc.error.message);
  }
  await audit(
    db,
    customerId,
    id,
    "OWNER_CREATED",
    `Web owner "${username}" created.`,
  );
  let demoPassword: string | null = null;
  try {
    demoPassword = await ensureDemoUser(db, customerId, true);
  } catch { /* non-fatal */ }
  const token = await signJwt({ sub: id, cid: customerId, role: OWNER, tv: 0 });
  return json({
    ok: true,
    token,
    user_id: id,
    username,
    role: OWNER,
    permissions: [],
    customer_id: customerId,
    ...(demoPassword ? { demo_password: demoPassword } : {}),
  });
}

// --- Change password ----------------------------------------------------------
async function changePassword(db: any, ctx: Ctx, body: any): Promise<Response> {
  const { data: user } = await db.from("pos_users")
    .select("*").eq("customer_id", ctx.customerId).eq("id", ctx.userId)
    .maybeSingle();
  if (!user) return json({ ok: false, error: "User not found." }, 404);
  const current = String(body.current_password ?? "");
  const next = String(body.new_password ?? "");
  if (
    current.length > MAX_PASSWORD_LENGTH || next.length > MAX_PASSWORD_LENGTH
  ) {
    return json({ ok: false, error: "Password is too long." }, 400);
  }
  if (!(await verifyPassword(current, user.pw_salt, user.pw_hash))) {
    return json({ ok: false, error: "Current password is incorrect." }, 401);
  }
  const minLen = user.role === OWNER ? 12 : 8;
  if (next.length < minLen) {
    return json({
      ok: false,
      error: `New password must be at least ${minLen} characters.`,
    }, 400);
  }
  const { salt, hash } = await hashPassword(next);
  const up = await db.from("pos_users").update(
    userStamp({
      pw_salt: salt,
      pw_hash: hash,
      token_version: (user.token_version ?? 0) + 1,
    }),
  )
    .eq("customer_id", ctx.customerId).eq("id", ctx.userId);
  if (up.error) throw new Error(up.error.message);
  // The token_version bump already makes every outstanding grant fail to
  // resolve; reclaim the rows as well.
  await revokeActorGrants(db, ctx.customerId, ctx.userId, null);
  await audit(
    db,
    ctx.customerId,
    ctx.userId,
    "PASSWORD_CHANGED",
    "Password changed.",
  );
  return json({ ok: true });
}

export {
  ACTION_FEATURES,
  b64,
  b64u,
  b64uStr,
  b64uToB64,
  CASHIER,
  changePassword,
  DEMO_ALPHABET,
  DEMO_PW_VERSION,
  demoVersionMarked,
  derive,
  ensureDemoUser,
  FEATURE_KEYS,
  hashPassword,
  hasUsers,
  hmac,
  issueActorGrant,
  licenseForActivationCode,
  loadActiveUser,
  login,
  loginIdentifier,
  markDemoVersion,
  normalizePhone,
  OWNER,
  OWNER_ONLY,
  PBKDF2_ITERATIONS,
  PBKDF2_SUPPORTED_ITERATIONS,
  publicSourceAllowed,
  randomDemoPassword,
  rateLimitAllow,
  rateLimitClear,
  rateLimitKey,
  revokeActorGrants,
  SESSION_TTL_SECONDS,
  setupOwner,
  signJwt,
  timingSafeEqualStr,
  unB64,
  userStamp,
  verifyJwt,
  verifyPassword,
};
