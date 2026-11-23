# Database Transaction Inventory — Stage 6.0

**Status:** characterisation only. No production file, SQL statement, schema,
repository method, transaction boundary, or table was changed to produce this
document or its tests.

**Date:** 2026-11-19
**Repository:** `C:\Users\www\wholesale_pos`, branch `main`, HEAD `64ff4fe`
(the Stage 1–4 working tree remains uncommitted).

**Scope:** every explicit `Database.transaction(...)` boundary under
`app/lib`, i.e. the 38 sites that make multi-row repository work atomic. Reads,
single-row settings writes, outbox drain/ack, and cursor writes are listed
separately because they are deliberately *not* transactions.

**Method:** static inspection of the current tree, an exhaustive search for
`.transaction(`, and a new failure-injection suite
(`frontend/test/core/database/transaction_rollback_test.dart`) that aborts a
transaction after earlier statements have written and verifies the rollback.

---

## 1. Summary

| File | Transaction sites |
|---|---:|
| `core/repositories/sale_repository.dart` | 6 |
| `core/repositories/shift_repository.dart` | 4 |
| `core/repositories/finance_repository.dart` | 9 |
| `core/repositories/user_repository.dart` | 7 |
| `core/repositories/picklist_repository.dart` | 6 |
| `core/repositories/product_repository.dart` | 4 |
| `core/sync/sync_pull_applier.dart` | 1 |
| `core/utils/data_importer.dart` | 1 |
| **Total** | **38** |

All 38 are `db.transaction((txn) async { … })` on the single long-lived
connection. No nested/independent transactions, no `BEGIN`/`COMMIT` SQL, no
savepoints, and no second connection exist.

---

## 2. Sales — `sale_repository.dart`

| # | Method | Line | Reads | Writes | Purpose | Existing coverage | Rollback test |
|---:|---|---:|---|---|---|---|---|
| 1 | `saveSale` | 106 | `shifts` | `sales`, `sale_items`, `audit_logs`, `sync_outbox` | Validate the sale against an open shift, insert header + every line, audit, queue the sale. | `sale_repository_test.dart`, `receipt_counter_test.dart` | **Yes** — duplicate line id aborts after header, first line and its outbox payload; nothing survives. |
| 2 | `nextReceiptNumber` | 228 | `counters`, `sales` | `counters` | Allocate the next daily receipt number above any number already present locally. | `receipt_counter_test.dart` | No dedicated rollback test; the only write is the counter upsert. |
| 3 | `voidSale` | 262 | `sales`, `users`, `shifts`, `void_requests` | `sales`, `void_requests`, `audit_logs`, `sync_outbox` | Owner void; settles any pending request for the same sale and queues both entities. | `void_sale_test.dart`, `void_request_test.dart` | **Yes** — audit trigger aborts after the sale update and request settlement; sale stays `COMPLETED`, request stays `PENDING`. |
| 4 | `requestVoid` | 463 | `sales`, `users`, `void_requests` | `void_requests`, `audit_logs`, `sync_outbox` | Cashier flags a completed sale for owner review; one pending request per sale. | `void_request_test.dart` | No dedicated rollback test. |
| 5 | `approveVoidRequest` | 573 | `users`, `void_requests`, `sales`, `shifts` | `sales`, `void_requests`, `audit_logs`, `sync_outbox` | Owner approval voids the sale and closes the request in one step. | `void_request_test.dart` | **Yes** — audit trigger aborts after both updates; sale and request revert together. |
| 6 | `rejectVoidRequest` | 667 | `users`, `void_requests` | `void_requests`, `audit_logs`, `sync_outbox` | Owner rejects the request; the sale is untouched. | `void_request_test.dart` | No dedicated rollback test. |

---

## 3. Register — `shift_repository.dart`

