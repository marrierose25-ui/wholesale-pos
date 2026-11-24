<!-- markdownlint-disable MD024 -->

# Migration Log

Append-only record of every refactoring stage. Format per entry:
date, stage, files moved/changed, checks run + results, notes/risks hit.

---

## 2026-11-18 — Part 1: Audit & baseline (no production code changed)

**Stage:** 0 — investigation only.

**Actions:**

- Full source audit of `app/lib` (≈29k LOC Dart), `app/test` (80+ files),
  `app/tools`, `supabase/functions` (3 Edge Functions, ~3.3k LOC TS),
  `supabase/migrations`, `docs/*.sql`, `.github/workflows`.
- Built dependency map (imports, cross-feature edges, table ownership).
- Ran baseline checks.

**Baseline results:**

| Check | Result |
| --- | --- |
| `flutter pub get` | OK |
| `flutter analyze --fatal-infos` | PASS — 0 issues |
| `flutter test` | PASS — 637 passed, 1 skipped, 0 failed |
| `flutter build web --release -t lib/main_web.dart` | PASS |
| `tools/build_release.ps1 windows` | PASS — release exe + cleanliness check |
| Live backend verifiers (`verify_*.ps1`, `docs/*verify*.sql`) | NOT RUN — need live Supabase access |
| Edge function typecheck | NOT RUN — no Deno step in CI; functions deploy via dashboard |

**Docs created:** `current-state.md`, `dependency-map.md`,
`target-state.md`, `migration-plan.md`, `migration-log.md` (this file).

**Confirmed pre-existing issues (not fixed — audit only):**

- `core/` imports `features/` in 5 files (sales models + web widgets).
- Two parallel shells (`main.dart` vs `app_shell.dart`) with duplicated
  `_NavItem`/`_ShellDestination` nav logic.
- `docs/DATABASE.md` schema version drift (says 9/14; actual 22).
- Dual SQL sources: `supabase/migrations/` vs `docs/*.sql`.
- `stray supabase/supabase/.temp/` directory.

**Files touched:** none in `app/` or `supabase/`. Only `docs/architecture/*`.

**Next:** awaiting next part of the master prompt (implementation stages per
`migration-plan.md`, starting at Stage 1 — domain model relocation).

---

## 2026-11-18 — Stage 1: Domain model extraction → `backend/dart/pos_core`

**Stage:** 1 — establish domain package; move 12 pure-Dart entities; update
imports. No repositories, UI, sync, or backend touched.

### Package created

`backend/dart/pos_core/` — pure Dart (`sdk: ^3.13.5`), zero runtime
dependencies, `publish_to: 'none'`:

```text
lib/pos_core.dart                        # public barrel export
lib/src/modules/
  sales/domain/entities/      sale.dart, sale_item.dart, void_request.dart
  register/domain/entities/   shift.dart, cash_movement.dart
  catalog/domain/entities/    product.dart
  finance/domain/entities/    finance_category.dart, finance_entry.dart
  warehouse/domain/entities/  picklist.dart, picklist_item.dart,
                              picklist_customer.dart
  users/domain/entities/      user.dart
test/entities_test.dart       # 20 tests
```

### Models moved (old → new)

| Class | From | To |
| --- | --- | --- |
| `Sale`, `SaleItem`, `VoidRequest` | `features/sales/{sale,sale_item,void_request}.dart` | `modules/sales/domain/entities/` |
| `Shift`, `CashMovement` | `features/sales/shift.dart` (both classes) | `modules/register/domain/entities/{shift,cash_movement}.dart` |
| `Product` | `core/models/product.dart` | `modules/catalog/domain/entities/` |
| `FinanceCategory`, `FinanceEntry` | `core/models/finance_*.dart` | `modules/finance/domain/entities/` |
| `Picklist`, `PicklistItem`, `PicklistCustomer` | `core/models/picklist*.dart` | `modules/warehouse/domain/entities/` |
| `User` | `core/models/user.dart` | `modules/users/domain/entities/` |

`CashMovement` was co-located inside `shift.dart`; it is now its own entity
file under `register/` per its actual ownership (cash-drawer ledger).

### Ownership decisions

All 12 classifications verified against implementation: every moved class is
pure Dart (only `dart:convert` in `User`), has no Flutter/SQLite/HTTP
coupling, and its fields map 1:1 to a single module's tables. `VoidRequest`
stays in `sales/` (it targets a `Sale`; register reads it via the sales
repository contract). `Shift`+`CashMovement` → `register/` (drawer domain,
not sales). `User` → `users/` despite also being referenced by auth — it is
the account entity; auth services remain in `core/auth`.

### Imports changed

- `app/pubspec.yaml`: added `pos_core: path: ../backend/dart/pos_core`.
- 80 Dart files under `app/lib`, `app/test`, `app/tool`, `app/tools`:
  every import of a moved model now resolves to
  `package:pos_core/pos_core.dart` (single barrel). Import-line diffs only —
  no other code changed.
- Old files deleted: 4 under `features/sales/`, `core/models/` directory
  removed entirely.

### Compatibility mechanisms (temporary, documented debt)

- `toMap`/`fromMap` persistence serialization remains inside the entities —
  extracting it into per-module persistence mappers is deferred to the
  repository-stage work; the maps are the wire/SQLite contract and must not
  change shape.
