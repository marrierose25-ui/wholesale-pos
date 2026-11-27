# Dependency Map — Wholesale POS

> Updated after Stage 1 (domain extraction). Current commit includes
> `backend/dart/pos_core`. See `migration-log.md` for the stage record.

Direction of arrows: `A → B` means "A imports/depends on B".
Only non-Flutter-SDK, non-pub dependencies are listed.

## 0. Domain package (`backend/dart/pos_core`)

Pure Dart, zero dependencies. All business entities live here; every layer
imports `package:pos_core/pos_core.dart`:

- `modules/sales/domain/entities/`: `Sale`, `SaleItem`, `VoidRequest`
- `modules/register/domain/entities/`: `Shift`, `CashMovement`
- `modules/catalog/domain/entities/`: `Product`
- `modules/finance/domain/entities/`: `FinanceCategory`, `FinanceEntry`
- `modules/warehouse/domain/entities/`: `Picklist`, `PicklistItem`,
  `PicklistCustomer`
- `modules/users/domain/entities/`: `User`

Entities still carry `toMap`/`fromMap` persistence serialization — documented
technical debt to be extracted in a later stage.

## 1. Layer overview

```text
main.dart (native entry)          main_web.dart (web entry)
   │                                    │
   ├─ core/database, auth, licensing    ├─ core/backend (AppBackend)
   ├─ core/repositories (direct)        │    └─ CloudBackend
   ├─ core/sync                         │         ├─ core/cloud/* (HTTP → pos-api)
   └─ features/* screens (own shell)    └─ app_shell.dart (PosRoot/AuthGate/MainScaffold)
                                              └─ features/* screens
```

There is no single composition root shared by both entries; each entry wires
its own graph.

## 2. Core internal dependencies

| File | Depends on (project imports) |
| --- | --- |
| `core/backend/app_backend.dart` | `auth/session_store`, `pos_core` (User), all 6 `repositories/*` interfaces |
| `core/backend/cloud_backend.dart` | `auth/session_store`, `cloud/*` (client + 6 repos), `pos_core` entities, all 6 `repositories/*` interfaces, **`features/web/web_activation_gate`, `features/web/web_settings_screen`** ⚠ (Stage 2) |
| `core/backend/web_local_storage.dart` | `package:web` only |
| `core/cloud/cloud_api_client.dart` | http only |
| `core/cloud/cloud_sale_repository.dart (+ reporting_repository.dart / cloud_reporting_repository.dart delegates)` | `repositories/sale_repository`, `utils/date_range`, `pos_core` (Sale/SaleItem/VoidRequest) |
| `core/cloud/cloud_shift_repository.dart` | `repositories/shift_repository`, `utils/date_range`, `pos_core` (Shift) |
| `core/cloud/cloud_{finance,picklist,product,user}_repository.dart` | matching `repositories/*` interface + `pos_core` entities |
| `core/database/local_database.dart` | sqflite/ffi, path_provider, uuid, `utils/app_logger` |
| `core/auth/session_store.dart` | sqflite (settings table) |
| `core/auth/features.dart` | flutter/cupertino only (permission registry) |
| `core/licensing/device_activation.dart` | `database/local_database`, `activation_client`, `device_fingerprint`, `license_validator` |
| `core/licensing/device_fingerprint.dart` | `database/local_database`, `license_validator` |
| `core/repositories/finance_repository.dart` | sqflite, `pos_core` (FinanceCategory/FinanceEntry/User), `sync/{sync_outbox,sync_outbox_entry}`, `utils/{date_range,money_utils}`, `repositories/sale_repository` (for `escapeLike` only) |
| `core/repositories/picklist_repository.dart` | sqflite, `pos_core` (Picklist*), `sync/*` |
| `core/repositories/product_repository.dart` | sqflite, `pos_core` (Product), `sync/*` |
| `core/repositories/sale_repository.dart (+ reporting_repository.dart / cloud_reporting_repository.dart delegates)` | sqflite, `pos_core` (Sale/SaleItem/Shift/VoidRequest), `sync/*`, `utils/{date_range,money_utils,report_filters}`, `repositories/shift_repository` (calls `getShiftSummary`) |
| `core/repositories/shift_repository.dart` | sqflite, `pos_core` (Shift/CashMovement), `sync/*`, `utils/{date_range,report_filters}` |
| `core/repositories/user_repository.dart` | sqflite, crypto/cryptography, `auth/features`, `pos_core` (User), `sync/*`, `util/{isolate_runner,phone_number}` |
| `core/sync/sync_outbox.dart` | sqflite, uuid, `sync_outbox_entry` |
| `core/sync/sync_outbox_repository.dart` | sqflite, `sync_outbox_entry` |
| `core/sync/sync_service.dart` | `sync_backend`, `sync_outbox_repository`, `sync_pull_applier`, `sync_status`, `utils/app_logger` |
| `core/sync/sync_runtime.dart` | `sync_service`, `sync_pull_applier` |
| `core/sync/sync_gateway_backend.dart` | http, `sync_backend`, `sync_outbox_entry`, `supabase_sync_backend` |
| `core/sync/sync_pull_applier.dart` | sqflite, `pos_core` (User — `cloudAccountMarker` via UserRepository), `utils/app_logger`, `sync_backend` |
| `core/sync/supabase_sync_backend.dart` | http, `dart:io`, `sync_backend`, `sync_outbox_entry` |
| `core/utils/data_exporter.dart` | sqflite, `database/local_database` |
| `core/utils/data_importer.dart` | sqflite, `database/local_database`, `data_exporter` |
| `core/utils/proof_photo_io.dart` / `_web.dart` | conditional-import pair (file_selector/image_picker vs `package:web`) |
| `core/utils/app_logger_io.dart` | `dart:io`, path_provider; facade `app_logger.dart` is Flutter-only |

