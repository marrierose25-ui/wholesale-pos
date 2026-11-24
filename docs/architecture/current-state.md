# Current-State Architecture Audit

Audit date: 2026-11-18. Baseline commit: `64ff4fe` on `main` (clean tree).
Method: full source inspection of `app/lib`, `app/test`, `app/tools`,
`supabase/functions`, `supabase/migrations`, `docs/`, `.github/workflows` —
not just existing documentation.

## 1. Repository inventory

### Flutter application (`app/`)

| Area | Contents | Size |
|---|---|---|
| Entry points | `lib/main.dart` (native, 1351 lines), `lib/main_web.dart` (PWA, 32 lines) | 2 files |
| Shells | `lib/app_shell.dart` (web shell: `PosRoot`/`AuthGate`/`MainScaffold`, 983 lines) and a **parallel native shell inside `main.dart`** (`WholesalePosApp`/`LicenseWrapper`/`AuthWrapper`/`MainLayout`, ~1100 lines) | 2 implementations |
| `lib/core/` | `auth/` (2), `backend/` (3: `AppBackend` seam, `CloudBackend`, `web_local_storage`), `cloud/` (7: `CloudApiClient` + 6 cloud repositories), `database/` (`local_database.dart`, 1066 lines — open/migrate/backup + settings + device registration helpers), `licensing/` (4), `models/` (7 — but the sales-domain models are NOT here), `repositories/` (6 SQLite repos + interfaces), `sync/` (10 files), `theme/` (2), `util/` + `utils/` (split, 12 files) | ~45 files |
| `lib/features/` | `audit`, `auth`, `dashboard` (+ `sales_by_day_screen` shared widget), `finance` (3), `licensing`, `register` (3), `reports`, `sales` (4 models + 2 screens), `settings` (2), `users`, `warehouse` (5), `web` (2) | ~25 files |
| Tests | `frontend/test/` — 80+ test files across core repos, sync, licensing, and widget/layout matrices | large suite |
| Tooling | `frontend/tools/` (build/deploy/verify PS scripts, k6/stress scripts, license key tools), `app/tool/seed_cloud.dart` (throwaway live-API harness) | mixed Dart + PS + JS + SQL |

### Backend (`supabase/`)

| Function | File | Size | Role |
|---|---|---|---|
| `pos-api` | `functions/pos-api/index.ts` (~210-line router) + `modules/*` (7 domains) + `shared/*` (auth, authorization, helpers, env) + `tests/*` | Modular Edge Function — `index.ts` is the production entry point: CORS/JSON guards → JWT verify → `checkAuthorization` (actor load, token_version, OWNER_ONLY, ACTION_FEATURES) → `ACTIONS` dispatch table → domain module handlers. Action contract unchanged. `Deno.serve` is guarded by `import.meta.main` so tests can import `handleRequest` with an injected DB. |
| `sync` | `functions/sync/index.ts` | 576 lines | License-gated push/pull gateway; stages into `sync_mirror`, `pos_sync_apply` RPC replays to canonical tables |
| `licensing` | `functions/licensing/index.ts` | 358 lines | Device activation/seats, vouchers, Ed25519 license issuance helpers |

Migrations: `supabase/migrations/` (9 timestamped files, newest 2026-11-11)
plus a parallel set of manually-applied scripts in `docs/*.sql` (17 files).

### CI/CD (`.github/workflows/`)

- `ci.yml` — gate: `flutter analyze --fatal-infos`, `flutter test`,
  `flutter build web --release -t lib/main_web.dart` on push/PR.
- `build.yml` — SonarQube scan (tests with coverage).
- `deploy-web.yml` — PWA build via `tools/build_release.ps1 web` → Cloudflare
  Pages on `main`.

## 2. How the app actually works today

### Two parallel application shells

