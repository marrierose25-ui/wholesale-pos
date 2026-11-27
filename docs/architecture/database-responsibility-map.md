# Database Responsibility Map — Stage 5 Audit (updated Stage 6.0)

**Status:** audit only. No production code, SQL, schema, repository, startup,
sync, or deployment file was modified to produce this document or its
Stage 6.0 companion artefacts.

**Date:** 2026-11-19
**Repository:** `C:\Users\www\wholesale_pos`, branch `main`, HEAD `64ff4fe`
(the Stage 1–4 working tree is uncommitted — see the Stage 5 entry in
`migration-log.md`).

**Stage 6.0 addendum:** characterisation and migration-safety only. Tests,
fixtures, tooling and docs were added; no production file changed. See §10 for
the updated coverage and §11 for the new findings.

**Scope:** the native SQLite persistence stack of the Flutter application:
`frontend/lib/core/database/local_database.dart` and every component that opens,
reads, writes, migrates, backs up, restores, or receives the local database.

**Method:** static inspection of the current working tree, import-graph
tracing, exhaustive search for `Database`/`Transaction`/`DatabaseExecutor`
parameters, `db.transaction` call sites, SQL string literals, settings keys,
and the database/sync/backup tests; plus the checks listed in §10.

---

## 1. Runtime topology (as implemented today)

```text
main.dart  (native composition root)
  └─ LocalDatabase.open()                         ← single Database handle
       ├─ registerCurrentDevice(db)               → devices row + device_id.txt
       ├─ ProductRepository(db)                   → products
       ├─ SaleRepository(db)                      → sales, sale_items, void_requests,
       │                                            audit_logs, counters, sync_outbox
       ├─ UserRepository(db)                      → users, audit_logs, settings, sync_outbox
       ├─ ShiftRepository(db)                     → shifts, cash_movements,
       │                                            cash_movement_photos, audit_logs, sync_outbox
       ├─ FinanceRepository(db)                   → finance_categories, finance_entries,
       │                                            cash_movements, shifts (read), audit_logs, sync_outbox
       ├─ NativeBackend(db, repos, session)       → shared AppBackend seam
       ├─ SyncOutboxRepository(db)                → sync_outbox
       ├─ CloudSyncPuller(backend, db)            → SyncPullApplier(db)
       └─ SyncService(outbox, backend, puller)

LicenseWrapper(db)  ──┬─ DeviceFingerprint.get(db)       → settings (+ platform id)
                      ├─ DeviceActivation.redeem(db)      → settings
                      └─ SqliteLocalDataOps(db)           → settings, backup/restore,
                                                            device registration
SettingsScreen (native builder) ── LocalDataOps (no raw Database)

Web (main_web.dart)
  └─ CloudBackend → Cloud*Repository → pos-api HTTP
     (no LocalDatabase, no path_provider, no sqflite_common_ffi)
```

There is exactly **one** `Database` instance in production. It is created once
in `_startup()` and is never closed; the process lifetime is the connection
lifetime. Repositories do not open their own connections.

---

## 2. Database lifecycle inventory

| Phase | Location | Behaviour | Preservation requirement |
| --- | --- | --- | --- |
| Factory selection | `local_database.dart:26-36` | On Windows/Linux/macOS (and the test host) installs `sqflite_common_ffi` as the global `databaseFactory`. Android/iOS keep the plugin default. | Exact platform condition and global-factory semantics must survive; tests rely on the FFI factory. |
| Open (production) | `local_database.dart:38-42` | Resolves `getApplicationSupportDirectory()` and opens `<support>/wholesale_pos.db`. | Filename and directory unchanged. |
| Open (explicit path) | `local_database.dart:46-49` | Test/migration entry point (`openAt`). | Keep for migration tests and recovery tooling. |
| Open in memory | `local_database.dart:51-62` | `inMemoryDatabasePath`, same version/callbacks, no file backup. | Every repository test depends on this. |
| Connection configuration | `local_database.dart:69-75` | `PRAGMA foreign_keys = ON`, then the pre-migration backup check, **before** sqflite reads `user_version`. | Callback order is load-bearing: backup must see the old file version. |
| Safety backup | `local_database.dart:110-145` | Copies the file to `<path>.bak` when on-disk `user_version` is neither `0` nor the current `schemaVersion` (including newer files). Failure is logged, never fatal. Current/zero files are skipped so a good backup is not clobbered. | Byte-for-byte pre-migration copy; identical skip rules; identical non-fatal failure behaviour. |
| Fresh schema | `local_database.dart:810-1065` | One batch creates all 18 tables, then `_createIndexesAndTriggers`. | Identical DDL, column order, defaults, FKs, and post-batch index/trigger creation. |
| Historical upgrades | `local_database.dart:231-626` | Version-gated `if (oldVersion < N)` chain, v2→v22, executed inside sqflite's single `onUpgrade` transaction. Includes two table rebuilds (v6 `cash_movements`, v7 `sale_items`), data backfills, and guarded additive ALTERs. | Never reorder, merge, rewrite, or renumber; never add a migration in Stage 6. |
| Duplicate-open-shift repair | `local_database.dart:149-165` | During v5, auto-closes all but the newest `OPEN` shift with a warning. | Preserve exactly. |
| Index/trigger creation | `local_database.dart:718-779`, `795-808` | Idempotent `IF NOT EXISTS` indexes and triggers, called from v6/v7/v8/v9/v10 and from `onCreate`. `one_open_shift` creation is wrapped in try/catch. | Preserve call sites and ordering; see finding F-2. |
| Runtime settings | `local_database.dart:213-229` | `getSetting` / `setSetting` (`INSERT … REPLACE`). | Key names and upsert semantics unchanged. |
| Device registration | `local_database.dart:170-211` | Stable UUID in `device_id.txt` beside the DB; ensures the matching `devices` row. In-memory path reuses/creates a row. | File name, location, UUID semantics, `name`/`platform` values unchanged. |
| No shutdown | `main.dart` | The handle is never closed. | Keep one long-lived handle; do not introduce connection pooling. |

