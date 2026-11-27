# Feature Ownership — Wholesale POS

**Purpose:** Map every feature to its owning module/repository, showing database table ownership, feature-gate vs owner-only action mapping, layering violations, and duplicated shell/navigation implementations.

**Date:** 2026-11-21
**Status:** Updated to reflect current architecture (Stages 1-8 complete); historical violations documented separately.

---

## Architecture Overview (Current)

### Two-Entry-Point Shell Architecture

The application uses a **single shared shell** (`frontend/lib/app_shell.dart` ~1026 lines) with **two entry points**:

| Entry Point | File | Backend | Purpose |
| --- | --- | --- | --- |
| Native | `frontend/lib/main.dart` (~512 lines) | `NativeBackend` | Wraps SQLite repos from `pos_local_engine`; full offline capability |
| Web/PWA | `frontend/lib/main_web.dart` (~55 lines) | `CloudBackend` | HTTP REST calls to `pos-api` Edge Function; no local database |

**Note:** The native shell constructs repositories directly within `NativeBackend`, while the web shell uses `CloudBackend` that implements the same `AppBackend` contract. Both share `PosRoot`, `AuthGate`, and `MainScaffold` from `app_shell.dart`.

### AppBackend Seam

The abstract `AppBackend` class in `backend/dart/pos_contracts/lib/src/backend/app_backend.dart` defines the storage contract. Concrete implementations:

- `frontend/lib/core/backend/native_backend.dart` — Native/SQLite
- `frontend/lib/core/backend/cloud_backend.dart` — Web/HTTP
- `frontend/lib/core/backend/web_local_storage.dart` — Web browser storage helper

---

## Table Ownership Map (SQLite) — As of Schema v22

| Table(s) | Owning Repository | Cross-Module Access | Sync Applicable | Export/Import Status |
| --- | --- | --- | --- | --- |
| `users` | `UserRepository` (`SqfliteUserRepository` in `pos_local_engine`) | `session_store` (settings), `sync_pull_applier` (all three), `sync_outbox` (demo check) | ✅ Yes | ✅ Exported/Imported (except pw_hash/salt stripped) |
| `products` | `ProductRepository` (`SqfliteProductRepository`) | `sync_pull_applier`, `data_exporter/importer` | ✅ Yes | ✅ Exported/Imported |
| `sales`, `sale_items`, `counters` | `SaleRepository` (`SqfliteSaleRepository`) | `shift_repository` (summary), `finance_repository` (joins), `sync_pull_applier`, `data_exporter/importer` | ✅ Yes | ✅ Exported/Imported |
| `shifts`, `cash_movements`, `cash_movement_photos` | `ShiftRepository` (`SqfliteShiftRepository`) | `sale_repository` (summary), `finance_repository` (reads), `sync_pull_applier`, `data_exporter/importer` | ✅ Yes | ✅ Exported/Imported |
| `finance_categories`, `finance_entries` | `FinanceRepository` (`SqfliteFinanceRepository`) | `sync_pull_applier`, `data_exporter/importer` | ✅ Yes | ✅ Exported/Imported |
| `picklists`, `picklist_items`, `picklist_customers` | `PicklistRepository` (`SqflitePicklistRepository`) | `sync_pull_applier` | ✅ Yes | ✅ Exported/Imported |
| `stores`, `store_inventory` | `InventoryRepository` (`SqfliteInventoryRepository`) | `sync_pull_applier` | ✅ Yes | ✅ Exported/Imported |
| `devices` | `LocalDatabase.registerCurrentDevice()` | `sync_pull_applier`, `data_exporter/importer` | ✅ Yes (device id only) | ✅ Exported/Imported |
| `audit_logs` | `SaleRepository`, `ShiftRepository`, `FinanceRepository` (write via audit helper) | `sync_pull_applier`, `data_exporter/importer` | ✅ Yes | ✅ Exported/Imported |
| `settings` | `SettingsSessionStore` (wraps `LocalDatabase` KV helpers) | All features (read), owner only (write) | ❌ No | ✅ Exported/Imported (excluding 5 stripped keys) |
| `sync_outbox` | `SyncOutbox` (enqueue from all repos) | `SyncOutboxRepository`, `SyncPullApplier` | ✅ Yes | ❌ Not in export (plumbing table) |

**Business Tables:** users, products, sales, sale_items, shifts, cash_movements, cash_movement_photos, finance_categories, finance_entries, picklists, picklist_items, picklist_customers, stores, store_inventory, devices, audit_logs, counters

**Infrastructure Tables:** settings, sync_outbox

**Source Path:** All repositories are now in:

- `backend/dart/pos_local_engine/lib/src/repositories/` — SQLite implementations
- `backend/dart/pos_cloud_engine/lib/src/repositories/` — HTTP implementations
Domain entities (`Sale`, `SaleItem`, `VoidRequest`, `Shift`, `Product`, `User`, `FinanceEntry`, `FinanceCategory`, `Picklist`, `PicklistItem`, `PicklistCustomer`, `Device`) live in `backend/dart/pos_core/lib/src/modules/`.

