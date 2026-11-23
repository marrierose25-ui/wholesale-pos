# Database Migration Plan — Stage 6 Proposal

**Status:** plan only. **Not executed, not authorised.**
This document describes how the target in
`database-target-architecture.md` would be reached without changing behaviour.
Stage 5 is audit-only; Stage 6 starts only after architectural-director
approval.

**Date:** 2026-11-19
**Baseline:** branch `main`, HEAD `64ff4fe`, Stage 1–4 working tree uncommitted.
**Authoritative audit:** `database-responsibility-map.md`.

---

## 1. Preconditions and working rules

Before the first Stage 6 edit:

1. Architectural-director approval of `database-target-architecture.md`, this
   plan, and `database-risk-register.md`.
2. Stage 1–4 changes committed or otherwise preserved by the director. Stage 6
   must not be mixed into an uncommitted tree that cannot be bisected.
3. Baseline re-measured on the approved commit:
   `flutter analyze --fatal-infos`, `flutter test`,
   `dart analyze`/`dart test` in every package, web release build, Windows
   release build.
4. No schema change, no data migration, no deployment, no sync protocol change.
5. One sub-stage at a time. After each: format the touched files, analyze,
   test, build the affected target, inspect the diff, update
   `migration-log.md`, report, stop.

**Hard prohibitions for every sub-stage**

- `git reset`, `git clean`, force-push, history rewrite.
- Committing, pushing, deploying, reconnecting Cloudflare/GitHub.
- Editing SQL text, DDL, migration order, settings keys, sync payloads,
  licensing rules, or UI behaviour.
- Adding a new schema version or a new migration.
- Fixing F-2/F-4/F-6/F-7 as a side effect.
- Creating a second database connection.

---

## 2. Sub-stage overview

| Sub-stage | Goal | Production behaviour change |
|---|---|---|
| **6.0** | Characterisation and schema snapshots | None (test/tooling only) |
| **6.1** | Create `pos_contracts`; extract ports and pure types | None (imports/constructors only) |
| **6.2** | Create `pos_local_engine`; move lifecycle/schema/migrations/backup | None (verbatim move) |
| **6.3** | Move settings and device identity behind typed stores | None |
| **6.4** | Move repositories, one module at a time | None |
| **6.5** | Move outbox and JSON backup/restore | None |
| **6.6** | Rewire composition roots; remove raw `Database` from widgets | None |
| **6.7** | Delete shims; enforce the web graph in tests; reconcile docs | None |

6.1 must land before 6.4 (ports are needed by the engine). 6.2 can land before
6.1 only if the engine keeps a temporary dependency on app files, which is not
allowed by the package boundary — so the order above is the safe one.

---

## 3. Stage 6.0 — Characterisation before touching code

**Purpose:** make the move falsifiable. A pure move is only safe if the
“before” state is captured independently of the code being moved.

### Work

1. Add a test helper that serialises a database:
   - `PRAGMA user_version`
   - `PRAGMA journal_mode`
   - `PRAGMA foreign_keys`
   - `sqlite_master` rows (`type`, `name`, `tbl_name`, `sql`) sorted by
     `type, name`
   - schema of every table via `PRAGMA table_info(<table>)`
   - `PRAGMA foreign_key_list(<table>)`
   - `PRAGMA index_list(<table>)` / `PRAGMA index_info(<index>)`
2. Capture snapshots for:
   - a fresh v22 database (`LocalDatabase.openInMemory()`);
   - an upgraded database for every historical version that can be
     constructed (see F-3; build true fixtures where the current rewind tests
     are insufficient: v2–v4, v12, v19, v20, v21, v22).
3. Add a transaction-inventory test:
   - count `transaction(` in production files = 38;
   - map each to its owning class/method;
   - fail if a method loses or gains a transaction.
4. Add SQL inventory hashes for:
   - `_onCreate` DDL;
   - `_createIndexesAndTriggers`;
   - each `if (oldVersion < N)` block.
   Hashes are over normalised SQL text, not file paths.
