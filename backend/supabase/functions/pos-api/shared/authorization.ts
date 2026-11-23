import type { Ctx } from "./types.ts";
import { loadActiveUser, OWNER } from "./auth.ts";
export type { Actor } from "./auth.ts";

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

// Permanently owner-only: a feature tick NEVER grants these. Money-integrity
// and account-admin mutations stay reserved for the all-access OWNER account,
// regardless of which tabs a staff account can see.
const OWNER_ONLY = new Set([
  // Voids: a cashier may request_void, only an owner may void/approve/reject.
  "void_sale",
  "approve_void",
  "reject_void",
  // Reviewing the pending-void queue hydrates the whole sale behind every
  // request (items, totals, customer). That is an owner surface: a cashier
  // could otherwise read every other operator's sales from the Register tab.
  "list_void_requests",
  // Account administration + credential/status mutations.
  "reset_password",
  "set_user_active",
  "create_user",
  "set_user_permissions",
  "set_user_phone",
  "delete_user",
]);

// Feature-gated actions: allowed when the actor is an OWNER or holds ANY of the
// listed features. This replaces the old blanket OWNER_ONLY gate for the
// readable/navigable actions so per-account ticks actually take effect. Keys
// are action names; values are the feature keys that unlock them.
const ACTION_FEATURES: Record<string, string[]> = {
  // Dashboard
  dashboard_summary: ["dashboard"],
  revenue_trend: ["dashboard"],
  // POS / products
  list_products: ["pos"],
  save_product: ["pos"],
  update_product: ["pos"],
  deactivate_product: ["pos"],
  reactivate_product: ["pos"],
  next_receipt_number: ["pos"],
  insert_sale: ["pos"],
  // Register / shifts
  get_shift: ["register"],
  ensure_shift: ["register"],
  register_snapshot: ["register"],
  open_shift: ["register"],
  close_shift: ["register"],
  add_cash_movement: ["register"],
  // The close-drawer dialog summarizes the shift the cashier is closing, which
  // is always the OPEN one; shiftSummary() refuses any other shift for a
  // non-owner so this tick cannot be used to browse past sessions.
  shift_summary: ["register"],
  // Money Tracking: one tickable feature, all of it. The native repository
  // checks the same tick inside every method (reads included), so a staff
  // account reaches this area only when the owner ticked it for that account —
  // and loses it the moment the tick is removed, because the sync pull applies
  // the permission change to the till's own user row.
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
  // Warehouse picklists: two separate ticks. `warehouse` is the shop worker
  // creating lists and customers; `warehouse_fill` is the picker reading the
  // queue and ticking items off. Both may read the queue and toggle taken
  // quantities, but only `warehouse` may create.
  list_picklists: ["warehouse", "warehouse_fill"],
  get_picklist_items: ["warehouse", "warehouse_fill"],
  create_picklist: ["warehouse"],
  update_picklist_items: ["warehouse"],
  // Correcting or removing a line is a warehouse-floor action: both ticks may
  // do it (the owner asked fill workers to fix a wrong entry without waiting
  // for the shop). Creating a list and its customer directory stay shop-only.
  update_picklist_item: ["warehouse", "warehouse_fill"],
  delete_picklist_item: ["warehouse", "warehouse_fill"],
  delete_picklist: ["warehouse", "warehouse_fill"],
  get_customers: ["warehouse"],
  add_customer: ["warehouse"],
  toggle_picklist_item: ["warehouse", "warehouse_fill"],
  // History. search_sales is also needed by the Register History day drill-down
  // (which sales brought cash in that day), so register_history unlocks it too.
  search_sales: ["history", "register_history"],
  // Requesting a void is a till action, not a history one: the cashier who rang
  // the sale asks for it from that sale's detail screen. Gating it on `history`
  // meant the default staff account (pos/register/reports) always got a 403.
  request_void: ["pos", "history", "register_history"],
  // Reports
  report_summary: ["reports"],
  // Users (read-only list; mutations are OWNER_ONLY above)
  list_users: ["users"],
  // Audit
  list_audit: ["audit"],
  // Register History (cross-shift ledger browsing)
  shift_history: ["register_history"],
  list_cash_movements: ["register_history"],
};

async function checkAuthorization(
  db: any,
  session: { userId: string; customerId: string; tv: number } | null,
  action: string,
): Promise<{ ctx?: Ctx; error?: string; status?: number }> {
  if (!session) return { error: "Not signed in.", status: 401 };
  const actor = await loadActiveUser(db, session.customerId, session.userId);
  if (!actor) return { error: "Session no longer valid.", status: 403 };
  if (session.tv !== actor.tokenVersion) {
    return { error: "Session no longer valid.", status: 403 };
  }
  if (OWNER_ONLY.has(action) && actor.role !== OWNER) {
    return { error: "Owner access required.", status: 403 };
  }
  const gated = ACTION_FEATURES[action];
  if (
    gated && actor.role !== OWNER &&
    !gated.some((f) => actor.permissions.includes(f))
  ) {
    return { error: "Not permitted for this account.", status: 403 };
  }
  return {
    ctx: {
      customerId: session.customerId,
      userId: session.userId,
      role: actor.role,
      canSeePicklistMoney: actor.role === OWNER ||
        actor.permissions.includes("warehouse") ||
        actor.permissions.includes("warehouse_fill"),
      deviceId: null, // set by caller
    },
  };
}

export {
  ACTION_FEATURES,
  checkAuthorization,
  FEATURE_KEYS,
  loadActiveUser,
  OWNER,
  OWNER_ONLY,
};
