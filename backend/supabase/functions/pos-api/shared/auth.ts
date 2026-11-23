import type { Ctx } from "./types.ts";
import { audit, json, str, userStamp } from "./helpers.ts";
import { JWT_SECRET } from "./env.ts";

const PBKDF2_ITERATIONS = 210000;
const SESSION_TTL_SECONDS = 3650 * 24 * 3600; // ~10 years; matches SessionStore.defaultLifetime

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

// --- Best-effort login throttle (audit #14) --------------------------------
const LOGIN_MAX_ATTEMPTS = 10;
const LOGIN_WINDOW_MS = 60_000;
const LOGIN_LOCKOUT_MS = 300_000;
type LoginBucket = { fails: number; first: number; lockedUntil: number };
const loginAttempts = new Map<string, LoginBucket>();
function loginThrottleKey(customerId: string, username: string): string {
  return `${customerId}|${username.toLowerCase()}`;
}
function loginBlocked(key: string): number {
  const b = loginAttempts.get(key);
  if (!b) return 0;
  const now = Date.now();
  if (b.lockedUntil > now) return b.lockedUntil - now;
  if (now - b.first > LOGIN_WINDOW_MS) loginAttempts.delete(key);
  return 0;
}
function loginRecordFail(key: string) {
  const now = Date.now();
  const b = loginAttempts.get(key);
  if (!b || now - b.first > LOGIN_WINDOW_MS) {
    loginAttempts.set(key, { fails: 1, first: now, lockedUntil: 0 });
    return;
  }
  b.fails += 1;
  if (b.fails >= LOGIN_MAX_ATTEMPTS) b.lockedUntil = now + LOGIN_LOCKOUT_MS;
}
function loginClear(key: string) {
  loginAttempts.delete(key);
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
  const [iterStr, b64Hash] = stored.split("$");
  const iterations = Number(iterStr);
  if (!Number.isFinite(iterations) || iterations < 1000 || !b64Hash) {
    return false;
  }
  const derived = await derive(password, unB64(salt), iterations);
  return timingSafeEqualStr(b64(derived), b64Hash);
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
  const lic = await licenseForActivationCode(db, code);
  if (!lic.ok) return json({ ok: false, error: lic.error }, 403);
  const customerId = lic.customerId;

  const tkey = loginThrottleKey(customerId, username);
  const retryAfter = loginBlocked(tkey);
  if (retryAfter > 0) {
    return json({
      ok: false,
      error: `Too many attempts. Retry in ${Math.ceil(retryAfter / 1000)}s.`,
    }, 429);
  }

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
    loginRecordFail(tkey);
    return json({ ok: false, error: "Invalid credentials." }, 401);
  }

  const ok = await verifyPassword(password, user.pw_salt, user.pw_hash);
  if (!ok) {
    loginRecordFail(tkey);
    return json({ ok: false, error: "Invalid credentials." }, 401);
  }
  loginClear(tkey);

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

// --- Owner bootstrap (unauthenticated) ---------------------------------------
async function setupOwner(db: any, body: any): Promise<Response> {
  const code = str(body.activation_code);
  const rawName = str(body.username);
  const password = String(body.password ?? "");
  if (!code || !rawName || !password) {
    return json({ ok: false, error: "Missing fields" }, 400);
  }
  const username = normalizePhone(rawName);
  if (!username) return json({ ok: false, error: PHONE_INVALID }, 400);
  const lic = await licenseForActivationCode(db, code);
  if (!lic.ok) return json({ ok: false, error: lic.error }, 403);
  const customerId = lic.customerId;

  const minLen = 12;
  if (password.length < minLen) {
    return json({
      ok: false,
      error: `Password must be at least ${minLen} characters.`,
    }, 400);
  }
  const { salt, hash } = await hashPassword(password);
  const id = crypto.randomUUID();
  const rpc = await db.rpc("pos_setup_owner", {
    p_customer: customerId,
    p_id: id,
    p_username: username,
    p_pw_salt: salt,
    p_pw_hash: hash,
  });
  if (rpc.error) {
    if (/already exists/i.test(rpc.error.message)) {
      return json({ ok: false, error: "Owner already exists." }, 409);
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
  licenseForActivationCode,
  loadActiveUser,
  login,
  loginBlocked,
  loginClear,
  loginIdentifier,
  loginRecordFail,
  loginThrottleKey,
  markDemoVersion,
  normalizePhone,
  OWNER,
  OWNER_ONLY,
  PBKDF2_ITERATIONS,
  randomDemoPassword,
  SESSION_TTL_SECONDS,
  setupOwner,
  signJwt,
  timingSafeEqualStr,
  unB64,
  userStamp,
  verifyJwt,
  verifyPassword,
};
