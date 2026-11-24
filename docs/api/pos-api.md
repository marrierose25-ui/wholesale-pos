# pos-api Endpoint Inventory

All actions POST to `/functions/v1/pos-api` with `{"action":"<name>","payload":{...}}`. Three actions (`login`, `setup_owner`, `has_users`) accept unauthenticated POSTs.

## Auth Module

| Action | Method | Requires Auth | Summary |
| -------- | -------- | -------------- | --------- |
| `login` | POST | ❌ | Issue JWT |
| `setup_owner` | POST | ❌ | Bootstrap first user |
| `has_users` | GET | ❌ | Tenant probe |
| `change_password` | POST | ✅ | Rotate secret |

## Catalog Module

| Action | Method | Requires Auth | Summary |
| -------- | -------- | -------------- | --------- |
| `list_products` | GET | ✅ | Paginated catalog |
| `save_product` | POST | ✅ | Upsert product |
| `update_product` | PATCH | ✅ | Partial update |
| `setProductActive` | POST | ✅ | Toggle active flag |

## Sales Module

| Action | Method | Requires Auth | Summary |
| -------- | -------- | -------------- | --------- |
| `insert_sale` | POST | ✅ | Record a sale (+ items) |
| `search_sales` | GET | ✅ | Filtered history query |
| `next_receipt_number` | GET | ✅ | Atomic counter increment |
| `voidSale` | POST | OWNER_ONLY | Finalize void |
| `requestVoid` | POST | ✅ | Cashier submits void request |
| `listVoidRequests` | GET | ✅ | Pending requests for owner |
| `decideVoid` | POST | OWNER_ONLY | Approve/reject request |

## Register Module

| Action | Method | Requires Auth | Summary |
| -------- | -------- | -------------- | --------- |
| `openShift` | POST | ✅ | Start a shift |
| `closeShift` | POST | ✅ | End a shift with cash count |
| `getActiveShift` | GET | ✅ | Current shift status |
| `ensureShift` | POST | ✅ | Auto-open if closed |
| `addCashMovement` | POST | ✅ | Record deposit/withdrawal |
| `listCashMovements` | GET | ✅ | Shift cash ledger |
| `registerSnapshot` | GET | ✅ | Mid-shift snapshot |
| `shiftSummary` | GET | ✅ | End-of-shift reconciliation |

## Finance Module

| Action | Method | Requires Auth | Summary |
| -------- | -------- | -------------- | --------- |
| `createCategory` | POST | ✅ | Add income/expense bucket |
| `renameCategory` | POST | ✅ | Update name |
| `deleteCategory` | POST | ✅ | Soft-delete (recycle bin) |
| `restoreCategory` | POST | ✅ | Restore from recycle bin |
| `permanentlyDeleteCategory` | POST | OWNER_ONLY | Hard-delete |
| `addEntry` | POST | ✅ | Create PENDING entry |
| `updateEntry` | POST | ✅ | Edit amount/note |
| `markCompleted` | POST | ✅ | Move to COMPLETED |
| `deleteEntry` | POST | ✅ | Soft-delete entry |
| `listEntries` | GET | ✅ | Paginated list with filters |
| `listCategories` | GET | ✅ | All categories incl. recycled |
| `categorySummary` | GET | ✅ | Per-category totals |
| `monthlySummary` | GET | ✅ | Monthly income/expense |
| `reverseEntry` | POST | ✅ | Create offsetting entry |
| `purgeRecycleBin` | POST | OWNER_ONLY | Clear recycled categories |

## Warehouse Module

| Action | Method | Requires Auth | Summary |
| -------- | -------- | -------------- | --------- |
| `createPicklist` | POST | ✅ | New picklist with items |
| `updatePicklistItems` | POST | ✅ | Bulk update quantities |
| `updatePicklistItem` | POST | ✅ | Single-line edit |
| `deletePicklistItem` | POST | ✅ | Remove a line |
| `deletePicklist` | POST | ✅ | Cancel entire picklist |
| `toggleItemTaken` | POST | ✅ | Mark single line received |
| `listPicklists` | GET | ✅ | Paginated, filterable |
| `getPicklist` | GET | ✅ | Detail + items |
| `listCustomers` | GET | ✅ | Supplier/customer directory |
| `upsertCustomer` | POST | ✅ | Add/edit contact |

## Reporting Module

| Action | Method | Requires Auth | Summary |
| -------- | -------- | -------------- | --------- |
| `dashboardSummary` | GET | ✅ | KPI tiles |
| `revenueTrend` | GET | ✅ | Time-series chart data |
| `reportSummary` | GET | ✅ | Detailed report |
| `listAudit` | GET | ✅ | Audit log with filters |

## Users Module

| Action | Method | Requires Auth | Summary |
| -------- | -------- | -------------- | --------- |
| `listUsers` | GET | ✅ | Tenant users |
| `createUser` | POST | OWNER_ONLY | Add staff member |
| `updateUser` | POST | OWNER_ONLY | Edit role/name |
| `setUserPermissions` | POST | OWNER_ONLY | Toggle feature access |
| `setUserPhone` | POST | OWNER_ONLY | Update contact number |
| `setUserActive` | POST | OWNER_ONLY | Activate/deactivate |
| `deleteUser` | POST | OWNER_ONLY | Soft-delete user |

---

## Action Count Summary

| Module | Unauth | Auth | Owner-only | Total |
| -------- | -------- | ------ | ------------ | ------- |
| auth | 3 | 1 | 0 | 4 |
| catalog | 0 | 4 | 0 | 4 |
| sales | 0 | 4 | 3 | 7 |
| register | 0 | 8 | 0 | 8 |
| finance | 0 | 10 | 2 | 12 |
| warehouse | 0 | 10 | 0 | 10 |
| reporting | 0 | 4 | 0 | 4 |
| users | 0 | 1 | 6 | 7 |
| **Total** | **3** | **42** | **11** | **61** |

OWNER_ONLY actions reject non-owner roles with HTTP 403 `"Owner access required."`.