## 3. Feature dependencies

| Feature file | Project imports beyond core/theme/utils |
| --- | --- |
| `features/sales/` | screens only now (`sales_screen`, `sale_details`); models moved to `pos_core` — imports `pos_core`, `repositories/*` |
| `features/dashboard/dashboard_screen.dart` | `sales_by_day_screen` (same feature) |
| `features/dashboard/sales_by_day_screen.dart` | `pos_core` (Sale) — the shared day browser other features import ⚠ |
| `features/register/register_screen.dart` | `pos_core` (Shift/VoidRequest), `register_history_screen` |
| `features/register/register_history_screen.dart` | `pos_core` (Shift), **`features/dashboard/sales_by_day_screen`**, `cash_history_screen` |
| `features/register/cash_history_screen.dart` | `pos_core` (Sale/Shift), **`features/dashboard/sales_by_day_screen`** |
| `features/audit/audit_log_screen.dart` | **`features/dashboard/sales_by_day_screen`** |
| `features/finance/*` | internal only |
| `features/warehouse/*` | internal (`warehouse_shared` helpers) |
| `features/settings/settings_screen.dart` | `devices_screen`, **`database/local_database` + `sqflite` (raw `Database` param)** ⚠ |
| `features/web/web_activation_gate.dart`, `web_settings_screen.dart` | core only; **imported BY `core/backend/cloud_backend.dart`** ⚠ |

Cross-feature edges remaining (feature → other feature):
`audit → dashboard`, `register → dashboard`. The `sales_by_day_screen` is a
de-facto shared "day browser / sale detail launcher" consumed by three
features — its extraction to a shared UI location is deferred work.

## 4. Entry-point wiring

- `main.dart` imports: `local_database`, `auth/features`, `auth/session_store`,
  `licensing/*`, `pos_core` (User), all 6 `repositories/*`, `sync/{gateway_backend,
  outbox_repository, pull_applier, runtime, service, status}`, `theme/*`,
  `utils/*`, and **every feature screen** (11 imports) to build `MainLayout`.
- `main_web.dart` imports: `app_shell`, `backend/{app_backend,cloud_backend,
  web_local_storage}`.
- `app_shell.dart` imports: `auth/{features,session_store}`, `backend/app_backend`,
  `pos_core` (User), `theme/*`, `utils/app_logger`, and 11 `features/*` screens.

## 5. Database table ownership (SQLite)

Single shared database — no per-module DBs (per Part-0 constraint).

| Table(s) | Primary writer(s) | Other direct accessors |
| --- | --- | --- |
| `users`, `settings`, `audit_logs` | `user_repository` | `session_store` (settings), `local_database` helpers, `device_fingerprint` (settings), `sync_pull_applier` (all three), `data_exporter/importer`, `sync_outbox` (reads `users` for demo check) |
| `products` | `product_repository` | `sync_pull_applier`, `data_exporter/importer` |
| `sales`, `sale_items`, `void_requests`, `counters` | `sale_repository` | `shift_repository` (reads sales for shift math), `finance_repository` (reads via join for person totals? — verify during migration), `sync_pull_applier`, `supabase_sync_backend` (entity names only), `data_exporter/importer` |
| `shifts`, `cash_movements`, `cash_movement_photos` | `shift_repository` | `sale_repository` (`getShiftSummary` call + reads), `finance_repository` (reads cash_movements/shifts), `sync_pull_applier`, `data_exporter/importer` |
| `finance_categories`, `finance_entries` | `finance_repository` | `sync_pull_applier`, `data_exporter/importer` |
| `picklists`, `picklist_items`, `picklist_customers` | `picklist_repository` | `sync_pull_applier` |
| `devices` | `local_database.registerCurrentDevice` | `sync_pull_applier`, `data_exporter/importer` |
| `sync_outbox` | `sync_outbox` (+ every repo via `enqueue`) | `sync_outbox_repository`, `sync_pull_applier` (synced_at markers), `data_importer` |

Cross-module reads that matter for future boundaries:

- `sale_repository → shifts` (shift summary for register snapshot)
- `finance_repository → cash_movements, shifts, users` (person/deposit views)
- `shift_repository → cash_movements, cash_movement_photos, users` (drawer math)
- `sync_outbox → users` (demo-ledger ownership check — deliberate central guard)