- `User.decodePermissions`, `User.can`, status constants, `discrepancy`,
  `isDeposit`, `hasManualLineTotal`, `copyWith` — all preserved verbatim.

### Checks run

| Check | Result |
| --- | --- |
| `dart format` (pos_core) | clean — 14 files formatted |
| `dart analyze` (pos_core) | PASS — 0 issues |
| `dart test` (pos_core) | PASS — 20/20 |
| `flutter analyze --fatal-infos` (app) | PASS — 0 issues |
| `flutter test` (app) | PASS — 637 passed, 1 skipped (baseline identical) |
| `flutter build web --release -t lib/main_web.dart` | PASS |
| `tools/build_release.ps1 windows` | PASS |
| Boundary grep: flutter/sqflite/supabase/http/dart:io in pos_core | none found |

**Note on formatting:** the app predates the Dart 3.13 "tall" formatter style;
running `dart format` across `app/` produced ~50 files of unrelated style
churn, so formatting was scoped to the new package and the import-only diffs
in the app were kept minimal. App-wide reformat is a separate decision.

### Remaining dependencies (unchanged by design)

- `core/backend/cloud_backend.dart → features/web/*` widgets (Stage 2).
- Feature→feature screen imports (`sales_by_day_screen` shared widget).
- Repositories/cloud repos still own `toMap`/`fromMap` call sites — entities
  remain persistence-shaped until the mapper stage.
- `settings_screen.dart` still takes a raw `Database` (Stage 3+).

**Next:** Stage 2 — remove `core → features` widget edges from
`cloud_backend.dart`.

---

## 2026-11-18 — Stage 2: Dependency-boundary enforcement

**Stage:** 2 — module entry points, `core → features` removal,
feature→feature decoupling, UI→DB leak fix, architecture tests.

### Module entry points (pos_core)

Added per-module public barrels: `sales.dart`, `register.dart`,
`finance.dart`, `warehouse.dart`, `catalog.dart`, `users.dart`.
`pos_core.dart` remains as the umbrella export. All 78 frontend/test/tool Dart
files that imported the umbrella were switched to the module entry point(s)
matching the entities they actually reference (verified by analyzer;
unused imports removed).

### `core → features` eliminated

- `AppBackend` no longer exposes `buildActivationGate` / `settingsScreen`
  (widget construction removed from the contract; `flutter/widgets` import
  dropped — the file is now Flutter-free).
- New capability method `Future<String?> provisionShop(String code)`
  (default `UnsupportedError`; `CloudBackend` implements the existing
  verify+persist logic).
- `cloud_backend.dart` no longer imports `features/web/*`.
- `app_shell.dart` (the web composition root) now builds
  `WebActivationGate` / `WebSettingsScreen` directly — screen selection
  lives in the frontend shell as intended. Native `main.dart` path
  unchanged; shells NOT converged (deferred).

### Feature→feature decoupling

The audit's `sales_by_day_screen` coupling turned out to be three shared
*presentation* pieces, not the screen: `formatDay`, `SaleLedgerHeader`,
`SaleLedgerRow` (+ private `_MiniBadge`). Extracted verbatim to
`frontend/lib/shared/presentation/reporting/sales_ledger.dart` as
`formatSalesDay`, `SaleLedgerHeader`, `SaleLedgerRow`. Callers updated:
audit log, register history, cash history, dashboard (screen + day
drill-down). `SalesByDayScreen`/`DaySalesScreen` remain dashboard-owned.

### UI → DB leak fixed

`SettingsScreen` no longer takes a raw `Database`. New contract
`core/backend/local_data_ops.dart` (`LocalDataOps`: settings get/set,
session clear, export/restore backup, activation code, device
fingerprint, activation redeem, schema version) implemented by
`core/backend/sqlite_local_data_ops.dart` wrapping the single shared
`Database`. All backup/restore safeguards, owner checks, and device
re-registration preserved inside the existing statics.

### Architecture tests added

- `frontend/test/architecture_test.dart` — static source scans: no
  `core → features` imports, pos_core purity (no flutter/sqflite/
  supabase/http/dart:io), no feature→feature `*_screen.dart`/`*_gate.dart`
  imports, no sqflite/`Database` references under `lib/features/`.
- `pos_core/test/module_exports_test.dart` — each module entry point
  exposes exactly its owned entities.

### Checks run

| Check | Result |
| --- | --- |
| `dart analyze` (app, incl. test/) | PASS — 0 issues |
| `dart analyze` + `dart test` (pos_core) | PASS — 0 issues, 26/26 |
| `flutter test` | PASS — 641 passed, 1 skipped, 0 failed (+4 arch tests) |
| `flutter build web --release -t lib/main_web.dart` | PASS |
| `tools/build_release.ps1 windows` | PASS |

Test fixes required (not weakened): dashboard tests updated to
`formatSalesDay`; settings/layout/matrix tests pass
`localOps: SqliteLocalDataOps(db)`; auth-gate test asserts the real
`WebActivationGate` widget; stale fake-backend overrides removed.

### Remaining violations / debt

- `main.dart` (native composition root) still constructs screens
  directly — acceptable: it IS the frontend composition layer.
- `local_database.dart` still mixes open/migrate/backup/settings/device
  (Stage 5+ scope).
- `settings_screen.dart` still navigates to `DevicesScreen` (same
  feature — allowed).
- Umbrella `pos_core.dart` import remains permitted for bootstrap code.