**Not present today (must not be introduced in Stage 6):** WAL mode, an
`onDowngrade` handler, second connections, per-module databases, an ORM, or a
schema-version change.

---

## 3. Component responsibility inventory

| Component | File | DB responsibility | Direct SQL? | Receives `Database`? |
| --- | --- | --- | --- | --- |
| `LocalDatabase` | `core/database/local_database.dart` | Factory, open, lifecycle, schema, all migrations, indexes, triggers, safety backup, settings helpers, device registration | Yes (DDL, PRAGMA, settings CRUD) | Yes (all statics) |
| `SqfliteProductRepository` | `core/repositories/product_repository.dart` | Catalog writes/reads + outbox | Yes (via sqflite API) | Yes (`_db`) |
| `SqfliteSaleRepository` | `core/repositories/sale_repository.dart` | Sales, line items, voids, receipts, audit, outbox; reporting delegates | Yes | Yes |
| `SqfliteReportingRepository` | `core/repositories/reporting_repository.dart` | Read-only dashboard/report queries | Yes | Yes |
| `SqfliteShiftRepository` | `core/repositories/shift_repository.dart` | Shifts, cash movements, photos, drawer math, audit, outbox | Yes | Yes |
| `SqfliteFinanceRepository` | `core/repositories/finance_repository.dart` | Finance categories/entries, cash deposit/reversal, audit, outbox | Yes | Yes |
| `SqflitePicklistRepository` | `core/repositories/picklist_repository.dart` | Picklists, lines, customers, soft delete, outbox | Yes | Yes |
| `SqfliteUserRepository` | `core/repositories/user_repository.dart` | Accounts, PBKDF2 credentials, login guards, demo account, audit, outbox | Yes | Yes |
| `requireFeature` | `core/repositories/feature_gate.dart` | Reads `users` for authorization | Yes (via `DatabaseExecutor`) | Executor only |
| `SettingsSessionStore` | `core/auth/session_store.dart` | Persists the opaque sign-in session in `settings` | Yes | Yes |
| `DeviceFingerprint` | `core/licensing/device_fingerprint.dart` | Reads/writes `device_hw_uuid`, `device_install_uuid` via `LocalDatabase` helpers | No (helper calls) | Yes |
| `DeviceActivation` | `core/licensing/device_activation.dart` | Reads/writes `license_code`, `activation_code` via helpers | No | Yes |
| `DataExporter` | `core/utils/data_exporter.dart` | Owner-only JSON export; reads every table; reattaches photos; writes a `BACKUP_EXPORTED` audit row | Yes | Yes |
| `DataImporter` | `core/utils/data_importer.dart` | Owner-only restore; validates; writes recovery snapshot; one replacement transaction; FK check; audit row | Yes | Yes |
| `LocalDataOps` | `core/backend/local_data_ops.dart` | UI-facing local-data contract (no SQLite types) | No | No |
| `SqliteLocalDataOps` | `core/backend/sqlite_local_data_ops.dart` | Adapts `LocalDatabase`, `SettingsSessionStore`, exporter/importer, licensing; re-registers device after restore | No direct SQL (delegates) | Yes |
| `NativeBackend` | `core/backend/native_backend.dart` | Composition of SQLite repositories + settings + session; exposes `AppBackend` | No direct SQL | Yes |
| `SyncOutbox` | `core/sync/sync_outbox.dart` | Inside caller's transaction: demo-ownership check, outbox insert; UTC stamp normalisation | Yes (`DatabaseExecutor`) | Executor only |
| `SyncOutboxRepository` | `core/sync/sync_outbox_repository.dart` | Drain/ack/prune `sync_outbox` | Yes | Yes |
| `SyncPullApplier` | `core/sync/sync_pull_applier.dart` | Applies one cloud page across 11 tables in one transaction | Yes | Yes |
| `CloudSyncPuller` | `core/sync/sync_pull_applier.dart:1385-1531` | Cursor persistence in `settings`, one-time price backfill, pull ordering | Yes | Yes |
| `main.dart` | `main.dart` | Opens the DB, composes repositories/sync, passes `db` into `LicenseWrapper`/`WholesalePosApp` | PRAGMA-free | Yes (widget fields) |
| `app_shell.dart` | `app_shell.dart` | No DB access; only `AppBackend` settings/session | No | No |
| Feature screens | `lib/features/**` | No sqflite import, no `Database` reference (enforced by `architecture_test.dart`) | No | No |