5. Record the current settings-key inventory and export/import policy as
   tests or fixtures (key names, stripped keys, cursor deletion).

### Gate

- New characterisation tests pass on the unmodified code.
- Snapshots are committed as fixtures (test data, not production SQL).
- No production file changed.

### Rollback

Delete the new tests/fixtures. No production impact.

---

## 4. Stage 6.1 — `pos_contracts`

**Purpose:** make every port pure and web-safe before any implementation
moves.

### Files created

```
backend/dart/pos_contracts/pubspec.yaml
backend/dart/pos_contracts/lib/pos_contracts.dart
backend/dart/pos_contracts/lib/src/repositories/*.dart
backend/dart/pos_contracts/lib/src/backend/{app_backend,session_store,local_data_ops}.dart
backend/dart/pos_contracts/lib/src/auth/feature_keys.dart
backend/dart/pos_contracts/lib/src/sync/sync_outbox_entry.dart
backend/dart/pos_contracts/lib/src/value/{date_range,money,phone_number,activation_result}.dart
```

### Edits

1. Move the abstract classes and their documentation verbatim from the seven
   repository files into the package.
2. Remove `factory X(Database db) = SqfliteX;` from every port.
3. Move `SessionData` + `SessionStore` out of `session_store.dart`; leave the
   SQLite implementation for 6.3.
4. Move `LocalDataOps`; replace its `device_activation.dart` import with the
   pure `DeviceActivationResult` DTO.
5. Move `DateRange`/`ReportPeriod`, `MoneyUtils`, `PhoneNumber`, and the
   activation-result DTO. They are pure and are used by both the engine
   implementations and the UI, so the engine cannot keep private copies.
6. Split `core/auth/features.dart`:
   - pure permission keys/defaults/validators/`normalizeFeatureKeys` →
     `pos_contracts/auth/feature_keys.dart`;
   - `FeatureDef`/`kFeatures` labels and icons stay in the app and derive from
     the same key list;
   - the app file re-exports the pure helpers for existing UI imports;
   - a test asserts the UI registry and the pure key list agree exactly.
7. Move `SyncOutboxEntry`/`SyncEntities`/`SyncOperations` (pure `dart:convert`
   only).
8. App files keep temporary re-exports so the tree compiles:
   - old port file → `export 'package:pos_contracts/…';`
   - implementation file still in app imports the port.
9. Add `pos_contracts` to `app/pubspec.yaml` and to a workspace/README if the
   repository uses one.

### What must not change

- Method names, parameter names, defaults, return types, static constants.
- Any SQL or transaction body (implementations are untouched).
- The `AppBackend` capability surface.

### Preservation proof

- `dart analyze`/`dart test` in `pos_contracts` (new purity test: no Flutter,
  sqflite, `dart:io`, HTTP).
- App analyze and full test suite unchanged.
- Diff review: only import/declaration movement; no method body edits.

### Gate

- `flutter analyze --fatal-infos` 0 issues.
- `flutter test` identical pass count.
- Web build passes.
- A new test asserts `pos_contracts` imports only `pos_core` + SDK.

### Rollback

Delete the package and revert re-exports; implementations never moved, so
runtime cannot be affected.

---

## 5. Stage 6.2 — Engine package and database lifecycle

**Purpose:** move the database manager without moving repositories yet.

### Package created

```
backend/dart/pos_local_engine/pubspec.yaml
backend/dart/pos_local_engine/lib/pos_local_engine.dart
backend/dart/pos_local_engine/lib/src/lifecycle/{database_factory,local_database}.dart
backend/dart/pos_local_engine/lib/src/schema/{schema_version,schema_v22,indexes_triggers}.dart
backend/dart/pos_local_engine/lib/src/migrations/migrations_v2_to_v22.dart
backend/dart/pos_local_engine/lib/src/backup/pre_migration_backup.dart
```

### Moves

