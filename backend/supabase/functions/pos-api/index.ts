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
//   * Unauthenticated: { action: 'login' | 'setup_owner' | 'has_users', ... }
//   * Authenticated:   header `Authorization: Bearer <jwt>` + { action, ... }
//   * Every response is { ok: true, ... } or { ok: false, error }.
//
// Request path:
//   Incoming request -> shared request handling (CORS, JSON, JWT verify,
//   actor load, owner-only + feature gates in shared/authorization.ts)
//   -> ACTIONS dispatch table -> domain module handler (modules/*) ->
//   existing database behaviour (PostgREST tables + pos_* RPCs).
//
// Security model:
//   * Passwords: PBKDF2-HMAC-SHA256, 210k rounds, per-user random salt, stored
//     base64 — identical policy to the native client (UserRepository) so a
//     provisioned account's strength is the same on both surfaces.
//   * Sessions: stateless HMAC-SHA256 JWT {sub, cid, role, exp}. No server
//     session store; a logout just drops the token client-side.
//   * Authorization: owner-vs-cashier is enforced here per action, not by
//     hiding navigation. Reads are always `.eq('customer_id', cid)` filtered.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";
import { SERVICE_KEY, SUPABASE_URL } from "./shared/env.ts";
import {
  changePassword,
  hasUsers,
  login,
  setupOwner,
  verifyJwt,
} from "./shared/auth.ts";
import { checkAuthorization } from "./shared/authorization.ts";
import { CORS_HEADERS, json, str } from "./shared/helpers.ts";
import type { Ctx } from "./shared/types.ts";
import * as catalog from "./modules/catalog/index.ts";
import * as finance from "./modules/finance/index.ts";
import * as register from "./modules/register/index.ts";
import * as reporting from "./modules/reporting/index.ts";
import * as sales from "./modules/sales/index.ts";
import * as users from "./modules/users/index.ts";
import * as warehouse from "./modules/warehouse/index.ts";

type Handler = (db: any, ctx: Ctx, body: any) => Promise<Response>;
type PublicHandler = (db: any, body: any) => Promise<Response>;

// Actions reachable without a session. Everything else requires a verified
// JWT plus the owner-only / feature-tick gates in checkAuthorization.
const PUBLIC_ACTIONS: Record<string, PublicHandler> = {
  login,
  setup_owner: setupOwner,
  has_users: hasUsers,
};

// The full authenticated action surface. Action names, parameters, response
// shapes, and error semantics are the production contract — do not rename or
// reinterpret keys here.
export const ACTIONS: Record<string, Handler> = {
  // Auth-adjacent
  change_password: changePassword,

  // Products / saved names
  list_products: catalog.listProducts,
  save_product: catalog.saveProduct,
  update_product: catalog.updateProduct,
  deactivate_product: (db, ctx, body) =>
    catalog.setProductActive(db, ctx, body, 0),
  reactivate_product: (db, ctx, body) =>
    catalog.setProductActive(db, ctx, body, 1),

  // Sales
  next_receipt_number: (db, ctx) => sales.nextReceiptNumber(db, ctx),
  insert_sale: sales.insertSale,
  search_sales: sales.searchSales,
  void_sale: sales.voidSale,
  request_void: sales.requestVoid,
  list_void_requests: sales.listVoidRequests,
  approve_void: (db, ctx, body) => sales.decideVoid(db, ctx, body, "APPROVED"),
  reject_void: (db, ctx, body) => sales.decideVoid(db, ctx, body, "REJECTED"),

  // Shifts + cash
  get_shift: register.getActiveShift,
  ensure_shift: (db, ctx) => register.ensureShift(db, ctx),
  register_snapshot: register.registerSnapshot,
  shift_history: register.shiftHistory,
  shift_summary: register.shiftSummary,
  open_shift: register.openShift,
  close_shift: register.closeShift,
  add_cash_movement: register.addCashMovement,
  list_cash_movements: register.listCashMovements,

  // Users
  list_users: users.listUsers,
  create_user: users.createUser,
  set_user_permissions: users.setUserPermissions,
  set_user_phone: users.setUserPhone,
  reset_password: users.resetPassword,
  set_user_active: users.setUserActive,
  delete_user: users.deleteUser,

  // Finance
  finance_categories: finance.financeCategories,
  finance_deleted_categories: finance.financeDeletedCategories,
  finance_summaries: finance.financeSummaries,
  finance_create_category: finance.financeCreateCategory,
  finance_rename_category: finance.financeRenameCategory,
  finance_delete_category: finance.financeDeleteCategory,
  finance_restore_category: finance.financeRestoreCategory,
  finance_permanently_delete_category: finance.financePermanentlyDeleteCategory,
  finance_add_entry: finance.financeAddEntry,
  finance_update_entry: finance.financeUpdateEntry,
  finance_mark_completed: finance.financeMarkCompleted,
  finance_delete_entry: finance.financeDeleteEntry,
  finance_search_entries: finance.financeSearchEntries,
  finance_person_totals: finance.financePersonTotals,

  // Warehouse picklists
  list_picklists: warehouse.listPicklists,
  get_picklist_items: warehouse.getPicklistItems,
  create_picklist: warehouse.createPicklist,
  update_picklist_items: warehouse.updatePicklistItems,
  get_customers: warehouse.getCustomers,
  add_customer: warehouse.addCustomer,
  toggle_picklist_item: warehouse.togglePicklistItem,
  update_picklist_item: warehouse.updatePicklistItem,
  delete_picklist_item: warehouse.deletePicklistItem,
  delete_picklist: warehouse.deletePicklist,

  // Counters, reporting, audit
  dashboard_summary: reporting.dashboardSummary,
  revenue_trend: reporting.revenueTrend,
  report_summary: reporting.reportSummary,
  list_audit: reporting.listAudit,
};

export async function handleRequest(
  req: Request,
  db?: any,
): Promise<Response> {
  // Answer the browser's CORS preflight before the POST-only guard, otherwise
  // OPTIONS falls into the 405 branch with no allow-origin and the fetch aborts.
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
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
  const action = String(body.action ?? "");

  try {
    // --- Unauthenticated actions ---------------------------------------
    const publicHandler = PUBLIC_ACTIONS[action];
    if (publicHandler) return await publicHandler(client, body);

    // --- Authenticated actions -----------------------------------------
    const cid = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ??
      body.token;
    const session = cid ? await verifyJwt(String(cid)) : null;
    const auth = await checkAuthorization(client, session, action);
    if (auth.error) {
      return json({ ok: false, error: auth.error }, auth.status ?? 403);
    }
    // Per-device identity for shift/receipt operations (audit D1). Optional:
    // empty -> NULL so the shared perpetual shift still matches.
    const ctx: Ctx = {
      ...auth.ctx!,
      deviceId: str(body.device_id) || null,
    };

    const handler = ACTIONS[action];
    if (!handler) {
      return json({ ok: false, error: `Unknown action: ${action}` }, 400);
    }
    return await handler(client, ctx, body);
  } catch (err) {
    console.error("pos-api error:", err);
    return json({ ok: false, error: "Internal error." }, 500);
  }
}

// Guarded so tests can import handleRequest without binding a port; the Edge
// Runtime loads this file as the main module, so the server still starts in
// production.
if (import.meta.main) {
  Deno.serve((req) => handleRequest(req));
}