`LocalDataOps` is the only UI-facing local-data boundary. `SettingsScreen`
receives it instead of a `Database`; `main.dart` constructs
`SqliteLocalDataOps(widget.db)` inside the native settings builder.

---

## 4. Table ownership map

One physical database. "Owner" is the module that defines the row's business
meaning, not the only code allowed to touch it — several cross-module writes
are deliberate and transaction-bound (§7).

| Table | Owning module | Primary writer(s) | Other writers / readers | Key constraints |
| --- | --- | --- | --- | --- |
| `users` | Users / Identity | `SqfliteUserRepository` | `SyncPullApplier` (upsert), `DataImporter`, `requireFeature` (read), `SyncOutbox` (demo check) | PK `id`; `username UNIQUE`; FKs from sales/shifts/movements/finance/voids |
| `products` | Catalog | `SqfliteProductRepository` | `SyncPullApplier`, `DataImporter`, warehouse screens read via repository | PK `id`; `code UNIQUE` |
| `devices` | Licensing / Device | `LocalDatabase.registerCurrentDevice` | `SyncPullApplier` placeholder/merge, `DataImporter`, `DataExporter`, sales FK | PK `id`; `sales.device_id` FK |
| `shifts` | Register | `SqfliteShiftRepository` | `SyncPullApplier`, `DataImporter`; Finance reads the open shift | PK `id`; partial unique index `one_open_shift`; two open-shift triggers; two cashier-existence triggers |
| `cash_movements` | Register | `SqfliteShiftRepository` | **`SqfliteFinanceRepository` inserts DEPOSIT/WITHDRAWAL**, `SyncPullApplier`, `DataImporter` | PK `id`; FK `shift_id`, `user_id`; `source_finance_entry_id` (cloud uniqueness contract) |
| `cash_movement_photos` | Register | `SqfliteShiftRepository` | `SyncPullApplier`, `DataImporter` (clears/writes), `DataExporter` (read) | PK `movement_id`; FK `ON DELETE CASCADE` |
| `sales` | Sales | `SqfliteSaleRepository` | `SyncPullApplier`, `DataImporter` | PK `id`; `receipt_number UNIQUE`; FKs cashier/device/shift |
| `sale_items` | Sales | `SqfliteSaleRepository` | `SyncPullApplier`, `DataImporter` | PK `id`; FK `sale_id` `ON DELETE CASCADE` |
| `void_requests` | Sales | `SqfliteSaleRepository` | `SyncPullApplier`, `DataImporter` | PK `id`; FKs sale/requested_by/decided_by |
| `finance_categories` | Finance | `SqfliteFinanceRepository` | `SyncPullApplier`, `DataImporter` | PK `id`; soft delete via `deleted_at` |
| `finance_entries` | Finance | `SqfliteFinanceRepository` | `SyncPullApplier`, `DataImporter` | PK `id`; FKs category/created_by/completed_by; status lifecycle |
| `picklists` | Warehouse | `SqflitePicklistRepository` | `SyncPullApplier` | PK `id`; soft delete via `deleted_at` |
| `picklist_items` | Warehouse | `SqflitePicklistRepository` | `SyncPullApplier` | PK `id`; FK `picklist_id` `ON DELETE CASCADE`; soft delete |
| `picklist_customers` | Warehouse | `SqflitePicklistRepository` | — (not in sync/pull/export lists; see F-6) | PK `id` |
| `audit_logs` | Cross-cutting audit | Sales, Register, Finance, Users, Exporter, Importer | `SqfliteReportingRepository` (read) | PK `id`; no FK (survives account deletion) |
| `counters` | Sales (receipt stream) | `SqfliteSaleRepository.nextReceiptNumber` | `DataImporter`, `DataExporter` | PK `name` |
| `settings` | Cross-cutting local state | Session, licensing, login guards, sync cursors, theme, demo version | `LocalDatabase`, user repo, puller, importer/exporter | PK `key`; see §8 |
| `sync_outbox` | Synchronization | Every business repository **inside its transaction** | `SyncOutboxRepository` drains; `SyncPullApplier` may write; importer clears it | PK `id`; index `sync_outbox_pending(synced_at)` |

`audit_logs`, `counters`, `settings`, and `sync_outbox` are shared kernel
tables. They are intentionally not module-private.

---

## 5. Every component that executes SQL

Direct sqflite imports in `app/lib`:

- `core/database/local_database.dart` (DDL, PRAGMA, settings, device rows)
- `core/repositories/{product,sale,reporting,shift,finance,picklist,user}_repository.dart`
- `core/repositories/feature_gate.dart` (users read)
- `core/auth/session_store.dart` (settings)
- `core/sync/sync_outbox.dart` (outbox, transactional executor)
- `core/sync/sync_outbox_repository.dart` (outbox)
- `core/sync/sync_pull_applier.dart` (all synced tables, settings cursors)
- `core/utils/data_exporter.dart`, `core/utils/data_importer.dart` (all tables)
- `core/backend/native_backend.dart` (type + settings helpers)
- `core/backend/sqlite_local_data_ops.dart` (type + helpers)
- `core/licensing/device_fingerprint.dart` (`Database` parameter, helpers)
- `core/licensing/device_activation.dart` (`Database` parameter, helpers)
- `main.dart` (type + open)

No file under `lib/features/` imports sqflite or references `Database`
(`architecture_test.dart` enforces both).

SQL shape observed (counts are occurrence counts, not unique statements):

| File | `rawQuery`/`rawInsert`/`rawUpdate`/`rawDelete`/`execute` | `query`/`insert`/`update`/`delete` |
| --- | ---: | ---: |
| `local_database.dart` | 102 | 8 |
| `sale_repository.dart` | 4 | 36 |
| `shift_repository.dart` | 12 | 18 |
| `finance_repository.dart` | 3 | 30 |
| `user_repository.dart` | 4 | 43 |
| `reporting_repository.dart` | 9 | 1 |
| `picklist_repository.dart` | 0 | 25 |
| `product_repository.dart` | 0 | 9 |
| `sync_pull_applier.dart` | 0 | 36 |
| `sync_outbox.dart` | 2 | 2 |
| `sync_outbox_repository.dart` | 1 | 3 |
| `data_exporter.dart` | 0 | 16 |
| `data_importer.dart` | 1 | 32 |
| `session_store.dart` | 0 | 3 |
| `feature_gate.dart` | 0 | 1 |

---

## 6. Every component that receives a raw `Database`

Production (`app/lib`):

| Receiver | Kind |
| --- | --- |
| `NativeBackend({required Database db})` and `_db` | constructor field |
| `Sqflite{Product,Sale,Reporting,Shift,Finance,Picklist,User}Repository(this._db)` | constructor field |
| `SettingsSessionStore(this._db)` | constructor field |
| `SyncOutboxRepository(this._db)` | constructor field |
| `SyncPullApplier(this.db)`, `CloudSyncPuller({required this.db})` | constructor field |
| `DataExporter.exportToJson(Database db, …)` | static parameter |
| `DataImporter.importFromJson(Database db, …)` | static parameter |
| `SqliteLocalDataOps(this.db)` | constructor field |
| `DeviceFingerprint.get(Database db)` / `_rawValue(Database db)` | static parameter |
| `DeviceActivation.redeem(Database db, …)` | static parameter |
| `LocalDatabase.*` statics | parameter |
| `WholesalePosApp.db`, `LicenseWrapper.db` | widget fields |
| `SyncOutbox.*`, `requireFeature` | `DatabaseExecutor` (no connection ownership) |

Tests (`app/test`) also receive/construct `Database` extensively (in-memory
fixtures); moving the class must keep `LocalDatabase.openInMemory()` available
or provide an equivalent test seam.

---

## 7. Transaction boundary register

38 `transaction(...)` call sites in `app/lib`. Each row is a single SQLite
transaction; partial commits are not possible.

### Sales — `sale_repository.dart`

| Method | Tables written | Atomic guarantee |
| --- | --- | --- |
| `saveSale` | `sales`, `sale_items`, `audit_logs`, `sync_outbox` | Sale + lines + audit + outbox commit or roll back together (`:106-161`). |
| `nextReceiptNumber` | `counters` (read `sales`) | Per-day counter read/increment is serialized (`:228-256`). |
| `voidSale` | `sales`, `void_requests`, `audit_logs`, `sync_outbox` | Void + auto-closing a pending request + audit + two outbox rows (`:262-353`). |
| `requestVoid` | `void_requests`, `audit_logs`, `sync_outbox` | Request + audit + outbox (`:463-516`). |
| `approveVoidRequest` | `void_requests`, `sales`, `audit_logs`, `sync_outbox` | Decision + sale void + audit + two outbox rows (`:573-664`). |
| `rejectVoidRequest` | `void_requests`, `audit_logs`, `sync_outbox` | Decision + audit + outbox (`:667-712`). |

### Register — `shift_repository.dart`

| Method | Tables written | Atomic guarantee |
| --- | --- | --- |
| `ensureActiveShift` | `shifts`, `sync_outbox` | Drawer creation + outbox (`:124-137`). |
| `openShift` | `shifts`, `audit_logs`, `sync_outbox` | Open + audit + outbox (`:188-206`). |
| `addCashMovement` | `cash_movements`, `cash_movement_photos`, `audit_logs`, `sync_outbox` | Movement + optional photo BLOB + audit + outbox (`:225-277`). |
| `closeShift` | `shifts`, `audit_logs`, `sync_outbox` | Expected-cash SQL reads and close + audit + outbox (`:472-524`). |