| Current | Target |
|---|---|
| `frontend/lib/core/database/local_database.dart` — factory selection, `open`, `openAt`, `openInMemory`, `onConfigure`, `onCreate`, `onUpgrade`, backup call | `engine/lifecycle/` + `engine/schema/` + `engine/migrations/` + `engine/backup/` |
| `schemaVersion` constant | `engine/schema/schema_version.dart` |
| `_createIndexesAndTriggers` | `engine/schema/indexes_triggers.dart` |
| v2→v22 `if (oldVersion < N)` chain | `engine/migrations/migrations_v2_to_v22.dart` |
| `_backupBeforeMigration` | `engine/backup/pre_migration_backup.dart` |

### Mechanics

- Move the method bodies **verbatim**. Do not reformat SQL. Do not reorder
  `if` blocks. Do not rename tables/columns.
- Keep `onCreate` calling `_createIndexesAndTriggers` exactly once.
- Keep `onUpgrade` calling the chain exactly once inside sqflite’s transaction.
- Keep the pre-migration backup call in `onConfigure` **before** sqflite reads
  `user_version`.
- Keep the FFI factory selection exactly as today, including its platform
  condition and global `databaseFactory` assignment.
- Introduce the engine `EngineLogger` seam (§4.3 of the target) and replace
  `AppLogger` calls with it. Copy the exact message strings, levels, and call
  order; install an adapter in `main.dart` that forwards to `AppLogger`.
  Tests install a recording logger. This is the only intentional non-verbatim
  edit in 6.2.
- App keeps `core/database/local_database.dart` as a native-only re-export shim
  until 6.7.
- `LocalDatabase` may expose `Database get handle` for the transitional
  `core/sync` code only.

### Preservation proof

- Characterisation snapshots (6.0) identical before/after for fresh and every
  upgrade fixture.
- `pre_migration_backup_test.dart` passes unchanged.
- `migration_test.dart` passes unchanged.
- Grep proof: exactly one `schemaVersion` definition; same 18 `CREATE TABLE`
  names; same index/trigger names; same `if (oldVersion <` sequence.
- `PRAGMA foreign_keys`, `journal_mode`, and `user_version` observed
  identically.
- Log parity: a recording `EngineLogger` sees the same levels/messages for a
  migration, a `.bak` copy, and the duplicate-shift repair. The app adapter
  forwards to `AppLogger` unchanged.

### Gate

- App analyze/test/build all green.
- New engine tests: open in memory, openAt temp file, `.bak` copy, schema
  snapshot.
- Web build green; engine is not imported by `main_web.dart`.

### Rollback

Revert the move and the shim. Because no schema or data changed, reverting the
code restores the exact previous behaviour.

---

## 6. Stage 6.3 — Settings and device identity

**Purpose:** remove database concerns from licensing/session code without
changing storage.

### Moves

| Current | Target |
|---|---|
| `LocalDatabase.getSetting` / `setSetting` | `engine/settings/settings_store.dart` |
| Key strings scattered across callers | `engine/settings/settings_keys.dart` (same values) |
| `registerCurrentDevice` and `device_id.txt` handling | `engine/device/device_identity.dart` |
| `SettingsSessionStore` | `engine/settings/settings_session_store.dart` (still implements the port) |

### Edits

- `DeviceFingerprint.get(db)` / `DeviceActivation.redeem(db, …)` change to take
  `SettingsStore` (or a narrower `KeyValueStore`), not `Database`.
- `main.dart` passes stores instead of the raw handle.
- Preserve the in-memory device fallback exactly.
- Preserve the five stripped settings and the export/import rules.

### Preservation proof

- Session-store tests (8) pass.
- Device-fingerprint tests (3) pass.
- Settings key inventory test passes (same names).
- Export/import tests still observe the same keys and stripping.
- `device_id.txt` filename/location/UUID semantics verified by test.

### Gate

- App analyze/test/web build green.
- No raw `Database` parameter remains in `core/licensing/`.
- No settings key string changed (diff review + key test).

### Rollback

Restore the thin wrappers over `LocalDatabase`; storage never changed.

---

## 7. Stage 6.4 — Repositories one module at a time

**Purpose:** move SQL and transaction bodies into the engine with the smallest
reviewable diff per module.

