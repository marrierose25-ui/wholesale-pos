# Stage 8: Supabase Backend API Action Inventory

**Generated:** 2026-11-21
**Source:** `supabase/functions/pos-api/` (post-modularization)

---

## Summary

| Category | Actions | Module |
|----------|---------|--------|
| Auth (unauthenticated) | 3 | modules/auth |
| Auth (authenticated) | 1 | modules/auth |
| Products / Catalog | 4 | modules/catalog |
| Sales | 7 | modules/sales |
| Register / Shifts | 9 | modules/register |
| Finance | 15 | modules/finance |
| Warehouse / Picklists | 10 | modules/warehouse |
| Reporting | 4 | modules/reporting |
| Users | 7 | modules/users |
| **Total** | **60** | |

---

## Unauthenticated Actions

### auth

| Action | Signature | Description |
|--------|-----------|-------------|
| `has_users` | `(db, body) → Response` | Check if any users exist for activation code. Returns `{ ok, has_users }`. |
| `login` | `(db, body) → Response` | Authenticate user by phone/username + password. Returns JWT token, role, permissions. Includes demo password rotation for first OWNER login. |
| `setup_owner` | `(db, body) → Response` | Bootstrap owner account from activation code. Validates phone number, creates owner user via RPC `pos_setup_owner`. Sets up demo cashier account. |

**Behavior notes:**
- Password hashing: PBKDF2-HMAC-SHA256, 210k iterations, per-user random 16-byte salt
- Session TTL: ~10 years (`SESSION_TTL_SECONDS`) — revocation done via `token_version` bump
- Login throttle: 10 attempts per minute per `(customerId, username)` pair; locks out for 5 minutes
- Demo user seeding: auto-rotates demo password on each OWNER setup, marks version in `pos_settings.demo_pw_version`

---

## Authenticated Actions

All authenticated actions require a valid JWT in `Authorization: Bearer <token>` header (or legacy `body.token`). The JWT payload is `{ sub, cid, role, tv, exp }`. A middleware layer then:

1. Verifies JWT signature and expiry
2. Loads active user record via `pos_users` (checks `active = true`, `deleted_at IS NULL`)
3. Checks token version (`tv`) matches to detect credential changes
4. Enforces feature-gate permissions for non-owner roles
5. Passes a `Ctx` object into every handler

### catalog — Products

| Action | Signature | Description |
|--------|-----------|-------------|
| `list_products` | `(db, ctx, body) → Response` | List products with optional category filter, search, pagination. Supports "name only" lightweight mode. |
| `save_product` | `(db, ctx, body) → Response` | Upsert product (insert or update). Handles image upload, serial number tracking. Audit: `PRODUCT_SAVED`. |
| `update_product` | `(db, ctx, body) → Response` | Update existing product fields without full replace. Audit: `PRODUCT_UPDATED`. |
| `setProductActive` | `(db, ctx, body, activeFlag) → Response` | Deactivate/reactivate product. Maps to `deactivate_product` (0) and `reactivate_product` (1) actions. |

### sales — Point of Sale

| Action | Signature | Description |
|--------|-----------|-------------|
| `next_receipt_number` | `(db, ctx) → Response` | Get next receipt number from counter. Atomic increment via row-level lock. |
| `insert_sale` | `(db, ctx, body) → Response` | Create sale with line items. Handles discount, tax, payment method splitting. Updates stock. Generates receipt PDF reference. Audit: `SALE_INSERTED`. |
| `search_sales` | `(db, ctx, body) → Response` | Search sales by date range, receipt number, customer, payment method. Paginated. Excludes demo user sales when flag set. |
| `voidSale` | `(db, ctx, body) → Response` | Void entire sale (owner-only). Restocks items. Audit: `SALE_VOIDED`. |
| `requestVoid` | `(db, ctx, body) → Response` | Request void from cashier (non-owner). Creates void request record for owner approval. |
| `listVoidRequests` | `(db, ctx, body) → Response` | List pending void requests. Owner only feature-gated but callable by any authenticated user with feature access. |
| `decideVoid` | `(db, ctx, body, decision) → Response` | Approve/reject a void request. Owner-only (`OWNER_ONLY` gate). Updates request status, restocks if approved. |

