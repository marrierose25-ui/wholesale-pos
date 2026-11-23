# Database Target Architecture — Stage 5 Proposal

**Status:** proposal only. **Nothing in this document is implemented.**
No production code, schema, SQL, migration, repository, startup, sync, or
deployment file was changed to produce it. Stage 6 requires separate approval.

**Date:** 2026-11-19
**Repository:** `C:\Users\www\wholesale_pos`, branch `main`, HEAD `64ff4fe`
(Stage 1–4 working tree uncommitted).

**Inputs:** `database-responsibility-map.md` (the Stage 5 audit), the existing
`target-state.md`, and the Stage 1–4 package conventions already in the tree.

---

## 1. Non-negotiable constraints

These constraints come from the preservation mandate and override every
structural preference below.

1. **One database, one file, one connection.** `wholesale_pos.db` in
   `getApplicationSupportDirectory()`. No per-module database, no connection
   pool, no second handle, no close-on-idle.
2. **Schema v22 is frozen.** 18 tables, every column/default/constraint/FK,
   every index, every trigger, and the complete v2→v22 `if (oldVersion < N)`
   ordering stay textually equivalent.
3. **No storage-engine change.** No WAL, no `onDowngrade`, no ORM, no query
   builder, no schema-version bump.
4. **All 38 transaction boundaries survive.** Cross-module writes (finance →
   cash movements, sales → shift reads, restore → every table) remain inside
   the same SQLite transaction. The transactional outbox stays inside the
   caller's transaction.
5. **Settings keys and device identity are byte-compatible.** Same key names,
   same `settings` table, same `device_id.txt` beside the database, same
   `devices` row semantics.
6. **Backup/restore policy is unchanged.** Pre-migration `.bak`, owner-only
   JSON export, credential stripping, recovery snapshot, cursor deletion,
   `PRAGMA foreign_key_check`, audit rows, post-restore device registration.
7. **The web dependency graph contains no sqflite, `sqflite_common_ffi`,
   `path_provider`, native DB helper, unconditional `dart:io`, or
   `LocalDatabase`.** This is stricter than today (see §9 and audit F-1).
8. **No functionality is added, removed, or “improved” by the move.** Findings
   F-2, F-4, F-6 and F-7 stay exactly as they are.

---

## 2. Target package topology

The target splits the current single-file database layer into three packages
with a one-way dependency graph.

```
                    ┌────────────────────────────────────┐
                    │ backend/dart/pos_core/             │
                    │ pure entities + value objects      │
                    │ (exists; unchanged scope)          │
                    └────────────────▲───────────────────┘
                                     │
                    ┌────────────────┴───────────────────┐
                    │ backend/dart/pos_contracts/  NEW   │
                    │ repository ports, session/local-   │
                    │ data ports, pure shared types      │
                    │ (pure Dart: no Flutter/sqflite/io) │
                    └───────▲────────────────────▲───────┘
                            │                    │
        ┌───────────────────┴──────┐   ┌─────────┴────────────────────┐
        │ Web compile graph        │   │ backend/dart/pos_local_engine│
        │ app_shell, cloud repos,  │   │ NEW — native only            │
        │ web settings             │   │ sqflite + schema + migrations│
        │ (no engine, no sqflite)  │   │ settings/device/repositories │
        └──────────────────────────┘   └─────────▲────────────────────┘
                                                 │
                                     ┌───────────┴────────────────────┐
                                     │ Native graph                   │
                                     │ main.dart, NativeBackend,      │
                                     │ licensing, sync runtime        │
                                     └────────────────────────────────┘
```

### 2.1 Dependency rules