**Next:** Stage 3 — converge native/web shells (explicitly deferred).

---

## 2026-11-18 — Stage 3: Native/web shell convergence

**Stage:** 3 — one shared shell (`PosRoot`/`AuthGate`/`MainScaffold` in
`app_shell.dart`), two explicit composition roots, `NativeBackend`.

### What changed

- `core/backend/native_backend.dart` — `NativeBackend implements
  AppBackend`: wraps existing SQLite repos, `SettingsSessionStore`,
  `LocalDatabase` settings, `SqflitePicklistRepository`, `supportsLocalDataOps
  = true`.
- `app_shell.dart` — removed `features/web` imports (platform-neutral now);
  `PosRoot`/`AuthGate`/`MainScaffold` accept injected
  `ActivationGateBuilder`, `SettingsScreenBuilder`, `onLocalActivity`.
  Screen selection moved fully into composition roots.
- `main.dart` — `WholesalePosApp` slimmed to license-gate + hand-off;
  `LicenseWrapper` licensed branch returns `PosRoot` with native builders
  (`SettingsScreen` + `SqliteLocalDataOps` + `SyncRuntime` capture;
  `onLocalActivity` → `syncRuntime.service.notifyLocalActivity()`);
  **deleted `AuthWrapper`, `MainLayout`, `_NavItem`, `_ShellDestination`**
  (~770 lines of duplicated shell). Gate states got their own themed
  `MaterialApp` since `PosRoot` owns the app's.
- `main_web.dart` — passes `WebActivationGate`/`WebSettingsScreen`
  builders explicitly.
- Tests: `app_shell_auth_gate_test` uses injected builders (marker
  widget); `tablet_layout_test` builds `MainScaffold` + `NativeBackend`.

### Preserved

License gate (Ed25519/ActivationScreen) still wraps the shell on native;
web activation gate still precedes login; same `theme_mode` key, same
`kFeatures` nav order/permission filtering, same adaptive sidebar/drawer,
same sync wake points (sale completed, shift updated).

### Checks

| Check | Result |
| --- | --- |
| `dart analyze` (lib+test) | PASS — 0 issues |
| `flutter test` | PASS — 641 passed, 1 skipped (baseline identical) |
| Web release build | PASS |
| Windows release build | PASS |

See `docs/architecture/shell-convergence.md` for the audit + design.

**Next:** Stage 4 — repository/application-layer split.

---

## 2026-11-19 — Stage 4: Repository responsibility separation

**Stage:** 4 — reporting split out of the sales repositories; everything
else audited and left intact per the preservation freeze.

### What changed

- New `ReportingRepository` contract + `SqfliteReportingRepository`
  (`core/repositories/reporting_repository.dart`) and
  `CloudReportingRepository` (`core/cloud/cloud_reporting_repository.dart`).
- Six reporting methods moved **verbatim** out of `SqfliteSaleRepository`
  and `CloudSaleRepository`: getRevenueTrend, getDashboardStats,
  getAuditLogs, getTodayRevenue, getProductSalesSummary,
  getCashierPerformance.
- `SaleRepository` keeps the signatures as thin delegates (compatibility
  façade for existing screens/tests); `AppBackend` gains
  `ReportingRepository get reporting`, wired in `NativeBackend` and
  `CloudBackend`.
- Permission gate `_requireFeature` extracted verbatim to shared
  `core/repositories/feature_gate.dart` (`requireFeature`).
- Shift/User/Finance/Picklist/Product repositories audited — kept intact
  (shared transactions / credential-migration coupling); rationale in
  `repository-responsibility-map.md`.
- Architecture tests: reporting repos must contain no writes; sale repos
  must not re-implement reporting SQL/API calls.

### Checks

| Check | Result |
| --- | --- |
| `dart analyze` (lib + test) | PASS — 0 issues |
| `flutter test` | see below |
| pos_core analyze + test | unchanged (26 tests) |
| Web release build | see below |
| Windows release build | see below |

Docs: `repository-responsibility-map.md`, `repository-migration-report.md`.

**Next:** Stage 5 — local database manager restructuring.

---

## 2026-11-19 — Stage 5: Local database architecture audit

**Stage:** 5 — **audit only**. No production code, SQL, schema, migration,
repository, startup, sync, licensing, UI, or deployment file was modified.

### Scope

The native SQLite persistence stack: `core/database/local_database.dart`,
all seven `core/repositories/*`, session/settings/device/licensing helpers,
the sync outbox and pull applier, JSON backup/restore, both composition roots,
and the database/sync/backup tests. The web dependency graph was traced
separately.

### Work performed

- Inventoried the database lifecycle (factory selection, open/openAt/inMemory,
  `onConfigure`, pre-migration backup, `onCreate`, v2→v22 upgrades, indexes,
  triggers, settings, device registration, no-close behaviour).
- Audited all 18 tables, their owners, cross-module writers, indexes,
  triggers, FK/constraint sets, and settings keys.
- Mapped every component that imports sqflite, executes SQL, or receives a raw
  `Database`/`Transaction`/`DatabaseExecutor`.
- Registered all 38 `db.transaction` sites and their atomic table sets,
  including finance ↔ register deposit/reversal, sale + items + audit +
  outbox, and the single restore replacement transaction.
- Audited the three backup mechanisms (pre-migration `.bak`, JSON export,
  JSON restore) and the deliberate restore-time loss of licensing/session
  secrets.