**Cloud ownership (Stage 1 consolidation):** `pos_cloud_engine` is the single
authoritative implementation of cloud repositories and `pos-api` transport
(`CloudApiClient` + the six domain repositories + `CloudReportingRepository`).
`frontend/lib/core/cloud/` duplicate implementations were deleted;
`CloudBackend` (`frontend/lib/core/backend/cloud_backend.dart`) is now only the
web composition adapter — it builds the package repositories over one shared
`CloudApiClient`, owns `WebSessionStore`/localStorage/activation/device-id
wiring, and keeps `reporting => null` (reporting stays reachable through
`CloudSaleRepository`'s compatibility delegates; a dedicated
`CloudReportingRepository` injection is a documented future improvement, not a
behavior change).

---

## Layering Violations — Historical (Pre-Stages 1-3)

**Status:** ALL FIVE violations below are **HISTORICAL FINDINGS** from pre-migration code. All violating files were deleted during the Stages 1-3 domain extraction. The current architecture has **no active layering violations**.

| Historical File | Import Path | Status | Resolution |
| --- | --- | --- | --- |
| `core/repositories/sale_repository.dart` | → `features/sales/{sale,sale_item,shift,void_request}.dart` | **DELETED** — file moved to `pos_local_engine` | Fixed by extracting domain models to `pos_core` |
| `core/repositories/shift_repository.dart` | → `features/sales/shift.dart` | **DELETED** | Fixed by extracting `Shift` to `pos_core` |
| `core/cloud/cloud_sale_repository.dart` | → `features/sales/{sale,sale_item,void_request}.dart` | **DELETED** | Fixed by using `pos_core` domain models |
| `core/cloud/cloud_shift_repository.dart` | → `features/sales/shift.dart` | **DELETED** | Fixed by using `pos_core` domain models |
| `core/backend/cloud_backend.dart` | → `features/web/{web_activation_gate,web_settings_screen}.dart` | **DELETED** | Fixed by constructing widgets in shell instead |

**Current Status:** All domain models (`Sale`, `SaleItem`, `VoidRequest`, `Shift`, `Product`, `User`, etc.) now reside in `backend/dart/pos_core/lib/src/modules/{sales,register,catalog,users,finance,warehouse}/domain/entities/`. The `pos_core` package has zero dependencies on `features/`. Feature widgets depend on `pos_core` for models — correct direction.

**Verification:** Grep search for `import.*features` or `import.*Features` in `backend/dart/` and `frontend/lib/core/` returns zero matches. The `app_shell.dart` imports `features/*` for UI widgets, which is the correct direction (features depend on app, not vice versa).

---

## Shell Implementation — Corrected Understanding

Contrary to earlier documentation, there is **ONE shared shell** with **TWO entry points**:

| Aspect | Native Shell | Web Shell |
| --- | --- | --- |
| Entry Point | `lib/main.dart` (~512 lines) | `lib/main_web.dart` (~55 lines) |
| Shared Code | `lib/app_shell.dart` (~1026 lines) | `lib/app_shell.dart` (same file) |
| Backend | `NativeBackend` → `pos_local_engine` SQLite | `CloudBackend` → `pos-api` HTTP |
| Navigation | `_NavItem`, `_ShellDestination` defined in main.dart | SAME — defined in app_shell.dart |
| Device License | Required, Ed25519 | None (tenant from activation code) |
| Offline | Full SQLite | None (all API calls) |

**Convergence Status:** The `app_shell.dart` is used by both entry points. Feature additions only require changes to `app_shell.dart`; the entry points simply construct different backend implementations. Full seam convergence (where NativeBackend uses pos_contracts interfaces) is deferred to later stages.

---

## Feature-Gate Authorization Matrix (`ACTION_FEATURES`)

| Action(s) | Required Permission | Feature | API Module |
| --- | --- | --- | --- |
| `dashboard_*` | `dashboard` | Dashboard | pos-api |
| `list_products`, `save_product`, `update_product`, `deactivate_product`, `reactivate_product`, `next_receipt_number`, `insert_sale`, `request_void` | `pos` | Products / Sales | pos-api |
| `get_shift`, `ensure_shift`, `register_snapshot`, `open_shift`, `close_shift`, `add_cash_movement`, `shift_summary` | `register` | Shift / Register | pos-api |
| `finance_*` | `finance` | Finance | pos-api |
| `list_picklists`, `get_picklist_items`, `create_picklist`, `update_picklist_items`, `update_picklist_item`, `toggle_picklist_item` | `warehouse` | Picklists/Customers | pos-api |
| `delete_picklist_item`, `delete_picklist`, `get_customers`, `add_customer` | `warehouse_fill` | Picklists/Customers | pos-api |
| `list_stores`, `create_store`, `delete_store`, `list_inventory`, `create_inventory_product` | `inventory` | Inventory | pos-api |
| `search_sales`, `void_sale`, `list_void_requests`, `approve_void`, `reject_void` | `history`, `register_history` | Sales history | pos-api |
| `report_summary`, `revenue_trend` | `reports` | Reporting | pos-api |
| `list_users`, `create_user`, `set_user_permissions`, `set_user_phone`, `reset_password`, `set_user_active`, `delete_user` | `users` | Staff management | pos-api |
| `list_audit` | `audit` | Audit log | pos-api |
| `shift_history`, `list_cash_movements` | `register_history` | Shift history / Cash movements | pos-api |

