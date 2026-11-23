# Repository Responsibility Map (Stage 4 input)

Audit of every repository implementation before the Stage 4 split.
Method bodies were preserved verbatim; only ownership moved.

## SqfliteSaleRepository / CloudSaleRepository — `core/repositories/sale_repository.dart`, `core/cloud/cloud_sale_repository.dart`

| Method | Responsibility | Stage 4 disposition |
|---|---|---|
| saveSale | Write sale + items + outbox (atomic txn) | stays — operational |
| nextReceiptNumber | Receipt numbering + `pos` gate | stays |
| voidSale | Void sale + audit + outbox (txn) | stays |
| getSales / getRecentSales / getVoidedSalesForShift / getSalesByIds/_hydrate | Sale retrieval/history | stays (retrieval, not reporting) |
| requestVoid / approveVoidRequest / rejectVoidRequest | Void workflow + audit + outbox | stays |
| _enqueueSale / _enqueueVoidRequest | Sync outbox writes | stays (private, txn-bound) |
| _requireFeature → `requireFeature` | Permission gate | extracted to `feature_gate.dart` (shared, verbatim) |
| getRevenueTrend | Reporting: daily revenue | **moved** → `ReportingRepository` |
| getDashboardStats | Reporting: dashboard figures (+ expected cash via ShiftRepository.getShiftSummary) | **moved** |
| getAuditLogs | Reporting: audit read | **moved** |
| getTodayRevenue | Reporting: convenience over getDashboardStats | **moved** |
| getProductSalesSummary | Reporting: product aggregation | **moved** |
| getCashierPerformance | Reporting: per-cashier aggregation | **moved** |

Compatibility: `SaleRepository` keeps all six signatures; both impls delegate
to `SqfliteReportingRepository` / `CloudReportingRepository`. `AppBackend`
gains `ReportingRepository get reporting` (native + cloud wired).

## ShiftRepository (575 lines)
ensureActiveShift, openShift, addCashMovement(+photo), closeShift,
getShiftSummary, cash-movement history. Expected-cash calc, movement photos,
deposit/withdrawal reversal and outbox writes share transactions —
**kept intact** (cohesive register module).

## UserRepository (1267 lines)
hasUsers, createFirstOwner, createUser, ensureDemoUser (+demo credential
adoption/retirement), setUserPermissions, setUserPhone, changePassword,
resetPassword, setUserActive, deleteUser; private: PBKDF2 hash/verify/legacy
verify/upgrade, constant-time compare, login guards (persist/record/clear),
user+audit outbox enqueues.
Password hashing is intertwined with credential migration (`_verifyCredential`
→ `_upgradePasswordHash` writes back to the user row in the same flow) and
the login-guard persistence — extracting a stateless hasher was assessed and
**deliberately postponed**: the only cleanly separable pieces are
`_generateSalt`/`_formatHash`/`_hashPasswordLegacy`/`_constantTimeEquals`,
which are ~60 lines of pure functions whose extraction buys little and risks
the freeze mandate. Documented as remaining coupling.

## FinanceRepository (907 lines)
Category CRUD (create/rename/delete/restore/permanentDelete) + entry
lifecycle (addEntry/updateEntry/markCompleted/deleteEntry) sharing
`_requireFinanceAccess`, `_audit`, `_validatedName/_validatedSource`,
`_requireCategory`, source-entry dedup. markCompleted/deleteEntry write
register cash movements inside the same transaction — **kept intact**;
splitting categories from entries was rejected because both share the same
transaction helpers and audit path.

## PicklistRepository (542 lines)
createPicklist, updateItemQuantities, addCustomer, toggleItemTaken,
updatePicklistItem, deletePicklistItem, deletePicklist — requested/taken
qty clamping, completion rules, soft delete, customer directory, price
visibility, outbox. **Kept intact** (cohesive warehouse module).

## ProductRepository (177 lines)
save/update/deactivate/reactivate + name-uniqueness. **Kept intact.**

## Cloud repositories
Cloud{Sale,Shift,User,Finance,Product,Picklist}Repository — thin `pos-api`
wrappers; only CloudSaleRepository contained reporting calls (now delegated
to CloudReportingRepository, same actions/payloads).
