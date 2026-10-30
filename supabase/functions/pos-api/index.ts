// Wholesale POS — pos-api Edge Function (PWA cloud backend, M2)
//
// The single authentication + data authority for the web/PWA build. Browsers
// never hold a Supabase key: they POST here with an Edge-Function-signed
// session JWT, and this function reads/writes the tenant's rows with the
// service role. `customer_id` is ALWAYS carved from the verified JWT (or, at
// login, from the shop's activation code via the licensing `customers`
// table) — never from a request body — so a client can neither read nor write
// another shop's partition, mirroring the audited `sync` gateway posture.
//
// Deployment (same pattern as `sync` / `licensing`):
//   supabase functions deploy pos-api --no-verify-jwt
//   supabase secrets set POS_API_JWT_SECRET=<long-random-hex>
//   (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are provided automatically.)
//   Apply docs/supabase_pos_users.sql first (adds pos_users + operational tables).
//
// Transport (POST /functions/v1/pos-api):
//   * Unauthenticated: { action: 'login' | 'setup_owner', ... }
//   * Authenticated:   header `Authorization: Bearer <jwt>` + { action, ... }
//   * Every response is { ok: true, ... } or { ok: false, error }.
//
// Security model:
//   * Passwords: PBKDF2-HMAC-SHA256, 210k rounds, per-user random salt, stored
//     base64 — identical policy to the native client (UserRepository) so a
//     provisioned account's strength is the same on both surfaces.
//   * Sessions: stateless HMAC-SHA256 JWT {sub, cid, role, exp}. No server
//     session store; a logout just drops the token client-side.
//   * Authorization: owner-vs-cashier is enforced here per action, not by
//     hiding navigation. Reads are always `.eq('customer_id', cid)` filtered.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const JWT_SECRET = Deno.env.get('POS_API_JWT_SECRET')!;

const PBKDF2_ITERATIONS = 210000;
// Persistent sign-in: the JWT is the browser's sole credential, so its
// lifetime mirrors SessionStore.defaultLifetime (effectively "never"). An
// operator stays signed in across browser restarts until they explicitly log
// out (which just drops the token client-side) or their account is deactivated
// (loadActiveUser then rejects the still-valid JWT on the next call).
const SESSION_TTL_SECONDS = 3650 * 24 * 3600; // ~10 years; matches SessionStore.defaultLifetime

// CORS: the browser/PWA build (e.g. https://web-xi-seven-15.vercel.app) POSTs
// here with `application/json` + an `Authorization: Bearer <jwt>` header, which
// makes the browser fire a preflight OPTIONS that ONLY this function can answer
// (Supabase does not add CORS for custom Edge Functions). No cookies/credentials
// ride along — per-tenant authority is the signed JWT, never the Origin — so a
// wildcard allow-origin is safe. Every response (via json()) carries these.
const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization, apikey, x-client-info',
  'Access-Control-Max-Age': '600',
};

const OWNER = 'OWNER';
const CASHIER = 'CASHIER';

// The canonical GRANTABLE feature-tab keys, mirroring
// app/lib/core/auth/features.dart. A staff account's `permissions` column stores
// a subset of these; the OWNER account bypasses them entirely.
const FEATURE_KEYS = new Set([
  'dashboard', 'pos', 'register', 'finance', 'history', 'reports',
  'users', 'audit', 'register_history',
]);

// Permanently owner-only: a feature tick NEVER grants these. Money-integrity
// and account-admin mutations stay reserved for the all-access OWNER account,
// regardless of which tabs a staff account can see.
const OWNER_ONLY = new Set([
  // Voids: a cashier may request_void, only an owner may void/approve/reject.
  'void_sale', 'approve_void', 'reject_void',
  // Reviewing the pending-void queue hydrates the whole sale behind every
  // request (items, totals, customer). That is an owner surface: a cashier
  // could otherwise read every other operator's sales from the Register tab.
  'list_void_requests',
  // Account administration + credential/status mutations.
  'reset_password', 'set_user_active', 'create_user', 'set_user_permissions',
  'set_user_phone', 'delete_user',
]);

// Feature-gated actions: allowed when the actor is an OWNER or holds ANY of the
// listed features. This replaces the old blanket OWNER_ONLY gate for the
// readable/navigable actions so per-account ticks actually take effect. Keys
// are action names; values are the feature keys that unlock them.
const ACTION_FEATURES: Record<string, string[]> = {
  // Dashboard
  dashboard_summary: ['dashboard'], revenue_trend: ['dashboard'],
  // POS / products
  list_products: ['pos'], save_product: ['pos'], update_product: ['pos'],
  deactivate_product: ['pos'], reactivate_product: ['pos'],
  next_receipt_number: ['pos'], insert_sale: ['pos'],
  // Register / shifts
  get_shift: ['register'], ensure_shift: ['register'], register_snapshot: ['register'],
  open_shift: ['register'], close_shift: ['register'], add_cash_movement: ['register'],
  // The close-drawer dialog summarizes the shift the cashier is closing, which
  // is always the OPEN one; shiftSummary() refuses any other shift for a
  // non-owner so this tick cannot be used to browse past sessions.
  shift_summary: ['register'],
  // Money Tracking: one tickable feature, all of it. The native repository
  // checks the same tick inside every method (reads included), so a staff
  // account reaches this area only when the owner ticked it for that account —
  // and loses it the moment the tick is removed, because the sync pull applies
  // the permission change to the till's own user row.
  finance_categories: ['finance'], finance_deleted_categories: ['finance'],
  finance_summaries: ['finance'], finance_create_category: ['finance'],
  finance_rename_category: ['finance'], finance_delete_category: ['finance'],
  finance_restore_category: ['finance'],
  finance_permanently_delete_category: ['finance'],
  finance_add_entry: ['finance'], finance_update_entry: ['finance'],
  finance_mark_completed: ['finance'], finance_search_entries: ['finance'],
  finance_person_totals: ['finance'],
  // History. search_sales is also needed by the Register History day drill-down
  // (which sales brought cash in that day), so register_history unlocks it too.
  search_sales: ['history', 'register_history'],
  // Requesting a void is a till action, not a history one: the cashier who rang
  // the sale asks for it from that sale's detail screen. Gating it on `history`
  // meant the default staff account (pos/register/reports) always got a 403.
  request_void: ['pos', 'history', 'register_history'],
  // Reports
  report_summary: ['reports'],
  // Users (read-only list; mutations are OWNER_ONLY above)
  list_users: ['users'],
  // Audit
  list_audit: ['audit'],
  // Register History (cross-shift ledger browsing)
  shift_history: ['register_history'], list_cash_movements: ['register_history'],
};

// get_setting / set_setting used to be served to every authenticated account
// with an arbitrary key, which let staff overwrite reserved server state — the
// demo-credential version marker included (audit 2 #4). The PWA keeps its
// preferences in browser storage and never called them, so they are gone.
// Server-only state (pos_settings.demo_pw_version) is written below by the
// service role, never by a client action.

Deno.serve(async (req) => {
  // Answer the browser's CORS preflight before the POST-only guard, otherwise
  // OPTIONS falls into the 405 branch with no allow-origin and the fetch aborts.
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== 'POST') return json({ ok: false, error: 'POST required' }, 405);
  let body: any;
  try { body = await req.json(); } catch { return json({ ok: false, error: 'Invalid JSON' }, 400); }

  const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
  const action = String(body.action ?? '');

  try {
    // --- Unauthenticated actions ---------------------------------------
    if (action === 'login') return await login(db, body);
    if (action === 'setup_owner') return await setupOwner(db, body);
    if (action === 'has_users') return await hasUsers(db, body);

    // --- Authenticated actions -----------------------------------------
    const cid = req.headers.get('authorization')?.replace(/^Bearer\s+/i, '') ?? body.token;
    const session = cid ? await verifyJwt(String(cid)) : null;
    if (!session) return json({ ok: false, error: 'Not signed in.' }, 401);
    // A revoked/deactivated cashier must lose access even on an unexpired JWT.
    const actor = await loadActiveUser(db, session.customerId, session.userId);
    if (!actor) return json({ ok: false, error: 'Session no longer valid.' }, 403);
    // Session revocation (audit #6): any credential change bumps the user's
    // token_version, so a JWT whose `tv` claim no longer matches is dead even
    // though its 10-year `exp` has not passed. Persistent sign-in is preserved
    // because we never shorten exp — only a tv mismatch kills the token.
    if (session.tv !== actor.tokenVersion) {
      return json({ ok: false, error: 'Session no longer valid.' }, 403);
    }
    if (OWNER_ONLY.has(action) && actor.role !== OWNER) {
      return json({ ok: false, error: 'Owner access required.' }, 403);
    }
    // Feature-tick enforcement: an OWNER passes everything; a staff account
    // only reaches actions whose feature it was ticked.
    const gated = ACTION_FEATURES[action];
    if (gated && actor.role !== OWNER && !gated.some((f) => actor.permissions.includes(f))) {
      return json({ ok: false, error: 'Not permitted for this account.' }, 403);
    }

    // Per-device identity for shift/receipt operations (audit D1). Optional:
    // empty -> NULL so the shared perpetual shift still matches.
    const deviceId = str(body.device_id) || null;
    const ctx = { customerId: session.customerId, userId: session.userId, role: actor.role, deviceId };

    switch (action) {
      // Auth-adjacent
      case 'change_password': return await changePassword(db, ctx, body);

      // Products / saved names
      case 'list_products': return await listProducts(db, ctx, body);
      case 'save_product': return await saveProduct(db, ctx, body);
      case 'update_product': return await updateProduct(db, ctx, body);
      case 'deactivate_product': return await setProductActive(db, ctx, body, 0);
      case 'reactivate_product': return await setProductActive(db, ctx, body, 1);

      // Sales
      case 'next_receipt_number': return await nextReceiptNumber(db, ctx);
      case 'insert_sale': return await insertSale(db, ctx, body);
      case 'search_sales': return await searchSales(db, ctx, body);
      case 'void_sale': return await voidSale(db, ctx, body);
      case 'request_void': return await requestVoid(db, ctx, body);
      case 'list_void_requests': return await listVoidRequests(db, ctx, body);
      case 'approve_void': return await decideVoid(db, ctx, body, 'APPROVED');
      case 'reject_void': return await decideVoid(db, ctx, body, 'REJECTED');

      // Shifts + cash
      case 'get_shift': return await getActiveShift(db, ctx);
      case 'ensure_shift': return await ensureShift(db, ctx);
      case 'register_snapshot': return await registerSnapshot(db, ctx, body);
      case 'shift_history': return await shiftHistory(db, ctx, body);
      case 'shift_summary': return await shiftSummary(db, ctx, body);
      case 'open_shift': return await openShift(db, ctx, body);
      case 'close_shift': return await closeShift(db, ctx, body);
      case 'add_cash_movement': return await addCashMovement(db, ctx, body);
      case 'list_cash_movements': return await listCashMovements(db, ctx, body);

      // Users
      case 'list_users': return await listUsers(db, ctx);
      case 'create_user': return await createUser(db, ctx, body);
      case 'set_user_permissions': return await setUserPermissions(db, ctx, body);
      case 'set_user_phone': return await setUserPhone(db, ctx, body);
      case 'reset_password': return await resetPassword(db, ctx, body);
      case 'set_user_active': return await setUserActive(db, ctx, body);
      case 'delete_user': return await deleteUser(db, ctx, body);

      // Finance
      case 'finance_categories': return await financeCategories(db, ctx);
      case 'finance_deleted_categories': return await financeDeletedCategories(db, ctx);
      case 'finance_summaries': return await financeSummaries(db, ctx);
      case 'finance_create_category': return await financeCreateCategory(db, ctx, body);
      case 'finance_rename_category': return await financeRenameCategory(db, ctx, body);
      case 'finance_delete_category': return await financeDeleteCategory(db, ctx, body);
      case 'finance_restore_category': return await financeRestoreCategory(db, ctx, body);
      case 'finance_permanently_delete_category': return await financePermanentlyDeleteCategory(db, ctx, body);
      case 'finance_add_entry': return await financeAddEntry(db, ctx, body);
      case 'finance_update_entry': return await financeUpdateEntry(db, ctx, body);
      case 'finance_mark_completed': return await financeMarkCompleted(db, ctx, body);
      case 'finance_search_entries': return await financeSearchEntries(db, ctx, body);
      case 'finance_person_totals': return await financePersonTotals(db, ctx, body);

      // Counters, reporting, audit. There is no client-writable key/value
      // surface: tenant settings are server-owned (audit 2 #4).
      case 'dashboard_summary': return await dashboardSummary(db, ctx, body);
      case 'revenue_trend': return await revenueTrend(db, ctx, body);
      case 'report_summary': return await reportSummary(db, ctx, body);
      case 'list_audit': return await listAudit(db, ctx, body);

      default: return json({ ok: false, error: `Unknown action: ${action}` }, 400);
    }
  } catch (err) {
    console.error('pos-api error:', err);
    return json({ ok: false, error: 'Internal error.' }, 500);
  }
});

