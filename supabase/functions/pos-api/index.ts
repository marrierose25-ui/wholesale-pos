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

// Actions that need an OWNER token. Everything authenticated is at least a
// valid (inactive-revoked-checked) session for the tenant.
//
// This set MUST mirror the owner-only screens in the client nav matrix
// (app/lib/app_shell.dart): Owner sees Dashboard / Money Tracking / Users /
// Audit / Register History / Reports; a Cashier sees only POS / Register /
// History / Settings. Reads the cashier's own Register/POS flow needs
// (ensure_shift, register_snapshot, next_receipt_number, insert_sale,
// request_void, open_shift/close_shift, add_cash_movement) stay OUT of this
// set. list_void_requests/shift_summary are owner-gated in the UI, so they
// belong here even though the Register screen builds for everyone.
const OWNER_ONLY = new Set([
  // Voids: a cashier may request_void, only an owner may void/approve/reject.
  'void_sale', 'approve_void', 'reject_void', 'list_void_requests',
  // User administration.
  'list_users', 'create_user', 'reset_password', 'set_user_active',
  // Money tracking (people + entries) incl. the recycle-bin mutations.
  'finance_categories', 'finance_deleted_categories', 'finance_summaries',
  'finance_create_category', 'finance_rename_category', 'finance_delete_category',
  'finance_restore_category', 'finance_permanently_delete_category',
  'finance_add_entry', 'finance_update_entry', 'finance_mark_completed',
  'finance_search_entries', 'finance_person_totals',
  // Ledger browsing + reporting aggregates (cross-shift; owner-only views).
  'list_cash_movements', 'shift_history', 'shift_summary',
  'dashboard_summary', 'revenue_trend', 'report_summary',
  'list_audit',
]);

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
    if (OWNER_ONLY.has(action) && actor.role !== OWNER) {
      return json({ ok: false, error: 'Owner access required.' }, 403);
    }

    const ctx = { customerId: session.customerId, userId: session.userId, role: actor.role };

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
      case 'list_void_requests': return await listVoidRequests(db, ctx);
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
      case 'reset_password': return await resetPassword(db, ctx, body);
      case 'set_user_active': return await setUserActive(db, ctx, body);

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

      // Settings, counters, reporting
      case 'get_setting': return await getSetting(db, ctx, body);
      case 'set_setting': return await setSetting(db, ctx, body);
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

// Resolves an activation code to its tenant, refusing revoked licenses. The
// activation code is itself the shared secret proving tenancy (same trust the
// licensing/sync functions already place in it).
async function tenantForActivationCode(db: any, code: string): Promise<string | null> {
  if (!code) return null;
  const { data } = await db
    .from('licenses').select('customer_id, revoked_at')
    .eq('activation_code', code).maybeSingle();
  if (!data || data.revoked_at) return null;
  return String(data.customer_id);
}

async function hasUsers(db: any, body: any): Promise<Response> {
  const code = str(body.activation_code);
  const customerId = await tenantForActivationCode(db, code);
  if (!customerId) return json({ ok: false, error: 'Invalid activation code.' }, 403);
  const { count } = await db.from('pos_users')
    .select('*', { count: 'exact', head: true }).eq('customer_id', customerId);
  return json({ ok: true, has_users: (count ?? 0) > 0 });
}

async function login(db: any, body: any): Promise<Response> {
  const code = str(body.activation_code);
  const username = str(body.username);
  const password = String(body.password ?? '');
  if (!code || !username || !password) return json({ ok: false, error: 'Missing fields' }, 400);
  const customerId = await tenantForActivationCode(db, code);
  if (!customerId) return json({ ok: false, error: 'Invalid activation code.' }, 403);

  const { data: user } = await db.from('pos_users')
    .select('*').eq('customer_id', customerId).eq('username', username)
    .eq('active', true).maybeSingle();
  if (!user) return json({ ok: false, error: 'Invalid credentials.' }, 401);

  const ok = await verifyPassword(password, user.pw_salt, user.pw_hash);
  if (!ok) return json({ ok: false, error: 'Invalid credentials.' }, 401);

  const token = await signJwt({ sub: user.id, cid: customerId, role: user.role });
  return json({
    ok: true, token,
    user_id: user.id, username: user.username, role: user.role,
    customer_id: customerId,
    expires_at: new Date(Date.now() + SESSION_TTL_SECONDS * 1000).toISOString(),
  });
}

// First-owner bootstrap: allowed ONLY while the tenant has no accounts, so an
// owner's first web sign-in (armed with the activation code) seeds their login.
async function setupOwner(db: any, body: any): Promise<Response> {
  const code = str(body.activation_code);
  const username = str(body.username);
  const password = String(body.password ?? '');
  if (!code || !username || !password) return json({ ok: false, error: 'Missing fields' }, 400);
  const customerId = await tenantForActivationCode(db, code);
  if (!customerId) return json({ ok: false, error: 'Invalid activation code.' }, 403);

  const { count } = await db.from('pos_users')
    .select('*', { count: 'exact', head: true }).eq('customer_id', customerId);
  if ((count ?? 0) > 0) return json({ ok: false, error: 'Owner already exists.' }, 409);

  const minLen = 12; // owner policy, matches UserRepository.ownerPasswordLength
  if (password.length < minLen) {
    return json({ ok: false, error: `Password must be at least ${minLen} characters.` }, 400);
  }
  const { salt, hash } = await hashPassword(password);
  const id = crypto.randomUUID();
  const ins = await db.from('pos_users').insert({
    id, customer_id: customerId, username, role: OWNER,
    pw_salt: salt, pw_hash: hash, active: true,
  });
  if (ins.error) throw new Error(ins.error.message);
  await audit(db, customerId, id, 'OWNER_CREATED', `Web owner "${username}" created.`);
  const token = await signJwt({ sub: id, cid: customerId, role: OWNER });
  return json({ ok: true, token, user_id: id, username, role: OWNER, customer_id: customerId });
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
  const up = await db.from('pos_users').update({ pw_salt: salt, pw_hash: hash })
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
  if (await duplicateName(db, ctx, String(p.name ?? ''), null)) {
    return json({ ok: false, error: 'A saved name already exists.' }, 409);
  }
  const row = tenantRow(ctx, p, {
    id: p.id ?? crypto.randomUUID(),
    is_active: 1,
    created_at: p.created_at ?? new Date().toISOString(),
  });
  const ins = await db.from('pos_products').insert(row);
  if (ins.error) throw new Error(ins.error.message);
  return json({ ok: true, id: row.id });
}