- **Native** (`main.dart`): `_startup()` opens `LocalDatabase`, constructs all
  six repositories inline, runs license activation (`LicenseWrapper`), auth
  (`AuthWrapper`), then `MainLayout` — its own nav/destination implementation
  with private `_NavItem`/`_ShellDestination` classes.
- **Web/PWA** (`main_web.dart` → `app_shell.dart`): constructs `CloudBackend`
  (implements `AppBackend`), shows activation gate + `AuthGate` + `MainScaffold`
  — a *second*, independent nav/destination implementation with its own
  `_NavItem`/`_ShellDestination`.

Both shells render the same `features/*` screens. `AppBackend` is the storage
seam **only the web shell uses**; the native shell never touches it and builds
repositories directly. There is no `NativeBackend` implementation of
`AppBackend`.

### Data access

- Six repository interfaces in `core/repositories/` with SQLite
  implementations (`Sqflite*Repository` via factory constructors) plus six
  `Cloud*Repository` HTTP clients in `core/cloud/` that call `pos-api` actions.
- Repositories own their SQL **and** business rules: permission re-checks
  inside transactions, outbox enqueue inside the same transaction, audit-row
  writes, demo-account ledger filtering (`report_filters.dart` SQL fragments).
- `SaleRepository` is also the reporting surface: `getRevenueTrend`,
  `getDashboardStats`, `getAuditLogs`, `getProductSalesSummary`,
  `getCashierPerformance`, `getTodayRevenue` live on the sales repository.
- Cross-repository calls exist inside the data layer:
  `SaleRepository` instantiates `ShiftRepository(_db).getShiftSummary(...)`;
  `FinanceRepository` borrows `SaleRepository.escapeLike`.
- `UserRepository` (1267 lines) combines: PBKDF2 password hashing (with isolate
  offload + legacy migration), login attempt guards persisted in `settings`,
  user CRUD + permissions + phone canonicalization, demo-user provisioning,
  credential sync markers, and audit writes.

### Database

- One SQLite file, `schemaVersion = 22`, all 18 tables in one database
  (users, products, devices, shifts, cash_movements, cash_movement_photos,
  sales, sale_items, finance_categories, finance_entries, void_requests,
  picklists, picklist_items, picklist_customers, audit_logs, counters,
  settings, sync_outbox).
- `LocalDatabase` owns open/migrate plus shared helpers (`getSetting`,
  `setSetting`, `registerCurrentDevice`, pre-migration byte-copy backup).
- Tables have real FK/unique/index/trigger enforcement, including
  `prevent_second_open_shift_*` and `shifts_cashier_must_exist_*` triggers.

### Sync

- Transactional outbox: every business write enqueues a `sync_outbox` row in
  the same transaction (`SyncOutbox.enqueue` inside repo transactions).
  `SyncOutbox._ledgerOwners` hard-codes which tables/columns identify the
  operator so demo-account money never leaves the device.
- `SyncService` drains pending entries with backoff; `SyncGatewayBackend`
  posts batches to the `sync` Edge Function using the signed license as the
  only credential (no embedded secret in shipped builds).
- `SyncPullApplier` (1531 lines) is the single writer for cloud→local
  application: it writes directly into nearly every table inside pull
  transactions and reconciles outbox `synced_at` markers.
- `SyncPullApplier` imports `UserRepository` only for the
  `cloudAccountMarker` constant.

### Security boundaries

- Ed25519 license verification (`license_validator.dart`), device
  fingerprint/activation (`device_activation.dart`, `device_fingerprint.dart`),
  activation client → `licensing` function.
- `pos-api` verifies JWT per request, checks `token_version` revocation,
  `OWNER_ONLY` action set, and `ACTION_FEATURES` permission gating server-side.
- Passwords: PBKDF2-HMAC-SHA256, per-user salt, role-based minimum length,
  legacy-hash upgrade path, login cooldown persisted across restarts.
- Web build carries no `dart:io`/sqflite — enforced by separate entry point,
  verified by CI's web build.

## 3. Confirmed architectural problems