// ===========================================================================
// Tenancy + authentication
// ===========================================================================

// Resolves an activation code to its tenant. The activation code is itself the
// shared secret proving tenancy (same trust the licensing/sync functions
// already place in it).
//
// ONE licence gate for every unauthenticated entry point (audit 2 #1).
// The licensing function has always refused a lapsed licence, but the POS
// authentication path used to check only `revoked_at`, so an expired shop
// could still sign in — and even bootstrap a new owner — through the PWA.
// `expires_at IS NULL` is the documented never-expiring licence.
type LicenseCheck =
  | { ok: true; customerId: string }
  | { ok: false; error: string };

async function licenseForActivationCode(db: any, code: string): Promise<LicenseCheck> {
  if (!code) return { ok: false, error: 'Invalid activation code.' };
  const { data, error } = await db
    .from('licenses').select('customer_id, revoked_at, expires_at')
    .eq('activation_code', code).maybeSingle();
  if (error) throw new Error(error.message);
  if (!data) return { ok: false, error: 'Invalid activation code.' };
  if (data.revoked_at) return { ok: false, error: 'This licence has been revoked.' };
  if (data.expires_at && Date.parse(String(data.expires_at)) < Date.now()) {
    return {
      ok: false,
      error: 'This licence has expired. Check the expiry date on the Devices screen.',
    };
  }
  return { ok: true, customerId: String(data.customer_id) };
}

// --- Best-effort login throttle (audit #14) --------------------------------
// Edge Functions share memory only within a warm container, so this is a blunt
// rate-limiter layered on top of the 210k-round PBKDF2 cost, NOT a durable
// cross-instance lockout. It still stops rapid-fire guessing against a single
// hot isolate, which is the realistic brute-force path for a hosted PWA.
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
function loginClear(key: string) { loginAttempts.delete(key); }

// --- Phone-number identity ---------------------------------------------------
// An account's login identifier is an Ethiopian mobile number kept in the
// `username` column in one canonical form: 0 + 9/7 + 8 digits. Anything a
// cashier can reasonably type is folded to that form. `demo` is the documented
// exception — the seeded training account keeps the literal identifier so a
// trainee only types `demo`.
const PHONE_RE = /^0[79]\d{8}$/;
const PHONE_INVALID = 'Enter a valid phone number, for example 0912345678.';
function normalizePhone(raw: string): string | null {
  let n = raw.trim().replace(/[\s\-()]/g, '');
  if (n.startsWith('+251')) n = '0' + n.slice(4);
  else if (n.startsWith('251') && n.length === 12) n = '0' + n.slice(3);
  else if (/^[79]\d{8}$/.test(n)) n = '0' + n;
  return PHONE_RE.test(n) ? n : null;
}
// Sign-in identifier: a normalised phone, `demo`, or a legacy value as typed so
// accounts created before phone-number login keep working until renamed.
function loginIdentifier(raw: string): string {
  const trimmed = raw.trim();
  if (trimmed.toLowerCase() === 'demo') return 'demo';
  return normalizePhone(trimmed) ?? trimmed;
}

async function hasUsers(db: any, body: any): Promise<Response> {
  const code = str(body.activation_code);
  const lic = await licenseForActivationCode(db, code);
  if (!lic.ok) return json({ ok: false, error: lic.error }, 403);
  const customerId = lic.customerId;
  const { count } = await db.from('pos_users')
    .select('*', { count: 'exact', head: true }).eq('customer_id', customerId)
    .is('deleted_at', null);
  return json({ ok: true, has_users: (count ?? 0) > 0 });
}

async function login(db: any, body: any): Promise<Response> {
  const code = str(body.activation_code);
  const username = loginIdentifier(str(body.username));
  const password = String(body.password ?? '');
  if (!code || !username || !password) return json({ ok: false, error: 'Missing fields' }, 400);
  const lic = await licenseForActivationCode(db, code);
  if (!lic.ok) return json({ ok: false, error: lic.error }, 403);
  const customerId = lic.customerId;

  // Brute-force throttle (audit #14): reject before deriving so a locked
  // account cannot be used to burn PBKDF2 CPU.
  const tkey = loginThrottleKey(customerId, username);
  const retryAfter = loginBlocked(tkey);
  if (retryAfter > 0) {
    return json({ ok: false, error: `Too many attempts. Retry in ${Math.ceil(retryAfter / 1000)}s.` }, 429);
  }

  // Case-insensitive username match, mirroring the native client (audit #10).
  // Wildcard chars are stripped so ilike degrades to a literal comparison.
  const needle = username.toLowerCase().replace(/[%_]/g, '');
  const { data: user } = await db.from('pos_users')
    .select('*').eq('customer_id', customerId).ilike('username', needle)
    .eq('active', true).is('deleted_at', null).maybeSingle();
  if (!user) {
    // Constant-time: derive against a dummy even when the user is unknown so
    // 'no such account' and 'wrong password' take the same wall-clock time.
    await verifyPassword(password, 'AAAAAAAAAAAAAAAAAAAAAA==',
      '210000\$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=');
    loginRecordFail(tkey);
    return json({ ok: false, error: 'Invalid credentials.' }, 401);
  }

  const ok = await verifyPassword(password, user.pw_salt, user.pw_hash);
  if (!ok) { loginRecordFail(tkey); return json({ ok: false, error: 'Invalid credentials.' }, 401); }
  loginClear(tkey);

  // Best-effort: guarantee the tenant's permanent training demo account exists.
  // A failure here must never block a login. Only an OWNER's sign-in may seed
  // or rotate it, and only that response carries the new password once so they
  // can hand it to a trainee (audit #2, audit 2 #10).
  let demoPassword: string | null = null;
  try { demoPassword = await ensureDemoUser(db, customerId, user.role === OWNER); } catch { /* non-fatal */ }

  const token = await signJwt({ sub: user.id, cid: customerId, role: user.role, tv: Number(user.token_version ?? 0) });
  return json({
    ok: true, token,
    user_id: user.id, username: user.username, role: user.role,
    permissions: Array.isArray(user.permissions) ? user.permissions : [],
    customer_id: customerId,
    ...(user.role === OWNER && demoPassword ? { demo_password: demoPassword } : {}),
    expires_at: new Date(Date.now() + SESSION_TTL_SECONDS * 1000).toISOString(),
  });
}

// First-owner bootstrap: allowed ONLY while the tenant has no accounts, so an
// owner's first web sign-in (armed with the activation code) seeds their login.
async function setupOwner(db: any, body: any): Promise<Response> {
  const code = str(body.activation_code);
  const rawName = str(body.username);
  const password = String(body.password ?? '');
  if (!code || !rawName || !password) return json({ ok: false, error: 'Missing fields' }, 400);
  const username = normalizePhone(rawName);
  if (!username) return json({ ok: false, error: PHONE_INVALID }, 400);
  const lic = await licenseForActivationCode(db, code);
  if (!lic.ok) return json({ ok: false, error: lic.error }, 403);
  const customerId = lic.customerId;

  const minLen = 12; // owner policy, matches UserRepository.ownerPasswordLength
  if (password.length < minLen) {
    return json({ ok: false, error: `Password must be at least ${minLen} characters.` }, 400);
  }
  const { salt, hash } = await hashPassword(password);
  const id = crypto.randomUUID();
  // Atomic "no users exist" check + insert (audit #15): the count guard and the
  // row write run in one transaction inside the RPC, with the one-owner unique
  // index as the hard backstop against a racing second bootstrap.
  const rpc = await db.rpc('pos_setup_owner', {
    p_customer: customerId, p_id: id, p_username: username, p_pw_salt: salt, p_pw_hash: hash,
  });
  if (rpc.error) {
    if (/already exists/i.test(rpc.error.message)) {
      return json({ ok: false, error: 'Owner already exists.' }, 409);
    }
    throw new Error(rpc.error.message);
  }
  await audit(db, customerId, id, 'OWNER_CREATED', `Web owner "${username}" created.`);
  // Seed the demo account alongside the first owner so it is ready immediately;
  // its random password is returned once, here, for the owner to keep.
  let demoPassword: string | null = null;
  try { demoPassword = await ensureDemoUser(db, customerId, true); } catch { /* non-fatal */ }
  const token = await signJwt({ sub: id, cid: customerId, role: OWNER, tv: 0 });
  return json({ ok: true, token, user_id: id, username, role: OWNER, permissions: [], customer_id: customerId,
    ...(demoPassword ? { demo_password: demoPassword } : {}) });
}

async function changePassword(db: any, ctx: Ctx, body: any): Promise<Response> {
  const { data: user } = await db.from('pos_users')
    .select('*').eq('customer_id', ctx.customerId).eq('id', ctx.userId).maybeSingle();
  if (!user) return json({ ok: false, error: 'User not found.' }, 404);
  const current = String(body.current_password ?? '');
  const next = String(body.new_password ?? '');
  if (!(await verifyPassword(current, user.pw_salt, user.pw_hash))) {
    return json({ ok: false, error: 'Current password is incorrect.' }, 401);
  }
  const minLen = user.role === OWNER ? 12 : 8;
  if (next.length < minLen) {
    return json({ ok: false, error: `New password must be at least ${minLen} characters.` }, 400);
  }
  const { salt, hash } = await hashPassword(next);
  // Bumping token_version revokes every JWT issued for this account before the
  // change (audit #6) — the current session's token is now stale too, so the
  // client must log back in with the new password to obtain a fresh tv.
  const up = await db.from('pos_users').update(userStamp({ pw_salt: salt, pw_hash: hash, token_version: (user.token_version ?? 0) + 1 }))
    .eq('customer_id', ctx.customerId).eq('id', ctx.userId);
  if (up.error) throw new Error(up.error.message);
  await audit(db, ctx.customerId, ctx.userId, 'PASSWORD_CHANGED', 'Password changed.');
  return json({ ok: true });
}