async function updateProduct(db: any, ctx: Ctx, body: any): Promise<Response> {
  const p = body.product ?? {};
  if (!p.id) return json({ ok: false, error: 'Missing product id.' }, 400);
  if (await duplicateName(db, ctx, String(p.name ?? ''), String(p.id))) {
    return json({ ok: false, error: 'A saved name already exists.' }, 409);
  }
  const up = await db.from('pos_products').update({
    name: p.name, code: p.code ?? null, category: p.category ?? null, unit: p.unit ?? null,
    selling_price_minor_units: p.selling_price_minor_units ?? 0,
    is_active: p.is_active ?? 1,
    updated_at: new Date().toISOString(),
  }).eq('customer_id', ctx.customerId).eq('id', p.id);
  if (up.error) throw new Error(up.error.message);
  return json({ ok: true });
}

async function setProductActive(db: any, ctx: Ctx, body: any, active: number): Promise<Response> {
  const up = await db.from('pos_products').update({
    is_active: active, updated_at: new Date().toISOString(),
  }).eq('customer_id', ctx.customerId).eq('id', String(body.id ?? ''));
  if (up.error) throw new Error(up.error.message);
  return json({ ok: true });
}

async function duplicateName(db: any, ctx: Ctx, name: string, excludeId: string | null) {
  const trimmed = name.trim().toLowerCase();
  if (!trimmed) return false;
  let q = db.from('pos_products').select('id')
    .eq('customer_id', ctx.customerId).filter(`lower(name)`, 'eq', trimmed);
  if (excludeId) q = q.neq('id', excludeId);
  const { data } = await q.maybeSingle();
  return !!data;
}

// ===========================================================================
// Sales
// ===========================================================================
async function nextReceiptNumber(db: any, ctx: Ctx): Promise<Response> {
  const now = new Date();
  const day = `${now.getUTCFullYear()}${String(now.getUTCMonth() + 1).padStart(2, '0')}${String(now.getUTCDate()).padStart(2, '0')}`;
  const name = `receipt-${day}`;
  const { data: cur } = await db.from('pos_counters').select('value')
    .eq('customer_id', ctx.customerId).eq('name', name).maybeSingle();
  const value = cur ? Number(cur.value) + 1 : 1;
  const up = await db.from('pos_counters').upsert(
    { customer_id: ctx.customerId, name, value }, { onConflict: 'customer_id,name' });
  if (up.error) throw new Error(up.error.message);
  return json({ ok: true, receipt_number: `REC-${day}-${String(value).padStart(4, '0')}` });
}