| # | Method | Line | Reads | Writes | Purpose | Existing coverage | Rollback test |
|---:|---|---:|---|---|---|---|---|
| 7 | `ensureActiveShift` | 124 | `shifts` | `shifts`, `sync_outbox` | Idempotently create the perpetual drawer only when none is open. | `shift_cash_math_test.dart`, `shift_history_test.dart` | No dedicated rollback test. |
| 8 | `openShift` | 188 | `shifts` | `shifts`, `audit_logs`, `sync_outbox` | Refuse a second open drawer, then insert + audit + queue. | `shift_cash_math_test.dart` | No dedicated rollback test. |
| 9 | `addCashMovement` | 225 | `shifts`, `users` | `cash_movements`, `cash_movement_photos`, `audit_logs`, `sync_outbox` | Withdrawal/deposit/expense plus optional JPEG proof, audit, queue. | `shift_cash_math_test.dart` | **Yes** — audit trigger aborts after movement + photo; all four tables roll back. |
| 10 | `closeShift` | 472 | `shifts`, `sales`, `cash_movements` | `shifts`, `audit_logs`, `sync_outbox` | Compute expected cash and close the drawer atomically. | `shift_cash_math_test.dart`, `shift_history_test.dart` | **Yes** — audit trigger leaves the shift `OPEN` with null closing fields. |

---

## 4. Finance — `finance_repository.dart`

| # | Method | Line | Reads | Writes | Purpose | Existing coverage | Rollback test |
|---:|---|---:|---|---|---|---|---|
| 11 | `createCategory` | 236 | `users` | `finance_categories`, `sync_outbox`, `audit_logs` | Add a person/category, queue it, audit. | `finance_repository_test.dart` | No dedicated rollback test. |
| 12 | `renameCategory` | 259 | `users`, `finance_categories` | `finance_categories`, `sync_outbox`, `audit_logs` | Rename in place; entries stay attached. | `finance_repository_test.dart` | No dedicated rollback test. |
| 13 | `deleteCategory` | 294 | `users`, `finance_categories` | `finance_categories`, `sync_outbox`, `audit_logs` | Soft-delete to the recycle bin. | `finance_repository_test.dart` | No dedicated rollback test. |
| 14 | `restoreCategory` | 332 | `users`, `finance_categories` | `finance_categories`, `sync_outbox`, `audit_logs` | Clear the tombstone. | `finance_repository_test.dart` | No dedicated rollback test. |
| 15 | `permanentlyDeleteCategory` | 369 | `users`, `finance_categories` | `finance_entries`, `finance_categories`, `sync_outbox`, `audit_logs` | Purge a binned person *and* every entry, then queue a durable DELETE. | `finance_repository_test.dart` | No dedicated rollback test. |
| 16 | `addEntry` | 542 | `users`, `finance_categories` | `finance_entries`, `sync_outbox`, `audit_logs` | Insert a pending collection/payment. | `finance_repository_test.dart` | No dedicated rollback test. |
| 17 | `updateEntry` | 577 | `users`, `finance_entries`, `finance_categories` | `finance_entries`, `sync_outbox`, `audit_logs` | Edit a still-pending entry only. | `finance_repository_test.dart` | No dedicated rollback test. |
| 18 | `markCompleted` | 626 | `users`, `finance_entries`, `finance_categories`, `shifts` | `finance_entries`, `cash_movements`, `sync_outbox`, `audit_logs` | Mark taken; a CASH collection also deposits into the open drawer. | `finance_repository_test.dart` | **Yes** — deposit insert aborts after the entry update and entry outbox; entry stays `PENDING`, no movement/outbox is left. |
| 19 | `deleteEntry` | 721 | `users`, `finance_entries`, `finance_categories`, `cash_movements`, `shifts` | `cash_movements`, `finance_entries`, `sync_outbox`, `audit_logs` | Tombstone the entry; a completed CASH collection first posts a reversing WITHDRAWAL. | `finance_repository_test.dart` | **Yes** — tombstone update aborts after the reversal movement; movement disappears and the entry stays `COMPLETED`. |

Note: `_audit` here intentionally swallows audit-insert failures so auditing can
never block financial record keeping. A failure trigger must therefore target a
**business** write (as the rollback tests do), not the audit row.

---

## 5. Users — `user_repository.dart`