### Order and gates

Each repository is its own sub-step (commit/checkpoint) in this order:

| Order | Repository | Why this position | Extra proof |
|---:|---|---|---|
| 1 | `ProductRepository` | No cross-module writes | product repository tests; outbox row shape |
| 2 | `PicklistRepository` | Self-contained; soft delete; outbox | picklist tests; header re-derivation |
| 3 | `ShiftRepository` | Register owner; drawer math | shift/cash-math tests; one-open-shift trigger |
| 4 | `FinanceRepository` | Writes `cash_movements`; needs shift repo present | finance tests; deposit/reversal atomicity |
| 5 | `SaleRepository` + `ReportingRepository` | Reporting delegates + shared filters | sale/void/receipt/report tests; 6 sale transactions |
| 6 | `UserRepository` | Credentials, guards, demo adoption; highest density | auth/user/demo tests; 7 user transactions; permission-key parity; isolate-runner import resolves |

### Mechanics per repository

- Move the class body verbatim into
  `engine/repositories/sqlite_<module>_repository.dart`.
- It `implements` the port from `pos_contracts`.
- Move `feature_gate.dart` and `report_filters.dart` into the engine when the
  first dependent repository moves (they are SQL/support code).
- When `UserRepository` moves, move `isolate_runner.dart` +
  `isolate_runner_native.dart` into the engine (the conditional import stays
  identical) and consume the pure feature-key helpers from `pos_contracts`.
- Keep constructors explicit. The composition root supplies shared instances
  where a repository delegates to another (sale → reporting, finance → shift).
- App file `core/repositories/<module>_repository.dart` becomes a
  contracts-only re-export; the SQLite class is re-exported from a
  **separate native-only** file, never from the file the web graph imports.
- Do not change a single `db.transaction` call, query string, or parameter
  order.

### Preservation proof per module

- The module’s existing repository test suite passes unchanged.
- SQL diff: move-only; compare a normalised hash of the class body before/after
  (allowing only import lines and class/constructor names).
- Transaction inventory still 38; method ownership unchanged.
- Outbox entities/payloads unchanged (outbox tests).
- No new `Database` parameter appears in a widget.

### Gate per module

- `flutter analyze --fatal-infos` 0 issues.
- Full `flutter test` green after each module (not only the module’s tests).
- Web build green; `main_web.dart` graph still free of sqflite.
- Diff review confirms move-only.

### Rollback per module

Move the class back and restore the factory/re-export. One module per
checkpoint keeps rollback local.

---

## 8. Stage 6.5 — Outbox and JSON backup/restore

### Part A — outbox

| Current | Target |
|---|---|
| `core/sync/sync_outbox.dart` | `engine/sync/sync_outbox.dart` |
| `core/sync/sync_outbox_repository.dart` | `engine/sync/sync_outbox_repository.dart` |
| `SyncOutboxEntry`/`SyncEntities` | already in `pos_contracts` (6.1) |

- Repositories keep calling `SyncOutbox.enqueue(txn, …)` inside the same
  transaction.
- Demo-ledger isolation is unchanged.
- `SyncService`/`SyncRuntime` stay in the app and import the engine.
- `SyncPullApplier`/`CloudSyncPuller` stay in the app in Stage 6 (documented
  raw-handle exception; Stage 7 owns them).

**Proof:** outbox atomicity tests, demo-isolation tests, sync-service tests;
transaction inventory unchanged; outbox table DDL unchanged.

### Part B — JSON export/import

| Current | Target |
|---|---|
| `core/utils/data_exporter.dart` | `engine/backup/json_backup_service.dart` (or `backup/export_service.dart` + `import_service.dart`) |
| `core/utils/data_importer.dart` | same |

- Replace `getApplicationDocumentsDirectory()` inside the service with an
  explicit destination/source path supplied by the app wrapper. The app still
  computes the documents directory and keeps the exact filename pattern.
- Preserve: owner check, active check, credential stripping/retention,
  recovery snapshot, single replacement transaction, cursor deletion, FK
  check, audit rows, and post-restore device registration.