---

## Owner-Only Actions (`OWNER_ONLY`)

Actions that reject any non-owner role with HTTP 403:

| Action(s) | Description | Enforced By |
| --- | --- | --- |
| `create_user`, `set_user_permissions`, `set_user_phone`, `reset_password`, `set_user_active`, `delete_user` | User management | pos-api middleware |
| `void_sale`, `approve_void`, `reject_void` | Void sales | pos-api middleware |

---

## Settings Keys Per Feature

| Key | Retained in Export/Import | Feature(s) Using | Write Permission | Read Permission |
| --- | --- | --- | --- | --- |
| `theme_mode` | ✅ | Settings screen | Write: owner | Read: all |
| `remember_login` | ✅ | Settings screen | Write: owner | Read: all |
| `demo_password_version` | ✅ | Auth, settings | Write: owner | Read: all |
| `login_guard:dashboard` | ✅ | Dashboard | Write: owner | Read: owner |
| `login_guard:register` | ✅ | Register | Write: owner | Read: owner |
| `login_guard:finance` | ✅ | Finance | Write: owner | Read: owner |
| `login_guard:warehouse` | ✅ | Warehouse | Write: owner | Read: owner |
| `login_guard:sales` | ✅ | Sales | Write: owner | Read: owner |
| `login_guard:reports` | ✅ | Reports | Write: owner | Read: owner |
| `login_guard:audit` | ✅ | Audit | Write: owner | Read: owner |
| `sync_cursor:*` (22 keys) | ❌ Deleted on restore | Sync | Write: system | Read: system |
| `license_code` | ❌ Lost on restore | Licensing | Write: owner | Read: owner |
| `activation_code` | ❌ Lost on restore | Licensing | Write: owner | Read: owner |
| `device_hw_uuid` | ❌ Lost on restore | Licensing | Write: system | Read: system |
| `device_install_uuid` | ❌ Lost on restore | Licensing | Write: system | Read: system |
| `auth_session` | ❌ Lost on restore | Auth | Write: system | Read: system |

**Export behavior:** `DataExporter.exportToJson` deliberately strips 5 keys (license_code, activation_code, device_hw_uuid, device_install_uuid, auth_session). Password hashes and salts are also stripped per F-8.

---

## Export/Restore Behavior Summary

- **JSON export** (`frontend/lib/core/sync/data_exporter.dart`): Reads all settings keys, deliberately strips 5 keys (license_code, activation_code, device_hw_uuid, device_install_uuid, auth_session). Password hashes and salts are also stripped.
- **JSON restore** (`frontend/lib/core/sync/data_importer.dart`): Writes all non-stripped keys. sync_cursor keys are deleted on restore. Known losses: license_code and activation_code (B-5).
- **Migration-safety backup**: Automatic `.bak` created in `onConfigure` before any migration.

---

## Feature Cross-Referencing

| Feature | Owning Module | Depends On | Is Depended On By |
| --- | --- | --- | --- |
| **Sales** | `SaleRepository` | `ShiftRepository`, `FinanceRepository` | Dashboard, Register, Audit |
| **Register** | `ShiftRepository` | `SaleRepository` | Dashboard, Audit |
| **Dashboard** | Multiple repos read | `SaleRepository`, `FinanceRepository`, `PicklistRepository`, `ShiftRepository` | Register, Audit |
| **Finance** | `FinanceRepository` | `SaleRepository` (via joins) | Settings |
| **Warehouse/Picklists** | `PicklistRepository` | None (local-only) | — |
| **Users/Staff** | `UserRepository` | `SessionStore`, `LocalDatabase` | pos-api, settings |
| **Settings** | `LocalDatabase` KV | All features (read) | All features (write via owner) |
| **Auth** | `UserRepository` + `SessionStore` | pos-api (JWT verification) | All features |
| **Licensing** | `LocalDatabase` + Ed25519 | pos-api | — |

---

## Notes

1. **Single source of truth for server schema:** `supabase/migrations/` (10 timestamped files). `docs/postgres_schema.sql` is reference only.
2. **Domain entities in pos_core:** `Sale`, `SaleItem`, `VoidRequest`, `Shift`, `Product`, `User`, `FinanceEntry`, `FinanceCategory`, `Picklist`, `PicklistItem`, `PicklistCustomer`, `Device` — all in `backend/dart/pos_core/lib/src/modules/`.
3. **No active layering violations:** All 5 previously-documented violations were from deleted pre-migration files; resolved in Stages 1-3.
4. **Feature-gate vs owner-only:** `ACTION_FEATURES` controls feature-based access; `OWNER_ONLY` actions (6 actions) always reject non-owners.
5. **Shell convergence:** `app_shell.dart` is shared; entry points differ only in backend construction. Full seam convergence deferred.
6. **Settings export:** 5 keys stripped from JSON export; password hashes/salts also stripped.