| Package / graph | May depend on | Must never depend on |
|---|---|---|
| `pos_core` | nothing (Dart SDK only) | Flutter, sqflite, HTTP, `dart:io`, app |
| `pos_contracts` | `pos_core` | Flutter, sqflite, `dart:io`, HTTP, app, engine |
| `pos_local_engine` | `pos_core`, `pos_contracts`, Flutter, sqflite, `sqflite_common_ffi`, `path`, `path_provider`, `crypto`, `cryptography`, `uuid` | app, `lib/features`, cloud/HTTP clients |
| App web graph (`main_web.dart`) | `pos_core`, `pos_contracts`, Flutter, `http` | engine, sqflite, `sqflite_common_ffi`, `path_provider`, `dart:io`, `LocalDatabase` |
| App native graph (`main.dart`) | everything above | — |

`pos_local_engine` is intentionally a **Flutter-native** package, not a pure
Dart package: `sqflite`, `path_provider` and the desktop FFI factory are
platform plugins. Purity is enforced where it matters — `pos_core` and
`pos_contracts` — and the web graph is protected by never importing the
engine.

### 2.2 Why a separate contracts package

A port cannot live in the app if the engine is to implement it: a package
cannot import its consumer. `pos_contracts` is the inversion point. It also
removes the current accidental web leaks:

- `app_shell.dart` → `core/auth/session_store.dart` → `package:sqflite`
- `app_shell.dart` → `core/backend/app_backend.dart` →
  `core/repositories/*_repository.dart` → `package:sqflite`
- `cloud_backend.dart` and `web_settings_screen.dart` →
  the same implementation files → `package:sqflite`

After the split, the web graph imports contracts only.

An alternative (fewer packages) is to put the ports and pure value objects in
`pos_core` itself. That is acceptable if the director prefers only two backend
packages, but it widens `pos_core` from “entities” to “entities + application
ports”. This proposal keeps the existing `pos_core` scope intact.

---

## 3. `pos_contracts` — contents

Pure Dart, `publish_to: 'none'`, depends only on `pos_core`.

```
backend/dart/pos_contracts/
  pubspec.yaml
  lib/pos_contracts.dart
  lib/src/
    repositories/
      product_repository.dart
      sale_repository.dart
      reporting_repository.dart
      shift_repository.dart
      finance_repository.dart
      picklist_repository.dart
      user_repository.dart
    backend/
      app_backend.dart          # capability seam (pure; no widgets)
      session_store.dart        # SessionData + SessionStore port
      local_data_ops.dart       # settings/backup/activation capability port
    auth/
      feature_keys.dart         # pure permission keys + normalizeFeatureKeys
    sync/
      sync_outbox_entry.dart    # SyncOutboxEntry, SyncEntities, SyncOperations
    value/
      date_range.dart           # DateRange, ReportPeriod
      money.dart                # MoneyUtils
      phone_number.dart         # canonical phone formatting
      activation_result.dart    # DeviceActivationResult DTO
```

Rules:

- Ports contain **no** `Database`, `Transaction`, `DatabaseExecutor`, sqflite
  import, factory constructor, SQL string, Flutter import, `dart:io`, or HTTP.
- The current `factory SaleRepository(Database db) = SqfliteSaleRepository;`
  lines are removed. Constructors are supplied by the native composition root.
- `UserRepository` keeps its static policy constants
  (`defaultIterations`, `roles`, password lengths, `cloudAccountMarker`,
  login-guard constants) in the port; they are policy, not storage.
- `AppBackend` moves here because it is a pure capability contract. The app
  keeps a re-export only where it does not pull in the engine.
- `LocalDataOps` no longer imports `device_activation.dart`; it references the
  pure `DeviceActivationResult` DTO so `dart:io` cannot enter the web graph
  through the settings contract.

`ReportFilters` (`notDemoOperator`) stays out of contracts: it is SQL text and
belongs to the engine.

`features.dart` needs a small, behaviour-preserving split. The current file
mixes pure permission policy with Flutter `IconData`/`FeatureDef` presentation.
`UserRepository` (moving to the engine) needs `normalizeFeatureKeys`,
`kDefaultStaffPermissions`, and the key validity checks, but the engine cannot
import the app. Therefore:

- `pos_contracts/auth/feature_keys.dart` holds the canonical key list,
  default/owner permission lists, `isValidFeatureKey`,
  `isGrantableFeatureKey`, and `normalizeFeatureKeys` — pure Dart, no
  `IconData`.
