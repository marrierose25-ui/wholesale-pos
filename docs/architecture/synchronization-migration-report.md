# Stage 7: Synchronization Architecture and Cloud Backend Modularization — Migration Report

**Date:** 2026-11-21  
**Status:** ✅ COMPLETE  
**Tests:** 682 passed, 1 skipped (live matrix)  
**Analysis:** All packages clean

---

## Executive Summary

Successfully migrated all cloud communication, synchronization transport, and cloud repository implementations from the application layer into a new independent Dart package `pos_cloud_engine`. The migration preserved 100% of business logic, synchronization behavior, conflict resolution, retry semantics, and payload structures. No functional changes were made.

---

## Target Architecture Achieved

```text
backend/dart/
├── pos_core/          — Pure domain entities (unchanged)
├── pos_contracts/     — Repository interfaces + sync contracts (unchanged)
├── pos_local_engine/  — SQLite persistence + local sync applier (unchanged)
└── pos_cloud_engine/  — NEW: cloud adapters, repos, sync gateway ✅
```

### Package Boundaries

| Package | Responsibility | Dependencies |
| --------- | --------------- | -------------- |
| `pos_core` | Domain models (Sale, User, Product, etc.) | None (pure Dart) |
| `pos_contracts` | Interfaces (SyncBackend, Repository traits), SyncOutboxEntry | pos_core |
| `pos_local_engine` | SQLite DB, SyncOutbox, SyncPullApplier, CloudSyncPuller | pos_contracts, sqflite |
| `pos_cloud_engine` | CloudApiClient, Cloud*Repositories, SyncGatewayBackend, SupabaseSyncBackend | pos_contracts, http, uuid |
| `app` (Flutter) | UI, SyncService orchestration, AppBackend composition | pos_contracts, pos_local_engine, **pos_cloud_engine** |

---

## Files Migrated

### From `frontend/lib/core/cloud/` → `pos_cloud_engine/lib/src/api/`

| Original Path | New Path | Lines | Status |
| -------------- | ---------- | ------- | -------- |
| `cloud_api_client.dart` | `src/api/cloud_api_client.dart` | 114 | ✅ Moved verbatim |
| *(deleted)* | *(new location above)* | — | Removed from app |

### From `frontend/lib/core/cloud/` → `pos_cloud_engine/lib/src/repositories/`

| Original Path | New Path | Repository Interface | Status |
| -------------- | ---------- | --------------------- | -------- |
| `cloud_sale_repository.dart` | `repositories/sales/cloud_sale_repository.dart` | SaleRepository | ✅ Moved |
| `cloud_shift_repository.dart` | `repositories/register/cloud_shift_repository.dart` | ShiftRepository | ✅ Moved |
| `cloud_product_repository.dart` | `repositories/catalog/cloud_product_repository.dart` | ProductRepository | ✅ Moved |
| `cloud_user_repository.dart` | `repositories/users/cloud_user_repository.dart` | UserRepository | ✅ Moved |
| `cloud_finance_repository.dart` | `repositories/finance/cloud_finance_repository.dart` | FinanceRepository | ✅ Moved |
| `cloud_picklist_repository.dart` | `repositories/warehouse/cloud_picklist_repository.dart` | PicklistRepository | ✅ Moved |
| `cloud_reporting_repository.dart` | `repositories/reporting/cloud_reporting_repository.dart` | ReportingRepository | ✅ Moved |

### From `frontend/lib/core/sync/` → `pos_cloud_engine/lib/src/sync/`

| Original Path | New Path | Class | Status |
| -------------- | ---------- | ------- | -------- |
| `sync_gateway_backend.dart` | `src/sync/sync_gateway_backend.dart` | SyncGatewayBackend | ✅ Moved |
| `supabase_sync_backend.dart` | `src/sync/supabase_sync_backend.dart` | SupabaseSyncBackend | ✅ Moved + Refactored |

---

## Code Modifications

### 1. SupabaseSyncBackend — Flutter Dependency Removal

**What changed:** Removed `import 'package:flutter/foundation.dart'` and `import 'dart:io' show Platform` from class body.

**Why:** `pos_cloud_engine` must not depend on Flutter or dart:io to maintain web compatibility.

**How it was handled:**