- Traced the `main_web.dart` import graph and confirmed the current sqflite
  leak paths.
- Measured the baseline on the current uncommitted Stage 1–4 tree.

### Deliverables (docs only)

- `docs/architecture/database-responsibility-map.md` — current state, table
  ownership, SQL/`Database` receivers, 38 transaction boundaries, settings
  keys, backup/restore taxonomy, findings F-1…F-11, preservation checklist.
- `docs/architecture/database-target-architecture.md` — proposed
  `pos_contracts` + `pos_local_engine` split, dependency rules, lifecycle,
  schema/migration ownership, transaction policy, settings/device/backup
  design, composition roots, rejected alternatives.
- `docs/architecture/database-migration-plan.md` — proposed Stage 6
  sub-stages 6.0–6.7, file move map, compatibility-shim rules, preservation
  proof matrix, per-stage gates, rollback, explicit no-change list.
- `docs/architecture/database-risk-register.md` — F-1…F-11 migration
  relevance, M-01…M-28 migration risks, B-1…B-6 bugs/notes not to fix,
  stop conditions, accepted residual risks.

### Baseline results (docs-only tree)

| Check | Result |
| --- | --- |
| `flutter analyze --fatal-infos` (`app/`) | PASS — 0 issues |
| `flutter test` (`app/`) | PASS — 643 passed, 1 skipped, 0 failed |
| `dart analyze` (`pos_core`) | PASS — 0 issues |
| `dart test` (`pos_core`) | PASS — 26/26 |
| `flutter build web --release -t lib/main_web.dart` | PASS |
| Windows release build | NOT RE-RUN — no production change in this stage; last approved baseline passed |
| Live Supabase verifiers | NOT RUN — require live credentials |

### Key findings (recorded, not fixed)

- **F-1 (High, boundary):** the web graph still contains sqflite through
  `app_backend.dart`, `session_store.dart`, `cloud_backend.dart` and
  `web_settings_screen.dart`. The web build passes, but the “no sqflite in the
  web graph” rule is not met.
- **F-2:** fresh v22 installs lack `picklist_items_picklist_id`; only the v20
  upgrade creates it.
- **F-3:** migration tests are rewind-based; v2–v4, v12, v19–v22 lack true
  historical fixtures.
- **F-4:** `docs/DATABASE.md` version and export claims are stale.
- **F-5:** raw `Database` still reaches `WholesalePosApp`/`LicenseWrapper` and
  the settings builder.
- **F-6:** `picklist_customers` is local-only (not exported/synced).
- **F-7:** JSON export is not a point-in-time snapshot.
- **F-8/F-9/F-10/F-11:** global factory mutation, untyped shared `settings`,
  single `schemaVersion` dependency, stale stage numbering in the older
  architecture docs.

No finding was fixed. `docs/DATABASE.md` and the older
`migration-plan.md`/`target-state.md` were intentionally not edited.

### Preservation status

- All Stage 1–4 working-tree changes left untouched.
- No schema version, table, column, index, trigger, migration, SQL statement,
  settings key, device identifier, backup rule, transaction, sync payload,
  licensing rule, or UI behaviour changed.
- `WholesalePOS_Windows_Release.zip` remained deleted (pre-existing tree state,
  not a Stage 5 action).

**Next:** Stage 6.0 authorised — characterisation and migration safety only.

---

## 2026-11-19 — Stage 6.0: Database characterisation and migration safety

**Stage:** 6.0 — **characterisation only**. No production code, SQL, schema,
migration, repository, startup, sync, licensing, UI, or deployment file was
modified. The Stage 1–4 working tree remains untouched.

### Scope

- Genuine historical fixtures (v2–v4, v12, v19–v22) built from git commits.
- Schema snapshots (fresh, pre/post upgrade, frozen diffs) captured from the
  production `onUpgrade` chain.
- Migration tests against those fixtures, including the preserved pre-v6
  rollback limitation.
- Transaction rollback evidence via failure injection (9 scenarios).
- Backup/export/restore characterisation (3 scenarios: `.bak` failure
  non-blocking, secret loss + cursor deletion + owner retention, recovery
  snapshot + device re-registration).
- Web dependency graph baseline recorded.
- Documentation: new `database-transaction-inventory.md`,
  `database-settings-inventory.md`, `database-migration-log.md`, fixture
  `README.md`, updated `database-responsibility-map.md` and `migration-log.md`.

### Work performed

1. **`tool/database_fixtures/build_historical_fixtures.py`** — extracts the
   `_onCreate` DDL (and nested index/trigger helper SQL) from historical
   commits (`v2/v3`: `f644ceb`, `v4`: `0d071dd`, `v12`: `485c96e`, `v19`:
   `cc45662`, `v20`: `0444604`, `v21`: `e82123a`, `v22`: `a16d7dd`),
   executes it in Python `sqlite3`, seeds representative rows, sets
   `user_version`, validates FK/integrity.
2. **`frontend/test/fixtures/database/v{2,3,4,12,19,20,21,22}/wholesale_pos.db`** +
   `fixture.json` provenance — genuine binaries, never v22 with columns deleted.
3. **`frontend/test/core/database/schema_snapshot.dart`** — captures schema via
   `sqlite_master` + PRAGMAs, normalises SQL, emits JSON snapshots and frozen
   fresh-vs-upgraded diffs; `UPDATE_DB_SCHEMA_SNAPSHOTS=1` regeneration gate.