- The app keeps `FeatureDef`, `kFeatures`, labels and icons, deriving them from
  the same key list, and re-exports the pure helpers for existing UI imports.
- The key strings, ordering, grantability, and default staff set must not
  change; a test asserts the two views agree.

`MoneyUtils` and `PhoneNumber` are pure and are used by both the engine
implementations and the UI, so they move to `pos_contracts/value/`. If the
director prefers fewer cross-package imports, the alternative is to keep them
in the app and duplicate nothing by having the engine accept them as injected
helpers — but that adds constructor noise for no behavioural gain, so the
package move is preferred.

`app_logger.dart` does **not** move into `pos_contracts` (it imports Flutter
`foundation`). See §4.3 for the engine logging adapter.

---

## 4. `pos_local_engine` — contents

```
backend/dart/pos_local_engine/
  pubspec.yaml
  lib/pos_local_engine.dart
  lib/src/
    lifecycle/
      database_factory.dart       # desktop FFI selection (verbatim)
      local_database.dart         # open/openAt/openInMemory, onConfigure,
                                  # onCreate, onUpgrade orchestration
    schema/
      schema_version.dart         # const schemaVersion = 22 (single source)
      schema_v22.dart             # all 18 CREATE TABLE statements
      indexes_triggers.dart       # _createIndexesAndTriggers (verbatim)
    migrations/
      migrations_v2_to_v22.dart   # ordered if (oldVersion < N) chain (verbatim)
    backup/
      pre_migration_backup.dart   # <db>.bak copy (verbatim)
      json_backup_service.dart    # DataExporter/DataImporter logic
    settings/
      settings_keys.dart          # named constants for every key
      settings_store.dart         # get/set + typed accessors
    device/
      device_identity.dart        # device_id.txt + devices row
    repositories/
      feature_gate.dart
      sqlite_product_repository.dart
      sqlite_sale_repository.dart
      sqlite_reporting_repository.dart
      sqlite_shift_repository.dart
      sqlite_finance_repository.dart
      sqlite_picklist_repository.dart
      sqlite_user_repository.dart
    sync/
      sync_outbox.dart
      sync_outbox_repository.dart
    logging/
      engine_logger.dart          # minimal debug/info/warn/error seam
    util/
      report_filters.dart         # SQL predicates used by queries
      isolate_runner.dart         # default/web-safe stub
      isolate_runner_native.dart  # dart:isolate implementation
```

### 4.1 Responsibility split inside the engine

| Unit | Owns | Explicitly does **not** own |
|---|---|---|
| `lifecycle/` | Factory selection, path resolution, `PRAGMA foreign_keys = ON`, pre-migration backup call, open/in-memory entry points, no close | Any business SQL, any repository behaviour |
| `schema/` | Frozen DDL, index/trigger creation, the single `schemaVersion` constant | Version bumps, “fixed” indexes, WAL |
| `migrations/` | The exact v2→v22 chain in the exact order | Reordering, merging, new migrations |
| `backup/` | `.bak` copy, JSON export/import SQL and policy | File-picker UI, licence validation |
| `settings/` | Key constants, get/set, typed accessors over the same `settings` table | Splitting the table, changing key names |
| `device/` | `device_id.txt`, `devices` upsert/merge, in-memory fallback | Hardware fingerprint, activation HTTP |
| `repositories/` | All operational SQL and the 38 transaction boundaries | UI decisions, permission UX |
| `sync/` | Transactional outbox enqueue and drain | HTTP protocol, retry/backoff, pull orchestration (stays app-side) |

### 4.2 Deliberate non-goals

- The migration chain is **not** split into one file per version in the first
  pass. A single verbatim file is easier to diff, hash, and prove identical.
  A later, separately approved cleanup may split it.
- The schema DDL is **not** generated from a model or an ORM.
- `cumulative`/`user_version` handling stays with sqflite exactly as today.
- No migration is added, removed, or renumbered.