- Keep F-7 (no snapshot transaction) exactly as is.

**Proof:** 13 importer/exporter tests pass; byte-level JSON comparison for a
fixture export (ignoring timestamp/path); restore of a fixture leaves identical
row sets; settings cursor deletion verified; `license_code`/`activation_code`
still absent after restore.

### Gate

- Full test suite green; web build green.
- Windows build green (file IO is platform-sensitive).
- No `dart:io`/`path_provider` import reaches the web graph.

### Rollback

Restore the two app files and their callers; engine storage unchanged.

---

## 9. Stage 6.6 — Composition roots and raw-handle removal

**Purpose:** finish the boundary at the top of the app.

### Edits

1. `main.dart`:
   - open the engine once;
   - construct repositories/stores;
   - pass ports + stores to `NativeBackend`;
   - pass `LocalDataOps`/`DeviceIdentity` to `WholesalePosApp`/`LicenseWrapper`;
   - keep the same startup order, licence gate, demo seeding, device
     registration, and sync runtime wake points.
2. `NativeBackend` no longer accepts `Database`; it accepts the constructed
   ports and `SettingsStore`/`SessionStore`.
3. `WholesalePosApp` and `LicenseWrapper` lose their `Database` fields.
4. `SqliteLocalDataOps` becomes `LocalDataOps` composed from engine stores and
   licensing; no `Database`.
5. `SettingsScreen` builder still receives `LocalDataOps`; no change to UI.
6. The transitional `Database get handle` is used only by `core/sync` and is
   annotated as such.

### Preservation proof

- Startup smoke: fresh install; existing v22 install; upgrade from a v21
  fixture; licence activation; sign-in; sale; shift close; backup; restore.
- Widget/layout matrix, auth-gate, settings, and shell tests pass.
- No widget constructor in `frontend/lib/features/` contains `Database`.

### Gate

- App analyze/test/web build + Windows build green.
- Manual smoke on Windows with a copy of a real v22 database (not the
  production file) confirms identical behaviour and schema.
- `git grep "Database" frontend/lib/features` returns only the allowed schema
  footer string, if any.

### Rollback

Restore the previous composition root. No data/schema change, so reverting the
binary is safe.

---

## 10. Stage 6.7 — Delete shims and enforce the graph

### Edits

1. Delete every temporary re-export in `frontend/lib/core/`.
2. Delete the old `local_database.dart`, repository implementation files, and
   `sqlite_local_data_ops.dart` from `frontend/lib/core/` once nothing imports them.
3. Move or update tests:
   - engine tests live in `pos_local_engine/test`;
   - app repository tests import the engine package (test VM is native);
   - no test imports a deleted shim.
4. Add architecture tests:
   - walk imports from `frontend/lib/main_web.dart`;
   - fail on `package:sqflite`, `sqflite_common_ffi`, `path_provider`,
     `dart:io`, `pos_local_engine`, or `LocalDatabase`;
   - fail on `Database`/`Transaction` references under `lib/features/`
     (existing rule, kept);
   - fail if `pos_contracts` imports Flutter/sqflite/io/http;
   - fail if `pos_local_engine` imports `app` or `features`.
5. Update `docs/DATABASE.md` only if the director authorises doc
   reconciliation (F-4); otherwise leave it and record the drift.

### Gate

- All tests/builds green.
- Import-graph test proves the web graph is clean.
- Repo-wide grep: one `schemaVersion` definition; 38 transactions; no SQL in
  `frontend/lib/features`; no `Database` above the composition root.
- Final schema snapshot diff is empty for fresh and every upgrade fixture.

### Rollback

Restore shims from the previous checkpoint. No data/schema change.

---

## 11. File move map