### Finance — `finance_repository.dart`

| Method | Tables written | Atomic guarantee |
| --- | --- | --- |
| `createCategory` | `finance_categories`, `sync_outbox` | Row + outbox (`:236-251`). |
| `renameCategory` / `deleteCategory` / `restoreCategory` | `finance_categories`, `sync_outbox` | Row + outbox (`:259-355`). |
| `permanentlyDeleteCategory` | `finance_entries`, `finance_categories` | Entries + category removed together (`:369-400`). |
| `addEntry` | `finance_entries`, `sync_outbox` | Row + outbox (`:542-554`). |
| `updateEntry` | `finance_entries`, `sync_outbox` | Row + outbox (`:577-617`). |
| **`markCompleted`** | `finance_entries`, `cash_movements`, `sync_outbox`, `audit_logs` | Completion + CASH deposit + outbox + audit in one transaction (`:626-707`). Refuses when no drawer is open. |
| **`deleteEntry`** | `cash_movements`, `finance_entries`, `sync_outbox`, `audit_logs` | Reversing WITHDRAWAL + soft-delete + outbox + audit in one transaction (`:721-806`). Refuses when a reversal is needed but no drawer is open. |

### Users — `user_repository.dart`

| Method | Tables written | Atomic guarantee |
| --- | --- | --- |
| `_upgradePasswordHash` | `users`, `sync_outbox` | Hash migration + outbox (`:359-378`). |
| `createFirstOwner` | `users`, `sync_outbox` | First-owner check + insert + outbox (`:613-628`). |
| `createUser` | `users`, `sync_outbox` | Optional phone-replacement + insert + outbox (`:725-764`). |
| `setUserPermissions` | `users`, `sync_outbox` | `:945-958`. |
| `setUserPhone` | `users`, `sync_outbox` | `:1003-1016`. |
| `setUserActive` | `users`, `audit_logs`, `sync_outbox` | Last-owner protection + state + audit + outbox (`:1115-1140`). |
| `deleteUser` | `users`, `audit_logs`, `sync_outbox` | History-preserving soft delete or physical delete + audit + outbox (`:1183-1236`). |

### Catalog / Warehouse

| Method | Tables written | Atomic guarantee |
| --- | --- | --- |
| `ProductRepository.save/update/deactivate/reactivate` | `products`, `sync_outbox` | Each pair atomic (`:43,54,115,128`). |
| `PicklistRepository.createPicklist` | `picklists`, `picklist_items`, `sync_outbox` | Header + lines + per-item outbox + header outbox (`:139-160`). |
| `updateItemQuantities` | `picklist_items`, `picklists`, `sync_outbox` | Lines + re-derived header + outboxes (`:173-220`). |
| `updatePicklistItem` | `picklist_items`, `picklists`, `sync_outbox` | `:246-286`. |
| `deletePicklistItem` | `picklist_items`, `picklists`, `sync_outbox` | `:316-330` + header re-derive. |
| `deletePicklist` | `picklists`, `picklist_items`, `sync_outbox` | Header + every line tombstone + outboxes (`:349-380`). |
| `toggleItemTaken` | `picklist_items`, `picklists`, `sync_outbox` | `:473-494` + header re-derive. |

### Restore / sync

| Method | Tables written | Atomic guarantee |
| --- | --- | --- |
| `DataImporter.importFromJson` | **every table** + `sync_outbox` purge + `audit_logs` | One transaction deletes and re-inserts the whole dataset, then `PRAGMA foreign_key_check`; any failure rolls the whole restore back (`data_importer.dart:218-325`). |
| `SyncPullApplier.apply` | 11 synced tables + placeholders | One transaction applies the whole page in dependency order (`sync_pull_applier.dart:156-203`); conflicts are handled inside. |

Not transactions (must remain so): `SyncOutboxRepository.pending/markSynced/pruneSynced`,
cursor writes, `LocalDatabase.getSetting/setSetting`, `registerCurrentDevice`,
and every read query.

---

## 8. Settings keys and device identity

| Key | Written by | Read by | Purpose | In JSON backup? |
| --- | --- | --- | --- | --- |
| `theme_mode` | Shell via `NativeBackend.setSetting` | `main.dart` at startup | Dark/light choice | Yes |
| `remember_login` | Settings screens via `LocalDataOps`/`AppBackend` | `app_shell.dart` | Stay-signed-in preference | Yes |
| `auth_session` | `SettingsSessionStore` | `SettingsSessionStore` | Opaque local session | **No** (stripped) |
| `license_code` | `DeviceActivation` | `main.dart` license gate, `SyncGatewayBackend` | Signed Ed25519 licence | **No** (stripped) |
| `activation_code` | `DeviceActivation` | `SqliteLocalDataOps` → Devices screen | Short seat code | **No** (stripped) |
| `device_hw_uuid` | `DeviceFingerprint` | `DeviceFingerprint` | Windows hardware-UUID cache | **No** (stripped) |
| `device_install_uuid` | `DeviceFingerprint` | `DeviceFingerprint` | Mobile fallback install id | **No** (stripped) |
| `demo_password_version` | `SqfliteUserRepository` | `SqfliteUserRepository` | Retires the published demo password | Yes |
| `login_guard:<guardKey>` | `SqfliteUserRepository` | `SqfliteUserRepository` | Persisted failed-attempt counter + lockout deadline | Yes |
| `sync_cursor.<table>` (11 keys) | `CloudSyncPuller` | `CloudSyncPuller` | Per-table keyset cursor | Yes on export; **deleted on import** |
| `sync_backfill.picklist_item_prices.v1` | `CloudSyncPuller` | `CloudSyncPuller` | One-time price re-read flag | Yes |

