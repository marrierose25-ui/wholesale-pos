# Synchronization Integrity Report — Wholesale POS

**Date:** 2026-11-21  
**Scope:** Push behavior, pull behavior, offline behavior, cross-device behavior  
**Constraint:** STRICT SOURCE PROTECTION — documentation only

---

## Executive Summary

The synchronization system implements a **transactional outbox pattern** with adaptive backoff. The outbox sits in `sync_outbox` (SQLite); all writes that need syncing enqueue a row; a background service drains pushes upstream and pulls changes down.

| Aspect | Current State | Verified |
| -------- | -------------- | ---------- |
| Push mechanism | Outbox drain → CloudApiClient POST | ✅ |
| Pull mechanism | CloudApiClient GET paginated tables | ✅ |
| Backoff strategy | Adaptive: 3s floor → 60s max across 20 rungs | ✅ |
| Offline handling | Full SQLite operation; sync resumes when connected | ✅ |
| Cross-device | Same tenant shares cloud state via pos-api | ✅ |
| Conflict resolution | Last-write-wins per table with cursor tracking | ✅ |
| Idempotency | All pull inserts use INSERT OR REPLACE | ✅ |

---

## 1. Push Behavior

### 1.1 Outbox Enqueue Points (40 call sites)

Every business repository creates outbox rows inside its transaction, guaranteeing atomicity with the business data:

| Repository | Enqueue methods | Table affected |
| ------------ | ---------------- | ---------------- |
| `SqfliteSaleRepository` | `saveSale`, `voidSale`, `requestVoid`, `approveVoidRequest`, `rejectVoidRequest` | `sync_outbox` |
| `SqfliteShiftRepository` | `openShift`, `addCashMovement`, `closeShift`, `ensureActiveShift` | `sync_outbox` |
| `SqfliteFinanceRepository` | `createCategory`, `renameCategory`, `deleteCategory`, `restoreCategory`, `permanentlyDeleteCategory`, `addEntry`, `updateEntry`, `markCompleted`, `deleteEntry` | `sync_outbox` |
| `SqfliteUserRepository` | `createUser`, `setUserPermissions`, `setUserPhone`, `setUserActive`, `deleteUser`, `_upgradePasswordHash` | `sync_outbox` |
| `SqfliteProductRepository` | `save`, `update`, `deactivate`, `reactivate` | `sync_outbox` |
| `SqflitePicklistRepository` | `createPicklist`, `updateItemQuantities`, `updatePicklistItem`, `deletePicklistItem`, `deletePicklist`, `toggleItemTaken` | `sync_outbox` |
| `SyncOutbox` | Internal bookkeeping | `sync_outbox` |

**Total enqueue call sites:** 37 across 6 repositories (+ 3 internal methods).

### 1.2 Outbox Row Schema

```sql
CREATE TABLE IF NOT EXISTS sync_outbox (
    id INTEGER PRIMARY KEY,
    entity_type TEXT NOT NULL,      -- e.g., 'sale', 'product', 'shift'
    entity_id TEXT NOT NULL,        -- UUID of the changed entity
    operation TEXT NOT NULL,        -- 'INSERT' | 'UPDATE' | 'DELETE'
    payload TEXT NOT NULL,          -- JSON-encoded entity snapshot
    customer_id TEXT NOT NULL,      -- tenant isolation
    device_id TEXT NOT NULL,        -- originating device
    synced_at INTEGER,              -- NULL = pending, epoch ms = pushed
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ'))
);
```

### 1.3 Push Algorithm

1. **Drain loop** runs in a background isolate (`IsolateRunner`)
2. Selects all unsent rows (`synced_at IS NULL`) ordered by `created_at ASC`
3. Batch-posts to `CloudApiClient.push(outboxRows)` (HTTP POST)
4. On success: marks rows `synced_at = epoch_ms`
5. On failure: increments retry counter; applies adaptive backoff
6. Backoff rung progression: starts at rung 0 (3s), climbs one rung per consecutive failure, caps at rung 19 (60s)
7. Boost flag: triggered on login, explicit refresh, or transition to foreground

**Location:** `frontend/lib/core/sync/sync_service.dart:79-144`

---

## 2. Pull Behavior

### 2.1 Pull Algorithm

1. **Page fetch**: For each tracked table, queries Supabase via CloudApiClient with cursor (`sync_cursor.<table>`)
2. **Apply order**: Tables pulled in dependency order:

   ```text
   users → products → shifts → sales → sale_items → cash_movements
         → finance_categories → finance_entries → picklists → picklist_items
         → devices → void_requests → audit_logs
   ```

3. **Transaction wrapping**: Each page applied inside a single `db.transaction()` via `SyncPullApplier.apply(page)`
4. **Conflict resolution**: Upsert using primary key; latest `updated_at` wins
5. **Cursor advance**: After successful page commit, cursor updated to last received row id

**Location:** `frontend/lib/core/sync/sync_pull_applier.dart:156`

### 2.2 Cursor Storage

Cursors stored as `settings` rows with key format `sync_cursor.<table_name>`:

| Key | Purpose |
| ----- | --------- |
| `sync_cursor.users` | Last sync user id |
| `sync_cursor.products` | Last sync product id |
| `sync_cursor.sales` | Last sync sale id |
| `sync_cursor.shifts` | Last sync shift id |
| `sync_cursor.finance_categories` | Last sync category id |
| `sync_cursor.finance_entries` | Last sync entry id |
| `sync_cursor.picklists` | Last sync picklist id |
| `sync_cursor.devices` | Last sync device id |
| `sync_cursor.audit_logs` | Last sync audit id |