- Extracted `fromEnvironment()` factory (which used kIsWeb + Platform) out of the class
- Made `selectBackend()` a pure static method that accepts parameters instead of reading environment
- The app layer now calls `SupabaseSyncBackend.selectBackend(url, key, unsafeAllowEmbed, isMobile)` directly
- Platform detection remains in `main.dart` where Flutter is available

**Business logic impact:** NONE. Same selection logic, same behavior, just parameterized differently.

### 2. Import Path Updates

All cloud repositories moved from flat `lib/core/cloud/` to nested `lib/src/repositories/{category}/`. Relative imports updated:

```dart
Before: import 'cloud_api_client.dart';
After:  import '../../api/cloud_api_client.dart';

Before: import 'cloud_reporting_repository.dart';
After:  import '../reporting/cloud_reporting_repository.dart';
```

**Function bodies:** 100% unchanged. Only import paths modified.

### 3. App Layer Import Consolidation

**Before:**

```dart
import '../cloud/cloud_api_client.dart';
import '../cloud/cloud_finance_repository.dart';
import '../cloud/cloud_picklist_repository.dart';
// ... 7 individual imports
```

**After:**

```dart
import 'package:pos_cloud_engine/pos_cloud_engine.dart';
// Barrel export provides all classes:
// CloudApiClient, CloudSaleRepository, CloudShiftRepository,
// CloudProductRepository, CloudUserRepository, CloudFinanceRepository,
// CloudPicklistRepository, CloudReportingRepository,
// SyncGatewayBackend, SupabaseSyncBackend
```

Same for `main.dart`:

```dart
// Before:
import 'core/sync/sync_gateway_backend.dart';

// After:
import 'package:pos_cloud_engine/pos_cloud_engine.dart';
```

### 4. Test File Updates

Updated 5 test files to import from `pos_cloud_engine` package instead of deleted app-layer paths:

- `test/core/cloud/cloud_repositories_test.dart`
- `test/core/sync/backend_selection_test.dart`
- `test/core/sync/supabase_sync_backend_test.dart`
- `test/core/sync/sync_gateway_backend_test.dart`
- `test/core/sync/sync_status_test.dart`
- `test/integration/sync_matrix_live_test.dart`

Added architecture test verifying `pos_cloud_engine` has no Flutter/sqlite/io imports.

---

## What Was NOT Changed (Functionality Preservation)

The following were verified as **untouched** in migration:

| Category | Items Verified Unchanged |
| ---------- | ------------------------- |
| Sync payloads | JSON structure for push/pull requests/responses |
| Conflict resolution | Parent-before-child ordering, placeholder creation |
| Retry behavior | Adaptive cadence (floor 3s, boost 30s, backoff rungs 10/30/60s) |
| Timestamp handling | UTC normalization, ISO-8601 formatting via `isoInstant()` |
| Transaction boundaries | Outbox enqueued inside DB transactions |
| Acknowledgement semantics | Per-entry ack: 'applied'/'stored'/'rejected' vs 'failed' |
| License gating | SyncGatewayBackend license provider pattern |
| Demo suppression | SyncOutbox._ledgerOwners demo user check |
| Pull cursor management | Keyset cursors persisted in SQLite settings |
| CloudApiClient behavior | Bearer token auth, device_id stamping, timeout |
| Repository contracts | All Cloud*Repository classes still implement same interfaces |

---

## Dependency Verification

### No Circular Dependencies

```text
pos_cloud_engine → pos_contracts → pos_core  ✅ (no cycle)
pos_cloud_engine ↛ pos_local_engine          ✅ (clean separation)
app → pos_cloud_engine                        ✅ (one-way import)
app → pos_local_engine                        ✅ (existing, unchanged)
```

### Web Build Safety

```text
main_web.dart imports:
  - CloudBackend (from app layer)
  - CloudBackend uses pos_cloud_engine (barrel export)
  - pos_cloud_engine has NO dart:io, NO sqflite, NO flutter imports  ✅
```

Verified by architecture test: `pos_cloud_engine/lib` contains zero occurrences of:

- `package:flutter`
- `package:sqflite`
- `dart:io`
- `/features/` or `/presentation/`

---

## Quality Gates

| Gate | Result |
| ------ | -------- |
| `dart analyze` (pos_cloud_engine) | ✅ 0 issues |
| `flutter analyze` (app) | ✅ 0 issues |
| `dart analyze` (pos_local_engine) | ✅ 0 issues (unchanged) |
| `dart analyze` (pos_contracts) | ✅ 0 issues (unchanged) |
| `dart analyze` (pos_core) | ✅ 0 issues (unchanged) |
| `flutter test --concurrency=1` | ✅ **682 passed**, 1 skipped |
| Business logic audit | ✅ All sync behavior preserved |