### 4.3 Engine logging adapter

`local_database.dart` currently logs migration/backup/duplicate-shift events
through the app's static `AppLogger`. The engine cannot import the app, and
`app_logger.dart` stays in the app because `app_shell.dart` (web graph) uses it.

The engine therefore defines a minimal seam:

```dart
// Proposed.
abstract class EngineLogger {
  void debug(String message);
  void info(String message);
  void warn(String message);
  void error(String message, [Object? error, StackTrace? stackTrace]);
}
```

The native composition root installs an adapter that forwards each call to
`AppLogger` with the same level and the same message text. Tests install a
no-op or recording logger. This is the **only intentional non-verbatim edit**
in the lifecycle/migration move: message strings, levels, and call order must
be copied exactly. A log-parity test compares a recording logger's output for
the migration/backup paths before and after the move.

The alternative (duplicating `AppLogger` inside the engine) is rejected: it
would split the log sink and break support-file diagnostics. Importing the app
logger from the engine is impossible by construction.

---

## 5. Lifecycle and connection ownership

### 5.1 Public engine entry points

```dart
// Proposed API — not implemented.
Future<LocalDatabase> open();            // preserves getApplicationSupportDirectory()
Future<LocalDatabase> openAt(String path);
Future<LocalDatabase> openInMemory();    // test/recovery seam
```

`open()` keeps the current filename (`wholesale_pos.db`) and the current
support-directory resolution. Keeping `path_provider` inside the engine is a
deliberate risk-reduction choice: it is a native-only package, and moving path
resolution into `main.dart` would create a new opportunity to open an empty
database in the wrong directory. The web graph never imports the engine.

### 5.2 Connection rules

- Exactly one handle per process.
- Created once in the native composition root.
- Never closed by production code; process exit is the shutdown.
- `openInMemory()` creates the same schema/version and is the only test seam.
- No repository opens its own connection.
- No `Database` is stored on a widget after Stage 6.

### 5.3 Transitional raw-handle exception

`SyncPullApplier` and `CloudSyncPuller` (currently in
`core/sync/sync_pull_applier.dart`) still need a `Database` in Stage 6. They
are native-only and will import the engine handle. The engine may expose:

```dart
/// Transitional: only core/sync may use this until Stage 7 moves the pull
/// applier behind an engine-owned store. Never pass this to a widget.
Database get handle;
```

This is a documented exception, not the target end-state. Stage 7 removes it.
It does not affect the web graph.

---

## 6. Schema, migrations, and versioning

| Concern | Target owner | Preservation proof |
|---|---|---|
| `schemaVersion = 22` | `engine/schema/schema_version.dart` only | Repo-wide grep finds one definition; exporter/importer/settings/tests import it |
| 18 `CREATE TABLE` statements | `engine/schema/schema_v22.dart` | Byte/text diff against current `_onCreate` SQL, normalised only for file placement |
| Index/trigger creation | `engine/schema/indexes_triggers.dart` | Same statements, same `IF NOT EXISTS`, same call sites |
| v2→v22 upgrades | `engine/migrations/migrations_v2_to_v22.dart` | Ordered diff; `sqlite_master` snapshot equality before/after for every fixture |
| Pre-migration backup | `engine/backup/pre_migration_backup.dart` | Existing 4 backup tests plus byte comparison |
| Fresh-install divergence (F-2) | unchanged | Fresh v22 schema snapshot must match today’s, including the missing `picklist_items_picklist_id` index |
| `PRAGMA foreign_keys = ON` | `engine/lifecycle/` | PRAGMA observed immediately after open |
| Journal mode | unchanged (no WAL) | `PRAGMA journal_mode` check |

The `onCreate`/`onUpgrade` callbacks remain callbacks registered with
`openDatabase`; only their host file changes. sqflite’s single upgrade
transaction is not replaced or wrapped.

---

## 7. Repositories and transaction management

### 7.1 Shape

Each existing repository becomes one engine class that implements the matching
port:

```dart
class SqliteSaleRepository implements SaleRepository {
  SqliteSaleRepository(this._db, {ReportingRepository? reporting})
      : _reporting = reporting ?? SqliteReportingRepository(_db);
  final Database _db;
  final ReportingRepository _reporting;
  // method bodies move verbatim; db.transaction(...) stays in place
}
```

### 7.2 Transaction rules

- Transactions remain **inside the repository method that owns the business
  operation**. No generic `UnitOfWork`, no transaction manager abstraction, no
  repository-to-repository transaction propagation.
- The outbox enqueue remains inside the same `txn` handle as the business
  write. `SyncOutbox` moves to the engine so repositories can keep calling it
  without an app dependency.
- Cross-module writes remain explicit and transactional:
  - `FinanceRepository.markCompleted` → `finance_entries` + `cash_movements`
    deposit + outbox + audit.
  - `FinanceRepository.deleteEntry` → reversing withdrawal + soft delete +
    outbox + audit.
  - `DataImporter` → every table + cursor deletion + FK check in one
    transaction.
- `SyncPullApplier` keeps its single-page transaction in Stage 6 (app-side,
  transitional exception). Stage 7 may move the SQL behind an engine store,
  but the boundary and order are frozen.
- Read-only methods stay non-transactional.

### 7.3 Repository move order

Move in dependency order to keep each sub-stage independently testable:

1. `ProductRepository` (no cross-module writes)
2. `PicklistRepository` (self-contained; outbox only)
3. `ShiftRepository` (register owner; finance later reads it)
4. `FinanceRepository` (writes register movements — shift must already exist)
5. `SaleRepository` + `ReportingRepository` together (reporting delegates and
   shared filters)
6. `UserRepository` last (PBKDF2, login guards, demo adoption, cross-table
   guards; highest behavioural density)

---

## 8. Settings, device identity, and licensing

### 8.1 Settings

One `settings` table, unchanged. The engine adds a typed facade over the same
keys:

| Group | Keys (unchanged) | Accessor |
|---|---|---|
| Appearance | `theme_mode` | `SettingsStore.themeMode` |
| Sign-in | `remember_login`, `auth_session` | `SettingsStore.rememberLogin`, session store |
| Licensing | `license_code`, `activation_code` | licensing accessors |
| Device | `device_hw_uuid`, `device_install_uuid` | device accessors |
| Demo | `demo_password_version` | user-repository accessors |
| Login guard | `login_guard:<guardKey>` | user-repository accessors |
| Sync | `sync_cursor.<table>`, `sync_backfill.picklist_item_prices.v1` | puller accessors |
| Restore | stripping rules | `JsonBackupService` |

The facade is additive: `getSetting`/`setSetting` remain available so a missed
call site cannot change behaviour. Key strings are centralised as constants but
their values do not change.

### 8.2 Device identity

`DeviceIdentity` owns:

- `device_id.txt` beside `wholesale_pos.db` (same name, same directory, same
  stable UUID).
- The matching `devices` row (`id`, `name`, `platform` semantics unchanged).
- The in-memory fallback that reuses/creates one row.
- The post-restore re-registration hook.

`device_id.txt` is **not** moved into the database, into `settings`, or into a
package-private location.

### 8.3 Licensing and activation

Licensing stays in the app (`core/licensing/`), because it combines platform
fingerprinting, HTTP activation, and Ed25519 verification. It consumes the
engine's `SettingsStore` and `DeviceIdentity` instead of a raw `Database`.
`SqliteLocalDataOps` becomes an app-level composition of engine stores plus
licensing; it no longer accepts `Database`.

This removes the last raw-handle path above the repository layer (audit F-5)
without moving licence policy into the engine.

---

## 9. Backup, export, and restore