### Layering violations (core → features)

Domain models live under `lib/features/sales/` but are imported by core:

- `core/repositories/sale_repository.dart` → `features/sales/{sale,sale_item,shift,void_request}.dart`
- `core/repositories/shift_repository.dart` → `features/sales/shift.dart`
- `core/cloud/cloud_sale_repository.dart` → `features/sales/{sale,sale_item,void_request}.dart`
- `core/cloud/cloud_shift_repository.dart` → `features/sales/shift.dart`
- `core/backend/cloud_backend.dart` → `features/web/{web_activation_gate,web_settings_screen}.dart`

The `Sale`, `SaleItem`, `Shift`, `VoidRequest` classes are pure Dart models
with no Flutter imports — they are domain models misplaced in the UI layer.
`cloud_backend.dart` (a core seam) importing feature screens inverts the
dependency direction the `AppBackend` doc comment claims to establish.

### Duplicated shell/navigation

`main.dart` and `app_shell.dart` each implement their own navigation model
(`_NavItem`, `_ShellDestination`, tab switching, mobile pill nav vs sidebar).
Feature additions must be wired twice; drift is already possible.

### Mixed responsibilities

- `main.dart` (1351 lines): DI wiring + sync loop bootstrap + license gate +
  auth gate + entire native shell UI.
- `local_database.dart` (1066 lines): connection management, 22-version
  migration chain, pre-migration backup, open-shift repair, settings KV,
  device registration.
- `user_repository.dart` (1267 lines): hashing, guards, CRUD, demo user,
  sync markers, audit — at least four responsibilities.
- `sale_repository.dart` (1047 lines): writes + outbox + void workflow +
  reporting/analytics queries.
- `pos-api/index.ts` (~210 lines): thin router only — transport guards, JWT
  verification, authorization gates, and the `ACTIONS` dispatch table. All
  ~60 action implementations live in `modules/*` (auth, catalog, sales,
  register, finance, warehouse, reporting, users) over `shared/*` helpers.
- `sync_pull_applier.dart` (1531 lines): per-entity appliers for all 12
  entity types in one class.

### Feature→feature coupling

- `features/audit/audit_log_screen.dart` → `features/dashboard/sales_by_day_screen.dart`
- `features/register/{cash_history,register_history}_screen.dart` → `features/dashboard/sales_by_day_screen.dart` and `features/sales/*`
- `features/dashboard/sales_by_day_screen.dart` → `features/sales/{sale,sale_details}.dart`
- `sales_by_day_screen` is effectively a shared sale-detail/day browser
  living inside `dashboard` — register, audit, and cash-history all import it.

### Storage seam asymmetry

`AppBackend` abstracts storage for web only; native constructs repositories
directly in `main.dart` and `settings_screen.dart` still accepts a raw
`Database` (`sqflite` import in a feature file). Backup/restore
(`data_exporter`/`data_importer`) reads/writes every table directly —
appropriate for a backup tool, but it is a third full-schema writer alongside
repositories and the pull applier.

### Model/serialization coupling

- `core/models/*` are clean for finance/picklist/product/user, but the
  sales-domain models bypass `core/models` entirely (see layering violation).
- Local repos map rows↔models with hand-written `toMap`/`fromMap`; cloud repos
  map API JSON↔the same models. Serialization logic is duplicated per
  repository pair rather than centralized — acceptable today, but any model
  move must update both sides atomically.

### Documentation drift (confirmed)

- `docs/DATABASE.md` title says "schema version 9" and body says "currently
  `14`"; actual `LocalDatabase.schemaVersion = 22`.
- `docs/CLOUD_SYNC.md` references `docs/postgres_schema.sql` as the server DDL
  source, but live migrations live in `supabase/migrations/`; `docs/*.sql`
  contains a parallel set of manually-applied scripts — two sources of truth
  for server schema.
- `supabase/supabase/.temp/` — stray nested temp directory inside the
  supabase folder.