Device identity has two halves: the `devices` row (FK target for sales) and the
`device_id.txt` state file next to the database. A restore replaces the
`devices` table; `SqliteLocalDataOps.restoreBackup` then calls
`LocalDatabase.registerCurrentDevice` so new sales keep a valid FK. The
in-memory path reuses the first existing row instead of the file.

Web settings are a separate namespace in `localStorage`
(`pos.setting.*`, `pos.activation_code`, `pos.device_id`, `pos.session`) and
never touch SQLite.

---

## 9. Backup / restoration taxonomy

### 9.1 Migration-safety backup (automatic)

- File: `<database>.bak`, beside `wholesale_pos.db`.
- Trigger: `onConfigure` sees `user_version` ∉ {0, 22}.
- Semantics: byte-for-byte copy of the pre-migration file; skipped for new and
  current files; also taken for newer-than-build files; failure is logged and
  startup continues.
- Recovery: operator renames `.bak` over the database.
- Tests: `test/core/database/pre_migration_backup_test.dart` (4 tests).

### 9.2 User-requested backup (JSON export)

- Entry: Settings → `LocalDataOps.exportBackup(userId)` →
  `DataExporter.exportToJson`.
- Authorization: `users.role == 'OWNER'` **and** `is_active == 1`, checked
  against the requesting id.
- Destination: `getApplicationDocumentsDirectory()`,
  `wholesale_pos_backup_<timestamp>.json`.
- Contents: `users` without `password_hash`/`salt`; all business tables;
  `cash_movement_photos` reattached to movement rows as base64; `settings`
  minus the five secret keys; `version = 22`.
- Side effect: inserts a `BACKUP_EXPORTED` audit row **after** writing the file.
- It is an operational snapshot, not a credential backup.

### 9.3 User-requested restoration (JSON import)

- Entry: Settings → `LocalDataOps.restoreBackup(path, userId)` →
  `DataImporter.importFromJson`, then device re-registration.
- Authorization: active owner only; the backup must retain that same owner.
- Validation: version must be 6–22; required table lists; required fields per
  table; optional finance/void tables default empty; schema-6 sale items are
  normalized to the flexible-quantity shape.
- Credential policy: the restoring owner keeps their live `password_hash`/`salt`;
  every other account receives an unusable PBKDF2-shaped digest and must be
  reset.
- Recovery snapshot: calls `DataExporter.exportToJson` **before** the
  replacement transaction.
- Replacement: one transaction deletes all tables (including `sync_outbox` and
  `settings`), re-inserts parents before children, deletes `sync_cursor.%`,
  runs `PRAGMA foreign_key_check`, writes `BACKUP_RESTORED`, commits.
- After commit: `registerCurrentDevice` restores this machine's `devices` row.
- Consequence to preserve: because licensed/session keys are stripped from the
  backup, a restore removes `license_code` / `activation_code` from `settings`.
  The running process keeps its validated licence; a later restart requires
  re-activation unless the keys are re-entered. This is existing behaviour and
  is **not** to be changed during the architecture work.

There is no user-facing raw-SQLite restore and no separate database file per
module.

---

## 10. Test coverage and current baseline

Database-focused tests:

| File | Tests | Coverage |
| --- | ---: | --- |
| `test/core/database/local_database_test.dart` | 2 | Fresh schema creates core tables; device id is stable. |
| `test/core/database/migration_test.dart` | 11 | v5→6, v6→7, v7→8, v8→9, v9→10, v10→11, v13→14, v15→16, v16→17, v17→18 (+v19 backfill), device re-registration. |
| `test/core/database/pre_migration_backup_test.dart` | 4 | Fresh install no backup; upgrade copies bytes; current file does not clobber; newer file is copied. |
| `test/core/utils/data_importer_test.dart` | 13 | Export/import, credential stripping, owner retention, invalid data, legacy normalization, cursors. |
| `test/core/auth/session_store_test.dart` | 8 | Session persistence/expiry/corruption. |
| `test/core/licensing/device_fingerprint_test.dart` | 3 | Fingerprint stability and settings row usage. |

Repository/sync suites (all against real in-memory SQLite) cover the
transactional behaviour: sales/voids/receipts, shift cash math/history, finance
lifecycle + cash deposit/reversal, picklists, users/credentials/demo isolation,
outbox atomicity, demo-account isolation, pull ordering and idempotency.