// ===========================================================================
// Products (saved names)
// ===========================================================================
async function listProducts(db: any, ctx: Ctx, body: any): Promise<Response> {
  const inactive = body.inactive === true;
  const { data, error } = await db.from('pos_products').select('*')
    .eq('customer_id', ctx.customerId).eq('is_active', inactive ? 0 : 1)
    .order('name', { ascending: true });
  if (error) throw new Error(error.message);
  return json({ ok: true, products: strip(data) });
}

async function saveProduct(db: any, ctx: Ctx, body: any): Promise<Response> {
  const p = body.product ?? {};
  const invalid = validateProduct(p);
  if (invalid) return json({ ok: false, error: invalid }, 400);
  if (await duplicateName(db, ctx, String(p.name ?? ''), null)) {
    return json({ ok: false, error: 'A saved name already exists.' }, 409);
  }
  const row = tenantRow(ctx, p, {
    id: p.id ?? crypto.randomUUID(),
    is_active: 1,
    created_at: p.created_at ?? new Date().toISOString(),
  });
  const ins = await db.from('pos_products').insert(row);
  if (ins.error) {
    if (/duplicate key|unique/i.test(ins.error.message)) {
      return json({ ok: false, error: 'A saved name already exists.' }, 409);
    }
    throw new Error(ins.error.message);
  }
  return json({ ok: true, id: row.id });
}

async function updateProduct(db: any, ctx: Ctx, body: any): Promise<Response> {
  const p = body.product ?? {};
  if (!p.id) return json({ ok: false, error: 'Missing product id.' }, 400);
  const invalid = validateProduct(p);
  if (invalid) return json({ ok: false, error: invalid }, 400);
  if (await duplicateName(db, ctx, String(p.name ?? ''), String(p.id))) {
    return json({ ok: false, error: 'A saved name already exists.' }, 409);
  }
  const up = await db.from('pos_products').update({
    name: p.name, code: p.code ?? null, category: p.category ?? null, unit: p.unit ?? null,
    selling_price_minor_units: p.selling_price_minor_units ?? 0,
    is_active: p.is_active ?? 1,
    updated_at: new Date().toISOString(),
  }).eq('customer_id', ctx.customerId).eq('id', p.id);
  if (up.error) {
    if (/duplicate key|unique/i.test(up.error.message)) {
      return json({ ok: false, error: 'A saved name already exists.' }, 409);
    }
    throw new Error(up.error.message);
  }
  return json({ ok: true });
}

async function setProductActive(db: any, ctx: Ctx, body: any, active: number): Promise<Response> {
  const up = await db.from('pos_products').update({
    is_active: active, updated_at: new Date().toISOString(),
  }).eq('customer_id', ctx.customerId).eq('id', String(body.id ?? ''));
  if (up.error) throw new Error(up.error.message);
  return json({ ok: true });
}

async function duplicateName(db: any, ctx: Ctx, name: string, excludeId: string | null): Promise<boolean> {
  const trimmed = name.trim().toLowerCase().replace(/[%_]/g, '');
  if (!trimmed) return false;
  // Case-insensitive exact match via ilike (no wildcards), avoiding the
  // `.filter('lower(name)')` expression form PostgREST cannot parse — which
  // previously errored and was silently read back as "no duplicate" (audit #10).
  let q = db.from('pos_products').select('id')
    .eq('customer_id', ctx.customerId).ilike('name', trimmed);
  if (excludeId) q = q.neq('id', excludeId);
  const { data, error } = await q.maybeSingle();
  if (error) throw new Error(`duplicate name check: ${error.message}`);
  return !!data;
}

// Server-side validation mirroring the native product form (audit #10): a
// non-empty name and a finite, non-negative whole-number price. Prices are
// minor units, so fractional/NaN/negative values are rejected before they can
// poison the cloud ledger that syncs alongside native sales.
function validateProduct(p: any): string | null {
  const name = String(p.name ?? '').trim();
  if (!name) return 'Product name is required.';
  if (name.length > 200) return 'Product name is too long.';
  const price = p.selling_price_minor_units;
  if (price != null) {
    const n = Number(price);
    if (!Number.isFinite(n) || !Number.isInteger(n) || n < 0) {
      return 'Selling price must be a non-negative whole number.';
    }
  }
  return null;
}

// ===========================================================================
// Sales
// ===========================================================================

// The receipt day is the shop's calendar day, not UTC. Ethiopia is UTC+3, so a
// 01:00 sale sits on the *previous* UTC date: numbering it by UTC would put it
// behind receipts already issued that morning and split the trend chart across
// the wrong day (audit #12). pos_revenue_trend buckets by the same zone.
const SHOP_TIME_ZONE = 'Africa/Addis_Ababa';
function shopDay(d: Date = new Date()): string {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: SHOP_TIME_ZONE, year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(d);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? '';
  return `${get('year')}${get('month')}${get('day')}`;
}

async function nextReceiptNumber(db: any, ctx: Ctx): Promise<Response> {
  const day = shopDay();
  // Atomic allocation in a single DB op (audit #5): INSERT..ON CONFLICT DO
  // UPDATE value=value+1 RETURNING, so two concurrent tills never read the same
  // counter and collide on receipt_number.
  const { data, error } = await db.rpc('pos_next_receipt', { p_customer: ctx.customerId, p_day: day });
  if (error) throw new Error(error.message);
  return json({ ok: true, receipt_number: String(data) });
}

async function insertSale(db: any, ctx: Ctx, body: any): Promise<Response> {
  const sale = body.sale ?? {};
  const items = Array.isArray(body.items) ? body.items : [];
  if (items.length === 0) return json({ ok: false, error: 'Incomplete sale.' }, 400);
  // The client pre-allocates the receipt via next_receipt_number (atomic cloud
  // counter), so pass it through unchanged: the shown number equals the stored
  // one and the counter is never double-incremented (audit D2).
  const receipt = str(sale.receipt_number);
  if (!receipt) return json({ ok: false, error: 'Sale requires a receipt number.' }, 400);
  const payment = str(sale.payment_method).toUpperCase();
  // Only the three till payment methods are accepted. LOAN is money owed, not
  // collected: pos_create_sale treats any non-CASH payment as paid-in-full, and
  // the revenue aggregates below filter to CASH/BANK so a loan never inflates the
  // dashboard or register cash.
  if (!['CASH', 'BANK', 'LOAN'].includes(payment)) {
    return json({ ok: false, error: 'Invalid payment method.' }, 400);
  }
  // Server-authoritative: cashier is the verified session user and every money
  // figure is recomputed inside the RPC, so a crafted body cannot forge totals
  // or post a sale under another operator (audit #2 + #4-sale).
  const { data, error } = await db.rpc('pos_create_sale', {
    p_customer: ctx.customerId,
    p_cashier: ctx.userId,
    p_device: str(sale.device_id) || ctx.deviceId || '',
    p_shift_id: str(sale.shift_id),
    p_receipt: receipt,
    p_items: items,
    p_payment: payment,
    p_discount: Number(sale.discount_minor_units ?? 0),
    p_amount_paid: Number(sale.amount_paid_minor_units ?? 0),
    p_customer_name: sale.customer_name == null ? null : str(sale.customer_name) || null,
    // The client's own sale id is the idempotency key (audit #6): a retry after
    // a timeout returns the sale already booked instead of a second one.
    p_sale_id: str(sale.id) || null,
  });
  if (error) return rpcFailure(error.message);
  const res = typeof data === 'string' ? JSON.parse(data) : (data ?? {});
  return json({ ok: true, id: res.id, receipt_number: res.receipt_number,
    subtotal_minor_units: res.subtotal_minor_units, total_minor_units: res.total_minor_units,
    duplicate: res.duplicate === true });
}

async function searchSales(db: any, ctx: Ctx, body: any): Promise<Response> {
  let q = db.from('sales').select('*')
    .eq('customer_id', ctx.customerId).order('created_at', { ascending: false });
  if (body.status && body.status !== 'ALL') q = q.eq('status', body.status);
  if (body.period_start) q = q.gte('created_at', body.period_start);
  if (body.period_end) q = q.lt('created_at', body.period_end);
  const query = str(body.search_query);
  if (query) {
    // Mirror the native getSales search: match customer name and void reason on
    // the sale, cashier username on pos_users, and product / quantity / notes on
    // the line items. PostgREST cannot express the cross-table EXISTS in one
    // filter, so resolve the item- and cashier-matching sale ids first and OR
    // them into the main query via id.in.(...).
    const esc = query.replace(/[%_,()]/g, ' ');
    // Each lookup is checked: an ignored error used to shrink the id set, so a
    // search quietly returned fewer sales than matched (audit 2 #18).
    const { data: itemRows, error: itemErr } = await db.from('sale_items').select('sale_id')
      .eq('customer_id', ctx.customerId)
      .or(`product_name_snapshot.ilike.%${esc}%,quantity_text.ilike.%${esc}%,notes.ilike.%${esc}%`);
    if (itemErr) throw new Error(itemErr.message);
    const { data: userRows, error: userErr } = await db.from('pos_users').select('id')
      .eq('customer_id', ctx.customerId).ilike('username', `%${esc}%`);
    if (userErr) throw new Error(userErr.message);
    const userIds = strip(userRows).map((r: any) => r.id);
    let cashierSaleIds: string[] = [];
    if (userIds.length) {
      const { data: cs, error: csErr } = await db.from('sales').select('id')
        .eq('customer_id', ctx.customerId).in('cashier_id', userIds);
      if (csErr) throw new Error(csErr.message);
      cashierSaleIds = strip(cs).map((r: any) => r.id);
    }
    const matchedIds = Array.from(new Set<string>([
      ...strip(itemRows).map((r: any) => r.sale_id),
      ...cashierSaleIds,
    ]));
    const orParts = [`customer_name.ilike.%${esc}%`, `void_reason.ilike.%${esc}%`];
    if (matchedIds.length) orParts.push(`id.in.(${matchedIds.map((id) => `"${id}"`).join(',')})`);
    q = q.or(orParts.join(','));
  }
  // The demo login practises on this tenant's own products and people, so its
  // receipts would otherwise be listed beside the shop's real ones. Mirrors the
  // native getSales filter.
  q = excludeDemoRows(q, await demoUserIds(db, ctx), 'cashier_id');
  const limit = pageLimit(body);
  q = q.limit(limit);
  const { data, error } = await q;
  if (error) throw new Error(error.message);
  const sales = strip(data);
  await hydrateItems(db, ctx, sales);
  // cashier_name + has_pending_void_request are display-only fields hydrated on
  // the local path by SQL joins; reproduce them here so the cloud Sale maps 1:1.
  const names = await usernamesById(db, ctx, sales.map((s: any) => s.cashier_id));
  const pending = await pendingSaleIds(db, ctx, sales.map((s: any) => s.id));
  for (const s of sales) {
    s.cashier_name = names[s.cashier_id] ?? null;
    s.has_pending_void_request = pending.has(s.id);
  }
  return json({ ok: true, sales, truncated: sales.length >= limit });
}

async function voidSale(db: any, ctx: Ctx, body: any): Promise<Response> {
  const reason = str(body.reason);
  if (!reason || reason.length > 240) return json({ ok: false, error: 'Void reason required.' }, 400);
  const saleId = String(body.sale_id ?? '');
  if (!saleId) return json({ ok: false, error: 'Sale not found.' }, 404);
  // Owner direct void: sale -> VOIDED + audit in one transaction (audit #4).
  const { error } = await db.rpc('pos_void_sale', {
    p_customer: ctx.customerId, p_user: ctx.userId, p_sale_id: saleId, p_reason: reason,
  });
  if (error) return rpcFailure(error.message);
  return json({ ok: true });
}