### register — Shift Management

| Action | Signature | Description |
|--------|-----------|-------------|
| `getActiveShift` | `(db, ctx) → Response` | Fetch currently open shift (if any). |
| `ensureShift` | `(db, ctx) → Response` | Ensure an open shift exists (create if none). Via RPC `pos_ensure_shift`. |
| `registerSnapshot` | `(db, ctx, body) → Response` | Cash snapshot for open shift. Computes expected cash via RPC `pos_expected_cash`, fetches counters via `pos_shift_counters`. Supports period filtering. |
| `shiftHistory` | `(db, ctx, body) → Response` | List shifts with optional status/date filters. Paginated. Excludes demo cashier shifts. |
| `openShift` | `(db, ctx, body) → Response` | Open new shift with opening cash amount. Via RPC `pos_open_shift`. |
| `closeShift` | `(db, ctx, body) → Response` | Close shift with closing cash amount. Validates amounts, computes difference. Via RPC `pos_close_shift`. Returns `expected_cash_minor_units`. |
| `shiftSummary` | `(db, ctx, body) → Response` | Detailed shift summary. Owner-only can review closed shifts. Via RPC `pos_shift_summary`. Returns cash/bank/void/deposit/withdrawal totals. |
| `addCashMovement` | `(db, ctx, body) → Response` | Record deposit, withdrawal, or expense against current shift. Requires open shift. Photo upload supported (max 300KB). Via RPC `pos_add_cash_movement`. |
| `listCashMovements` | `(db, ctx, body) → Response` | List cash movements with optional shift filter. Enriches with user names. Excludes demo user movements. Paginated. |

### finance — Personal Accounts & Entries

| Action | Signature | Description |
|--------|-----------|-------------|
| `financeCategories` | `(db, ctx) → Response` | List all categories (including deleted). Returns array of `{ id, name, deleted_at? }`. |
| `financeDeletedCategories` | `(db, ctx) → Response` | List only deleted categories (recycle bin view). |
| `financeSummaries` | `(db, ctx) → Response` | Summarize entries by category with totals. Uses RPC `pos_finance_summary`. |
| `financeCreateCategory` | `(db, ctx, body) → Response` | Create new finance category/person. Audit: `FINANCE_CATEGORY_CREATED`. |
| `financeRenameCategory` | `(db, ctx, body) → Response` | Rename existing category. Audit: `FINANCE_CATEGORY_RENAMED`. |
| `financeDeleteCategory` | `(db, ctx, body) → Response` | Soft-delete category (move to recycle bin). Audit: `FINANCE_CATEGORY_DELETED`. |
| `financeRestoreCategory` | `(db, ctx, body) → Response` | Restore soft-deleted category. Audit: `FINANCE_CATEGORY_RESTORED`. |
| `financePermanentlyDeleteCategory` | `(db, ctx, body) → Response` | Hard delete category and all associated entries. Via RPC `pos_delete_finance_category`. |
| `financeAddEntry` | `(db, ctx, body) → Response` | Create new finance entry (income/expense). Validates category exists. Status defaults to PENDING. Audit: `FINANCE_ENTRY_ADDED`. |
| `financeUpdateEntry` | `(db, ctx, body) → Response` | Update pending entry details. Rejects updates to completed entries. Audit: `FINANCE_ENTRY_UPDATED`. |
| `financeMarkCompleted` | `(db, ctx, body) → Response` | Complete a pending entry. Via RPC `pos_complete_finance`. |
| `financeDeleteEntry` | `(db, ctx, body) → Response` | Delete entry. Via RPC `pos_delete_finance_entry`. |
| `financeSearchEntries` | `(db, ctx, body) → Response` | Search entries by date range, category, keyword, amount range. Paginated. |
| `financePersonTotals` | `(db, ctx, body) → Response` | Get totals per person/category over date range. Aggregates from entries table. |

### warehouse — Picklists & Customers