| Current file | Target |
|---|---|
| `frontend/lib/core/database/local_database.dart` | `engine/lifecycle/local_database.dart` + `engine/schema/*` + `engine/migrations/*` + `engine/backup/pre_migration_backup.dart` |
| `frontend/lib/core/repositories/{product,sale,reporting,shift,finance,picklist,user}_repository.dart` | port in `pos_contracts`; implementation in `engine/repositories/sqlite_*` |
| `frontend/lib/core/repositories/feature_gate.dart` | `engine/repositories/feature_gate.dart` |
| `frontend/lib/core/auth/session_store.dart` | port in `pos_contracts`; `SettingsSessionStore` in `engine/settings/` |
| `frontend/lib/core/backend/local_data_ops.dart` | `pos_contracts/backend/local_data_ops.dart` |
| `frontend/lib/core/backend/sqlite_local_data_ops.dart` | app composition (no engine move required) |
| `frontend/lib/core/backend/native_backend.dart` | stays app; stops taking `Database` |
| `frontend/lib/core/backend/app_backend.dart` | `pos_contracts/backend/app_backend.dart` |
| `frontend/lib/core/sync/sync_outbox.dart` | `engine/sync/sync_outbox.dart` |
| `frontend/lib/core/sync/sync_outbox_repository.dart` | `engine/sync/sync_outbox_repository.dart` |
| `frontend/lib/core/sync/sync_outbox_entry.dart` | `pos_contracts/sync/sync_outbox_entry.dart` |
| `frontend/lib/core/sync/sync_pull_applier.dart` | **stays app** in Stage 6 (Stage 7) |
| `frontend/lib/core/utils/data_exporter.dart`, `data_importer.dart` | `engine/backup/` |
| `frontend/lib/core/utils/date_range.dart` | `pos_contracts/value/date_range.dart` |
| `frontend/lib/core/utils/report_filters.dart` | `engine/util/report_filters.dart` |
| `frontend/lib/core/utils/money_utils.dart`, `frontend/lib/core/util/phone_number.dart` | `pos_contracts/value/` (pure; used by UI + engine) |
| `frontend/lib/core/auth/features.dart` (pure subset) | `pos_contracts/auth/feature_keys.dart`; icon/label registry stays app |
| `frontend/lib/core/util/isolate_runner*.dart` | `engine/util/` (used only by `UserRepository`) |
| `frontend/lib/core/licensing/device_fingerprint.dart`, `device_activation.dart` | stay app; consume `SettingsStore`/`DeviceIdentity` |
| `frontend/lib/core/cloud/*` | stay app/web; import ports only |
| `frontend/lib/features/**` | unchanged |

---

## 12. Compatibility-shim rules

| Rule | Reason |
|---|---|
| Port shims may live in old app paths and export `pos_contracts` | Keeps the tree compiling during the move |
| Implementation shims must be native-only files | Prevents sqflite from re-entering the web graph |
| Never combine port + implementation in one re-export file | That is exactly today’s leak |
| Shims contain no SQL and no `Database` | Keeps them removable and auditable |
| Every shim is deleted in 6.7 | Prevents permanent indirection |
| No shim changes a default/parameter | Behaviour must be move-only |

---

## 13. Preservation proof matrix

| Artefact | Proof before/after |
|---|---|
| DB path/filename | `openInMemory` tests + a temp-path test asserting basename `wholesale_pos.db` and `.bak` sibling |
| Schema v22 | `sqlite_master` snapshot equality (fresh + every upgrade fixture) |
| Columns/FKs/indexes/triggers | PRAGMA snapshot equality; name lists identical |
| Migration order | Normalised hash per `if (oldVersion < N)` block; sequence list identical |
| Fresh-install F-2 divergence | Fresh snapshot still missing `picklist_items_picklist_id` |
| `schemaVersion` | One definition; same value 22 |
| Transactions | Inventory = 38; method ownership and table sets unchanged |
| Outbox | Entity/payload tests; demo isolation tests |
| Settings keys | Key inventory test; same strings |
| `device_id.txt` | Stable UUID test; same filename/location |
| Pre-migration backup | 4 backup tests + byte comparison |
| JSON export/import | 13 tests + fixture round-trip; same stripped keys |
| Restore licensing-key loss | Test asserts keys absent after restore (existing behaviour) |
| Web graph | Import-graph test forbids sqflite/engine/path_provider/io |
| UI | Widget/layout/auth/settings/shell matrix unchanged |
| Windows | Release build + manual smoke |