async function requestVoid(db: any, ctx: Ctx, body: any): Promise<Response> {
  const reason = str(body.reason);
  if (!reason || reason.length > 240) return json({ ok: false, error: 'Void reason required.' }, 400);
  const { data: sale, error: saleErr } = await db.from('sales').select('status')
    .eq('customer_id', ctx.customerId).eq('id', String(body.sale_id ?? '')).maybeSingle();
  if (saleErr) throw new Error(saleErr.message);
  if (!sale || sale.status !== 'COMPLETED') return json({ ok: false, error: 'Sale not voidable.' }, 400);
  const { data: existingReq } = await db.from('void_requests').select('id')
    .eq('customer_id', ctx.customerId).eq('sale_id', String(body.sale_id ?? ''))
    .eq('status', 'PENDING').maybeSingle();
  if (existingReq) return json({ ok: false, error: 'A void request is already pending for this sale.' }, 409);
  const id = crypto.randomUUID();
  const ins = await db.from('void_requests').insert({
    id, customer_id: ctx.customerId, sale_id: body.sale_id,
    requested_by: ctx.userId, reason, status: 'PENDING',
    created_at: new Date().toISOString(),
  });
  if (ins.error) throw new Error(ins.error.message);
  await audit(db, ctx.customerId, ctx.userId, 'VOID_REQUESTED', `Void requested for ${body.sale_id}.`);
  return json({ ok: true, id });
}

async function listVoidRequests(db: any, ctx: Ctx, body: any): Promise<Response> {
  // Paged like every other list: the unbounded query used to truncate at the
  // fetch cap without saying so (audit 2 #18).
  const limit = pageLimit(body, MAX_PAGE);
  let q = db.from('void_requests').select('*')
    .eq('customer_id', ctx.customerId).eq('status', 'PENDING')
    .order('created_at', { ascending: false });
  // A practice sale the owner cannot see in Sales History must not turn up in
  // their approval queue either. Mirrors the native getPendingVoidRequests.
  q = excludeDemoRows(q, await demoUserIds(db, ctx), 'requested_by');
  const { data, error } = await q.limit(limit);
  if (error) throw new Error(error.message);
  const reqs = strip(data);
  const names = await usernamesById(db, ctx, reqs.map((r: any) => r.requested_by));
  for (const r of reqs) r.requester_name = names[r.requested_by] ?? null;
  const saleIds = [...new Set(reqs.map((r: any) => r.sale_id))];
  if (saleIds.length) {
    const { data: sales } = await db.from('sales').select('*')
      .eq('customer_id', ctx.customerId).in('id', saleIds);
    const hydrated = strip(sales);
    await hydrateItems(db, ctx, hydrated);
    const cashierNames = await usernamesById(db, ctx, hydrated.map((s: any) => s.cashier_id));
    for (const s of hydrated) s.cashier_name = cashierNames[s.cashier_id] ?? null;
    const byId: Record<string, any> = {};
    for (const s of hydrated) byId[s.id] = s;
    for (const r of reqs) r.sale = byId[r.sale_id] ?? null;
  }
  return json({ ok: true, void_requests: reqs });
}

async function decideVoid(db: any, ctx: Ctx, body: any, decision: string): Promise<Response> {
  const requestId = String(body.request_id ?? '');
  if (!requestId) return json({ ok: false, error: 'Request not found.' }, 404);
  // Approving marks the request APPROVED and flips the sale to VOIDED in one
  // transaction; if the sale update affects 0 rows the RPC aborts so we never
  // return success while the sale stays COMPLETED (audit #4-void).
  const fn = decision === 'APPROVED' ? 'pos_approve_void' : 'pos_reject_void';
  const { error } = await db.rpc(fn, {
    p_customer: ctx.customerId, p_user: ctx.userId, p_request_id: requestId,
  });
  if (error) return rpcFailure(error.message);
  return json({ ok: true });
}

// ===========================================================================
// Shifts + cash movements
// ===========================================================================
async function getActiveShift(db: any, ctx: Ctx): Promise<Response> {
  const { data } = await db.from('shifts').select('*')
    .eq('customer_id', ctx.customerId).eq('status', 'OPEN').limit(1).maybeSingle();
  return json({ ok: true, shift: data ? deSnake(data) : null });
}

// Returns the perpetual open shift, creating one (opening cash 0) if none
// exists so the register screen always has a balance to show. The find-or-create
// runs in one transaction guarded by a per-tenant advisory lock inside the RPC,
// so two concurrent tills can no longer both see "no OPEN shift" and both insert
// (audit #3).
async function ensureShift(db: any, ctx: Ctx): Promise<Response> {
  const { data, error } = await db.rpc('pos_ensure_shift', {
    p_customer: ctx.customerId, p_user: ctx.userId, p_device: ctx.deviceId,
  });
  if (error) throw new Error(error.message);
  const shiftId = String(data);
  const { data: row } = await db.from('shifts').select('*')
    .eq('customer_id', ctx.customerId).eq('id', shiftId).maybeSingle();
  return json({ ok: true, shift: row ? deSnake(row) : { id: shiftId } });
}

// Register balance (all-time expected cash) plus today's activity counters,
// date-filtered so the counters reset each calendar day. Mirrors
// ShiftRepository.getRegisterSnapshot. Zeros when no shift is open.
async function registerSnapshot(db: any, ctx: Ctx, body: any): Promise<Response> {
  const { data: shift } = await db.from('shifts').select('*')
    .eq('customer_id', ctx.customerId).eq('status', 'OPEN').limit(1).maybeSingle();
  if (!shift) {
    return json({ ok: true, snapshot: {
      balance: 0, today_cash_sales: 0, today_bank_sales: 0,
      today_deposits: 0, today_withdrawals: 0 } });
  }
  const balance = await computeExpectedCash(db, ctx.customerId, shift);
  // Today's counters are SQL aggregates (audit #13): summing rows here would
  // silently stop at PostgREST's 1000-row page and under-report a busy day.
  const { data: counters, error: cErr } = await db.rpc('pos_shift_counters', {
    p_customer: ctx.customerId, p_shift_id: shift.id,
    p_start: body.period_start ?? null, p_end: body.period_end ?? null,
  });
  if (cErr) throw new Error(cErr.message);
  const c = typeof counters === 'string' ? JSON.parse(counters) : (counters ?? {});
  return json({ ok: true, snapshot: {
    balance,
    today_cash_sales: Number(c.cash_sales ?? 0),
    today_bank_sales: Number(c.bank_sales ?? 0),
    today_deposits: Number(c.deposits ?? 0),
    today_withdrawals: Number(c.withdrawals ?? 0) } });
}

async function shiftHistory(db: any, ctx: Ctx, body: any): Promise<Response> {
  let q = db.from('shifts').select('*').eq('customer_id', ctx.customerId)
    .order('opened_at', { ascending: false });
  if (body.status) q = q.eq('status', body.status);
  if (body.period_start) q = q.gte('opened_at', body.period_start);
  if (body.period_end) q = q.lt('opened_at', body.period_end);
  q = excludeDemoRows(q, await demoUserIds(db, ctx), 'cashier_id');
  const limit = pageLimit(body);
  const { data, error } = await q.limit(limit);
  if (error) throw new Error(error.message);
  const shifts = strip(data);
  return json({ ok: true, shifts, truncated: shifts.length >= limit });
}

async function openShift(db: any, ctx: Ctx, body: any): Promise<Response> {
  const opening = Number(body.opening_cash_minor_units ?? 0);
  if (!Number.isFinite(opening) || opening < 0) return json({ ok: false, error: 'Opening cash cannot be negative.' }, 400);
  // Advisory-locked open + the partial unique index backstop mean a racing
  // second OPEN for the same device cannot both succeed (audit #3).
  const { data, error } = await db.rpc('pos_open_shift', {
    p_customer: ctx.customerId, p_user: ctx.userId, p_device: ctx.deviceId, p_opening: opening,
  });
  if (error) return rpcFailure(error.message);
  return json({ ok: true, id: String(data) });
}

async function closeShift(db: any, ctx: Ctx, body: any): Promise<Response> {
  const closing = Number(body.closing_cash_minor_units ?? 0);
  if (!Number.isFinite(closing) || closing < 0) return json({ ok: false, error: 'Closing cash cannot be negative.' }, 400);
  const shiftId = String(body.shift_id ?? '');
  if (!shiftId) return json({ ok: false, error: 'Shift is no longer open.' }, 409);
  // Reconciliation + close run inside one advisory-locked transaction, so a
  // cash movement that races in just before close is still counted (audit #3).
  const { data, error } = await db.rpc('pos_close_shift', {
    p_customer: ctx.customerId, p_user: ctx.userId, p_shift_id: shiftId, p_closing: closing,
  });
  if (error) return rpcFailure(error.message);
  return json({ ok: true, expected_cash_minor_units: Number(data) });
}

// Reconciliation shared by register_snapshot + shift_summary + dashboard.
// Delegates to the pos_expected_cash SQL aggregate (audit #9) so the drawer
// balance stays exact even when a shift has more than PostgREST's 1000-row
// fetch cap worth of sales/movements. Mirrors the native rule including the
// cross-shift cash refund netting (a sale rung up in another shift but refunded
// while this one was open is the only void that drains THIS drawer).
async function computeExpectedCash(db: any, customerId: string, shift: any): Promise<number> {
  const { data, error } = await db.rpc('pos_expected_cash', {
    p_customer: customerId, p_shift_id: shift.id,
  });
  if (error) throw new Error(error.message);
  return Number(data ?? 0);
}

async function shiftSummary(db: any, ctx: Ctx, body: any): Promise<Response> {
  const { data: shift } = await db.from('shifts').select('id, status')
    .eq('customer_id', ctx.customerId).eq('id', String(body.shift_id ?? '')).maybeSingle();
  if (!shift) return json({ ok: false, error: 'Shift not found.' }, 404);
  // A cashier only ever closes the drawer that is open right now, so anything
  // else is browsing another operator's session and stays owner-only (audit #9).
  if (ctx.role !== OWNER && shift.status !== 'OPEN') {
    return json({ ok: false, error: 'Owners can review a closed shift.' }, 403);
  }
  // One aggregate RPC, so the screen and the reconciliation can never disagree
  // and a 1000-row page cap cannot truncate the totals (audit #13).
  const { data, error } = await db.rpc('pos_shift_summary', {
    p_customer: ctx.customerId, p_shift_id: shift.id,
  });
  if (error) throw new Error(error.message);
  const s = typeof data === 'string' ? JSON.parse(data) : (data ?? {});
  return json({
    ok: true,
    summary: {
      cash_sales: Number(s.cash_sales ?? 0),
      bank_sales: Number(s.bank_sales ?? 0),
      voids: Number(s.voids ?? 0),
      deposits: Number(s.deposits ?? 0),
      withdrawals: Number(s.withdrawals ?? 0),
      cash_refunds: Number(s.cash_refunds ?? 0),
      expected_cash: Number(s.expected_cash ?? 0),
    },
  });
}