| Action | Signature | Description |
|--------|-----------|-------------|
| `listPicklists` | `(db, ctx, body) → Response` | List picklists with optional status/customer/name filters. Shows item counts and progress. Excludes customer-only picklists unless requester has `warehouse_fill` permission. |
| `getPicklistItems` | `(db, ctx, body) → Response` | Fetch picklist with items, pricing (if permitted), and customer info. Shows remaining qty if partially filled. |
| `createPicklist` | `(db, ctx, body) → Response` | Create new picklist with initial items. Auto-fills supplier prices if permitted. Audit: `PICKLIST_CREATED`. |
| `updatePicklistItems` | `(db, ctx, body) → Response` | Batch update multiple line items at once. Replaces all items atomically. Recalculates totals and status. Audit: `PICKLIST_UPDATED`. |
| `updatePicklistItem` | `(db, ctx, body) → Response` | Update single line item field (qty, price, note). Recalculates line total and list status. Audit: `PICKLIST_ITEM_UPDATED`. |
| `deletePicklistItem` | `(db, ctx, body) → Response` | Soft-delete line item. Removes from pending/partial states automatically. If last item deleted, also closes parent picklist. Audit: `PICKLIST_UPDATED`. |
| `deletePicklist` | `(db, ctx, body) → Response` | Soft-delete entire picklist (header + all active lines). Audit: `PICKLIST_DELETED`. |
| `getCustomers` | `(db, ctx, body) → Response` | List suppliers/customers with optional search. Required for picklist creation. |
| `addCustomer` | `(db, ctx, body) → Response` | Create new supplier/customer record. Deduplicates by normalized name. Audit: `CUSTOMER_ADDED`. |
| `togglePicklistItem` | `(db, ctx, body) → Response` | Toggle item taken/completed status. Updates `taken_qty` and recalculates picklist status. Audit: `PICKLIST_UPDATED`. |

### reporting — Dashboards & Audit

| Action | Signature | Description |
|--------|-----------|-------------|
| `dashboardSummary` | `(db, ctx, body) → Response` | Dashboard KPIs: today's sales, recent sales count, low-stock products, pending picklists. Requires owner or specific feature flags. |
| `revenueTrend` | `(db, ctx, body) → Response` | Daily revenue trend over configurable period (default 30 days). Groups by `DATE(created_at)`. |
| `reportSummary` | `(db, ctx, body) → Response` | Detailed sales report: daily breakdown, payment method split, top products. Period defaults to previous calendar month. |
| `listAudit` | `(db, ctx, body) → Response` | List audit log entries. Filters by entity type/user/action/date. Ordered by created_at desc. Admin audience. |

### users — Staff Management (Owner-only for mutations)

| Action | Signature | Description |
|--------|-----------|-------------|
| `listUsers` | `(db, ctx, body) → Response` | List all staff users with roles, active status, join dates. Supports search by name/phone. Excludes demo user from results. |
| `createUser` | `(db, ctx, body) → Response` | Create new staff account. OWNER_ONLY action. Requires owner session verification via RPC. Password min 12 chars for owner, 8 for others. |
| `setUserPermissions` | `(db, ctx, body) → Response` | Update user feature permissions. OWNER_ONLY. Sanitizes input to only known FEATURE_KEYS. Audit: `USER_PERMISSIONS_CHANGED`. |
| `setUserPhone` | `(db, ctx, body) → Response` | Update user phone number. OWNER_ONLY. Validates phone format. Audit: `USER_PHONE_CHANGED`. |
| `resetPassword` | `(db, ctx, body) → Response` | Force password reset by owner. Generates random 14-char password. OWNER_ONLY. Audit: `PASSWORD_RESET`. |
| `setUserActive` | `(db, ctx, body) → Response` | Activate/deactivate user account. OWNER_ONLY. Logs reason in audit. Audit: `USER_ACTIVATED` / `USER_DEACTIVATED`. |
| `deleteUser` | `(db, ctx, body) → Response` | Hard delete user account. OWNER_ONLY. Cascade-deletes related rows. Audit: `USER_DELETED`. |

---

## Authorization Model

### Feature Gates (`ACTION_FEATURES`)