async function insertSale(db: any, ctx: Ctx, body: any): Promise<Response> {
  const sale = body.sale ?? {};
  const items = Array.isArray(body.items) ? body.items : [];
  if (!sale.id || items.length === 0) return json({ ok: false, error: 'Incomplete sale.' }, 400);
  const subtotal = Number(sale.subtotal_minor_units ?? 0);
  const discount = Number(sale.discount_minor_units ?? 0);
  const total = Number(sale.total_minor_units ?? 0);
  if (total !== subtotal - discount || total < 0) {
    return json({ ok: false, error: 'Sale totals do not match.' }, 400);
  }
  // Require an OPEN shift owned by this tenant.
  const { data: shift } = await db.from('shifts').select('id')
    .eq('customer_id', ctx.customerId).eq('id', sale.shift_id).eq('status', 'OPEN').maybeSingle();
  if (!shift) return json({ ok: false, error: 'Sale requires an open shift.' }, 400);

  const saleRow = tenantRow(ctx, sale, { status: 'COMPLETED', created_at: new Date().toISOString() });
  const ins = await db.from('sales').insert(saleRow);
  if (ins.error) throw new Error(`insert sale: ${ins.error.message}`);
  const itemRows = items.map((it: any) => tenantRow(ctx, it, {}));
  const insItems = await db.from('sale_items').insert(itemRows);
  if (insItems.error) {
    // Compensate: the sale is the parent, so a failed item batch must roll it
    // back to keep the ledger consistent (best-effort; sync gateway is likewise
    // non-atomic). 
    await db.from('sales').delete().eq('customer_id', ctx.customerId).eq('id', sale.id);
    throw new Error(`insert items: ${insItems.error.message}`);
  }
  await audit(db, ctx.customerId, ctx.userId, 'SALE_COMPLETED',
    `Total: ${total} minor units, Lines: ${items.length}`);
  return json({ ok: true, id: sale.id });
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
    const { data: itemRows } = await db.from('sale_items').select('sale_id')
      .eq('customer_id', ctx.customerId)
      .or(`product_name_snapshot.ilike.%${esc}%,quantity_text.ilike.%${esc}%,notes.ilike.%${esc}%`);
    const { data: userRows } = await db.from('pos_users').select('id')
      .eq('customer_id', ctx.customerId).ilike('username', `%${esc}%`);
    const userIds = strip(userRows).map((r: any) => r.id);
    let cashierSaleIds: string[] = [];
    if (userIds.length) {
      const { data: cs } = await db.from('sales').select('id')
        .eq('customer_id', ctx.customerId).in('cashier_id', userIds);
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
  if (body.limit) q = q.limit(Number(body.limit));
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
  return json({ ok: true, sales });
}

async function voidSale(db: any, ctx: Ctx, body: any): Promise<Response> {
  const reason = str(body.reason);
  if (!reason || reason.length > 240) return json({ ok: false, error: 'Void reason required.' }, 400);
  const { data: sale } = await db.from('sales').select('status')
    .eq('customer_id', ctx.customerId).eq('id', String(body.sale_id ?? '')).maybeSingle();
  if (!sale) return json({ ok: false, error: 'Sale not found.' }, 404);
  if (sale.status === 'VOIDED') return json({ ok: false, error: 'Already voided.' }, 409);
  const { data: active } = await db.from('shifts').select('id')
    .eq('customer_id', ctx.customerId).eq('status', 'OPEN').maybeSingle();
  const up = await db.from('sales').update({
    status: 'VOIDED', void_reason: reason, voided_at: new Date().toISOString(),
    voided_by: ctx.userId, voided_shift_id: active ? active.id : null,
  }).eq('customer_id', ctx.customerId).eq('id', body.sale_id);
  if (up.error) throw new Error(up.error.message);
  await audit(db, ctx.customerId, ctx.userId, 'SALE_VOIDED', `Sale ${body.sale_id}: ${reason}`);
  return json({ ok: true });
}

async function requestVoid(db: any, ctx: Ctx, body: any): Promise<Response> {
  const reason = str(body.reason);
  if (!reason || reason.length > 240) return json({ ok: false, error: 'Void reason required.' }, 400);
  const { data: sale } = await db.from('sales').select('status')
    .eq('customer_id', ctx.customerId).eq('id', String(body.sale_id ?? '')).maybeSingle();
  if (!sale || sale.status !== 'COMPLETED') return json({ ok: false, error: 'Sale not voidable.' }, 400);
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

async function listVoidRequests(db: any, ctx: Ctx): Promise<Response> {
  const { data, error } = await db.from('void_requests').select('*')
    .eq('customer_id', ctx.customerId).eq('status', 'PENDING')
    .order('created_at', { ascending: false });
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
  const { data: vr } = await db.from('void_requests').select('*')
    .eq('customer_id', ctx.customerId).eq('id', String(body.request_id ?? '')).maybeSingle();
  if (!vr) return json({ ok: false, error: 'Request not found.' }, 404);
  if (vr.status !== 'PENDING') return json({ ok: false, error: 'Already decided.' }, 409);
  const patch: any = { status: decision, decided_by: ctx.userId, decided_at: new Date().toISOString() };
  const up = await db.from('void_requests').update(patch)
    .eq('customer_id', ctx.customerId).eq('id', vr.id);
  if (up.error) throw new Error(up.error.message);
  if (decision === 'APPROVED') {
    const { data: active } = await db.from('shifts').select('id')
      .eq('customer_id', ctx.customerId).eq('status', 'OPEN').maybeSingle();
    await db.from('sales').update({
      status: 'VOIDED', void_reason: vr.reason, voided_at: new Date().toISOString(),
      voided_by: ctx.userId, voided_shift_id: active ? active.id : null,
    }).eq('customer_id', ctx.customerId).eq('id', vr.sale_id);
  }
  await audit(db, ctx.customerId, ctx.userId, `VOID_${decision}`, `Request ${vr.id} ${decision.toLowerCase()}.`);
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
// exists so the register screen always has a balance to show. Racy double-open
// is prevented server-side by re-checking inside the insert guard.
async function ensureShift(db: any, ctx: Ctx): Promise<Response> {
  const { data: existing } = await db.from('shifts').select('*')
    .eq('customer_id', ctx.customerId).eq('status', 'OPEN').limit(1).maybeSingle();
  if (existing) return json({ ok: true, shift: deSnake(existing) });
  const id = crypto.randomUUID();
  const ins = await db.from('shifts').insert({
    id, customer_id: ctx.customerId, cashier_id: ctx.userId,
    opening_cash_minor_units: 0, status: 'OPEN', opened_at: new Date().toISOString(),
  }).select().maybeSingle();
  if (ins.error) throw new Error(ins.error.message);
  // Another request may have opened a shift concurrently; prefer the OPEN row.
  const { data: open } = await db.from('shifts').select('*')
    .eq('customer_id', ctx.customerId).eq('status', 'OPEN').limit(1).maybeSingle();
  return json({ ok: true, shift: deSnake(open ?? ins.data) });
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
  const start = body.period_start; const end = body.period_end;
  const inDay = (q: any) => { if (start) q = q.gte('created_at', start); if (end) q = q.lt('created_at', end); return q; };
  const sumSales = async (method: string) => {
    let q = db.from('sales').select('total_minor_units')
      .eq('customer_id', ctx.customerId).eq('shift_id', shift.id)
      .eq('status', 'COMPLETED').eq('payment_method', method);
    q = inDay(q);
    const { data } = await q;
    return (data ?? []).reduce((s: number, r: any) => s + Number(r.total_minor_units), 0);
  };
  let mq = db.from('cash_movements').select('type, amount_minor_units')
    .eq('customer_id', ctx.customerId).eq('shift_id', shift.id);
  mq = inDay(mq);
  const { data: mvs } = await mq;
  let deposits = 0, withdrawals = 0;
  for (const m of mvs ?? []) {
    if (m.type === 'DEPOSIT') deposits += Number(m.amount_minor_units);
    else withdrawals += Number(m.amount_minor_units);
  }
  return json({ ok: true, snapshot: {
    balance, today_cash_sales: await sumSales('CASH'), today_bank_sales: await sumSales('BANK'),
    today_deposits: deposits, today_withdrawals: withdrawals } });
}

async function shiftHistory(db: any, ctx: Ctx, body: any): Promise<Response> {
  let q = db.from('shifts').select('*').eq('customer_id', ctx.customerId)
    .order('opened_at', { ascending: false });
  if (body.status) q = q.eq('status', body.status);
  if (body.period_start) q = q.gte('opened_at', body.period_start);
  if (body.period_end) q = q.lt('opened_at', body.period_end);
  const { data, error } = await q;
  if (error) throw new Error(error.message);
  return json({ ok: true, shifts: strip(data) });
}

async function openShift(db: any, ctx: Ctx, body: any): Promise<Response> {
  const opening = Number(body.opening_cash_minor_units ?? 0);
  if (opening < 0) return json({ ok: false, error: 'Opening cash cannot be negative.' }, 400);
  const { data: existing } = await db.from('shifts').select('id')
    .eq('customer_id', ctx.customerId).eq('status', 'OPEN').maybeSingle();
  if (existing) return json({ ok: false, error: 'A shift is already open.' }, 409);
  const id = crypto.randomUUID();
  const ins = await db.from('shifts').insert({
    id, customer_id: ctx.customerId, cashier_id: ctx.userId,
    opening_cash_minor_units: opening, status: 'OPEN',
    opened_at: new Date().toISOString(),
  });
  if (ins.error) throw new Error(ins.error.message);
  await audit(db, ctx.customerId, ctx.userId, 'SHIFT_OPENED', `Shift ${id} opened.`);
  return json({ ok: true, id });
}

async function closeShift(db: any, ctx: Ctx, body: any): Promise<Response> {
  const closing = Number(body.closing_cash_minor_units ?? 0);
  if (closing < 0) return json({ ok: false, error: 'Closing cash cannot be negative.' }, 400);
  const shiftId = String(body.shift_id ?? '');
  const { data: shift } = await db.from('shifts').select('*')
    .eq('customer_id', ctx.customerId).eq('id', shiftId).eq('status', 'OPEN').maybeSingle();
  if (!shift) return json({ ok: false, error: 'Shift is no longer open.' }, 409);
  const expected = await computeExpectedCash(db, ctx.customerId, shift);
  const up = await db.from('shifts').update({
    closing_cash_minor_units: closing, expected_cash_minor_units: expected,
    status: 'CLOSED', closed_at: new Date().toISOString(),
  }).eq('customer_id', ctx.customerId).eq('id', shiftId).eq('status', 'OPEN');
  if (up.error) throw new Error(up.error.message);
  await audit(db, ctx.customerId, ctx.userId, 'SHIFT_CLOSED',
    `Expected ${expected}, Counted ${closing}, Difference ${closing - expected}.`);
  return json({ ok: true, expected_cash_minor_units: expected });
}

// Reconciliation shared by shift_summary + close_shift. Mirrors
// ShiftRepository.getShiftSummary exactly, including the cross-shift cash
// refund netting rule (a sale rung up in another shift but refunded while this
// one was open is the only void that drains THIS drawer).
async function computeExpectedCash(db: any, customerId: string, shift: any): Promise<number> {
  const opening = Number(shift.opening_cash_minor_units ?? 0);
  const { data: cash } = await db.from('sales').select('total_minor_units')
    .eq('customer_id', customerId).eq('shift_id', shift.id).eq('status', 'COMPLETED').eq('payment_method', 'CASH');
  const cashTotal = (cash ?? []).reduce((s: number, r: any) => s + Number(r.total_minor_units), 0);
  const { data: mvs } = await db.from('cash_movements').select('type, amount_minor_units')
    .eq('customer_id', customerId).eq('shift_id', shift.id);
  let deposits = 0, withdrawals = 0;
  for (const m of mvs ?? []) {
    if (m.type === 'DEPOSIT') deposits += Number(m.amount_minor_units);
    else withdrawals += Number(m.amount_minor_units);
  }
  const { data: refunds } = await db.from('sales').select('total_minor_units')
    .eq('customer_id', customerId).eq('status', 'VOIDED').eq('payment_method', 'CASH')
    .eq('voided_shift_id', shift.id).neq('shift_id', shift.id);
  const refundTotal = (refunds ?? []).reduce((s: number, r: any) => s + Number(r.total_minor_units), 0);
  return opening + cashTotal + deposits - withdrawals - refundTotal;
}

async function shiftSummary(db: any, ctx: Ctx, body: any): Promise<Response> {
  const { data: shift } = await db.from('shifts').select('*')
    .eq('customer_id', ctx.customerId).eq('id', String(body.shift_id ?? '')).maybeSingle();
  if (!shift) return json({ ok: false, error: 'Shift not found.' }, 404);
  const sumBy = async (filter: (q: any) => any) => {
    const { data } = await filter(db.from('sales').select('total_minor_units').eq('customer_id', ctx.customerId));
    return (data ?? []).reduce((s: number, r: any) => s + Number(r.total_minor_units), 0);
  };
  const cashSales = await sumBy((q) => q.eq('shift_id', shift.id).eq('status', 'COMPLETED').eq('payment_method', 'CASH'));
  const bankSales = await sumBy((q) => q.eq('shift_id', shift.id).eq('status', 'COMPLETED').eq('payment_method', 'BANK'));
  const { data: mvs } = await db.from('cash_movements').select('type, amount_minor_units')
    .eq('customer_id', ctx.customerId).eq('shift_id', shift.id);
  let deposits = 0, withdrawals = 0;
  for (const m of mvs ?? []) {
    if (m.type === 'DEPOSIT') deposits += Number(m.amount_minor_units);
    else withdrawals += Number(m.amount_minor_units);
  }
  const { data: voidRows } = await db.from('sales').select('total_minor_units')
    .eq('customer_id', ctx.customerId).eq('status', 'VOIDED')
    .or(`voided_shift_id.eq.${shift.id},and(shift_id.eq.${shift.id},voided_shift_id.is.null)`);
  const voids = (voidRows ?? []).reduce((s: number, r: any) => s + Number(r.total_minor_units), 0);
  const { data: refundRows } = await db.from('sales').select('total_minor_units')
    .eq('customer_id', ctx.customerId).eq('status', 'VOIDED').eq('payment_method', 'CASH')
    .eq('voided_shift_id', shift.id).neq('shift_id', shift.id);
  const cashRefunds = (refundRows ?? []).reduce((s: number, r: any) => s + Number(r.total_minor_units), 0);
  const expected = await computeExpectedCash(db, ctx.customerId, shift);
  return json({
    ok: true,
    summary: {
      cash_sales: cashSales, bank_sales: bankSales, voids,
      deposits, withdrawals, cash_refunds: cashRefunds,
      expected_cash: expected,
    },
  });
}

async function addCashMovement(db: any, ctx: Ctx, body: any): Promise<Response> {
  const amount = Number(body.amount_minor_units ?? 0);
  const type = String(body.type ?? '');
  if (amount <= 0) return json({ ok: false, error: 'Amount must be positive.' }, 400);
  if (!['WITHDRAWAL', 'DEPOSIT', 'EXPENSE'].includes(type)) return json({ ok: false, error: 'Invalid movement type.' }, 400);
  const { data: shift } = await db.from('shifts').select('id')
    .eq('customer_id', ctx.customerId).eq('id', String(body.shift_id ?? '')).eq('status', 'OPEN').maybeSingle();
  if (!shift) return json({ ok: false, error: 'Movement requires an open shift.' }, 400);
  const id = crypto.randomUUID();
  const ins = await db.from('cash_movements').insert({
    id, customer_id: ctx.customerId, shift_id: body.shift_id, user_id: ctx.userId,
    type, amount_minor_units: amount, reason: str(body.reason),
    created_at: new Date().toISOString(),
  });
  if (ins.error) throw new Error(ins.error.message);
  await audit(db, ctx.customerId, ctx.userId, 'CASH_MOVEMENT_ADDED', `${type} ${amount}.`);
  return json({ ok: true, id });
}

async function listCashMovements(db: any, ctx: Ctx, body: any): Promise<Response> {
  // shift_id optional: omit it to list the whole ledger across every shift.
  let q = db.from('cash_movements').select('*').eq('customer_id', ctx.customerId);
  if (body.shift_id != null && String(body.shift_id) !== '') {
    q = q.eq('shift_id', String(body.shift_id));
  }
  const { data, error } = await q.order('created_at', { ascending: false });
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
  return json({ ok: true, movements: rows.map((r: any) => ({ ...r, user_name: nameById[r.user_id] ?? null })) });
}

// ===========================================================================
// Users (OWNER_ONLY enforced above)
// ===========================================================================
async function listUsers(db: any, ctx: Ctx): Promise<Response> {
  const { data, error } = await db.from('pos_users')
    .select('id, username, role, active, created_at').eq('customer_id', ctx.customerId)
    .order('username');
  if (error) throw new Error(error.message);
  return json({ ok: true, users: strip(data) });
}

async function createUser(db: any, ctx: Ctx, body: any): Promise<Response> {
  const username = str(body.username);
  const role = String(body.role ?? '');
  const password = String(body.password ?? '');
  if (!username) return json({ ok: false, error: 'Username required.' }, 400);
  if (![OWNER, CASHIER].includes(role)) return json({ ok: false, error: 'Invalid role.' }, 400);
  const minLen = role === OWNER ? 12 : 8;
  if (password.length < minLen) return json({ ok: false, error: `Password must be at least ${minLen} characters.` }, 400);
  const { data: dup } = await db.from('pos_users').select('id')
    .eq('customer_id', ctx.customerId).filter('lower(username)', 'eq', username.toLowerCase()).maybeSingle();
  if (dup) return json({ ok: false, error: 'Username is already taken.' }, 409);
  const { salt, hash } = await hashPassword(password);
  const id = crypto.randomUUID();
  const ins = await db.from('pos_users').insert({
    id, customer_id: ctx.customerId, username, role, pw_salt: salt, pw_hash: hash, active: true,
  });
  if (ins.error) throw new Error(ins.error.message);
  await audit(db, ctx.customerId, ctx.userId, 'USER_CREATED', `User "${username}" (${role}).`);
  return json({ ok: true, id });
}

async function resetPassword(db: any, ctx: Ctx, body: any): Promise<Response> {
  const target = String(body.target_user_id ?? '');
  const password = String(body.new_password ?? '');
  const { data: t } = await db.from('pos_users').select('role, username')
    .eq('customer_id', ctx.customerId).eq('id', target).maybeSingle();
  if (!t) return json({ ok: false, error: 'User not found.' }, 404);
  const minLen = t.role === OWNER ? 12 : 8;
  if (password.length < minLen) return json({ ok: false, error: `Password must be at least ${minLen} characters.` }, 400);
  const { salt, hash } = await hashPassword(password);
  const up = await db.from('pos_users').update({ pw_salt: salt, pw_hash: hash })
    .eq('customer_id', ctx.customerId).eq('id', target);
  if (up.error) throw new Error(up.error.message);
  await audit(db, ctx.customerId, ctx.userId, 'PASSWORD_RESET', `Password reset for "${t.username}".`);
  return json({ ok: true });
}

async function setUserActive(db: any, ctx: Ctx, body: any): Promise<Response> {
  const target = String(body.target_user_id ?? '');
  const active = body.active === true;
  if (target === ctx.userId && !active) return json({ ok: false, error: 'You cannot deactivate your own account.' }, 400);
  if (!active) {
    const { data: t } = await db.from('pos_users').select('role').eq('customer_id', ctx.customerId).eq('id', target).maybeSingle();
    if (t?.role === OWNER) {
      const { count } = await db.from('pos_users').select('*', { count: 'exact', head: true })
        .eq('customer_id', ctx.customerId).eq('role', OWNER).eq('active', true);
      if ((count ?? 0) <= 1) return json({ ok: false, error: 'At least one active owner is required.' }, 409);
    }
  }
  const up = await db.from('pos_users').update({ active }).eq('customer_id', ctx.customerId).eq('id', target);
  if (up.error) throw new Error(up.error.message);
  await audit(db, ctx.customerId, ctx.userId, active ? 'USER_ACTIVATED' : 'USER_DEACTIVATED', `Account ${target}.`);
  return json({ ok: true });
}

async function loadActiveUser(db: any, customerId: string, userId: string): Promise<{ role: string } | null> {
  const { data } = await db.from('pos_users').select('role, active')
    .eq('customer_id', customerId).eq('id', userId).eq('active', true).maybeSingle();
  return data ? { role: data.role } : null;
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
  const { data: cats } = await db.from('pos_finance_categories').select('id, name')
    .eq('customer_id', ctx.customerId).is('deleted_at', null).order('name');
  const { data: entries } = await db.from('pos_finance_entries').select('category_id, amount_minor_units')
    .eq('customer_id', ctx.customerId).eq('status', 'PENDING');
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
  const up = await db.from('pos_finance_categories').update({ name: newName, updated_at: new Date().toISOString() })
    .eq('customer_id', ctx.customerId).eq('id', String(body.category_id ?? ''));
  if (up.error) throw new Error(up.error.message);
  await audit(db, ctx.customerId, ctx.userId, 'FINANCE_CATEGORY_RENAMED', `Person ${body.category_id} renamed.`);
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
// Permanent delete: only for a binned person; drops their entries then the row.
async function financePermanentlyDeleteCategory(db: any, ctx: Ctx, body: any): Promise<Response> {
  const id = String(body.category_id ?? '');
  const { data: existing } = await db.from('pos_finance_categories').select('id, name, deleted_at')
    .eq('customer_id', ctx.customerId).eq('id', id).maybeSingle();
  if (!existing) return json({ ok: false, error: 'Person not found.' }, 404);
  if (!existing.deleted_at) return json({ ok: false, error: 'Move the person to the recycle bin first.' }, 409);
  const delEntries = await db.from('pos_finance_entries').delete()
    .eq('customer_id', ctx.customerId).eq('category_id', id);
  if (delEntries.error) throw new Error(delEntries.error.message);
  const delCat = await db.from('pos_finance_categories').delete()
    .eq('customer_id', ctx.customerId).eq('id', id);
  if (delCat.error) throw new Error(delCat.error.message);
  await audit(db, ctx.customerId, ctx.userId, 'FINANCE_CATEGORY_PERMANENTLY_DELETED', `Person "${existing.name}" permanently deleted.`);
  return json({ ok: true });
}
async function financeAddEntry(db: any, ctx: Ctx, body: any): Promise<Response> {
  const amount = Number(body.amount_minor_units ?? 0);
  if (amount <= 0) return json({ ok: false, error: 'Amount must be positive.' }, 400);
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
  const now = new Date().toISOString();
  const { data: entry } = await db.from('pos_finance_entries').select('*')
    .eq('customer_id', ctx.customerId).eq('id', String(body.entry_id ?? '')).eq('status', 'PENDING').maybeSingle();
  if (!entry) return json({ ok: false, error: 'Entry is not pending.' }, 409);
  const up = await db.from('pos_finance_entries').update({
    status: 'COMPLETED', completed_at: now, completed_by: ctx.userId, updated_at: now,
  }).eq('customer_id', ctx.customerId).eq('id', String(body.entry_id ?? '')).eq('status', 'PENDING').select('id');
  if (up.error) throw new Error(up.error.message);
  if (!up.data || up.data.length === 0) {
    return json({ ok: false, error: 'Entry is not pending.' }, 409);
  }
  // A cash collection physically puts money into the drawer, so deposit it onto
  // the open (perpetual) shift. Bank/non-cash collections never touch it.
  if (entry.payment_method === 'CASH') {
    const { data: cats } = await db.from('pos_finance_categories').select('name')
      .eq('customer_id', ctx.customerId).eq('id', entry.category_id).maybeSingle();
    let { data: shift } = await db.from('shifts').select('id')
      .eq('customer_id', ctx.customerId).eq('status', 'OPEN').limit(1).maybeSingle();
    if (!shift) {
      const sid = crypto.randomUUID();
      const ins = await db.from('shifts').insert({
        id: sid, customer_id: ctx.customerId, cashier_id: ctx.userId,
        opening_cash_minor_units: 0, status: 'OPEN', opened_at: now,
      }).select('id').maybeSingle();
      if (ins.error) throw new Error(ins.error.message);
      shift = { id: sid };
    }
    const mv = await db.from('cash_movements').insert({
      id: crypto.randomUUID(), customer_id: ctx.customerId, shift_id: shift!.id, user_id: ctx.userId,
      type: 'DEPOSIT', amount_minor_units: Number(entry.amount_minor_units),
      reason: `Collected from ${cats?.name ?? 'a person'}`, created_at: now,
    });
    if (mv.error) throw new Error(mv.error.message);
  }
  await audit(db, ctx.customerId, ctx.userId, 'FINANCE_ENTRY_COMPLETED', `Entry ${body.entry_id} taken.`);
  return json({ ok: true });
}
async function financeSearchEntries(db: any, ctx: Ctx, body: any): Promise<Response> {
  let q = db.from('pos_finance_entries').select('*').eq('customer_id', ctx.customerId)
    .order('entry_date', { ascending: false });
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
  const { data: cat } = await db.from('pos_finance_categories').select('deleted_at')
    .eq('customer_id', ctx.customerId).eq('id', String(body.category_id ?? '')).maybeSingle();
  if (!cat || cat.deleted_at) {
    return json({ ok: true, totals: { pending_total: 0, completed_total: 0 } });
  }
  const { data } = await db.from('pos_finance_entries').select('status, amount_minor_units')
    .eq('customer_id', ctx.customerId).eq('category_id', String(body.category_id ?? ''));
  let pending = 0, completed = 0;
  for (const e of data ?? []) {
    if (e.status === 'PENDING') pending += Number(e.amount_minor_units); else completed += Number(e.amount_minor_units);
  }
  return json({ ok: true, totals: { pending_total: pending, completed_total: completed } });
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
// Settings, reporting, audit
// ===========================================================================
async function getSetting(db: any, ctx: Ctx, body: any): Promise<Response> {
  const { data } = await db.from('pos_settings').select('value')
    .eq('customer_id', ctx.customerId).eq('key', String(body.key ?? '')).maybeSingle();
  return json({ ok: true, value: data ? data.value : null });
}
async function setSetting(db: any, ctx: Ctx, body: any): Promise<Response> {
  const up = await db.from('pos_settings').upsert(
    { customer_id: ctx.customerId, key: String(body.key ?? ''), value: String(body.value ?? '') },
    { onConflict: 'customer_id,key' });
  if (up.error) throw new Error(up.error.message);
  return json({ ok: true });
}

async function dashboardSummary(db: any, ctx: Ctx, body: any): Promise<Response> {
  const start = body.period_start;
  const end = body.period_end;
  const inRange = (q: any) => {
    if (start) q = q.gte('created_at', start);
    if (end) q = q.lt('created_at', end);
    return q;
  };
  const { data: completed } = await inRange(
    db.from('sales').select('total_minor_units, payment_method')
      .eq('customer_id', ctx.customerId).eq('status', 'COMPLETED'));
  const rows = completed ?? [];
  const revenue = rows.reduce((s: number, r: any) => s + Number(r.total_minor_units), 0);
  const cashRevenue = rows.filter((r: any) => r.payment_method === 'CASH')
    .reduce((s: number, r: any) => s + Number(r.total_minor_units), 0);
  const bankRevenue = rows.filter((r: any) => r.payment_method === 'BANK')
    .reduce((s: number, r: any) => s + Number(r.total_minor_units), 0);
  const count = rows.length;

  const { count: voidCount } = await inRange(
    db.from('sales').select('*', { count: 'exact', head: true })
      .eq('customer_id', ctx.customerId).eq('status', 'VOIDED'));

  // Pending cashier void requests whose target sale falls in the period.
  const { data: periodSales } = await inRange(
    db.from('sales').select('id').eq('customer_id', ctx.customerId));
  const periodIds = (periodSales ?? []).map((s: any) => s.id);
  let pendingRequests = 0;
  if (periodIds.length) {
    const { count: pc } = await db.from('void_requests')
      .select('*', { count: 'exact', head: true })
      .eq('customer_id', ctx.customerId).eq('status', 'PENDING').in('sale_id', periodIds);
    pendingRequests = pc ?? 0;
  }

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
      cash_revenue: cashRevenue,
      bank_revenue: bankRevenue,
      average_sale: count === 0 ? 0 : Math.floor(revenue / count),
      expected_cash: expectedCash,
      is_shift_open: shiftOpen,
      void_count: voidCount ?? 0,
      pending_void_requests: pendingRequests,
    },
  });
}

async function revenueTrend(db: any, ctx: Ctx, body: any): Promise<Response> {
  let q = db.from('sales').select('created_at, total_minor_units')
    .eq('customer_id', ctx.customerId).eq('status', 'COMPLETED');
  if (body.period_start) q = q.gte('created_at', body.period_start);
  if (body.period_end) q = q.lt('created_at', body.period_end);
  const { data, error } = await q;
  if (error) throw new Error(error.message);
  // Group by local calendar day (first 10 chars of the ISO timestamp), the same
  // `substr(created_at,1,10)` bucketing the local report uses, oldest to newest.
  const byDay: Record<string, { count: number; total: number }> = {};
  for (const r of data ?? []) {
    const day = String(r.created_at).slice(0, 10);
    const a = (byDay[day] ??= { count: 0, total: 0 });
    a.count += 1;
    a.total += Number(r.total_minor_units);
  }
  const trend = Object.entries(byDay)
    .map(([day, v]) => ({ day, count: v.count, total: v.total }))
    .sort((a, b) => a.day.localeCompare(b.day));
  return json({ ok: true, trend });
}

async function reportSummary(db: any, ctx: Ctx, body: any): Promise<Response> {
  const rangeStart = body.period_start; const rangeEnd = body.period_end;
  let q = db.from('sales').select('*').eq('customer_id', ctx.customerId).eq('status', 'COMPLETED');
  if (rangeStart) q = q.gte('created_at', rangeStart);
  if (rangeEnd) q = q.lt('created_at', rangeEnd);
  const { data: sales } = await q;
  const saleIds = (sales ?? []).map((s: any) => s.id);
  const byProduct: Record<string, { qty: number; lines: number; revenue: number }> = {};
  if (saleIds.length) {
    const { data: items } = await db.from('sale_items').select('*')
      .eq('customer_id', ctx.customerId).in('sale_id', saleIds);
    for (const it of items ?? []) {
      const k = it.product_name_snapshot;
      const a = (byProduct[k] ??= { qty: 0, lines: 0, revenue: 0 });
      a.qty += Number(it.billing_quantity_milliunits ?? 0);
      a.lines += 1;
      a.revenue += Number(it.line_total_minor_units ?? 0);
    }
  }
  return json({
    ok: true,
    product_summary: Object.entries(byProduct)
      .map(([name, v]) => ({ product_name_snapshot: name, ...v }))
      .sort((a, b) => b.revenue - a.revenue),
    cashier_performance: await cashierPerformance(db, ctx, rangeStart, rangeEnd),
  });
}

// Sales count + revenue per cashier for the reports screen, highest revenue
// first. Mirrors the local `getCashierPerformance` grouped join.
async function cashierPerformance(db: any, ctx: Ctx, start: any, end: any): Promise<any[]> {
  let q = db.from('sales').select('cashier_id, total_minor_units')
    .eq('customer_id', ctx.customerId).eq('status', 'COMPLETED');
  if (start) q = q.gte('created_at', start);
  if (end) q = q.lt('created_at', end);
  const { data } = await q;
  const names = await usernamesById(db, ctx, (data ?? []).map((r: any) => r.cashier_id));
  const byCashier: Record<string, { total_sales: number; total_revenue: number }> = {};
  for (const r of data ?? []) {
    const a = (byCashier[r.cashier_id] ??= { total_sales: 0, total_revenue: 0 });
    a.total_sales += 1;
    a.total_revenue += Number(r.total_minor_units);
  }
  return Object.entries(byCashier)
    .map(([id, v]) => ({ username: names[id] ?? null, ...v }))
    .sort((a, b) => b.total_revenue - a.total_revenue);
}

async function listAudit(db: any, ctx: Ctx, body: any): Promise<Response> {
  const { data, error } = await db.from('pos_audit_logs').select('*')
    .eq('customer_id', ctx.customerId).order('created_at', { ascending: false })
    .limit(Number(body.limit ?? 500));
  if (error) throw new Error(error.message);
  const logs = strip(data);
  // `username` is display-only and never stored; joined from pos_users so the
  // Audit screen renders the same shape as the local SQLite implementation.
  const names = await usernamesById(db, ctx, logs.map((l: any) => l.user_id));
  for (const l of logs) l.username = l.user_id ? (names[l.user_id] ?? null) : null;
  return json({ ok: true, audit_logs: logs });
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

async function signJwt(claims: { sub: string; cid: string; role: string }): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: 'HS256', typ: 'JWT' };
  const payload = { ...claims, iat: now, exp: now + SESSION_TTL_SECONDS };
  const head = b64uStr(JSON.stringify(header));
  const body = b64uStr(JSON.stringify(payload));
  const sig = await hmac(`${head}.${body}`);
  return `${head}.${body}.${sig}`;
}

async function verifyJwt(token: string): Promise<{ userId: string; customerId: string } | null> {
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  const expectSig = await hmac(`${parts[0]}.${parts[1]}`);
  if (!timingSafeEqualStr(expectSig, parts[2])) return null;
  let payload: any;
  try { payload = JSON.parse(atob(b64uToB64(parts[1]))); } catch { return null; }
  if (!payload || typeof payload.exp !== 'number' || payload.exp * 1000 < Date.now()) return null;
  if (!payload.sub || !payload.cid) return null;
  return { userId: String(payload.sub), customerId: String(payload.cid) };
}

async function hmac(data: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(JWT_SECRET), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(data));
  return b64u(new Uint8Array(sig));
}

// ===========================================================================
// Small shared helpers
// ===========================================================================
type Ctx = { customerId: string; userId: string; role: string };

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
  try {
    await db.from('pos_audit_logs').insert({
      id: crypto.randomUUID(), customer_id: customerId, user_id: userId,
      action, details, created_at: new Date().toISOString(),
    });
  } catch (_) { /* audit must never block a write */ }
}

function strip(rows: any[] | null): any[] {
  return (rows ?? []).map((r) => { const { customer_id: _c, received_at: _r, ...rest } = r; return rest; });
}
function deSnake(row: any): any { return row; }

function str(v: unknown): string { return typeof v === 'string' ? v.trim() : ''; }

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