async function addCashMovement(db: any, ctx: Ctx, body: any): Promise<Response> {
  const amount = Number(body.amount_minor_units ?? 0);
  const type = String(body.type ?? '').toUpperCase();
  if (!Number.isFinite(amount) || amount <= 0) return json({ ok: false, error: 'Amount must be positive.' }, 400);
  if (!['WITHDRAWAL', 'DEPOSIT', 'EXPENSE'].includes(type)) return json({ ok: false, error: 'Invalid movement type.' }, 400);
  const shiftId = String(body.shift_id ?? '');
  if (!shiftId) return json({ ok: false, error: 'Movement requires an open shift.' }, 400);
  const reason = str(body.reason);
  if (!reason) return json({ ok: false, error: 'A reason is required.' }, 400);
  const reason2 = reason.slice(0, 240);
  // Optional proof photo (base64 image, usually attached on a debit as
  // withdrawal evidence). Capped server-side so entries can't bloat the row.
  const photo = typeof body.photo === 'string' && body.photo.length > 0 ? body.photo : null;
  if (photo !== null && photo.length > 300_000) {
    return json({ ok: false, error: 'Proof photo is too large.' }, 400);
  }
  // The open-shift check, the row and its audit entry commit together, with the
  // shift share-locked against pos_close_shift (audit #3 + #11): a movement can
  // never be booked by a read that raced the drawer's reconciliation.
  const { data, error } = await db.rpc('pos_add_cash_movement', {
    p_customer: ctx.customerId, p_user: ctx.userId, p_shift_id: shiftId,
    p_type: type, p_amount: amount, p_reason: reason2, p_photo: photo,
  });
  if (error) return rpcFailure(error.message);
  const res = typeof data === 'string' ? JSON.parse(data) : (data ?? {});
  return json({ ok: true, id: res.id });
}

async function listCashMovements(db: any, ctx: Ctx, body: any): Promise<Response> {
  // shift_id optional: omit it to list the whole ledger across every shift.
  let q = db.from('cash_movements').select('*').eq('customer_id', ctx.customerId);
  if (body.shift_id != null && String(body.shift_id) !== '') {
    q = q.eq('shift_id', String(body.shift_id));
  }
  q = excludeDemoRows(q, await demoUserIds(db, ctx), 'user_id');
  const limit = pageLimit(body);
  const { data, error } = await q.order('created_at', { ascending: false }).limit(limit);
  if (error) throw new Error(error.message);
  // Hydrate the recorder's username (cash_movements has no FK to pos_users,
  // so PostgREST embedding can't do this in one query).
  const rows = strip(data);
  const userIds = [...new Set(rows.map((r: any) => r.user_id).filter(Boolean))];
  let nameById: Record<string, string> = {};
  if (userIds.length > 0) {
    const { data: users } = await db.from('pos_users')
      .select('id, username').eq('customer_id', ctx.customerId).in('id', userIds);
    nameById = Object.fromEntries((users ?? []).map((u: any) => [u.id, u.username]));
  }
  return json({ ok: true, movements: rows.map((r: any) => ({ ...r, user_name: nameById[r.user_id] ?? null })),
    truncated: rows.length >= limit });
}

// ===========================================================================
// Users (OWNER_ONLY enforced above)
// ===========================================================================
async function listUsers(db: any, ctx: Ctx): Promise<Response> {
  const { data, error } = await db.from('pos_users')
    .select('id, username, role, active, created_at, permissions, is_demo').eq('customer_id', ctx.customerId)
    .is('deleted_at', null)
    .order('username');
  if (error) throw new Error(error.message);
  return json({ ok: true, users: strip(data) });
}

// Every edit to an account has to move `received_at`: the sync gateway pages
// `pos_users` by that stamp, so without it a password set here never reaches a
// till that already pulled the row — the till keeps signing in with the old
// one, which reads as "invalid password" to whoever was given the new one.
// (A fresh INSERT is stamped by the column default.)
function userStamp(patch: Record<string, unknown>): Record<string, unknown> {
  return { ...patch, received_at: new Date().toISOString() };
}

async function createUser(db: any, ctx: Ctx, body: any): Promise<Response> {
  const rawName = str(body.username);
  const role = String(body.role ?? '');
  const password = String(body.password ?? '');
  if (!rawName) return json({ ok: false, error: 'Phone number required.' }, 400);
  if (rawName.trim().toLowerCase() === 'demo') return json({ ok: false, error: 'That name is reserved for the demo account.' }, 400);
  const username = normalizePhone(rawName);
  if (!username) return json({ ok: false, error: PHONE_INVALID }, 400);
  if (![OWNER, CASHIER].includes(role)) return json({ ok: false, error: 'Invalid role.' }, 400);
  if (role === OWNER) {
    // pos_users_one_owner is a partial unique index, so without this check a
    // second owner surfaced as a 500 constraint error (audit #10). The count
    // deliberately includes deleted rows, matching the index predicate.
    const { count } = await db.from('pos_users')
      .select('*', { count: 'exact', head: true })
      .eq('customer_id', ctx.customerId).eq('role', OWNER);
    if ((count ?? 0) > 0) {
      return json({ ok: false, error: 'This shop already has an owner account.' }, 409);
    }
  }
  const minLen = role === OWNER ? 12 : 8;
  if (password.length < minLen) return json({ ok: false, error: `Password must be at least ${minLen} characters.` }, 400);
  // Owners bypass the tick list (store []); a staff account keeps only the
  // validated feature keys it was given, de-duplicated, in registry order.
  const rawPerms = Array.isArray(body.permissions) ? body.permissions.map(String) : [];
  const perms = role === OWNER ? [] : Array.from(new Set(rawPerms.filter((k) => FEATURE_KEYS.has(k))));
  const { data: dup, error: dupErr } = await db.from('pos_users').select('id, deleted_at')
    .eq('customer_id', ctx.customerId).ilike('username', username.toLowerCase().replace(/[%_]/g, '')).maybeSingle();
  if (dupErr) throw new Error(`duplicate username check: ${dupErr.message}`);
  if (dup && !dup.deleted_at) return json({ ok: false, error: 'That phone number is already in use.' }, 409);
  const { salt, hash } = await hashPassword(password);
  // A deleted account still holds the number. Reuse its row instead of
  // violating the unique index: the sales it recorded keep the same cashier.
  if (dup?.deleted_at) {
    const up = await db.from('pos_users').update(userStamp({
      username, role, pw_salt: salt, pw_hash: hash, active: true,
      permissions: perms, is_demo: false, deleted_at: null,
    })).eq('customer_id', ctx.customerId).eq('id', dup.id);
    if (up.error) throw new Error(up.error.message);
    await audit(db, ctx.customerId, ctx.userId, 'USER_CREATED', `Deleted account "${username}" reused (${role}).`);
    return json({ ok: true, id: dup.id });
  }
  const id = crypto.randomUUID();
  const ins = await db.from('pos_users').insert({
    id, customer_id: ctx.customerId, username, role, pw_salt: salt, pw_hash: hash, active: true, permissions: perms,
  });
  if (ins.error) throw new Error(ins.error.message);
  await audit(db, ctx.customerId, ctx.userId, 'USER_CREATED', `User "${username}" (${role}).`);
  return json({ ok: true, id });
}

// Seeds (once) the tenant's permanent training account. Idempotent: a no-op
// when a demo row already exists. Mirrors the native ensureDemoUser(): a
// `demo` CASHIER with the default staff permissions, flagged so it can never be
// deactivated.
//
// The password is random per tenant, never a literal in the source (audit #2):
// the caller returns it to the OWNER exactly once, when this function mints it,
// and the owner can reset it from Users afterwards. Returns that password, or
// null when nothing new was minted.
const DEMO_PW_VERSION = '2';
const DEMO_ALPHABET = 'abcdefghijkmnpqrstuvwxyz23456789';
function randomDemoPassword(): string {
  const bytes = new Uint8Array(14);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => DEMO_ALPHABET[b % DEMO_ALPHABET.length]).join('');
}

async function demoVersionMarked(db: any, customerId: string): Promise<boolean> {
  const { data, error } = await db.from('pos_settings').select('value')
    .eq('customer_id', customerId).eq('key', 'demo_pw_version').maybeSingle();
  // A failed read must not read as "not marked": that would rotate the demo
  // password again on the next sign-in (audit 2 #10).
  if (error) throw new Error(error.message);
  return data?.value === DEMO_PW_VERSION;
}
async function markDemoVersion(db: any, customerId: string): Promise<void> {
  const up = await db.from('pos_settings').upsert(
    { customer_id: customerId, key: 'demo_pw_version', value: DEMO_PW_VERSION },
    { onConflict: 'customer_id,key' });
  // Checked, not fire-and-forget: an unwritten marker would keep the legacy
  // password alive and re-run the PBKDF2 probe on every sign-in.
  if (up.error) throw new Error(up.error.message);
}

async function ensureDemoUser(db: any, customerId: string, ownerSession: boolean): Promise<string | null> {
  // Only an owner's sign-in may seed or rotate the training credentials. A
  // cashier signing in used to trigger the rotation and then never see the new
  // password, silently locking the trainee out (audit 2 #10).
  if (!ownerSession) return null;
  const marked = await demoVersionMarked(db, customerId);
  const { data: existing, error: readErr } = await db.from('pos_users').select('id, pw_salt, pw_hash')
    .eq('customer_id', customerId).eq('is_demo', true).maybeSingle();
  if (readErr) throw new Error(readErr.message);

  if (existing) {
    if (marked) return null;
    // A tenant seeded by an older build still holds the published `demo1234`.
    // Rotate it once — the version marker makes the PBKDF2 check a one-time
    // cost rather than something every login pays.
    if (!(await verifyPassword('demo1234', existing.pw_salt, existing.pw_hash))) {
      await markDemoVersion(db, customerId);
      return null;
    }
    const password = randomDemoPassword();
    const { salt, hash } = await hashPassword(password);
    const up = await db.from('pos_users').update(userStamp({ pw_salt: salt, pw_hash: hash }))
      .eq('customer_id', customerId).eq('id', existing.id).select('id');
    if (up.error) throw new Error(up.error.message);
    // Never mark a rotation that did not land, or the tenant keeps an unknown
    // password while the marker claims it was rotated.
    if (!Array.isArray(up.data) || up.data.length !== 1) {
      throw new Error('Demo account could not be rotated.');
    }
    await markDemoVersion(db, customerId);
    return password;
  }

  const password = randomDemoPassword();
  const { salt, hash } = await hashPassword(password);
  // Adopt a pre-existing 'demo' username (created before the flag) so the
  // unique index can't reject the seed, else insert a fresh one.
  const { data: byName, error: nameErr } = await db.from('pos_users').select('id')
    .eq('customer_id', customerId).ilike('username', 'demo').maybeSingle();
  if (nameErr) throw new Error(nameErr.message);
  if (byName) {
    const up = await db.from('pos_users').update(userStamp({ is_demo: true, pw_salt: salt, pw_hash: hash }))
      .eq('customer_id', customerId).eq('id', byName.id).select('id');
    if (up.error) throw new Error(up.error.message);
    if (!Array.isArray(up.data) || up.data.length !== 1) {
      throw new Error('Demo account could not be adopted.');
    }
  } else {
    const ins = await db.from('pos_users').insert({
      id: crypto.randomUUID(), customer_id: customerId, username: 'demo', role: CASHIER,
      pw_salt: salt, pw_hash: hash, active: true, is_demo: true,
      permissions: ['pos', 'register', 'reports'],
    });
    if (ins.error) throw new Error(ins.error.message);
  }
  await markDemoVersion(db, customerId);
  return password;
}