| # | Method | Line | Reads | Writes | Purpose | Existing coverage | Rollback test |
|---:|---|---:|---|---|---|---|---|
| 20 | `_upgradePasswordHash` | 359 | `users` (via queue) | `users`, `sync_outbox` | Re-hash a legacy credential on successful sign-in and publish the cloud pair. | `user_repository_test.dart`, `demo_user_test.dart` | No dedicated rollback test. |
| 21 | `createFirstOwner` | 613 | `users` | `users`, `sync_outbox` | Count-inside-transaction guard against a second owner, insert, queue. | `user_repository_test.dart` | No dedicated rollback test. |
| 22 | `createUser` | 725 | `users` | `users`, `sync_outbox` | Refuse a live duplicate; revive a tombstoned phone number or insert a new row; queue. | `user_repository_test.dart` | No dedicated rollback test. |
| 23 | `setUserPermissions` | 945 | `users` | `users`, `sync_outbox` | Persist the tick list for a staff account; owners are refused before the transaction. | `user_repository_test.dart` | No dedicated rollback test. |
| 24 | `setUserPhone` | 1003 | `users` | `users`, `sync_outbox` | Owner-only login-phone change after uniqueness checks outside the transaction. | `user_repository_test.dart` | No dedicated rollback test. |
| 25 | `setUserActive` | 1115 | `users` | `users`, `audit_logs`, `sync_outbox` | Last-active-owner guard + activation state + audit + queue. | `user_repository_test.dart` | No dedicated rollback test. |
| 26 | `deleteUser` | 1183 | `users`, `sales`, `shifts`, `cash_movements`, `finance_entries`, `void_requests` | `users`, `audit_logs`, `sync_outbox` | Count historical references inside the transaction; tombstone when referenced, delete when clean; queue a bin state either way. | `user_repository_test.dart` | No dedicated rollback test. |

`_audit` in this file also catches its own insert failure, by design.

---

## 6. Catalog — `product_repository.dart`

| # | Method | Line | Reads | Writes | Purpose | Existing coverage | Rollback test |
|---:|---|---:|---|---|---|---|---|
| 27 | `save` | 43 | `products` (unique-name check before the transaction) | `products`, `sync_outbox` | Insert a saved name and queue it. | `test/core/models/product_repository_test.dart` | No dedicated rollback test. |
| 28 | `update` | 54 | `products` | `products`, `sync_outbox` | Update name/price/active flag and queue. | same | No dedicated rollback test. |
| 29 | `deactivate` | 115 | `products` | `products`, `sync_outbox` | Set `is_active = 0` and queue. | same | No dedicated rollback test. |
| 30 | `reactivate` | 128 | `products` | `products`, `sync_outbox` | Set `is_active = 1` and queue. | same | No dedicated rollback test. |

---

## 7. Warehouse — `picklist_repository.dart`

| # | Method | Line | Reads | Writes | Purpose | Existing coverage | Rollback test |
|---:|---|---:|---|---|---|---|---|
| 31 | `createPicklist` | 139 | — (validated before the transaction) | `picklists`, `picklist_items`, `sync_outbox` | Header + every line + per-item/header queue rows. | `picklist_repository_test.dart` | No dedicated rollback test. |
| 32 | `updateItemQuantities` | 173 | `picklists`, `picklist_items` | `picklist_items`, `picklists`, `sync_outbox` | Progress pass, then re-derive header status from all active lines. | `picklist_repository_test.dart` | No dedicated rollback test. |
| 33 | `updatePicklistItem` | 246 | `picklists`, `picklist_items` | `picklist_items`, `picklists`, `sync_outbox` | Correct one line, clamp `taken_qty`, recompute the line total, re-derive the header. | `picklist_repository_test.dart` | No dedicated rollback test. |
| 34 | `deletePicklistItem` | 316 | `picklists`, `picklist_items` | `picklist_items`, `picklists`, `sync_outbox` | Tombstone a line; tombstone the header when it was the last active line, otherwise re-derive. | `picklist_repository_test.dart` | No dedicated rollback test. |
| 35 | `deletePicklist` | 349 | `picklists`, `picklist_items` | `picklist_items`, `picklists`, `sync_outbox` | Tombstone every active line + the header. | `picklist_repository_test.dart` | No dedicated rollback test. |
| 36 | `toggleItemTaken` | 473 | `picklists`, `picklist_items` | `picklist_items`, `picklists`, `sync_outbox` | Full/zero one line + re-derive the header. | `picklist_repository_test.dart` | No dedicated rollback test. |

---

## 8. Sync pull — `sync_pull_applier.dart`

| # | Method | Line | Reads | Writes | Purpose | Existing coverage | Rollback test |
|---:|---|---:|---|---|---|---|---|
| 37 | `SyncPullApplier.apply` | 156 | Inside each applier helper | `users`, `products`, `finance_categories`, `picklists`, `picklist_items`, `devices`, `shifts`, `sales`, `sale_items`, `cash_movements`, `void_requests`, `finance_entries` | Apply one cloud page in dependency order; conflicts are resolved inside the transaction. | `sync_pull_test.dart`, `sync_master_data_test.dart` | No dedicated rollback test; page-level atomicity is exercised by existing idempotency/ordering tests. |