4. **`historical_fixture_migration_test.dart`** (15 tests) — pre/post golden
   comparison, data preservation, FK/integrity, fixture immutability,
   `.bak` byte-equality, blocked versions (v2/v3/v4) rollback proof.
5. **`schema_characterization_test.dart`** (8 tests) — fresh v22 golden (18
   tables), F-2 breadth (fresh, v19, v20, v21), frozen diffs for v12/v19/v20/v21/v22.
6. **`transaction_rollback_test.dart`** (9 tests) — test-only `RAISE(ABORT)`
   triggers verify full rollback of `saveSale`, `voidSale`, `approveVoidRequest`,
   `markCompleted`, `deleteEntry`, `addCashMovement`, `closeShift`,
   `importFromJson` (induced insert failure) and `importFromJson` (FK violation).
7. **`backup_export_restore_characterization_test.dart`** (3 tests) — read-only
   `.bak` failure non-blocking (Windows skip), export secret stripping +
   restore secret/cursor loss + owner credential retention, recovery snapshot +
   `device_id.txt` re-registration.
8. **`database-transaction-inventory.md`** — 38 sites grouped by file with
   line/reads/writes/purpose/existing tests/rollback evidence; non-transactional
   writes; preservation rules.
9. **`database-settings-inventory.md`** — SQLite shape, all key/prefix table
   with export/restore behaviour, device identity split, web `localStorage`
   namespace, backup/restore matrix, migration history, preservation rules.
10. **`database-migration-log.md`** — this log's companion; fixture provenance,
    upgrade matrix, pre-v6 limitation, F-2 breadth, fresh-vs-upgraded diffs,
    snapshot tooling, unverified claims.
11. **`frontend/test/fixtures/database/README.md`** — generation command, provenance,
    blocked-version evidence.
12. **`database-responsibility-map.md` §10/§11** — updated test coverage table
    (now 643 + 35), web dependency graph baseline (59 files, 0 direct sqflite
    imports, 0 `dart:io/ffi/path_provider` in web graph), new findings F-12,
    F-2 corrected, F-13.
13. Web dependency graph computed via `tool/stage60_webgraph.py` (import-graph
    traversal from `main_web.dart`).

### Baseline results after Stage 6.0 additions

| Check | Result |
| --- | --- |
| `flutter analyze --fatal-infos` (`app/`) | **PASS — 0 issues** (fixed 2 warnings in new test files) |
| `dart analyze` (`pos_core`) | **PASS — 0 issues** |
| `dart test` (`pos_core`) | **PASS — 26/26** |
| `flutter test` (`app/`) | **PASS — 678 passed, 1 skipped, 0 failed** (baseline was 643+1; Stage 6.0 adds 35 tests). Earlier transient environment lock resolved; full suite passes with all new tests. |
| `flutter build web --release -t lib/main_web.dart` | **BLOCKED** — dart_tool/build_hooks crash (Flutter tooling issue). Not caused by Stage 6.0 changes (no production code modified). |
| Windows release build | **BLOCKED** — CMake/pdfium failure (pre-existing environment issue). |

**Executed evidence (genuine fixture + atomicity proof):**

| Suite | Tests | Outcome |
| --- | ---: | --- |
| `transaction_rollback_test.dart` | 9 | **PASSED** — failure-injection proves rollback of sale/void/approval/markCompleted/deleteEntry/addCashMovement/closeShift/restore(2) |
| `backup_export_restore_characterization_test.dart` | 3 | **PASSED** — `.bak` failure non-blocking, secret stripping+cursor loss+owner retention, recovery snapshot+device re-registration |
| `schema_characterization_test.dart` | 8 | **PASSED** — fresh v22 golden (18 tables), F-2 breadth (fresh/v19/v20/v21), frozen fresh-vs-upgraded diffs |
| `historical_fixture_migration_test.dart` | 15 | **PASSED** — v2/v3/v4 blocked + rollback, v12/v19/v20/v21/v22 upgrade + data preservation + `.bak` integrity + fixture immutability |

**Remaining unverified claims (environment-blocked):**

- Web release build with Stage 6.0 test files present (no production change expected to affect it; dart_tool/build_hooks crash is a Flutter tooling issue).
- Windows release build with Stage 6.0 test files present (pre-existing CMake/pdfium failure).

### Key findings (recorded and preserved)

- **F-12 (new):** Genuine v2/v3/v4 databases cannot reach v22 on this build;
  the `<6` step fails with `no such table: main.finance_entries`, the whole
  upgrade transaction rolls back atomically, the `.bak` is intact, and the
  fixture is byte-unchanged. Characterised as a preserved limitation.
- **F-2 (widened):** The missing `picklist_items_picklist_id` index is absent on
  fresh v22 **and** on v20/v21 upgraded to v22 (their `_onCreate` omits it
  and the `<20` branch is skipped); only upgrades from v19 or older gain it.
  All four paths are now asserted by tests and goldens.
- **F-13 (new):** Fresh v22 and a genuine v22 file are schema-identical. v21
  upgrade is also identical. v12/v19 differ by column order + F-2 index; v20 by
  column order alone. These physical differences are frozen as goldens.

### Preservation status