### Minor

- `lib/core/util/` vs `lib/core/utils/` split (isolate_runner + phone_number in
  `util/`; everything else in `utils/`) — cosmetic but confusing.
- `tool/seed_cloud.dart` sits beside `tools/` (singular vs plural) — a
  throwaway harness mixed with shipping scripts.
- `sync_gateway_backend.dart` and `supabase_sync_backend.dart` coexist;
  gateway is the shipped path, supabase backend remains for tests/private
  opt-in.

## 4. What is already good (must be preserved)

- Transactional outbox with in-transaction enqueue — the strongest invariant
  in the codebase, heavily tested.
- `SyncBackend`/`SyncPullApplier`/`SyncService` separation; keyset cursor
  paging; idempotent push; append-only ledger rules; demo-account isolation
  enforced in `SyncOutbox` centrally.
- `AppBackend` seam concept (storage/platform abstraction) — right idea,
  currently only adopted by web.
- Pre-migration byte-copy backup; migration tests; demo-data isolation tests.
- Server-side authorization is real (JWT + token_version + OWNER_ONLY +
  ACTION_FEATURES), not UI-gated.
- CI gate (`analyze --fatal-infos` + tests + web build) is genuinely enforced.
- Conditional web/native entry points correctly keep `dart:io` out of the
  browser graph.
- Extensive test coverage of money math, sync, licensing, migrations,
  layout matrices.

## 5. Baseline results (Part 1, before any refactoring)

| Check | Command | Result |
|---|---|---|
| Analyze | `flutter analyze --fatal-infos` | **PASS** — no issues (62.7s) |
| Tests | `flutter test` | **PASS** — 637 passed, 1 skipped, 0 failed (~4:53) |
| Web release | `flutter build web --release -t lib/main_web.dart` | **PASS** (211.6s) |
| Windows release | `powershell -File tools/build_release.ps1 windows` | **PASS** — built `wholesale_pos_app.exe` with license/API/sync dart-defines + post-build cleanliness check (62.4s compile) |
| Backend live checks | `tools/verify_pos_api.ps1`, `verify_phone_login.ps1`, `verify_delete_user.ps1` | **NOT RUN** — require live Supabase credentials/project access; not part of local baseline |
| SQL verifiers | `docs/*verify*.sql`, `smoke_test.sql` | **NOT RUN** — designed for the Supabase SQL editor against the live project |
| Edge function typecheck | `supabase/functions/tsconfig.json` exists; no local Deno/deno task in CI | **NOT RUN** — no deno toolchain invoked by CI; functions are deployed manually via dashboard paste per `docs/LICENSING.md` |

All baseline failures: **none**. Everything green that can run locally.

## 6. Files requiring migration (preview — detail in migration-plan.md)

1. `lib/features/sales/{sale,sale_item,shift,void_request}.dart` → domain models layer.
2. `lib/core/repositories/*`, `lib/core/cloud/*` — update imports; later split reporting out of `SaleRepository`, auth out of `UserRepository`.
3. `lib/core/backend/cloud_backend.dart` — remove `features/web` imports (inject widgets instead).
4. `lib/main.dart` + `lib/app_shell.dart` — converge on one shell/navigation implementation.
5. `lib/features/settings/settings_screen.dart` — remove raw `Database` dependency behind the backend seam.
6. ~~`supabase/functions/pos-api/index.ts` — split into internal feature modules without changing the action contract.~~ Done (Stage 2): `index.ts` is the modular router; implementations live in `modules/*` + `shared/*`; behaviour locked by `pos-api/tests/`.
7. `supabase/functions/sync/index.ts`, `licensing/index.ts` — same internal organization treatment.
8. `lib/core/database/local_database.dart` — separate schema/migrations from runtime helpers.
9. `lib/core/sync/sync_pull_applier.dart` — per-entity applier modules.
10. `docs/*.sql` vs `supabase/migrations/` — reconcile single source of truth.