// Replaces a staff account's feature ticks. Owner rows are rejected (they
// bypass the list). Enforced as OWNER_ONLY at the gate above.
async function setUserPermissions(db: any, ctx: Ctx, body: any): Promise<Response> {
  const target = String(body.target_user_id ?? '');
  const rawPerms = Array.isArray(body.permissions) ? body.permissions.map(String) : [];
  const perms = Array.from(new Set(rawPerms.filter((k) => FEATURE_KEYS.has(k))));
  const { data: t } = await db.from('pos_users').select('role, username')
    .eq('customer_id', ctx.customerId).eq('id', target).is('deleted_at', null).maybeSingle();
  if (!t) return json({ ok: false, error: 'User not found.' }, 404);
  if (t.role === OWNER) return json({ ok: false, error: 'Owner accounts bypass feature permissions.' }, 400);
  const up = await db.from('pos_users').update(userStamp({ permissions: perms }))
    .eq('customer_id', ctx.customerId).eq('id', target);
  if (up.error) throw new Error(up.error.message);
  await audit(db, ctx.customerId, ctx.userId, 'USER_PERMISSIONS_SET', `Permissions for "${t.username}": ${perms.join(', ') || '(none)'}.`);
  return json({ ok: true });
}

// Moves an account onto a phone-number login (or changes the existing one).
// Owner-only, unique, canonical, and refused for the demo account so `demo`
// stays a stable training login.
async function setUserPhone(db: any, ctx: Ctx, body: any): Promise<Response> {
  const target = String(body.target_user_id ?? '');
  const phone = normalizePhone(String(body.phone ?? ''));
  if (!phone) return json({ ok: false, error: PHONE_INVALID }, 400);
  const { data: t } = await db.from('pos_users').select('username, is_demo')
    .eq('customer_id', ctx.customerId).eq('id', target).is('deleted_at', null).maybeSingle();
  if (!t) return json({ ok: false, error: 'User not found.' }, 404);
  if (t.is_demo) return json({ ok: false, error: 'The demo account keeps its demo login.' }, 400);
  const { data: dup, error: dupErr } = await db.from('pos_users').select('id')
    .eq('customer_id', ctx.customerId).ilike('username', phone).neq('id', target).maybeSingle();
  if (dupErr) throw new Error(`duplicate phone check: ${dupErr.message}`);
  if (dup) return json({ ok: false, error: 'That phone number is already in use.' }, 409);
  const up = await db.from('pos_users').update(userStamp({ username: phone }))
    .eq('customer_id', ctx.customerId).eq('id', target);
  if (up.error) throw new Error(up.error.message);
  await audit(db, ctx.customerId, ctx.userId, 'USER_PHONE_CHANGED', `Login phone for "${t.username}" is now "${phone}".`);
  return json({ ok: true });
}

async function resetPassword(db: any, ctx: Ctx, body: any): Promise<Response> {
  const target = String(body.target_user_id ?? '');
  const password = String(body.new_password ?? '');
  const { data: t } = await db.from('pos_users').select('role, username, token_version')
    .eq('customer_id', ctx.customerId).eq('id', target).is('deleted_at', null).maybeSingle();
  if (!t) return json({ ok: false, error: 'User not found.' }, 404);
  const minLen = t.role === OWNER ? 12 : 8;
  if (password.length < minLen) return json({ ok: false, error: `Password must be at least ${minLen} characters.` }, 400);
  const { salt, hash } = await hashPassword(password);
  const up = await db.from('pos_users').update(userStamp({ pw_salt: salt, pw_hash: hash, token_version: (t.token_version ?? 0) + 1 }))
    .eq('customer_id', ctx.customerId).eq('id', target);
  if (up.error) throw new Error(up.error.message);
  await audit(db, ctx.customerId, ctx.userId, 'PASSWORD_RESET', `Password reset for "${t.username}".`);
  return json({ ok: true });
}

async function setUserActive(db: any, ctx: Ctx, body: any): Promise<Response> {
  const target = String(body.target_user_id ?? '');
  if (!target) return json({ ok: false, error: 'Target user is required.' }, 400);
  // `body.active === true` used to fold "missing" into "deactivate"; a boolean
  // is now required so a malformed body can never flip an account (audit 2 #16).
  if (typeof body.active !== 'boolean') {
    return json({ ok: false, error: 'active must be true or false.' }, 400);
  }
  const active: boolean = body.active;
  if (target === ctx.userId && !active) return json({ ok: false, error: 'You cannot deactivate your own account.' }, 400);

  // Both directions load and validate the target. Activation used to skip this,
  // so an unknown id updated 0 rows, was audited as USER_ACTIVATED and answered
  // ok:true (audit 2 #16).
  const { data: t, error: readErr } = await db.from('pos_users')
    .select('role, is_demo, username, token_version')
    .eq('customer_id', ctx.customerId).eq('id', target).is('deleted_at', null).maybeSingle();
  if (readErr) throw new Error(readErr.message);
  if (!t) return json({ ok: false, error: 'User not found.' }, 404);
  if (!active) {
    if (t.is_demo) return json({ ok: false, error: 'The demo account cannot be deactivated.' }, 400);
    if (t.role === OWNER) {
      const { count, error: countErr } = await db.from('pos_users').select('*', { count: 'exact', head: true })
        .eq('customer_id', ctx.customerId).eq('role', OWNER).eq('active', true);
      if (countErr) throw new Error(countErr.message);
      if ((count ?? 0) <= 1) return json({ ok: false, error: 'At least one active owner is required.' }, 409);
    }
  }
  // Deactivating an account must also invalidate its live sessions, and
  // resetting the version on activation is harmless (there is no valid token),
  // so bump unconditionally — any previously issued JWT is now stale (audit #6).
  const up = await db.from('pos_users')
    .update(userStamp({ active, token_version: Number(t.token_version ?? 0) + 1 }))
    .eq('customer_id', ctx.customerId).eq('id', target).is('deleted_at', null)
    .select('id');
  if (up.error) throw new Error(up.error.message);
  if (!Array.isArray(up.data) || up.data.length !== 1) {
    return json({ ok: false, error: 'User not found.' }, 404);
  }
  // Log the phone number, not the row id: the audit screen is read by the owner.
  await audit(db, ctx.customerId, ctx.userId, active ? 'USER_ACTIVATED' : 'USER_DEACTIVATED', `Account "${t.username ?? target}" ${active ? 'activated' : 'deactivated'}.`);
  return json({ ok: true });
}

// Removes a deactivated account. An account that already recorded sales,
// shifts, cash movements, finance entries or void requests keeps its row
// (flagged with deleted_at, hidden from every list and from login) so that
// history keeps its cashier name; a clean account is dropped outright, which
// frees its phone number for reuse. OWNER_ONLY at the gate above.
async function deleteUser(db: any, ctx: Ctx, body: any): Promise<Response> {
  const target = String(body.target_user_id ?? '');
  if (target === ctx.userId) return json({ ok: false, error: 'You cannot delete your own account.' }, 400);
  const { data: t } = await db.from('pos_users').select('username, active, is_demo, token_version')
    .eq('customer_id', ctx.customerId).eq('id', target).is('deleted_at', null).maybeSingle();
  if (!t) return json({ ok: false, error: 'User not found.' }, 404);
  if (t.is_demo) return json({ ok: false, error: 'The demo account cannot be deleted.' }, 400);
  if (t.active !== false) return json({ ok: false, error: 'Deactivate the account before deleting it.' }, 400);

  const counted = async (table: string, column: string): Promise<number> => {
    const { count, error } = await db.from(table).select('*', { count: 'exact', head: true })
      .eq('customer_id', ctx.customerId).eq(column, target);
    if (error) throw new Error(error.message);
    return count ?? 0;
  };
  const records =
    (await counted('sales', 'cashier_id')) +
    (await counted('shifts', 'cashier_id')) +
    (await counted('cash_movements', 'user_id')) +
    (await counted('void_requests', 'requested_by')) +
    (await counted('pos_finance_entries', 'created_by'));

  if (records > 0) {
    const up = await db.from('pos_users').update(userStamp({
      deleted_at: new Date().toISOString(),
      token_version: (t.token_version ?? 0) + 1,
    })).eq('customer_id', ctx.customerId).eq('id', target);
    if (up.error) throw new Error(up.error.message);
  } else {
    const del = await db.from('pos_users').delete()
      .eq('customer_id', ctx.customerId).eq('id', target);
    if (del.error) throw new Error(del.error.message);
  }
  await audit(db, ctx.customerId, ctx.userId, 'USER_DELETED',
    `Account "${t.username}" was deleted${records > 0 ? ' (history retained)' : ''}.`);
  return json({ ok: true, retained: records > 0 });
}

async function loadActiveUser(db: any, customerId: string, userId: string): Promise<{ role: string; tokenVersion: number; permissions: string[] } | null> {
  const { data } = await db.from('pos_users').select('role, active, token_version, permissions')
    .eq('customer_id', customerId).eq('id', userId).eq('active', true).is('deleted_at', null).maybeSingle();
  if (!data) return null;
  const permissions = Array.isArray(data.permissions) ? data.permissions.map(String) : [];
  return { role: data.role, tokenVersion: Number(data.token_version ?? 0), permissions };
}