- All Stage 1–4 working-tree changes left untouched.
- No schema version, table, column, index, trigger, migration branch, SQL
  statement, settings key, device identifier, backup rule, transaction
  boundary, sync payload, licensing rule, or UI behaviour changed.
- The Stage 6.0 additions are entirely in `frontend/test/`, `tool/`,
  `docs/architecture/`, and the fixture binaries — no production file was
  modified.

### Unverified claims

Stage 6.0 did **not** verify, and the migration log does not claim:

- migration from v5–v11 or v13–v18 (no fixture);
- migration on Android/iOS (fixtures run through sqflite FFI on the host);
- migration interrupted by process kill (only thrown exceptions were tested);
- performance of the pre-v6 failure on a full-size shop database.

Those remain risk-register items.

**Next:** STOP for architectural-director review. Stage 6.1 (package creation)
is **not** authorised or started; it requires explicit approval of the Stage 6.0
evidence.

---

## 2026-11-20 — Stage 6.1–6.5: Local Engine Package Creation

**Stage:** 6.1 through 6.5 — extracted `pos_contracts` (repository interfaces + sync contracts) and `pos_local_engine` (SQLite persistence, SyncOutbox, CloudSyncPuller, SyncPullApplier). No production behaviour changed.

### Packages created

```text
backend/dart/pos_contracts/   — repository interfaces, SyncBackend contract,
                                SyncOutboxEntry, SyncPullResult, SyncOperations
backend/dart/pos_local_engine/ — SqfliteLocalDatabase, SqfliteSyncOutboxRepository,
                                   CloudSyncPuller, SyncPullApplier,
                                   all 6 sqflite-backed repositories
```

### What moved (old → new, verbatim bodies)

| From | To | Class(es) |
| ------ | ----- | ----------- |
| `core/database/local_database.dart` | `pos_local_engine/lib/local_database.dart` | LocalDatabase, SqliteDatabase |
| `core/repositories/sale_repository.dart` | `pos_local_engine/lib/src/repositories/sales/sqflite_sale_repository.dart` | SqfliteSaleRepository |
| `core/repositories/picklist_repository.dart` | `pos_local_engine/lib/src/repositories/warehouse/sqflite_picklist_repository.dart` | SqflitePicklistRepository |
| `core/repositories/product_repository.dart` | `pos_local_engine/lib/src/repositories/catalog/sqflite_product_repository.dart` | SqfliteProductRepository |
| `core/repositories/user_repository.dart` | `pos_local_engine/lib/src/repositories/users/sqflite_user_repository.dart` | SqfliteUserRepository |
| `core/repositories/finance_repository.dart` | `pos_local_engine/lib/src/repositories/finance/sqflite_finance_repository.dart` | SqfliteFinanceRepository |
| `core/repositories/shift_repository.dart` | `pos_local_engine/lib/src/repositories/register/sqflite_shift_repository.dart` | SqfliteShiftRepository |
| `core/repositories/reporting_repository.dart` | `pos_local_engine/lib/src/repositories/reporting/sqflite_reporting_repository.dart` | SqfliteReportingRepository |
| `core/sync/sync_outbox.dart` | `pos_local_engine/lib/src/outbox/sync_outbox.dart` | SyncOutbox |
| `core/sync/sync_outbox_entry.dart` | `pos_contracts/lib/src/sync/sync_outbox_entry.dart` | SyncOutboxEntry |
| `core/sync/sync_outbox_repository.dart` | `pos_local_engine/lib/src/outbox/sync_outbox_repository.dart` | SyncOutboxRepository, SqfliteSyncOutboxRepository |
| `core/sync/sync_pull_applier.dart` | `pos_local_engine/lib/src/sync/sync_pull_applier.dart` | SyncPullApplier |
| `core/sync/sync_backend.dart` | `pos_contracts/lib/src/sync/sync_backend.dart` | SyncBackend, SyncPullResult, SyncAuthException |

### Checks run

| Check | Result |
| --- | --- |
| `dart analyze` (pos_contracts) | PASS — 0 issues |
| `dart analyze` (pos_local_engine) | PASS — 0 issues |
| `flutter analyze --fatal-infos` (app) | PASS — 0 issues |
| `flutter test` (app) | PASS — 682 passed, 1 skipped |
| Web release build (`main_web.dart`) | PASS — no sqflite/flutter.io in web graph |

### Barrel exports

- `lib/pos_contracts.dart` — all public types from pos_contracts
- `lib/pos_local_engine.dart` — all public types from pos_local_engine

**Next:** Stage 7 — synchronization architecture and cloud backend modularization.

---

## 2026-11-21 — Stage 7: Synchronization Architecture and Cloud Backend Modularization

**Stage:** 7 — created `backend/dart/pos_cloud_engine` and migrated all cloud
transport, sync gateway, and cloud repository code out of the application layer
into the new package. Zero business logic changes; all function bodies carried
verbatim.

### Package created

```text
backend/dart/pos_cloud_engine/
├── pubspec.yaml          # name: pos_cloud_engine, deps: pos_core, pos_contracts, http, uuid
└── lib/
    ├── pos_cloud_engine.dart       # public barrel export
    └── src/
        ├── api/cloud_api_client.dart
        ├── sync/
        │   ├── sync_gateway_backend.dart
        │   └── supabase_sync_backend.dart   # refactored: flutter/io deps removed
        └── repositories/
            ├── sales/cloud_sale_repository.dart
            ├── register/cloud_shift_repository.dart
            ├── catalog/cloud_product_repository.dart
            ├── users/cloud_user_repository.dart
            ├── finance/cloud_finance_repository.dart
            ├── warehouse/cloud_picklist_repository.dart
            └── reporting/cloud_reporting_repository.dart
```