**Stage 6.0 additions** (see `frontend/test/fixtures/database/README.md` and
`docs/architecture/database-migration-log.md` for provenance):

| File | Tests | Coverage |
| --- | ---: | --- |
| `test/core/database/schema_characterization_test.dart` | 8 | Fresh v22 schema golden (18 tables); F-2 breadth (fresh, v19, v20, v21); frozen fresh-vs-upgraded diffs for v12/v19/v20/v21/v22. |
| `test/core/database/historical_fixture_migration_test.dart` | 15 | Genuine v2/v3/v4/v12/v19/v20/v21/v22 fixtures: pre-shape golden + data, upgrade to v22 with data preservation + post golden + integrity/FK checks + `.bak` byte equality, fixture immutability; pre-v6 blocked versions roll back atomically. |
| `test/core/database/transaction_rollback_test.dart` | 9 | Failure-injection rollback evidence for `saveSale`, `voidSale`, `approveVoidRequest`, `markCompleted`, `deleteEntry`, `addCashMovement`, `closeShift`, restore (induced failure) and restore (FK violation). |
| `test/core/database/backup_export_restore_characterization_test.dart` | 3 | Pre-migration `.bak` failure is non-blocking (Windows); export secret-stripping + restore secret/cursor loss + owner credential retention; recovery snapshot + `device_id.txt` re-registration. |

The former gap (F-3) is closed for the versions where genuine fixtures can be
built from git: v2/v3/v4 (blocked-path rollback), v12, v19, v20, v21 and v22.
Versions v5–v11 and v13–v18 remain unfixed — the migration log records that
claim as unverified rather than assuming the fixture chain.

**Baseline re-measured after the Stage 6.0 additions:**

| Check | Result |
| --- | --- |
| `flutter analyze --fatal-infos` (`app/`) | re-run with Stage 6.0 tests present |
| `flutter test` (`app/`) | baseline was **643 passed, 1 skipped, 0 failed**; Stage 6.0 adds 35 tests (8 + 15 + 9 + 3) |
| `dart analyze` (`pos_core`) | **0 issues** (re-run) |
| `dart test` (`pos_core`) | **26/26 passed** (re-run) |
| `flutter build web --release -t lib/main_web.dart` | re-run — see final Stage 6.0 report |
| Windows release build | re-run — see final Stage 6.0 report |
| Live Supabase verifiers | Not run (require live credentials) |

**Web dependency graph baseline (F-1 gate input).** Computed on 2026-11-19 with
`tool/stage60_webgraph.py` (import-graph traversal from `main_web.dart`):

- 59 local files reachable from `main_web.dart`;
- of those, **0** import `package:sqflite` directly — the sqflite import chain
  enters the web graph only through `app_backend.dart`, `session_store.dart`
  (shared with web screens) and the `Sqflite*Repository` files that
  `app_backend.dart` re-imports for the shared shell;
- no reachable file imports `dart:io`, `dart:ffi`, `sqflite_common_ffi`,
  `path_provider` or `LocalDatabase`.

The graph is recorded, not fixed: Stage 6.0 deliberately keeps sqflite in the
web compile graph as it is today and changes no composition root.

---

## 11. Audit findings

Findings are recorded, not fixed. None authorize a production change.