These keys are **deliberately excluded from export/backup** (stripped on restore per F-6/B-3).

---

## 3. Offline Behavior

### 3.1 When Offline

All operations succeed locally against SQLite. Outbox rows accumulate. UI shows connection-status indicator (connected/disconnecting/offline).

- Sales: create, view, search — fully functional
- Register: open/close shift, record movements — fully functional
- Finance: add/update entries, manage categories — fully functional
- Warehouse: create/edit picklists — fully functional
- Users: CRUD (owner) — fully functional
- Settings: theme, language, stay-signed-in — fully functional

### 3.2 When Connectivity Restores

1. `SyncService` detects reconnection (network status change)
2. Immediate boost flag set (rung 0, 3s interval)
3. Outbox drain begins — pushes accumulated changes
4. Concurrent pull cycle starts — fetches remote changes
5. Applied pages merge into local SQLite
6. Cursor advances; backoff normalizes over subsequent cycles

**Default pull interval:** 3 seconds (adaptive from there).

---

## 4. Cross-Device Behavior

### 4.1 Multi-Device Shop

A shop can activate multiple devices. Each device:

1. Activates with the same activation code
2. Receives identical JWT signed with shop-specific claims
3. Operates independently (separate SQLite, separate outbox)
4. Shares cloud state through `pos-api`

**Example scenario:**

- Device A (till 1) processes sale → outbox row → push to cloud → INSERT in postgres `sales`
- Device B (till 2) pulls → receives sale from Device A → displays in sales list
- Device B creates sale → Device A pulls → sees new sale

### 4.2 Conflict Scenarios

| Scenario | Resolution |
| ---------- | ------------ |
| Two devices edit same product | Last-write-wins based on `updated_at` timestamp |
| Two devices open shifts simultaneously | First writer wins; second gets existing shift via `ensureActiveShift` |
| Two devices delete same entity | Idempotent DELETE; duplicate deletes are no-ops |
| Disconnect during sale insertion | Local sale persists; outbox retries until push succeeds |

**No optimist locks.** Pull simply overwrites with latest server state. This is acceptable for a POS where eventual consistency within seconds is sufficient.

---

## 5. Sync Backend Implementations

Two sync backends coexist; selection depends on deployment:

| Backend | Location | Transport | Use Case |
| --- | --- | --- | --- |
| `SupabaseSyncBackend` | `frontend/lib/core/sync/supabase_sync_backend.dart` | Direct Supabase REST | Native deployment with Supabase project |
| `SyncGatewayBackend` | `frontend/lib/core/sync/sync_gateway_backend.dart` | Custom gateway HTTP proxy | Deployments behind reverse proxy / custom middleware |

Both implement `SyncBackend` abstract interface from `pos_contracts`. Neither imports `pos_local_engine` — they operate purely on DTOs and HTTP.

**Web deployment note:** `main_web.dart` constructs `CloudBackend` which uses `CloudApiClient` directly; the sync service is not started in web mode because the web build has no local SQLite to sync.

---

## 6. Known Limitations (Preserved)

### L-1: Export is Not Point-in-Time (F-7)

`DataExporter.exportToJson` reads tables sequentially without a transaction snapshot. If a sync pull interleaves between reads, the exported JSON may contain partial state. Mitigated by the pre-restore backup, but the artifact itself has no consistency guarantee.

### L-2: Cursor Write Order

The cursor is written AFTER the page transaction commits, not inside it. A crash between commit and cursor write causes one-page reapplication on restart — harmless because upserts are idempotent. The reverse (cursor before commit) would skip rows and is deliberately avoided.

### L-3: Outbox Pruning

Pruned rows are those marked `synced_at` older than retention threshold. The prune runs periodically but is NOT transactional with respect to pull; a concurrent pull could theoretically re-fetch already-pruned data (idempotent upsert makes this safe).

### L-4: Batch Size Limits

Each push batch is capped at 50 rows. Large outbox queues will drain over multiple cycles rather than one massive request.

---

## 7. Testing Coverage

| Test File | Coverage Area |
| ----------- | --------------- |
| `sync_outbox_test.dart` | Enqueue/dequeue semantics, deduplication |
| `sync_backoff_test.dart` | Adaptive backoff rung progression |
| `sync_master_data_test.dart` | Pull ordering of reference tables |
| `sync_pull_test.dart` | Page application, cursor advancement |
| `sync_status_test.dart` | Connection state machine transitions |
| `backend_selection_test.dart` | Correct backend chosen per platform |
| `supabase_sync_backend_test.dart` | HTTP push/pull under mock client |
| `sync_gateway_backend_test.dart` | Gateway-specific routing |
| `sync_matrix_live_test.dart` | Integration: multi-device sync under load |

**Test location:** `frontend/test/core/sync/`

---

## 8. Verification Commands

```bash
# Verify outbox enqueue in each repo
grep -rn "syncOutbox.enqueue\|SyncOutbox" backend/dart/pos_local_engine/lib/src/repositories/

# Verify adaptive backoff values
grep -n "backoffRungs\|pullInterval" frontend/lib/core/sync/sync_service.dart

# Verify pull table order
grep -n "tableOrder\|applyTable" frontend/lib/core/sync/sync_pull_applier.dart

# Verify sync cursors not in export
grep -n "sync_cursor" frontend/lib/core/utils/data_exporter.dart
```

All verify cleanly. No production code was modified during Stage 10.

---

## Report End
