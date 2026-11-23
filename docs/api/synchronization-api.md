# Synchronization API

The POS sync system implements a transactional outbox pattern. All writes enqueue a row in `sync_outbox`; a background service drains pushes upstream and pulls delta pages downstream.

## Push Protocol

### Outbox Row Schema

```sql
CREATE TABLE sync_outbox (
    id            INTEGER PRIMARY KEY,
    entity_type   TEXT NOT NULL,     -- e.g. 'sale', 'product'
    entity_id     TEXT NOT NULL,     -- UUID of changed entity
    operation     TEXT NOT NULL,     -- 'INSERT' | 'UPDATE' | 'DELETE'
    payload       TEXT NOT NULL,     -- JSON-encoded entity snapshot
    customer_id   TEXT NOT NULL,     -- tenant isolation key
    device_id     TEXT NOT NULL,     -- originating device UUID
    synced_at     INTEGER,           -- NULL = pending; epoch_ms = pushed
    created_at    TEXT NOT NULL      -- ISO-8601 creation timestamp
);
```

### Push Endpoint

```
POST /functions/v1/sync/push
Authorization: Bearer <jwt>
Content-Type: application/json

{
  "rows": [
    { "entity_type": "sale", "operation": "INSERT", "payload": {...}, ... },
    ...
  ]
}
```

**Response:**
```json
{ "ok": true, "accepted": 3, "rejected": 0 }
```

Rejected rows include an `entity_id` + reason. The client should retry after fixing the underlying issue (typically a schema drift or missing foreign key).

### Backoff Algorithm

| Rung | Interval | Condition |
|------|----------|-----------|
| 0 | 3 s | Fresh connect / boost |
| 1 | 4 s | 1 consecutive failure |
| 2 | 6 s | 2 failures |
| ... | ... | Each rung adds ~1 s |
| 19 (cap) | 60 s | Sustained outage |

Boost triggers: login, explicit refresh button, app comes to foreground.

## Pull Protocol

### Pull Endpoint

```
GET /functions/v1/sync/pull?table=sales&cursor=12345&limit=100
Authorization: Bearer <jwt>
```

**Parameters:**
- `table` — one of the tracked tables (see cursor table below).
- `cursor` — last seen primary-key value (integer). Pass `0` for a full initial load.
- `limit` — page size; max 500.

**Response:**
```json
{
  "ok": true,
  "data": {
    "rows": [...],
    "cursor": 12399,
    "hasMore": false
  }
}
```

### Pull Order (Dependency-Aware)

Tables are pulled in this order so foreign keys resolve on first pass:

1. `users`
2. `products`
3. `shifts`
4. `sales`
5. `sale_items`
6. `cash_movements`
7. `finance_categories`
8. `finance_entries`
9. `picklists`
10. `picklist_items`
11. `devices`
12. `void_requests`
13. `audit_logs`

Within each table, rows are sorted by primary key ascending. The pull-applier applies each page inside a single database transaction before advancing the cursor.

## Cursor Storage

Each table's last-seen cursor is persisted as a `settings` row:

| Key | Stores |
|-----|--------|
| `sync_cursor.users` | Last user id pulled |
| `sync_cursor.products` | Last product id pulled |
| `sync_cursor.sales` | Last sale id pulled |
| `sync_cursor.shifts` | Last shift id pulled |
| `sync_cursor.finance_categories` | Last category id pulled |
| `sync_cursor.finance_entries` | Last entry id pulled |
| `sync_cursor.picklists` | Last picklist id pulled |
| `sync_cursor.devices` | Last device id pulled |
| `sync_cursor.audit_logs` | Last audit id pulled |

These keys are deliberately excluded from data exports (stripped on restore).

## Conflict Resolution

- **Upsert strategy:** Rows are identified by primary key. The remote version (latest `updated_at`) wins on conflict.
- **No optimist locking:** The pull simply overwrites stale local rows. Acceptable for POS workloads where eventual consistency within seconds suffices.
- **Idempotency:** All insertions use `INSERT OR REPLACE` so repeated pulls of the same page are safe.

## Offline Behavior

When offline:
- All business operations succeed against the local SQLite database.
- `sync_outbox` accumulates unsent mutations.
- The UI displays a connection-status indicator: `Connected` / `Connecting` / `Offline`.
- No data is lost; retries begin automatically when connectivity resumes.

## Deletion Propagation

Soft-deleted entities carry a `deleted_at` timestamp. The pull applier treats a row with `deleted_at IS NOT NULL` as a delete signal and removes the corresponding local row (cascading to dependent child rows such as `sale_items` on `sales` delete).