---

## 14. Test and build gates (every sub-stage)

| Gate | Command | Pass condition |
|---|---|---|
| App analyze | `flutter analyze --fatal-infos` | 0 issues |
| App tests | `flutter test` | Same or higher pass count, 0 failures |
| Domain package | `dart analyze` + `dart test` in `pos_core` | 0 issues, all pass |
| Contracts package | `dart analyze` + `dart test` in `pos_contracts` | 0 issues, purity tests pass |
| Engine package | `dart analyze` + `dart test` in `pos_local_engine` | 0 issues, all pass |
| Web build | `flutter build web --release -t lib/main_web.dart` | Passes |
| Web graph | Import-graph test | No sqflite/engine/path_provider/io |
| Windows build | `tools/build_release.ps1 windows` | Passes |
| Schema | Snapshot comparison | Empty diff |
| Transactions | Inventory test | 38, same owners |
| Permissions | Feature-key parity test | Same keys/defaults/grantability/order |
| Logging | Recording-logger comparison | Same levels/messages on migration/backup paths |
| Diff review | Manual | Move-only; no SQL/DDL/key edits |

Formatting note: the app predates the Dart 3.13 tall formatter. Stage 6 should
format only files it creates/moves, and keep moved bodies byte-identical where
possible. A repo-wide reformat is not part of this plan.

---

## 15. Rollback strategy

- **Per sub-stage:** revert the sub-stage checkpoint. No schema or data
  migration exists, so reverting code restores the previous binary behaviour.
- **Shims:** every old import path remains valid until 6.7, so an intermediate
  rollback does not require a mass import rewrite.
- **6.2–6.5:** the database file is untouched; a rollback simply opens the same
  v22 file with the old code.
- **6.6:** reverting the composition root restores the old startup path; the
  database file and `device_id.txt` are unchanged.
- **6.7:** shims are deleted last, so rollback is still a code revert.
- **No downgrade handler:** because no version bump occurs, rollback never
  asks the database to downgrade.

If a schema snapshot differs at any point, stop immediately, restore the last
green checkpoint, and report — do not “repair” the schema by hand.

---

## 16. Explicit no-change list

Stage 6 must leave all of the following exactly as audited:

1. DB filename/location, `.bak` sibling, `device_id.txt` sibling and UUID.
2. `schemaVersion = 22`; 18 tables; every column/default/constraint/FK.
3. Index/trigger names, definitions, and creation call sites (including the
   F-2 fresh-install divergence).
4. The v2→v22 migration chain, its order, the duplicate-open-shift repair, and
   the pre-migration backup trigger.
5. `PRAGMA foreign_keys = ON`; no WAL; no downgrade handler; one connection;
   no close.
6. All 38 transaction bodies and their table sets.
7. Outbox enqueue-inside-transaction semantics and demo isolation.
8. Every settings key, value format, and export/import stripping rule.
9. Restore’s credential policy, recovery snapshot, cursor deletion, FK check,
   audit rows, and post-restore device registration.
10. The restore-induced loss of `license_code`/`activation_code` (existing
    behaviour).
11. Sync entity names, cursors, ordering, retries, and payload shapes.
12. Licensing, activation, seat, and fingerprint rules.
13. All UI flows, permissions, navigation, and screen behaviour.
14. F-2, F-4, F-6, F-7 — recorded, not fixed.

---

## 17. Definition of done (Stage 6)

Stage 6 is complete only when:

1. Every sub-stage has a `migration-log.md` entry with actual results.
2. The final tree has no temporary shims and no SQL outside the engine except
   the documented Stage 7 sync exception.
3. The web import-graph test is green.
4. Fresh and upgraded schema snapshots are identical to the pre-move
   snapshots.
5. Transaction inventory is still 38.
6. All gates in §14 pass.
7. A final report distinguishes implemented work from planned work and lists
   any new findings separately.
8. The architectural director reviews and accepts the result.
