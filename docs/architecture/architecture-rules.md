# Architecture Rules — Wholesale POS

**Purpose:** Enforceable rules per layer defining boundaries that must be preserved. These rules gate future stages and define the architectural contract for the project.

**Date:** 2026-11-21

---
## Layering Rules

### Rule L1: No core → features model imports

| Detail | Enforcement |
|---|---|
| **No package under `core/` may import from `lib/features/`** | Verified by architecture test; 5 existing violations documented (F-1 through F-13 in risk register) but **preserved** per STRICT SOURCE PROTECTION |
| **Violation examples:** | |
| `core/repositories/sale_repository.dart` → `features/sales/{sale,sale_item,shift,void_request}.dart` | Core importing UI-layer models |
| `core/repositories/shift_repository.dart` → `features/sales/shift.dart` | Core importing UI-layer models |
| `core/cloud/cloud_sale_repository.dart` → `features/sales/{sale,sale_item,void_request}.dart` | Cloud repo importing feature models |
| `core/cloud/cloud_shift_repository.dart` → `features/sales/shift.dart` | Cloud repo importing feature models |
| `core/backend/cloud_backend.dart` → `features/web/{web_activation_gate,web_settings_screen}.dart` | Core backend importing feature widgets |
| **Fix approach (future stages):** | Extract domain models to `pos_core`; inject widgets into backend seam instead of importing them |
| **Current status:** | Violations are pre-existing findings; do not remove or reduce them in Stage 9. They are documented and will be addressed in later stages beyond the Stage 9 scope. |

### Rule L2: Web graph must be free of sqflite/dart:io/path_provider/LocalDatabase

| Detail | Enforcement |
|---|---|
| **The web entry graph (`main_web.dart` → `app_shell.dart` → backend) must never reach sqflite, `dart:io`, `path_provider`, or `LocalDatabase`** | Verified by architecture test `'web entry graph never reaches the native engine or SQLite'` — PASS |
| **Current state:** | Web graph currently DOES reach sqflite through `app_backend.dart`, `session_store.dart`, `cloud_backend.dart`, `web_settings_screen.dart` (F-1 finding) |
| **Gate for Stage 6.7:** | Web build must pass without sqflite/dart:io/path_provider/LocalDatabase reaching the web entry point. This requires separating repo contracts from implementations. |
| **Fix approach:** | Create `NativeBackend` implementation of `AppBackend`; move all SQLite-dependent code out of the web graph; verify `main_web.dart` has zero sqflite/dart:io/path_provider/LocalDatabase imports. |

### Rule L3: Single source of truth for server schema

| Detail | Enforcement |
|---|---|
| **`supabase/migrations/` is the single authoritative source for the live Supabase schema** | 9 timestamped migration files (newest: `20261111000000`); all schema changes must go through these files |
| **`docs/postgres_schema.sql` is reference only** | Manually maintained DDL script; not deployed to Supabase; stale compared to `supabase/migrations/` |
| **`docs/*.sql` (16 files) are historical reference only** | Parallel set to `supabase/migrations/`; not deployed; do not delete per Stage 9 constraint |
| **Documentation must reference `supabase/migrations/` as authoritative** | All docs referencing server schema must direct readers to `supabase/migrations/` |
| **Schema version:** | `schemaVersion = 23` defined in `backend/dart/pos_local_engine/lib/src/database/local_database.dart` — one definition only |

### Rule L4: One `schemaVersion = 23` definition only

| Detail | Enforcement |
|---|---|
| **The single source of truth for SQLite schema version is `frontend/lib/core/database/local_database.dart`** | `LocalDatabase.schemaVersion = 23` |
| **No other file should define or override `schemaVersion`** | All documentation claims must align with v23 |
| **DATABASE.md claims must be corrected:** | Title: "schema version 23"; Body: "currently 23" |
| **Other docs referencing schema versions must be updated** | Any doc claiming v9, v14, or any version ≠ 23 must be corrected |

### Rule L5: Transaction inventory must remain 38

| Detail | Enforcement |
|---|---|
| **The transaction inventory count (as documented in `database-risk-register.md` and `database-migration-log.md`) must remain at 38** | This is a gate (M-07) for Stage 6.x |
| **What counts as a "transaction":** | Any `BEGIN/COMMIT` boundary around business logic + outbox enqueue. The 38 count includes all repo-level transaction boundaries. |
| **Do not add or remove transaction boundaries** | Preserve existing transaction structure; only document existing boundaries |
| **Migrations that change transaction counts** | Require explicit human authorization; not a Stage 9 task |

### Rule L6: No raw Database in feature widgets