| ID | Severity | Finding |
| --- | --- | --- |
| **F-1** | High (boundary) | **The web compile graph still contains sqflite.** `main_web.dart` → `app_shell.dart` → `app_backend.dart` imports all seven `Sqflite*Repository` implementations, each importing `package:sqflite/sqflite.dart`. `app_shell.dart` also imports `core/auth/session_store.dart`, which imports sqflite. `cloud_backend.dart` and `web_settings_screen.dart` import the same mixed port/implementation files. The build succeeds because sqflite is web-compilable, but the stated web-protection rule ("web dependency graph free of sqflite") is not literally satisfied. `sqflite_common_ffi`, `path_provider`, `dart:io` and `LocalDatabase` are *not* in the web graph. Fixing this requires separating repository/session contracts from SQLite implementations (Stage 6 target). |
| **F-2** | Low (schema drift) | **Fresh v22 installs lack `picklist_items_picklist_id`.** The index is created only inside the v20 upgrade branch (`local_database.dart:568-571`); `_createIndexesAndTriggers` does not create it and `_onCreate` calls only that helper. Upgraded databases have the index; fresh databases do not. No data/constraint difference — query performance only. Do not fix during the audit; candidate for a future authorized schema-alignment stage. |
| **F-3** | Medium (test gap) | Migration tests start from the **current** schema and rewind selected parts, rather than from true historical fixtures. v2–v4, v12, v19 (standalone), v20, v21 and v22 have no dedicated upgrade assertion. A Stage 6 pure move must therefore be verified by schema-diff tests (fresh vs upgraded) before and after, not just by the existing suite. |
| **F-4** | Low (doc drift) | `docs/DATABASE.md` still says "schema version 9" in its title and "currently 14" in the body; actual is 22. It also claims exports contain password hashes, while `DataExporter` deliberately omits them. Stage 9 reconciliation item. |
| **F-5** | Low | `WholesalePosApp`/`LicenseWrapper` carry a raw `Database` field, and `main.dart` constructs `SqliteLocalDataOps(widget.db)` inside the settings builder on every shell build. This is composition-root code (not a feature widget), but it is the remaining raw-handle path above the repository layer. |
| **F-6** | Low (behavioral note) | `picklist_customers` is not included in `DataExporter`/`DataImporter`, the sync outbox, or the pull table order. It is local-only today. Preserve as-is; do not add it to sync/backup without authorization. |
| **F-7** | Medium (concurrency) | `DataExporter` reads tables sequentially **outside a transaction**. A sync pull (or any interleaved write) between reads can produce a backup that is not a point-in-time snapshot. The restore path protects itself with a pre-restore export + atomic replacement, but the exported file itself has no snapshot guarantee. Preserve current behaviour in Stage 6; flag for a separately authorized fix. |
| **F-8** | Low | `LocalDatabase._configureFactory` mutates the global `databaseFactory`. Tests rely on it. Moving the class into a package must not move this side effect somewhere web code can execute. |
| **F-9** | Low | `settings` is a shared untyped key/value table used by six concerns (theme, session, licensing, guards, cursors, demo version). Splitting it would change storage and is out of scope; Stage 6 should keep one table and give each concern a typed accessor. |
| **F-10** | Info | `schemaVersion` is referenced from `LocalDatabase` by exporter/importer, `SqliteLocalDataOps`, settings UI, and migration tests. It must remain a single authoritative constant after the move (a compatibility re-export is acceptable). |
| **F-11** | Info | `docs/architecture/migration-plan.md` and `target-state.md` predate the approved Stage 3–5 sequence and describe a different stage numbering (their "Stage 5" is repository module-ization). They were not edited in this audit; reconciliation belongs to the documentation stage. |
| **F-12** | Medium (migration gap) — **new in Stage 6.0** | **Genuine pre-v6 databases cannot reach v22 on the current build.** The `<6` upgrade step calls `_createIndexesAndTriggers`, which creates indexes on `finance_entries` before that table exists at `<7`, raising `no such table: main.finance_entries`. Proven with genuine v2/v3/v4 fixtures: the whole `onUpgrade` transaction rolls back, `user_version` stays at the original value, the pre-migration `.bak` is intact, and the file is byte-identical afterwards. Characterised and **preserved** in `historical_fixture_migration_test.dart` (blocked-version group) and `database-migration-log.md`. A repair changes migration order and requires its own approval. |
| **F-2** (corrected) | Low (schema drift) — **widened in Stage 6.0** | The missing `picklist_items_picklist_id` index affects **fresh v22 installs, v20 and v21 databases upgraded to v22** (their `_onCreate` omits it and the `<20` branch is skipped), not only fresh installs. Upgrades from v19 or older do receive it. All four cases are now asserted by tests and frozen in the `fresh_vs_upgraded_v*.json` goldens. Still preserved, not fixed. |
| **F-13** | Info — **new in Stage 6.0** | Fresh v22 and a genuine v22 upgraded "in place" are schema-identical; a v21 upgrade is also identical. v12/v19 upgrades differ from fresh only by physical column order (`users`, `picklist_items`) plus the F-2 index; v20 by column order alone. These differences are frozen as goldens, so any future change to the upgrade chain that alters them fails the suite first. |

---

## 12. Preservation checklist for the future restructuring

The following must be provably identical after any Stage 6 move:

1. File name `wholesale_pos.db`, location, `<db>.bak` sibling, `device_id.txt`
   sibling and its UUID semantics.
2. `schemaVersion = 22`; all 18 table names, every column, default, constraint
   and FK; the complete v2→v22 `if (oldVersion < N)` chain and its order.
3. `PRAGMA foreign_keys = ON`, rollback-journal mode (no WAL), no downgrade
   handler, one connection, no close.
4. `onCreate` + `_createIndexesAndTriggers` equivalence for fresh installs,
   including the F-2 divergence (do not "fix" it as a side effect).
5. All 38 transaction bodies, their table sets, and their outbox writes —
   especially `markCompleted`/`deleteEntry` (finance ↔ register) and the
   restore replacement transaction.
6. Every settings key in §8 and the five stripped/exported distinctions.
7. Backup/restore authorization, validation, credential policy, recovery
   snapshot, cursor deletion, FK check, audit rows, and post-restore device
   registration.
8. `LocalDataOps` remains the only UI-facing local-data contract; feature
   widgets still never see `Database` or sqflite.
9. The `main_web.dart` import graph contains no `sqflite`,
   `sqflite_common_ffi`, `path_provider`, unconditional `dart:io`, or
   `LocalDatabase` (this is the F-1 gate).
10. Feature-permission keys/defaults/grantability and migration/backup log
    messages keep the same values, levels, and order.