## 6. Cloud/API dependencies

- `CloudApiClient` → `pos-api` Edge Function (`action`-dispatched JSON).
- `SyncGatewayBackend` → `sync` Edge Function (license-authenticated).
- `ActivationClient` → `licensing` Edge Function.
- `pos-api` internally → Supabase Postgres via service role + `pos_*` RPCs
  (`pos_sync_apply` lives in migrations).
- `sync` Edge Function → `sync_mirror` staging tables + `pos_sync_apply` RPC.
- `licensing` Edge Function → license/seats/voucher tables + audit.

## 7. Tests → code under test

`frontend/test/` mirrors `lib/` structure (`core/...`, `features/...`). Notable:

- Repository tests exercise the **same** repository classes the app uses.
- `sync_matrix_live_test.dart` (integration) hits live endpoints — skipped
  by default (`~1` skip in baseline).
- Widget/layout tests pump real screens through the shells.

## 8. Circular dependencies

None detected at file level (Dart would still compile, but import cycles are
absent). After Stage 1 the only remaining upward edge is
`core/backend/cloud_backend.dart → features/web/*` (widgets injected into the
backend seam — scheduled for Stage 2). Everything else flows features → core,
core → `pos_core`, or core → core.

## 9. Package summary

| Package | Path | Runtime deps | Depends on |
| --------- | ------ | ------------- | ------------ |
| `pos_core` | `backend/dart/pos_core` | none | — |
| `pos_contracts` | `backend/dart/pos_contracts` | none | `pos_core` |
| `pos_local_engine` | `backend/dart/pos_local_engine` | `sqflite_common_ffi` | `pos_contracts`, `pos_core` |
| **`pos_cloud_engine`** | `backend/dart/pos_cloud_engine` | `http`, `uuid` | `pos_contracts`, `pos_core` |
| `app` | `app/` | all Flutter SDK + plugins | `pos_contracts`, `pos_local_engine`, `pos_cloud_engine` |

### `pos_cloud_engine` responsibilities

Cloud transport, cloud repositories, and sync gateway backends:

- `api/cloud_api_client.dart` — thin HTTP client over pos-api Edge Function;
  `isoInstant()` helper.
- `sync/sync_gateway_backend.dart` — license-gated push/pull through the
  Edge Function.
- `sync/supabase_sync_backend.dart` — legacy PostgREST sink (Flutter deps
  removed; platform selection parameterized by caller).
- `repositories/{sales,register,catalog,users,finance,warehouse,reporting}/cloud_*_repository.dart` —
  all 7 cloud repository implementations implementing pos_contracts interfaces.

### Import direction

```text
app ──► pos_cloud_engine ──► pos_contracts ──► pos_core
app      pos_local_engine ──► pos_contracts ──► pos_core
                                   ▲
                              pos_cloud_engine
                                 (no dep on local engine)
```

No cycle. `pos_cloud_engine` has no dependency on `pos_local_engine`; both
packages are independent consumers of `pos_contracts`. The app composes them.

### Supabase Edge Function (`supabase/functions/pos-api`)

Modularized in Stage 8 (~2399 → ~434 lines router + 28 new files):

```text
pos-api/
├── index.ts                        ← Router (JWT verify → feature-gate → switch dispatch)
├── shared/
│   ├── auth.ts                     ← JWT, PBKDF2, login throttle, demo seeding
│   ├── authorization.ts            ← feature-gate middleware (OWNER_ONLY, ACTION_FEATURES)
│   ├── helpers.ts                  ← json, str, audit, rpcFailure, strip, deSnake
│   ├── types.ts                    ← Ctx interface
│   └── env.ts                      ← requireEnv
└── modules/
    ├── auth/                       ← hasUsers, login, setupOwner, changePassword
    ├── catalog/                    ← listProducts, saveProduct, updateProduct, setProductActive
    ├── sales/                      ← nextReceiptNumber, insertSale, searchSales, void, requests
    ├── register/                   ← shift CRUD, snapshot, cash movements
    ├── finance/                    ← categories, entries, searches
    ├── warehouse/                  ← picklists, items, customers
    ├── reporting/                  ← dashboard, revenue trend, report summary, audit log
    └── users/                      ← user CRUD, permissions, phone, password reset
```

**External deps:** Only `@supabase/supabase-js@2.39.0` (ESM import from esm.sh).
**Internal deps:** Each module depends only on `shared/` utilities and types.
**Cross-module deps:** None — modules are independent; the router coordinates via switch.

#### Deploy boundary

The deployable unit is still `supabase/functions/pos-api/index.ts` (Supabase Edge Function).
The `modules/*` and `shared/*` directories are imported at runtime by Deno but not deployed separately.
Deployment command unchanged: `supabase functions deploy pos-api --no-verify-jwt`.

### Web build safety

`main_web.dart` resolves via `pos_cloud_engine` barrel — it imports no
`sqflite`, `dart:io`, or Flutter framework code from the backend packages.
Verified by the architecture test `'web entry graph never reaches the native
engine or SQLite'`.