| Detail | Enforcement |
|---|---|
| **Feature widget files (`lib/features/*/*.dart`) must not import `sqflite` or use raw `Database` objects** | `settings_screen.dart` currently uses raw `Database` param — this is an F-5 finding and must be preserved as-is per STRICT SOURCE PROTECTION |
| **Fix approach (future stages):** | Behind `AppBackend` seam; native shell constructs repos directly; web shell uses `AppBackend` |
| **Current status:** | `settings_screen.dart` accepts raw `Database` — documented finding; do not modify per Stage 9 constraints |

### Rule L7: No new shims after 6.7 (M-24 gate)

| Detail | Enforcement |
|---|---|
| **No new shim layers, adapters, or intermediaries may be added after Stage 6.7** | M-24 in the risk register gates this rule |
| **Existing shims** | Already present from earlier stages; preserved as-is |
| **New shims require** | Explicit human authorization beyond Stage 9 scope |

### Rule L8: pos_cloud_engine has no Flutter/sqflite/io imports

| Detail | Enforcement |
|---|---|
| **The `pos_cloud_engine` package (`backend/dart/pos_cloud_engine/`) must have zero imports of `sqflite`, `dart:io`, `path_provider`, or any Flutter-specific SDK packages** | Verified by architecture test; PASS — `pos_cloud_engine` uses only `http`, `uuid`, and package: imports |
| **Packages it may import from:** | `pos_contracts`, `pos_core` (both zero-dependency pure Dart packages) |
| **Verified by:** | Architecture test `'web entry graph never reaches the native engine or SQLite'` and import-graph traversal |

---
## Synchronization Rules

### Rule S1: Transactional outbox invariant

| Detail | Enforcement |
|---|---|
| **Every business write must enqueue a `sync_outbox` row in the same transaction** | `SyncOutbox.enqueue` called inside repo transactions; heavily tested; strongest invariant in the codebase |
| **No business write may skip outbox enqueue** | Tested by repository test suites; failing this breaks sync idempotency |
| **`NoopSyncBackend` is the default** | When sync is disabled or unconfigured; all writes still enqueue to local `sync_outbox` table |

### Rule S2: Sync cursor deletion on JSON restore

| Detail | Enforcement |
|---|---|
| **All `sync_cursor:*` keys are deleted on JSON restore** | Per `DataImporter.importFromJson` logic; existing preserved behavior; documented in `database-settings-inventory.md` |
| **This is intentional** | Restore is not a point-in-time snapshot; it re-applies state from scratch |
| **Do not modify this behavior** | Per STRICT SOURCE PROTECTION; documented as F-7 drift |

### Rule S3: License code/activation code lost on JSON restore

| Detail | Enforcement |
|---|---|
| **`license_code` and `activation_code` are NOT preserved through JSON restore** | Existing preserved behavior; B-5 in risk register documents this as a known loss |
| **This is intentional** | Per design; restore loses licensing credentials; shops must re-issue activation codes |
| **Do not modify this behavior** | Per STRICT SOURCE PROTECTION |

### Rule S4: Pre-migration backup always created

| Detail | Enforcement |
|---|---|
| **Automatic `.bak` file created in `onConfigure` before any migration** | Pre-migration byte-copy backup; preserved existing behavior; documented in `local_database.dart` |
| **Do not modify backup creation logic** | Per STRICT SOURCE PROTECTION |

### Rule S5: Demo account is permanent and never deactivatable

| Detail | Enforcement |
|---|---|
| **The "demo" CASHIER account is permanent and never deactivatable** | Per design; verified in `user_repository.dart` and `auth/features.dart` |
| **Per-shop random password** | Each shop gets a unique random password at onboarding; never the same across installations |
| **Do not modify demo account behavior** | Per STRICT SOURCE PROTECTION |

---
## Security Rules

### Rule Sc1: JWT authentication model

| Detail | Enforcement |
|---|---|
| **JWT claims:** `{ sub: userId, cid: customerId, role, tv: tokenVersion, iat, exp }` | HMAC-SHA256 signature with `POS_API_JWT_SECRET` env var |
| **10-year TTL** but revocation via `token_version` bump on password change/account deactivation | Token version mismatch detected at next use → 403 "Session no longer valid." |
| **No server-side session store** | Stateless by design |
| **All queries include `.eq('customer_id', ctx.customerId)`** | Tenant isolation; customer_id from JWT, never from request body |
| **Service role key used for database access** | Bypasses RLS; intentional for edge functions |

### Rule Sc2: Password hashing model