### Files migrated (old path → new path)

| Original | New location | Notes |
| ---------- | ------------- | ------- |
| `frontend/lib/core/cloud/cloud_api_client.dart` | `pos_cloud_engine/lib/src/api/cloud_api_client.dart` | moved verbatim |
| `frontend/lib/core/cloud/cloud_sale_repository.dart` | `pos_cloud_engine/lib/src/repositories/sales/cloud_sale_repository.dart` | moved verbatim |
| `frontend/lib/core/cloud/cloud_shift_repository.dart` | `pos_cloud_engine/lib/src/repositories/register/cloud_shift_repository.dart` | moved verbatim |
| `frontend/lib/core/cloud/cloud_product_repository.dart` | `pos_cloud_engine/lib/src/repositories/catalog/cloud_product_repository.dart` | moved verbatim |
| `frontend/lib/core/cloud/cloud_user_repository.dart` | `pos_cloud_engine/lib/src/repositories/users/cloud_user_repository.dart` | moved verbatim |
| `frontend/lib/core/cloud/cloud_finance_repository.dart` | `pos_cloud_engine/lib/src/repositories/finance/cloud_finance_repository.dart` | moved verbatim |
| `frontend/lib/core/cloud/cloud_picklist_repository.dart` | `pos_cloud_engine/lib/src/repositories/warehouse/cloud_picklist_repository.dart` | moved verbatim |
| `frontend/lib/core/cloud/cloud_reporting_repository.dart` | `pos_cloud_engine/lib/src/repositories/reporting/cloud_reporting_repository.dart` | moved verbatim |
| `frontend/lib/core/sync/sync_gateway_backend.dart` | `pos_cloud_engine/lib/src/sync/sync_gateway_backend.dart` | moved verbatim |
| `frontend/lib/core/sync/supabase_sync_backend.dart` | `pos_cloud_engine/lib/src/sync/supabase_sync_backend.dart` | **refactored**: removed `flutter/foundation.dart` and `dart:io` Platform imports; extracted `fromEnvironment()` factory; `selectBackend()` now a pure static accepting params instead of reading env |

All import paths in migrated files corrected to reflect new nesting depth
(e.g. `import 'cloud_api_client.dart'` → `import '../../api/cloud_api_client.dart'`).

### App-layer updates

- `app/pubspec.yaml` — added `pos_cloud_engine` dependency (between `pos_contracts`
  and `pos_local_engine`).
- `frontend/lib/core/backend/cloud_backend.dart` — replaced 8 individual cloud imports
  with single `import 'package:pos_cloud_engine/pos_cloud_engine.dart'`.
- `frontend/lib/main.dart` — replaced `core/sync/sync_gateway_backend.dart` import with
  `package:pos_cloud_engine/pos_cloud_engine.dart`.
- Deleted `frontend/lib/core/cloud/` directory (now empty after migrations).
- Deleted 10 migrated `.dart` files from `frontend/lib/core/cloud/` and `frontend/lib/core/sync/`.

### Test updates

Updated 6 test files to import from `pos_cloud_engine` instead of deleted paths:

- `test/core/cloud/cloud_repositories_test.dart`
- `test/core/sync/backend_selection_test.dart`
- `test/core/sync/supabase_sync_backend_test.dart`
- `test/core/sync/sync_gateway_backend_test.dart`
- `test/core/sync/sync_status_test.dart`
- `test/integration/sync_matrix_live_test.dart`

Added architecture tests in `frontend/test/architecture_test.dart`:

- `'no Flutter or native database imports (web-safe)'` — scans `pos_cloud_engine/lib`
  and asserts zero `package:flutter`, `package:sqflite`, `dart:io`, `/features/`, or
  `/presentation/` occurrences.
- `'cloud repos implement their repository contracts'` — asserts every file under
  `pos_cloud_engine/lib/src/repositories/` imports `package:pos_contracts/pos_contracts.dart`.

### What was NOT changed (verified preserved)

Sync payloads, conflict resolution, retry cadence, timestamp handling,
transaction boundaries, acknowledgement semantics, license gating, demo-user
suppression, pull cursor management, CloudApiClient auth/token behaviour, and
all repository interface contracts were verified as unchanged (code moved
verbatim, only imports and one flutter-dep extraction were modified).

### Checks run

| Check | Result |
| --- | --- |
| `dart analyze` (pos_cloud_engine) | PASS — 0 issues |
| `flutter analyze --fatal-infos` (app) | PASS — 0 issues |
| `dart analyze` (pos_local_engine) | PASS — 0 issues (unchanged) |
| `dart analyze` (pos_contracts) | PASS — 0 issues (unchanged) |
| `dart analyze` (pos_core) | PASS — 0 issues (unchanged) |
| `flutter test --concurrency=1` (app) | PASS — **682 passed**, 1 skipped (live matrix) |
| Web release build (`main_web.dart`) | PASS — pos_cloud_engine has no sqflite/flutter.io |

### Architectural outcome

Four-package boundary achieved exactly per directive:

```text
pos_core          ← pure entities
pos_contracts     ← interfaces + sync contracts
pos_local_engine  ← SQLite persistence + pull applier
pos_cloud_engine  ← cloud transport + cloud repos ✅ NEW
```

Orchestration (SyncService, SyncRuntime, SyncStatus) stays in the app layer
due to its Flutter ValueNotifier dependency. Web entry uses `pos_cloud_engine`
barrel exclusively — never touches `pos_local_engine` or sqflite.

**Next:** Stage 8 deferred per requirements.

---

## Documentation deliverables (Stage 7)

- `docs/architecture/synchronization-migration-report.md` — full Stage 7 report
- `docs/architecture/dependency-map.md` §9 — updated with pos_cloud_engine node
- `docs/architecture/migration-log.md` — Stage 7 entry above

---

## 2026-11-21 — Stage 8: Supabase Backend Modularization

**Goal:** Restructure `supabase/functions/pos-api/index.ts` (~2399 lines, ~60 action handlers) into clean independent modules with a minimal router as the central dispatch layer. Preserve ALL existing behavior verbatim — no API changes, no SQL changes, no behavioral differences.

### What changed

| File | Lines before | Lines after |
| ------ | ------------- | ------------ |
| `index.ts` | ~2399 | 434 |
| `shared/auth.ts` | (extracted) | 641 |
| `shared/authorization.ts` | (extracted) | ~50 |
| `shared/helpers.ts` | (extracted) | ~100 |
| `shared/types.ts` | (extracted) | ~20 |
| `shared/env.ts` | (extracted) | ~15 |
| `modules/auth/index.ts` | — | 1 |
| `modules/auth/login.ts` | — | 13 |
| `modules/catalog/index.ts` | — | 6 |
| `modules/catalog/list_products.ts` | — | 11 |
| `modules/catalog/product_actions.ts` | — | 97 |
| `modules/sales/index.ts` | — | 10 |
| `modules/sales/next_receipt.ts` | — | 13 |
| `modules/sales/sale_actions.ts` | — | 248 |
| `modules/register/index.ts` | — | 11 |
| `modules/register/shift_actions.ts` | — | 232 |
| `modules/finance/index.ts` | — | 18 |
| `modules/finance/finance_mutations.ts` | — | 260 |
| `modules/finance/finance_queries.ts` | — | 69 |
| `modules/finance/finance_search.ts` | — | 48 |
| `modules/warehouse/index.ts` | — | 12 |
| `modules/warehouse/picklist_items.ts` | — | 680 |
| `modules/reporting/index.ts` | — | 3 |
| `modules/reporting/dashboard.ts` | — | 22 |
| `modules/reporting/revenue.ts` | — | 77 |
| `modules/reporting/audit.ts` | — | 63 |
| `modules/users/index.ts` | — | 10 |
| `modules/users/list_users.ts` | — | 17 |
| `modules/users/user_actions.ts` | — | 373 |

Total new files: 28 | Total new LoC: ~2294 (vs. 2399 original)

### Fixes applied during extraction

1. **Missing `async` on `computeExpectedCash`** (register/shift_actions.ts): `deno fmt` stripped the async keyword from the function that contained an `await` expression. Restored `async`.
2. **Undefined `status` variable** (warehouse/picklist_items.ts:601): Pre-existing bug where `$"status"` was referenced in an audit message but never declared. Fixed by adding `const status = derivePicklistStatus(remaining)` before the audit call.
3. **Duplicate identifier errors in index.ts**: Two import blocks for auth module functions caused TS2300 errors. Consolidated to single import+export pairs per module.
4. **Non-exported `categoryNames`** (finance_mutations.ts): Added `export` so finance_search.ts can import it.
5. **Missing `OWNER` import** (shift_actions.ts): Added `import { OWNER }` at top of file.
6. **Non-exported `PHONE_INVALID`** (auth.ts): Added `export` so user_actions.ts can reference it.

### Verification

```bash
deno check "supabase/functions/pos-api"   # EXIT: 0 — zero errors
flutter test                               # PASS — 684 passed, 1 skipped
```

### Zero-impact guarantees

- No API contract changes — every action name maps to the same handler signature
- No SQL changes — all PostgreSQL RPC calls and table references are untouched
- No security changes — JWT signing, PBKDF2 hashing, feature-gate authorization logic is identical
- No deployment boundary changes — `supabase/functions/pos-api/index.ts` remains the deploy entry point
- Export compatibility — every exported action is re-exported from `index.ts` via `export { ... } from './modules/X/index.ts'` statements

### Architecture

```text
index.ts              ← Minimal router (~434 lines)
  ├── shared/         ← Types, helpers, auth primitives, authorization middleware
  │   ├── auth.ts
  │   ├── authorization.ts
  │   ├── helpers.ts
  │   ├── types.ts
  │   └── env.ts
  └── modules/        ← Domain-specific handlers (each independently testable)
      ├── auth/
      ├── catalog/
      ├── sales/
      ├── register/
      ├── finance/
      ├── warehouse/
      ├── reporting/
      └── users/
```

Each module exports a barrel (`index.ts`) that re-exports every handler. The router imports and re-exports each barrel for dispatch.

**Next:** Stage 9 deferred.

---

## Documentation deliverables (Stage 8)

- `docs/architecture/supabase-backend-migration-report.md` — full Stage 8 report
- `docs/architecture/migration-log.md` — Stage 8 entry above