// ===========================================================================
// Finance (OWNER_ONLY enforced above)
// ===========================================================================
async function financeCategories(db: any, ctx: Ctx): Promise<Response> {
  const { data, error } = await db.from('pos_finance_categories').select('*')
    .eq('customer_id', ctx.customerId).is('deleted_at', null).order('name');
  if (error) throw new Error(error.message);
  // FinanceCategory.fromMap parses updated_at; back-fill it from created_at for
  // rows whose name has never been edited (updated_at is null in the table).
  const cats = strip(data).map((c: any) => ({ ...c, updated_at: c.updated_at ?? c.created_at }));
  return json({ ok: true, categories: cats });
}
// People in the recycle bin, newest trashed first.
async function financeDeletedCategories(db: any, ctx: Ctx): Promise<Response> {
  const { data, error } = await db.from('pos_finance_categories').select('*')
    .eq('customer_id', ctx.customerId).not('deleted_at', 'is', null)
    .order('deleted_at', { ascending: false });
  if (error) throw new Error(error.message);
  const cats = strip(data).map((c: any) => ({ ...c, updated_at: c.updated_at ?? c.created_at }));
  return json({ ok: true, categories: cats });
}
async function financeSummaries(db: any, ctx: Ctx): Promise<Response> {
  // Both reads are checked: an ignored error used to return zeroed totals, so
  // the owner read "nothing pending" off a failed query (audit 2 #12).
  const { data: cats, error: catErr } = await db.from('pos_finance_categories').select('id, name')
    .eq('customer_id', ctx.customerId).is('deleted_at', null).order('name');
  if (catErr) throw new Error(catErr.message);
  const { data: entries, error: entErr } = await db.from('pos_finance_entries').select('category_id, amount_minor_units')
    .eq('customer_id', ctx.customerId).eq('status', 'PENDING');
  if (entErr) throw new Error(entErr.message);
  const totals: Record<string, { count: number; total: number }> = {};
  for (const e of entries ?? []) {
    const t = (totals[e.category_id] ??= { count: 0, total: 0 });
    t.count++; t.total += Number(e.amount_minor_units);
  }
  return json({
    ok: true, summaries: (cats ?? []).map((c: any) => ({
      id: c.id, name: c.name,
      pending_count: totals[c.id]?.count ?? 0,
      pending_total: totals[c.id]?.total ?? 0,
    })),
  });
}
async function financeCreateCategory(db: any, ctx: Ctx, body: any): Promise<Response> {
  const name = str(body.name);
  if (!name) return json({ ok: false, error: 'A name is required.' }, 400);
  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  const { data, error } = await db.from('pos_finance_categories').insert({
    id, customer_id: ctx.customerId, name, created_at: now, updated_at: now,
  }).select().single();
  if (error) throw new Error(error.message);
  await audit(db, ctx.customerId, ctx.userId, 'FINANCE_CATEGORY_CREATED', `Person "${name}".`);
  return json({ ok: true, category: strip([data])[0] });
}
async function financeRenameCategory(db: any, ctx: Ctx, body: any): Promise<Response> {
  const newName = str(body.new_name);
  if (!newName) return json({ ok: false, error: 'A name is required.' }, 400);
  const id = String(body.category_id ?? '');
  // Round-trip the row: an unchecked update let a rename against a missing or
  // binned id answer ok:true and leave an audit line naming a change that never
  // happened (audit 2 #14).
  const up = await db.from('pos_finance_categories').update({ name: newName, updated_at: new Date().toISOString() })
    .eq('customer_id', ctx.customerId).eq('id', id).is('deleted_at', null).select('id, name');
  if (up.error) throw new Error(up.error.message);
  if (!Array.isArray(up.data) || up.data.length !== 1) {
    return json({ ok: false, error: 'Person not found.' }, 404);
  }
  await audit(db, ctx.customerId, ctx.userId, 'FINANCE_CATEGORY_RENAMED', `Person "${up.data[0].name}" renamed.`);
  return json({ ok: true });
}
// Soft-delete: move a person to the recycle bin, keeping their history.
async function financeDeleteCategory(db: any, ctx: Ctx, body: any): Promise<Response> {
  const id = String(body.category_id ?? '');
  const { data: existing } = await db.from('pos_finance_categories').select('id, name, deleted_at')
    .eq('customer_id', ctx.customerId).eq('id', id).maybeSingle();
  if (!existing) return json({ ok: false, error: 'Person not found.' }, 404);
  if (existing.deleted_at) return json({ ok: false, error: 'Person is already in the recycle bin.' }, 409);
  const now = new Date().toISOString();
  const up = await db.from('pos_finance_categories').update({ deleted_at: now, updated_at: now })
    .eq('customer_id', ctx.customerId).eq('id', id);
  if (up.error) throw new Error(up.error.message);
  await audit(db, ctx.customerId, ctx.userId, 'FINANCE_CATEGORY_DELETED', `Person "${existing.name}" to recycle bin.`);
  return json({ ok: true });
}
async function financeRestoreCategory(db: any, ctx: Ctx, body: any): Promise<Response> {
  const id = String(body.category_id ?? '');
  const { data: existing } = await db.from('pos_finance_categories').select('id, name, deleted_at')
    .eq('customer_id', ctx.customerId).eq('id', id).maybeSingle();
  if (!existing) return json({ ok: false, error: 'Person not found.' }, 404);
  if (!existing.deleted_at) return json({ ok: false, error: 'Person is not in the recycle bin.' }, 409);
  const now = new Date().toISOString();
  const up = await db.from('pos_finance_categories').update({ deleted_at: null, updated_at: now })
    .eq('customer_id', ctx.customerId).eq('id', id);
  if (up.error) throw new Error(up.error.message);
  await audit(db, ctx.customerId, ctx.userId, 'FINANCE_CATEGORY_RESTORED', `Person "${existing.name}" restored.`);
  return json({ ok: true });
}
// Permanent delete: only for a binned person. Entries and the person leave in
// one RPC transaction (audit 2 #15); the RPC writes the audit line itself.
async function financePermanentlyDeleteCategory(db: any, ctx: Ctx, body: any): Promise<Response> {
  const id = String(body.category_id ?? '');
  if (!id) return json({ ok: false, error: 'Person not found.' }, 404);
  const { error } = await db.rpc('pos_delete_finance_category', {
    p_customer: ctx.customerId, p_id: id, p_user: ctx.userId,
  });
  if (error) return rpcFailure(error.message);
  return json({ ok: true });
}
async function financeAddEntry(db: any, ctx: Ctx, body: any): Promise<Response> {
  const amount = Number(body.amount_minor_units ?? 0);
  if (amount <= 0) return json({ ok: false, error: 'Amount must be positive.' }, 400);
  const source = str(body.source);
  if (!source) return json({ ok: false, error: 'A source is required.' }, 400);
  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  const description = body.description == null ? null : str(body.description) || null;
  const paymentMethod = body.payment_method == null ? null : str(body.payment_method).toUpperCase() || null;
  const { data, error } = await db.from('pos_finance_entries').insert({
    id, customer_id: ctx.customerId, category_id: body.category_id, source: str(body.source),
    amount_minor_units: amount, description, status: 'PENDING', payment_method: paymentMethod,
    entry_date: body.entry_date ?? now, created_at: now, created_by: ctx.userId, updated_at: now,
  }).select().single();
  if (error) throw new Error(error.message);
  await audit(db, ctx.customerId, ctx.userId, 'FINANCE_ENTRY_ADDED', `${body.source} ${amount}.`);
  return json({ ok: true, entry: await withCategoryName(db, ctx, strip([data])[0]) });
}
async function financeUpdateEntry(db: any, ctx: Ctx, body: any): Promise<Response> {
  const amount = Number(body.amount_minor_units ?? 0);
  if (amount <= 0) return json({ ok: false, error: 'Amount must be positive.' }, 400);
  const description = body.description == null ? null : str(body.description) || null;
  const paymentMethod = body.payment_method == null ? null : str(body.payment_method).toUpperCase() || null;
  const up = await db.from('pos_finance_entries').update({
    source: str(body.source), amount_minor_units: amount,
    description, payment_method: paymentMethod, entry_date: body.entry_date ?? new Date().toISOString(),
    updated_at: new Date().toISOString(),
  }).eq('customer_id', ctx.customerId).eq('id', String(body.entry_id ?? '')).eq('status', 'PENDING').select('id');
  if (up.error) throw new Error(up.error.message);
  if (!up.data || up.data.length === 0) {
    return json({ ok: false, error: 'Entry not found or already completed.' }, 409);
  }
  await audit(db, ctx.customerId, ctx.userId, 'FINANCE_ENTRY_UPDATED', `Entry ${body.entry_id} edited.`);
  return json({ ok: true });
}
async function financeMarkCompleted(db: any, ctx: Ctx, body: any): Promise<Response> {
  const entryId = String(body.entry_id ?? '');
  if (!entryId) return json({ ok: false, error: 'Entry is not pending.' }, 409);
  // Flipping the entry to COMPLETED, depositing the CASH movement onto the open
  // shift, and the audit all commit in one transaction, so a completed entry
  // can never be missing its drawer deposit and become unretryable (audit
  // #4-finance). Non-cash collections never touch the drawer (handled in RPC).
  const { error } = await db.rpc('pos_complete_finance', {
    p_customer: ctx.customerId, p_user: ctx.userId, p_entry_id: entryId,
  });
  if (error) return rpcFailure(error.message);
  return json({ ok: true });
}
async function financeSearchEntries(db: any, ctx: Ctx, body: any): Promise<Response> {
  let q = db.from('pos_finance_entries').select('*').eq('customer_id', ctx.customerId)
    .order('entry_date', { ascending: false }).limit(pageLimit(body));
  if (body.category_id) q = q.eq('category_id', body.category_id);
  if (body.status && body.status !== 'ALL') q = q.eq('status', body.status);
  if (body.date_range_start) q = q.gte('entry_date', body.date_range_start);
  if (body.date_range_end) q = q.lt('entry_date', body.date_range_end);
  const query = str(body.search_query);
  if (query) {
    // Match source + description in the query; person-name matches resolve
    // against the hydrated category rows below (kept cheap by one join).
    const esc = query.replace(/[%_,()]/g, ' ');
    q = q.or(`source.ilike.%${esc}%,description.ilike.%${esc}%`);
  }
  const { data, error } = await q;
  if (error) throw new Error(error.message);
  // Drop entries that belong to binned people so they leave the active area.
  const { data: activeRows } = await db.from('pos_finance_categories').select('id')
    .eq('customer_id', ctx.customerId).is('deleted_at', null);
  const activeSet = new Set<string>((activeRows ?? []).map((c: any) => c.id));
  const entries = strip(data).filter((e: any) => activeSet.has(e.category_id));
  const cats = await categoryNames(db, ctx);
  for (const e of entries) {
    e.category_name = cats[e.category_id] ?? null;
    e.updated_at = e.updated_at ?? e.created_at;
    e.created_by = e.created_by ?? '';
  }
  if (query) {
    // Apply the person-name part of the search locally so it matches the native
    // behaviour that also searches the joined category name.
    const needle = query.toLowerCase();
    return json({
      ok: true,
      entries: entries.filter((e: any) =>
        String(e.source ?? '').toLowerCase().includes(needle) ||
        String(e.description ?? '').toLowerCase().includes(needle) ||
        String(e.category_name ?? '').toLowerCase().includes(needle)),
    });
  }
  return json({ ok: true, entries });
}
async function financePersonTotals(db: any, ctx: Ctx, body: any): Promise<Response> {
  // One SQL aggregate, not a row fetch: PostgREST caps a select at 1,000 rows,
  // so summing a busy person's entries in JavaScript understated their totals
  // once they passed that many. The RPC also answers zeros for a binned person.
  const { data, error } = await db.rpc('pos_finance_person_totals', {
    p_customer: ctx.customerId,
    p_category_id: String(body.category_id ?? ''),
  });
  if (error) throw new Error(error.message);
  const totals = data ?? {};
  return json({
    ok: true,
    totals: {
      pending_total: Number(totals.pending_total ?? 0),
      completed_total: Number(totals.completed_total ?? 0),
    },
  });
}

// Attaches the display-only category_name and guarantees FinanceEntry.fromMap's
// non-null parses (updated_at, created_by) for a freshly inserted row.
async function withCategoryName(db: any, ctx: Ctx, entry: any): Promise<any> {
  const cats = await categoryNames(db, ctx);
  return {
    ...entry,
    category_name: cats[entry.category_id] ?? null,
    updated_at: entry.updated_at ?? entry.created_at,
    created_by: entry.created_by ?? '',
  };
}
async function categoryNames(db: any, ctx: Ctx): Promise<Record<string, string>> {
  const { data } = await db.from('pos_finance_categories').select('id, name')
    .eq('customer_id', ctx.customerId);
  const map: Record<string, string> = {};
  for (const c of data ?? []) map[c.id] = c.name;
  return map;
}

// ===========================================================================
// Reporting, audit
// ===========================================================================
async function dashboardSummary(db: any, ctx: Ctx, body: any): Promise<Response> {
  const start = body.period_start ?? null;
  const end = body.period_end ?? null;
  // All headline totals come from the pos_sales_totals SQL aggregate so the
  // numbers stay exact past PostgREST's 1000-row fetch cap (audit #9).
  const { data: tot, error: totErr } = await db.rpc('pos_sales_totals', {
    p_customer: ctx.customerId, p_start: start, p_end: end,
  });
  if (totErr) throw new Error(totErr.message);
  const t = typeof tot === 'string' ? JSON.parse(tot) : (tot ?? {});
  const revenue = Number(t.revenue ?? 0);
  const count = Number(t.sales_count ?? 0);

  // Expected cash uses the currently open shift (mirrors the native dashboard).
  let expectedCash = 0;
  let shiftOpen = 0;
  const { data: openShift } = await db.from('shifts').select('*')
    .eq('customer_id', ctx.customerId).eq('status', 'OPEN').limit(1).maybeSingle();
  if (openShift) {
    shiftOpen = 1;
    expectedCash = await computeExpectedCash(db, ctx.customerId, openShift);
  }

  return json({
    ok: true,
    stats: {
      revenue,
      sales_count: count,
      cash_revenue: Number(t.cash_revenue ?? 0),
      bank_revenue: Number(t.bank_revenue ?? 0),
      average_sale: count === 0 ? 0 : Math.floor(revenue / count),
      expected_cash: expectedCash,
      is_shift_open: shiftOpen,
      void_count: Number(t.void_count ?? 0),
      pending_void_requests: Number(t.pending_void_requests ?? 0),
    },
  });
}