The cursor (`sync_cursor.<table>`) is written by `CloudSyncPuller` **after** a
page has committed, not inside this transaction. That ordering is deliberate:
a crash between commit and cursor write re-applies one page, which is a no-op,
whereas the reverse would skip rows.

---

## 9. Restore — `data_importer.dart`

| # | Method | Line | Reads | Writes | Purpose | Existing coverage | Rollback test |
|---:|---|---:|---|---|---|---|---|
| 38 | `DataImporter.importFromJson` | 218 | Every table for its pre-restore recovery export (outside the transaction) | Deletes/re-inserts every business table, `settings`, `counters`, `sync_outbox`; deletes `sync_cursor.%`; inserts `BACKUP_RESTORED` | Replace the dataset in one transaction after validation, owner-preserving credential reseeding, and a recovery export. | `data_importer_test.dart` | **Yes** — an induced insert failure and a foreign-key violation both restore the pre-restore dataset exactly. |

---

## 10. Deliberately non-transactional writes

These must **not** be wrapped in a transaction during a later stage without an
approved design:

| Site | Why it is not transactional |
|---|---|
| `LocalDatabase.getSetting` / `setSetting` | Single-row upsert; callers depend on immediate, independent commitment (theme, session, licence, guards). |
| `CloudSyncPuller._writeCursor` / `_backfillPicklistPrices` | Cursor must follow a committed page; re-reading is safe, skipping is not. |
| `SyncOutboxRepository.pending` / `markSynced` / `pruneSynced` | Each is one statement (or an idempotent batch); batching them would hold a write lock across network-adjacent bookkeeping. |
| `LocalDatabase.registerCurrentDevice` / `_insertDeviceIfMissing` | Single idempotent insert plus a state file; called after a restore commits. |
| `SettingsSessionStore.save/load/clear` | One settings row; session expiry/corruption handling deletes that row. |
| `DataExporter.exportToJson` | Intentional sequential read snapshot, not a point-in-time transaction (preserved finding F-7). |
| `UserRepository._audit`, `FinanceRepository._audit` | Best-effort audit inserts; failures are swallowed by design. |
| Login guards (`_persistGuard`) | Best-effort persistence; the in-memory guard remains authoritative for the session. |

---

## 11. Rollback evidence produced in Stage 6.0

`frontend/test/core/database/transaction_rollback_test.dart` (9 tests) installs
test-only `RAISE(ABORT)` triggers and asserts the full rollback:

| Scenario | Failure injected after | Proven outcome |
|---|---|---|
| `saveSale` | Header + first line + first outbox payload | No sale, no lines, no audit, no outbox. |
| `voidSale` | Sale update + pending-request settlement | Sale `COMPLETED`, request `PENDING`, outbox unchanged. |
| `approveVoidRequest` | Sale void + request approval | Both revert. |
| `markCompleted` | Entry update + entry outbox | Entry `PENDING`, no deposit, no extra outbox. |
| `deleteEntry` | Reversal movement + movement outbox | Reversal gone, entry still `COMPLETED`. |
| `addCashMovement` | Movement + proof photo | No movement, photo, audit or outbox. |
| `closeShift` | Shift update | Shift `OPEN`, closing fields null. |
| `importFromJson` (insert failure) | Deletes + partial re-inserts | Previous dataset intact; recovery snapshot survives. |
| `importFromJson` (FK violation) | Deletes + partial re-inserts | Previous dataset intact; `foreign_key_check` clean. |

The remaining 29 sites are covered by happy-path and rejection tests but not by
a dedicated failure-injection rollback test. Stage 6.0 records that gap rather
than claiming rollback evidence it did not collect. Adding those tests was not
required to preserve production behaviour and no production behaviour was
changed to make the nine scenarios pass.

---

## 12. Preservation rules

1. Do not move a write out of its current transaction into a neighbouring one.
2. Do not merge two repository transactions into a wider transaction; the
   outbox and audit ordering is consumed by sync and by the screens.
3. Do not add `BEGIN`/`COMMIT`, savepoints, WAL, or a second connection.
4. Do not make audit inserts fatal where they currently swallow errors.
5. Do not make cursor writes transactional with page application.
6. Keep `DataImporter`'s recovery export before the transaction and
   `registerCurrentDevice` after it.