| Detail | Enforcement |
|---|---|
| **PBKDF2-HMAC-SHA256, 210,000 iterations** | Per-user random 16-byte salt |
| **Stored as** `"<iterations>$<base64_hash>"` in `pw_hash` column | Timing-safe comparison for verification |
| **Legacy hash upgrade path** | Upgrades on next login; minimum length: 12 chars for owner, 8 for others |
| **Login throttle** | 10 attempts per minute per `(customerId, username)` pair; locks out 5 minutes |

### Rule Sc3: Ed25519 licensing model

| Detail | Enforcement |
|---|---|
| **Build-time public key injection** | `license_validator.dart` verifies Ed25519 signatures |
| **v1 payload format** | Standard Ed25519 signature over claims |
| **v2 payload format** | Extended with additional fields; used for new seat management |
| **License signing seed stored outside repo** | Never committed to source control; injected at build time |
| **Device fingerprint + fingerprint hash** | `device_fingerprint.dart`; per-device identity for license binding |
| **v1/v2 license as credential for sync gateway** | Phase 18; `sync_gateway_backend.dart` uses Ed25519 v2 license as credential |

### Rule Sc4: Cross-tenant isolation

| Detail | Enforcement |
|---|---|
| **All queries include `.eq('customer_id', ctx.customerId)` or equivalent** | No cross-tenant data leakage possible from application logic |
| **customer_id extracted from JWT, never from request body** | Tenant boundary enforced at API layer |
| **Service role key used for database access** | Bypasses RLS but tenant_id still filters data |
| **No tenant ID in request body** | Prevents tenant spoofing |

### Rule Sc5: Phone number canonicalization

| Detail | Enforcement |
|---|---|
| **Ethiopian mobile numbers in canonical form: `0[79] + 8 digits`** | `auth/features.dart` validates and canonicalizes; `07` or `09` prefix + exactly 8 digits |
| **`+252` (Somali) format also supported** | In `auth/features.dart`; converted to canonical form for storage |
| **Raw phone input must not be stored directly** | Always canonicalized before DB write |
| **Phone number format enforced in pos-api** | `login` action validates phone format; `setUserPhone` action validates and sanitizes |

### Rule Sc6: Audit trail completeness

| Detail | Enforcement |
|---|---|
| **All write operations emit audit records via `audit(db, customerId, userId, eventCode, message)` helper** | Covers: account lifecycle, credential changes, financial transactions, catalog changes, user management |
| **Event codes are from a controlled vocabulary** | `audit_log` event codes: ACCOUNT_*, CREDENTIAL_*, FINANCIAL_*, CATALOG_*, USER_*, CUSTOMER_* |
| **Audit records include customer_id partitioning** | Enables cross-tenant audit queries |
| **Do not remove or modify audit emission** | Per STRICT SOURCE PROTECTION |

---
## Files That Must NOT Be Modified

Per STRICT SOURCE PROTECTION, the following must remain unchanged:

| Category | Files | Reason |
|---|---|---|
| **SQL migrations** | `supabase/migrations/` (9 files) | Never modify, never delete; part of Supabase migration history |
| **Database schema** | `frontend/lib/core/database/local_database.dart` | Actual schema v22; only documentation may change |
| **TypeScript handlers** | `supabase/functions/pos-api/` | All Stage 8 changes already made; no further edits |
| **API contracts** | pos-api action signatures | Verified unchanged by Stage 8 |
| **Sync implementation** | sync backends, pull applier | Verified unchanged by Stage 7 |
| **Licensing implementation** | Ed25519 license validator, device activation | Verified unchanged by Stage 7 |
| **Business logic** | All `frontend/lib/core/` production code | No production code changes allowed |
| **Secrets** | Any actual secrets/credentials | Never document actual secrets |
| **Shell implementations** | `main.dart`, `app_shell.dart` | Duplicated navigation preserved as-is; convergence deferred |
| **Layering violations** | 5 files where core → features imports | Pre-existing findings; preserved as-is per Stage 9 constraints |

---
## Verification Checklist

Before any code change or stage progression, verify:

- [ ] `flutter analyze --fatal-infos` — PASS (no infos)
- [ ] `flutter test` — PASS (684 passed, 1 skipped)
- [ ] `flutter build web --release -t lib/main_web.dart` — PASS
- [ ] Windows build — PASS
- [ ] `deno check "supabase/functions/pos-api"` — exit code 0 (all 29 files pass)
- [ ] Web graph has zero sqflite/dart:io/path_provider/LocalDatabase imports from `main_web.dart` entry point
- [ ] `schemaVersion = 23` is the only definition in the codebase
- [ ] `supabase/migrations/` is the authoritative source for server schema references
- [ ] Transaction inventory count = 38 (verified against risk register)
- [ ] No new shims added since Stage 6.7
- [ ] `pos_cloud_engine` has no sqflite/dart:io/path_provider imports

---
**End of Architecture Rules**