---

## New Package Structure: pos_cloud_engine

```text
backend/dart/pos_cloud_engine/
├── pubspec.yaml                    # name: pos_cloud_engine, deps: pos_core, pos_contracts, http, uuid
├── lib/
│   ├── pos_cloud_engine.dart       # Barrel export
│   └── src/
│       ├── api/
│       │   └── cloud_api_client.dart    # CloudApiClient, CloudApiException, isoInstant()
│       ├── sync/
│       │   ├── sync_gateway_backend.dart # License-gated sync through Edge Function
│       │   └── supabase_sync_backend.dart # Legacy PostgREST sink (refactored, no flutter)
│       └── repositories/
│           ├── sales/cloud_sale_repository.dart
│           ├── register/cloud_shift_repository.dart
│           ├── catalog/cloud_product_repository.dart
│           ├── users/cloud_user_repository.dart
│           ├── finance/cloud_finance_repository.dart
│           ├── warehouse/cloud_picklist_repository.dart
│           └── reporting/cloud_reporting_repository.dart
└── test/
    └── (empty — tests remain in app package for Flutter integration)
```

---

## Files Deleted from App Layer

The following files were removed after successful migration and import verification:

- `frontend/lib/core/cloud/cloud_api_client.dart`
- `frontend/lib/core/cloud/cloud_finance_repository.dart`
- `frontend/lib/core/cloud/cloud_picklist_repository.dart`
- `frontend/lib/core/cloud/cloud_product_repository.dart`
- `frontend/lib/core/cloud/cloud_reporting_repository.dart`
- `frontend/lib/core/cloud/cloud_sale_repository.dart`
- `frontend/lib/core/cloud/cloud_shift_repository.dart`
- `frontend/lib/core/cloud/cloud_user_repository.dart`
- `frontend/lib/core/sync/supabase_sync_backend.dart`
- `frontend/lib/core/sync/sync_gateway_backend.dart`

The `frontend/lib/core/cloud/` directory was removed (now empty). The `frontend/lib/core/sync/` directory retains only orchestration files:

- `sync_service.dart` — adaptive cadence, single-flight guard (kept in app due to Flutter ValueNotifier dep)
- `sync_runtime.dart` — composition root helper (kept in app)
- `sync_status.dart` — pure data class (kept in app per requirements)

---

## Acceptance Criteria Met

| Criterion | Status | Evidence |
| ----------- | -------- | ---------- |
| Synchronization responsibilities have clear ownership | ✅ | pos_cloud_engine owns transport; pos_local_engine owns persistence; app owns orchestration |
| Local sync persistence belongs to local engine | ✅ | SyncOutbox, SyncPullApplier, CloudSyncPuller all remain in pos_local_engine |
| Cloud transport belongs to cloud engine | ✅ | CloudApiClient, SyncGatewayBackend, SupabaseSyncBackend all in pos_cloud_engine |
| Orchestration clearly separated | ✅ | SyncService/SyncRuntime stay in app with Flutter dependencies |
| Entity application logic modular | ✅ | SyncPullApplier in pos_local_engine; cloud repos in pos_cloud_engine |
| Cloud repositories separated from frontend | ✅ | All 7 Cloud*Repository classes moved out of frontend/lib/ |
| Native and cloud use shared contracts | ✅ | Both implement pos_contracts interfaces |
| No circular dependencies | ✅ | Verified by architecture test + manual inspection |
| Web does not import local engine | ✅ | main_web.dart uses pos_cloud_engine barrel; no sqflite/flutter.io |
| All tests pass | ✅ | 682 passed, 1 skipped |
| All analyzers clean | ✅ | 4 packages, 0 issues each |
| No functionality changed | ✅ | Verbatim code moves; only import paths and flutter deps removed |

---

## Next Steps (Not Started — Per Requirements)

- [ ] Stage 8: Application Shell Convergence (deferred per directive)
- [ ] Run Windows/Web/Android builds (deferred — requires user confirmation)
- [ ] Update graphify knowledge graph (`graphify update .`)

---

**Migration complete. Zero behavioral changes. All 682 tests green.**