async function revenueTrend(db: any, ctx: Ctx, body: any): Promise<Response> {
  const { data, error } = await db.rpc('pos_revenue_trend', {
    p_customer: ctx.customerId, p_start: body.period_start ?? null, p_end: body.period_end ?? null,
  });
  if (error) throw new Error(error.message);
  const trend = typeof data === 'string' ? JSON.parse(data) : (data ?? []);
  return json({ ok: true, trend });
}

async function reportSummary(db: any, ctx: Ctx, body: any): Promise<Response> {
  const rangeStart = body.period_start ?? null;
  const rangeEnd = body.period_end ?? null;
  // Product mix aggregated in SQL (audit #9): exact across every matching line
  // item rather than the first 1000 sales PostgREST would return.
  const { data, error } = await db.rpc('pos_product_summary', {
    p_customer: ctx.customerId, p_start: rangeStart, p_end: rangeEnd,
  });
  if (error) throw new Error(error.message);
  const productSummary = typeof data === 'string' ? JSON.parse(data) : (data ?? []);
  return json({
    ok: true,
    product_summary: productSummary,
    cashier_performance: await cashierPerformance(db, ctx, rangeStart, rangeEnd),
  });
}

// Sales count + revenue per cashier, aggregated in SQL and hydrated with the
// operator username (cashier_id is the pos_users key) for the reports screen.
async function cashierPerformance(db: any, ctx: Ctx, start: any, end: any): Promise<any[]> {
  const { data, error } = await db.rpc('pos_cashier_performance', {
    p_customer: ctx.customerId, p_start: start ?? null, p_end: end ?? null,
  });
  if (error) throw new Error(error.message);
  const rows = (typeof data === 'string' ? JSON.parse(data) : (data ?? [])) as any[];
  const names = await usernamesById(db, ctx, rows.map((r: any) => r.cashier_id));
  return rows.map((r: any) => ({
    username: names[r.cashier_id] ?? null,
    total_sales: Number(r.total_sales ?? 0),
    total_revenue: Number(r.total_revenue ?? 0),
  }));
}

async function listAudit(db: any, ctx: Ctx, body: any): Promise<Response> {
  const limit = pageLimit(body, 500);
  const { data, error } = await db.from('pos_audit_logs').select('*')
    .eq('customer_id', ctx.customerId).order('created_at', { ascending: false })
    .limit(limit);
  if (error) throw new Error(error.message);
  const logs = strip(data);
  // `username` is display-only and never stored; joined from pos_users so the
  // Audit screen renders the same shape as the local SQLite implementation.
  const names = await usernamesById(db, ctx, logs.map((l: any) => l.user_id));
  for (const l of logs) l.username = l.user_id ? (names[l.user_id] ?? null) : null;
  return json({ ok: true, audit_logs: logs, truncated: logs.length >= limit });
}

// ===========================================================================
// Password hashing (PBKDF2-HMAC-SHA256, Web Crypto) + JWT (HMAC-SHA256)
// ===========================================================================
async function hashPassword(password: string): Promise<{ salt: string; hash: string }> {
  const saltBytes = new Uint8Array(16);
  crypto.getRandomValues(saltBytes);
  const salt = b64(saltBytes);
  const derived = await derive(password, saltBytes, PBKDF2_ITERATIONS);
  return { salt, hash: `${PBKDF2_ITERATIONS}$${b64(derived)}` };
}

async function verifyPassword(password: string, salt: string, stored: string): Promise<boolean> {
  const [iterStr, b64Hash] = stored.split('$');
  const iterations = Number(iterStr);
  if (!Number.isFinite(iterations) || iterations < 1000 || !b64Hash) return false;
  const derived = await derive(password, unB64(salt), iterations);
  return timingSafeEqualStr(b64(derived), b64Hash);
}

async function derive(password: string, salt: Uint8Array, iterations: number): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(password), 'PBKDF2', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', salt: salt as unknown as ArrayBuffer, iterations, hash: 'SHA-256' },
    key, 256);
  return new Uint8Array(bits);
}

async function signJwt(claims: { sub: string; cid: string; role: string; tv: number }): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: 'HS256', typ: 'JWT' };
  const payload = { ...claims, iat: now, exp: now + SESSION_TTL_SECONDS };
  const head = b64uStr(JSON.stringify(header));
  const body = b64uStr(JSON.stringify(payload));
  const sig = await hmac(`${head}.${body}`);
  return `${head}.${body}.${sig}`;
}

async function verifyJwt(token: string): Promise<{ userId: string; customerId: string; tv: number } | null> {
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  const expectSig = await hmac(`${parts[0]}.${parts[1]}`);
  if (!timingSafeEqualStr(expectSig, parts[2])) return null;
  let payload: any;
  try { payload = JSON.parse(atob(b64uToB64(parts[1]))); } catch { return null; }
  if (!payload || typeof payload.exp !== 'number' || payload.exp * 1000 < Date.now()) return null;
  if (!payload.sub || !payload.cid) return null;
  // Tokens minted before the token_version migration carry no tv -> treated as
  // 0, matching the column DEFAULT, so existing persistent sessions survive.
  return { userId: String(payload.sub), customerId: String(payload.cid), tv: Number(payload.tv ?? 0) };
}

async function hmac(data: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(JWT_SECRET), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(data));
  return b64u(new Uint8Array(sig));
}

// ===========================================================================
// Small shared helpers
// ===========================================================================
type Ctx = { customerId: string; userId: string; role: string; deviceId: string | null };

// Stamps ownership + defaults; strips any client-supplied customer_id so a
// crafted body can never target another tenant.
function tenantRow(ctx: Ctx, src: any, defaults: Record<string, unknown>): any {
  const { customer_id: _drop, ...rest } = src;
  return { ...rest, ...defaults, customer_id: ctx.customerId };
}

async function hydrateItems(db: any, ctx: Ctx, sales: any[]) {
  if (!sales.length) return;
  const ids = sales.map((s) => s.id);
  const { data: items } = await db.from('sale_items').select('*')
    .eq('customer_id', ctx.customerId).in('sale_id', ids);
  const bySale: Record<string, any[]> = {};
  for (const it of strip(items)) (bySale[it.sale_id] ??= []).push(it);
  for (const s of sales) s.items = bySale[s.id] ?? [];
}

// Resolves a set of pos_users ids to { id: username } in one query. Nulls and
// duplicates are ignored; unknown ids simply fall back to null at the caller.
async function usernamesById(db: any, ctx: Ctx, ids: (string | null)[]): Promise<Record<string, string>> {
  const unique = [...new Set(ids.filter((x): x is string => !!x))];
  if (!unique.length) return {};
  const { data } = await db.from('pos_users').select('id, username')
    .eq('customer_id', ctx.customerId).in('id', unique);
  const map: Record<string, string> = {};
  for (const u of data ?? []) map[u.id] = u.username;
  return map;
}

// Keeps the training account's rows out of a list. PostgREST cannot express the
// native `NOT IN (SELECT id FROM users WHERE is_demo = 1)` in one filter, so the
// demo ids are resolved first — one row per tenant, so the inline list stays
// short, and a tenant without a demo account is returned untouched. The report
// aggregates do the same exclusion inside their SQL RPCs.
//
// The id lookup and the filter application are deliberately split. `excludeDemoRows`
// returns a PostgREST builder, which is a *thenable*; if it were `async`, callers
// writing `q = await excludeDemoRows(q, …)` would adopt that thenable and execute
// the query early, leaving `q` as a `{data, error}` result with no `.limit()`. So
// the async half (`demoUserIds`) returns a plain id array and the sync half just
// chains `.not()` onto the still-live builder.
async function demoUserIds(db: any, ctx: Ctx): Promise<string[]> {
  const { data, error } = await db.from('pos_users').select('id')
    .eq('customer_id', ctx.customerId).eq('is_demo', true);
  if (error) throw new Error(error.message);
  return strip(data).map((r: any) => r.id) as string[];
}

function excludeDemoRows(q: any, ids: string[], column: string): any {
  if (!ids.length) return q;
  return q.not(column, 'in', `(${ids.map((id) => `"${id}"`).join(',')})`);
}

// Sale ids that currently have a PENDING void request, for the flag the sales
// history screen shows next to a cashier-requested void.
async function pendingSaleIds(db: any, ctx: Ctx, saleIds: string[]): Promise<Set<string>> {
  const unique = [...new Set(saleIds.filter(Boolean))];
  if (!unique.length) return new Set();
  const { data } = await db.from('void_requests').select('sale_id')
    .eq('customer_id', ctx.customerId).eq('status', 'PENDING').in('sale_id', unique);
  return new Set((data ?? []).map((r: any) => r.sale_id));
}

async function audit(db: any, customerId: string, userId: string | null, action: string, details: string) {
  // Audit must never block a write, but a dropped audit row is itself a finding,
  // so a failure is logged instead of swallowed (audit #11). Mutation RPCs write
  // their audit row inside the same transaction and are the authoritative trail.
  try {
    const { error } = await db.from('pos_audit_logs').insert({
      id: crypto.randomUUID(), customer_id: customerId, user_id: userId,
      action, details, created_at: new Date().toISOString(),
    });
    if (error) console.error('audit insert failed:', action, error.message);
  } catch (err) {
    console.error('audit insert threw:', action, err);
  }
}

function strip(rows: any[] | null): any[] {
  return (rows ?? []).map((r) => { const { customer_id: _c, received_at: _r, ...rest } = r; return rest; });
}
function deSnake(row: any): any { return row; }

function str(v: unknown): string { return typeof v === 'string' ? v.trim() : ''; }

// PostgREST caps every response at 1000 rows and says nothing about it, so an
// unbounded ledger query used to truncate silently (audit #13). Lists ask for
// an explicit page and report `truncated` when the page came back full, so the
// screen can say "showing the newest N" rather than quietly losing rows.
const MAX_PAGE = 1000;
function pageLimit(body: any, fallback: number = MAX_PAGE): number {
  const n = Number(body?.limit);
  if (!Number.isFinite(n) || n <= 0) return fallback;
  return Math.min(Math.floor(n), MAX_PAGE);
}

// Maps a raised Postgres EXCEPTION (from a SECURITY DEFINER RPC) back to a
// structured 4xx so the client sees the same ok:false/error contract it would
// from a native failure, instead of a generic 500. Not-found / conflict wording
// keeps its status; anything else is a client-correctable 400.
function rpcFailure(message: string): Response {
  const m = String(message || '').trim();
  if (/not found|no longer|already voided|not voidable|not pending|already decided|already open|already exists|no longer open/i.test(m)) {
    return json({ ok: false, error: m }, 409);
  }
  return json({ ok: false, error: m || 'Operation rejected.' }, 400);
}

function b64(bytes: Uint8Array): string {
  let s = ''; for (const x of bytes) s += String.fromCharCode(x);
  return btoa(s);
}
function unB64(s: string): Uint8Array {
  const bin = atob(s); const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function b64u(bytes: Uint8Array): string { return b64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''); }
function b64uStr(s: string): string { return b64u(new TextEncoder().encode(s)); }
function b64uToB64(s: string): string { return s.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (s.length % 4)) % 4); }
function timingSafeEqualStr(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } });
}