| Action(s) | Required Permission(s) |
|-----------|----------------------|
| `dashboard_*` | `dashboard` |
| `list_products`, `save_product`, `update_product`, `deactivate_product`, `reactivate_product`, `next_receipt_number`, `insert_sale`, `request_void` | `pos` |
| `get_shift`, `ensure_shift`, `register_snapshot`, `open_shift`, `close_shift`, `add_cash_movement`, `shift_summary` | `register` |
| `finance_*` | `finance` |
| `list_picklists`, `get_picklist_items`, `create_picklist`, `update_picklist_items`, `update_picklist_item`, `toggle_picklist_item` | `warehouse`, `warehouse_fill` |
| `delete_picklist_item`, `delete_picklist`, `get_customers`, `add_customer` | `warehouse`, `warehouse_fill` |
| `search_sales`, `void_sale`, `list_void_requests`, `approve_void`, `reject_void` | `history`, `register_history` |
| `report_summary`, `revenue_trend` | `reports` |
| `list_users`, `create_user`, `set_user_permissions`, `set_user_phone`, `reset_password`, `set_user_active`, `delete_user` | `users` |
| `list_audit` | `audit` |
| `shift_history`, `list_cash_movements` | `register_history` |

### Owner-Only Actions (`OWNER_ONLY`)

These actions reject any non-Olney role with HTTP 403 regardless of feature permissions:

- `void_sale` (and approve/reject variants)
- `reset_password`
- `set_user_active`
- `create_user`
- `set_user_permissions`
- `set_user_phone`
- `delete_user`

---

## Error Response Contract

Every action returns one of:

```typescript
{ ok: true, ...data }      // Success
{ ok: false, error: string }  // Business error (4xx)
```

Unhandled exceptions return:
```typescript
{ ok: false, error: "Internal error." }  // 500
```

Known error patterns:
- `"Not signed in."` — 401 (invalid/expired JWT)
- `"Session no longer valid."` — 403 (user deactivated or token version mismatch)
- `"Owner access required."` — 403 (non-owner hitting OWNER_ONLY action)
- `"Not permitted for this account."` — 403 (cashier missing feature permission)
- `"POST required"` — 405 (wrong HTTP method)
- `"Unknown action: <action>"` — 400 (unrecognized action name)

---

## Security Notes

### Password Storage
- PBKDF2-HMAC-SHA256, 210,000 iterations
- 16-byte random salt per user
- Stored as `<iterations>$<base64_hash>` in `pw_hash` column
- Timing-safe comparison for verification
- Homoglyph attack mitigation: usernames normalized via `_escape_sql_like()`

### Session Security
- Stateless JWT: `{ sub: userId, cid: customerId, role, tv: tokenVersion, iat, exp }`
- HMAC-SHA256 signature with `POS_API_JWT_SECRET` env var
- No server-side session store
- Token revocation via `token_version` column bump on password change/account deactivation
- 10-year expiry but revoked at next use if `tv` mismatch detected

### Tenant Isolation
- All queries include `.eq('customer_id', ctx.customerId)` or equivalent
- `customer_id` extracted from JWT, never from request body
- Service role key used for database access (bypasses RLS)
- No cross-tenant data leakage possible from application logic

### Audit Trail
All write operations emit audit records to `audit_log` table via `audit(db, customerId, userId, eventCode, message)` helper. Covers:
- Account lifecycle (CREATE, DEACTIVATE, REACTIVATE, DELETE)
- Credential changes (PASSWORD_CHANGED, PASSWORD_RESET)
- Financial transactions (SALE_INSERTED, SALE_VOIDED, FINANCE_ENTRY_ADDED, etc.)
- Catalog changes (PRODUCT_SAVED, PRODUCT_UPDATED, PICKLIST_*)
- User management (USER_*, CUSTOMER_*)

---

## Migration Impact Assessment

### Zero Breaking Changes
- All 60 action handlers maintain identical signatures
- Request/response shapes unchanged
- PostgreSQL RPC calls unchanged
- JWT claims structure unchanged
- Error codes and messages preserved

### Behavioral Equivalents
- Login flow: same throttling, same demo user seeding, same password requirements
- Sale insertion: same stock deduction, same receipt generation, same void workflow
- Shift management: same RPC calls, same expected cash calculation
- Finance: same soft-delete pattern, same category renaming behavior

### Files Added (no deletions from original repo)
- 28 new files under `supabase/functions/pos-api/`
- Original `index.ts` rewritten (not deleted) to act as router
- No git history loss — all original code preserved in new locations