| Mechanism | Target owner | Behaviour that must not change |
|---|---|---|
| Pre-migration safety copy | `engine/backup/pre_migration_backup.dart` | `<db>.bak` sibling, skip for version 0/22, copy for newer, non-fatal failure |
| JSON export | `engine/backup/json_backup_service.dart` | Owner-only, active-owner check, credential stripping, photo reattachment, five secret settings omitted, `BACKUP_EXPORTED` audit after file write, `version = 22` |
| JSON restore | `engine/backup/json_backup_service.dart` | Version 6–22 validation, required tables/fields, legacy sale-item normalisation, owner credential retention, unusable digests for others, pre-restore recovery export, one replacement transaction, cursor deletion, `PRAGMA foreign_key_check`, `BACKUP_RESTORED`, post-restore device registration |
| File location | app wrapper passes the documents directory/path to the engine | `wholesale_pos_backup_<timestamp>.json` in `getApplicationDocumentsDirectory()` |

The engine receives an explicit destination/source path from the app wrapper,
so the engine does not need `path_provider` for user backups. The pre-migration
copy still uses the open database’s own path.

Known defect F-7 (export is not a point-in-time snapshot) is **preserved** and
documented. The move must not silently “fix” it by adding a transaction; that
would be a separately authorised behaviour change.

---

## 10. Composition roots

### 10.1 Native (`main.dart`)

```
main()
  └─ LocalDatabase.open()                      // engine
       ├─ SettingsStore(db)
       ├─ DeviceIdentity(db)
       ├─ SqliteProductRepository(db)
       ├─ SqliteSaleRepository(db, reporting: …)
       ├─ SqliteReportingRepository(db)
       ├─ SqliteShiftRepository(db)
       ├─ SqliteFinanceRepository(db, shifts: …)
       ├─ SqlitePicklistRepository(db)
       ├─ SqliteUserRepository(db)
       ├─ SettingsSessionStore(settings)
       ├─ JsonBackupService(db, deviceIdentity)
       ├─ NativeBackend(ports…, settings, session, deviceId)
       ├─ SyncOutboxRepository(db)
       └─ SyncRuntime(engine repos/outbox, CloudSyncPuller(db))
  └─ WholesalePosApp(backend, localOps, deviceIdentity)  // no Database field
```

`NativeBackend` receives ports and stores, not a `Database`. The composition
root is the only place that knows the engine exists above `core/sync`.

### 10.2 Web (`main_web.dart`)

```
main_web()
  └─ CloudBackend(
        CloudSaleRepository, CloudReportingRepository, CloudShiftRepository,
        CloudFinanceRepository, CloudProductRepository, CloudUserRepository,
        CloudPicklistRepository,
        WebSessionStore)
  └─ PosRoot / WebActivationGate / WebSettingsScreen
```

No engine import, no sqflite, no `path_provider`, no `dart:io` in this graph.

---

## 11. Compatibility shims and removal

Stage 6 will temporarily need old import paths to keep the tree compiling.
Rules:

1. A shim may re-export a **contracts** file from an old app path. Contracts
   are web-safe.
2. A shim must **not** re-export the engine from a file that the web graph
   imports. If an old file currently mixes port and implementation (as all
   seven repository files do), split it instead of re-exporting both:
   - `core/repositories/sale_repository.dart` → contracts-only re-export
   - `core/repositories/sqflite_sale_repository.dart` → engine re-export
     (native-only; deleted at the end of Stage 6)
3. `schemaVersion`, `SessionData`, `SyncEntities`, `DateRange` and other pure
   symbols may be re-exported for one sub-stage; each re-export is deleted in
   the final sub-stage.
4. No shim may contain SQL or a `Database` type.

The final Stage 6 sub-stage removes every shim and adds an architecture test
that walks the `main_web.dart` import graph and fails on the forbidden
packages.

---

## 12. Test seams and gates

| Seam | Purpose |
|---|---|
| `LocalDatabase.openInMemory()` | Existing repository/sync tests keep using real SQLite in the VM |
| `openAt(tempPath)` | Migration and backup tests use temporary files |
| `SettingsStore` over the same table | Licensing/session tests can use a fake store without SQLite |
| `JsonBackupService` with explicit paths | Export/import tests avoid `path_provider` on the test host |
| Schema snapshot helper | Dumps `sqlite_master` + `PRAGMA user_version` for fresh and upgraded databases |

Required gates for every Stage 6 sub-stage:

- `flutter analyze --fatal-infos` → 0 issues.
- `flutter test` → all existing tests pass, plus new characterization tests.
- `dart analyze` + `dart test` in `pos_core`, `pos_contracts`,
  `pos_local_engine` → 0 issues, all pass.
- `flutter build web --release -t lib/main_web.dart` → passes, and the new
  import-graph test proves sqflite/engine/path_provider are absent.
- Windows release build (`tools/build_release.ps1 windows`) → passes.
- Schema equivalence: fresh v22 snapshot and every upgrade fixture snapshot
  identical before/after the move.
- Transaction inventory: 38 `transaction(` sites, same method ownership.

---

## 13. What explicitly does **not** change

- Database filename, directory, `.bak` sibling, `device_id.txt` sibling.
- Schema version 22, DDL, columns, defaults, FKs, indexes, triggers.
- Migration sequence, rewind semantics, duplicate-open-shift repair.
- Journal mode, FK pragma, connection count, close behaviour.
- Any SQL text or transaction body.
- Any settings key, value format, or export/restore stripping rule.
- Any sync entity name, payload, cursor key, ordering, retry, or demo
  isolation rule.
- Any licensing, activation, seat, or device-fingerprint rule.
- Any UI flow, screen, permission check, or navigation.
- Any feature key string, permission default, grantability rule, or ordering.
- Any log message text, level, or emission order on migration/backup paths.
- Findings F-2, F-4, F-6, F-7 (documented, not fixed).

---

## 14. Rejected alternatives

| Alternative | Why rejected |
|---|---|
| Keep `LocalDatabase` in `app/lib` and only “tidy” it | Does not give the engine a reusable boundary; the web graph keeps importing mixed port/implementation files. |
| Move the engine but keep `factory X(Database db)` on ports | Reintroduces sqflite into the contract and therefore into the web graph. |
| Split the schema into one table per module / one DB per module | Breaks the atomic cross-module transactions and the single restore transaction. |
| Introduce an ORM or query builder | Rewrites SQL; violates the freeze and risks schema drift. |
| Introduce WAL for concurrency | Changes journal mode and file sidecars; outside the mandate. |
| Generic `UnitOfWork` / transaction manager | Would rewrite all 38 boundaries; highest-risk change for zero functional gain. |
| Move sync HTTP/protocol into the engine | Scope creep; Stage 7 owns sync modularisation. Only the outbox storage moves now. |
| Split `settings` into typed tables | Storage change; would break restore compatibility. |
| Fix F-2/F-4/F-6/F-7 during the move | Behaviour/schema/doc changes outside Stage 6 authorisation. |
| Put ports in `pos_core` | Acceptable variant, but widens the pure-entity package. Kept as a fallback if a third package is undesirable. |

---

## 15. Acceptance criteria for the future Stage 6

The target architecture is realised only when **all** of the following hold:

1. `backend/dart/pos_contracts/` contains every repository/session/local-data
   port and has zero Flutter/sqflite/io/http imports.
2. `backend/dart/pos_local_engine/` contains the lifecycle, schema, migration
   chain, backup, settings, device, and repository implementations.
3. `app/lib` contains no SQLite SQL except the documented transitional
   `SyncPullApplier`/`CloudSyncPuller` path.
4. `app_shell.dart`, `app_backend.dart`, `cloud_backend.dart`,
   `web_settings_screen.dart`, and the whole `main_web.dart` import graph
   contain no sqflite/engine/path_provider/`dart:io`.
5. No widget receives a `Database`.
6. Fresh and upgraded schemas are byte-identical to the pre-move snapshots.
7. All existing tests pass unchanged in behaviour; new schema/import tests
   pass.
8. Web and Windows release builds pass.
9. `migration-log.md` records the move with actual results.
10. The director has reviewed and authorised the stage.
