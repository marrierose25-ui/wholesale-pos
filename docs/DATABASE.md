# Database Schema (SQLite, schema version 23)

> ⚠️ Partially stale. The system has 3 Edge Functions, 10 timestamped
> Supabase migrations under `backend/supabase/migrations/`, and active cloud
> sync. Verify claims against code before trusting them.

This document describes the local SQLite database used by the native app. The
Flutter application lives in `frontend/`; the database engine and all schema
definitions live in `backend/dart/pos_local_engine/lib/src/database/local_database.dart`.
The cloud/Supabase side is documented under `backend/supabase/`.

## Conventions

- **Money:** stored as `INTEGER` minor units (e.g., `1250` = 12.50 Br). Never floating point.
- **Billing quantities:** stored as `INTEGER` milliunits (e.g., `2000` = 2.000) where a numeric quantity is meaningful; `NULL` for free-text/manual-amount lines.
- **IDs:** UUID strings generated on the device.
- **Snapshots:** `sale_items` stores the product name and price at sale time; it never joins to the current product price.
- **Timestamps:** ISO-8601 strings (`DateTime.toIso8601String()`), compared as strings for ranges and sorted descending for history.
- **Foreign keys:** enabled with `PRAGMA foreign_keys = ON` on every connection.

## Tables

### `users`

- `id` TEXT PK
- `username` TEXT UNIQUE NOT NULL — the login identifier: the account's phone
  number in one canonical form (0 + 9/7 + 8 digits, e.g. `0912345678`), looked up
  case-insensitively. The seeded training account stores the literal `demo`.
- `password_hash` TEXT NOT NULL (`pbkdf2-sha256$v=1$i=<iterations>$<base64>`)
- `salt` TEXT NOT NULL (random per user)
- `role` TEXT NOT NULL (`OWNER` or `CASHIER`)
- `is_active` INTEGER NOT NULL DEFAULT 1
- `permissions` TEXT NOT NULL DEFAULT `'[]'` — feature keys a staff account may open (owners bypass it)
- `is_demo` INTEGER NOT NULL DEFAULT 0 — the permanent training account; it can never be deactivated or deleted
- `deleted_at` TEXT (nullable) — set when a *deactivated* account is deleted but still owns history
- `created_at` TEXT NOT NULL

Deleting an account is a two-step, owner-only action. An account that never recorded a sale, shift, cash movement, finance entry or void request is removed outright, which frees its phone number. One that did keeps its row with `deleted_at` set (the foreign keys would otherwise be violated and old sales would lose their cashier); such rows are hidden from the Users list, from login and from session restore, and re-creating the same phone number reuses the row so the history stays attributed. The demo account and the acting owner's own row are always refused.

### `products`

- `id` TEXT PK, `name`, `code` (UNIQUE), `category`, `unit`
- `selling_price_minor_units` INTEGER
- `is_active` INTEGER, `created_at`, `updated_at`

### `devices`

- `id` TEXT PK — stable per installation, persisted in `device_id.txt` next to the database
- `name`, `platform`, `license_key`, `last_sync_at`

### `shifts`

- `id` TEXT PK, `cashier_id` TEXT
- `opening_cash_minor_units`, `closing_cash_minor_units`, `expected_cash_minor_units`
- `status` TEXT (`OPEN`/`CLOSED`), `opened_at`, `closed_at`

A partial unique index (`one_open_shift`) plus insert/update triggers enforce at most one open shift.

### `cash_movements`

- `id` TEXT PK, `shift_id` TEXT FK -> shifts, `user_id` TEXT FK -> users
- `type` TEXT (`DEPOSIT`, `WITHDRAWAL`, `EXPENSE`), `amount_minor_units`, `reason`, `created_at`

### `sales`

- `id` TEXT PK, `receipt_number` TEXT UNIQUE (`REC-YYYYMMDD-NNNN`, sequential per day)
- `cashier_id` FK -> users, `device_id` FK -> devices, `shift_id` FK -> shifts
- `customer_name`, `payment_method` (`CASH`/`BANK`/`LOAN`). `LOAN` is recorded in history but collects no money, so it is excluded from the dashboard revenue, the reports aggregates and the register drawer math (only `CASH` feeds the drawer; `BANK`/`LOAN` never do).
- `subtotal_minor_units`, `discount_minor_units`, `total_minor_units`
- `amount_paid_minor_units`, `change_minor_units`
- `status` (`COMPLETED`/`VOIDED`), `void_reason`, `voided_at`, `voided_by`, `voided_shift_id`
- `created_at` TEXT NOT NULL (local wall clock when recorded, converted to UTC for cloud sync)
- `synced_at` TEXT (when the sale was last pulled from cloud)

**Important Note**: Offline sales are recorded with the real transaction time from `DateTime.now()` in the native application layer. When these sales are synced to the cloud, timestamps are converted to UTC format using `timestampsToUtc()`. The sync gateway transports these timestamps unchanged — it does not modify business logic timestamps.

Voids are soft deletes. `voided_shift_id` attributes the cash refund to the shift that was open when the void happened; refunds fall back to the original `shift_id` for legacy voids.

### `void_requests` (cashier-initiated, owner-approved voids)

- `id` TEXT PK
- `sale_id` TEXT FK -> sales
- `requested_by` TEXT FK -> users (the cashier who flagged the sale)
- `reason` TEXT NOT NULL
- `status` TEXT NOT NULL (`PENDING`/`APPROVED`/`REJECTED`, default `PENDING`)
- `created_at` TEXT NOT NULL
- `decided_by` TEXT FK -> users (nullable — set when the owner approves/rejects)
- `decided_at` TEXT (nullable)

A pending request leaves the sale `COMPLETED` and does not touch revenue or the cash drawer. Only an active `OWNER` may approve (which runs the normal void path, marking the sale `VOIDED` and stamping `voided_shift_id`) or reject. A direct owner void auto-settles any `PENDING` request on that sale.

### `sale_items`

- `id` TEXT PK, `sale_id` FK -> sales ON DELETE CASCADE
- `product_id` TEXT (catalog ID, or `MANUAL` for free-form items)
- `product_name_snapshot`, `unit_price_snapshot_minor_units`
- `quantity_text` TEXT NOT NULL — the operator's exact wording (e.g. `"2 boxes and 1 piece"), never parsed for billing
- `billing_quantity_milliunits` INTEGER NULL — the numeric quantity actually charged (milliunits); `NULL` when the line is billed by a manual amount instead of a quantity
- `line_discount_minor_units`, `line_total_minor_units`
- `notes` TEXT — free-text remark on the line

### `finance_categories` (money tracking)

- `id` TEXT PK, `name` TEXT NOT NULL (a person/source label)
- `created_at`, `updated_at`

### `finance_entries` (money tracking)

- `id` TEXT PK, `category_id` TEXT FK -> finance_categories
- `source` TEXT NOT NULL, `amount_minor_units` INTEGER NOT NULL (> 0)
- `description` TEXT
- `status` TEXT (`PENDING`/`COMPLETED`), `entry_date` TEXT
- `created_at`, `created_by` FK -> users, `completed_at`, `completed_by` FK -> users, `updated_at`

Finance entries are completely separate from sales: completing one never affects revenue. Access is the `finance` ("Money Tracking") tick — an active `OWNER`, or a staff account the owner ticked — enforced in the data layer (every read/write re-checks the acting row inside its own transaction), not by hiding the tab. The cloud backend (`pos-api`) applies the same rule to every `finance_*` action.

### `audit_logs`

- `id` TEXT PK, `user_id` TEXT (nullable for unknown login attempts)
- `action` TEXT (e.g. `LOGIN_SUCCEEDED`, `LOGIN_FAILED`, `SALE_COMPLETED`, `SALE_VOIDED`, `SHIFT_OPENED`, `SHIFT_CLOSED`, `CASH_MOVEMENT_ADDED`, `PASSWORD_CHANGED`, `PASSWORD_RESET`, `USER_CREATED`, `USER_ACTIVATED`, `USER_DEACTIVATED`, `USER_DELETED`, `USER_PHONE_CHANGED`, `BACKUP_EXPORTED`, `BACKUP_RESTORED`, and `FINANCE_*` for money-tracking mutations)
- `details` TEXT, `created_at` TEXT

### `counters`

- `name` TEXT PK (e.g. `receipt-20261021`), `value` INTEGER — sequential receipt allocation.

### `settings`

- `key` TEXT PK, `value` TEXT — currently stores `theme_mode` (`light`/`dark`), `remember_login` (`1`/`0`, opt-in persistent sign-in, default off) and `auth_session` (opaque JSON nonce for a persisted sign-in; never the password or hash).

### `sync_outbox` (transactional change queue for future cloud sync)

- `id` TEXT PK, `entity_type` TEXT (`sale`/`shift`/`cash_movement`/`void_request`), `entity_id` TEXT
- `operation` TEXT (`UPSERT`/`DELETE`), `payload` TEXT (serialized aggregate: the row plus any children)
- `created_at` TEXT, `synced_at` TEXT (null until pushed)
- Appended **inside the same transaction** as every business write; drained by `SyncService` only when a real `SyncBackend` is configured (ships as `NoopSyncBackend`, so it stays empty/queued and inert today). SQLite remains the single source of truth. See `docs/CLOUD_SYNC.md`. Not included in JSON backups.

## Indexes

- `one_open_shift` (partial unique on `shifts.status WHERE status = 'OPEN'`)
- `sales_shift_id`, `sales_created_at`
- `sale_items_sale_id`
- `audit_logs_created_at`
- `cash_movements_shift_id`
- `finance_entries_category_id`
- `void_requests_sale_id`, `void_requests_status`
- `sync_outbox_pending` (on `sync_outbox.synced_at`)
- `picklist_items_picklist_id` (on `picklist_items.picklist_id`)

## Migrations

`LocalDatabase.schemaVersion` (`backend/dart/pos_local_engine/lib/src/database/local_database.dart`) is the single source of truth (currently `23`). Both `onCreate` and `onUpgrade` build the same final shape:

- v2: shifts
- v3: `sales.payment_method`
- v4: `users.salt`, `sales.shift_id`, `sales.void_reason`, `cash_movements`
- v5: void attribution columns, `cash_movements.user_id`, open-shift index/triggers, shift index
- v6: rebuilds `cash_movements` with a real `user_id` foreign key, adds `counters`/`settings`, and creates all indexes/triggers on upgraded databases
- v7: rebuilds `sale_items` to replace the integer `quantity` with `quantity_text` (the old number is preserved as text), `billing_quantity_milliunits` (old quantity x 1000), and `notes`; adds `finance_categories`/`finance_entries` and the `finance_entries_category_id` index
- v8: adds the `void_requests` table with `void_requests_sale_id` and `void_requests_status` indexes
- v9: adds the `sync_outbox` table and `sync_outbox_pending` index (purely additive — no existing table or column is touched)
- v10: `finance_categories.deleted_at` (recycle bin) and `finance_entries.payment_method`
- v11: `users.permissions`, backfilled with today's cashier matrix so an upgrade never strips access
- v12: optional proof photo on `cash_movements`
- v13: `users.is_demo` (the permanent training account)
- v14: `users.deleted_at` (deleted accounts that still own history keep their row, hidden)
- v15: separate cloud-issued password hash columns so a browser-issued password never overwrites a device-set one
- v16: proof photos move from `cash_movements` into a BLOB table (`cash_movement_photos`); the old column is kept nullable for older builds
- v17: `cash_movements.finance_entry_id` so a cloud and a local collection of the same finance entry deposit once, not twice
- v18: shift drawer ownership guard — a drawer belongs to an account (`_createShiftCashierGuards`)
- v19: `users.updated_at` conflict stamp so cloud sync cannot overwrite a newer edit with an older one
- v20: `picklists` + `picklist_items` tables (warehouse picklists) with `picklist_items_picklist_id` index
- v21: picklist line pricing (unit, unit price, line total) and reusable `picklist_customers` directory
- v22: soft-delete tombstones (`deleted_at`) on `picklists` and `picklist_items` so deletes propagate through sync
- v23: creates `picklist_items_picklist_id` with `CREATE INDEX IF NOT EXISTS`, converging the index onto databases created at v20 or later (fresh installs and v20/v21/v22 upgrades never ran the `<20` branch that introduces it)

Note: every historical version from v2 upward upgrades to the current schema.
The pre-v6 ordering defect (indexes on `finance_entries` before the `<7` step
created the table) was repaired by gating each index on verified table
existence inside `_createIndexesAndTriggers`; deferred indexes are created by
the later step that creates their table, all inside the same atomic
transaction. `frontend/test/core/database/historical_fixture_migration_test.dart`
exercises every shipped schema version — v2 through v22 minus the never-released v7, v11 and v18 (v1 predates the first commit; v5 is a documented reconstruction) — via genuine and reconstructed fixture files.

**Downgrade protection:** if the on-disk `user_version` is newer than this
build's `schemaVersion`, the open is refused with
`UnsupportedDatabaseVersionException` via sqflite's `onDowngrade` hook —
before `user_version` is rewritten and inside the version transaction, so
the file, its schema and its rows are left untouched. A `.bak` safety copy is
still taken first. The app never auto-downgrades or repairs an unsupported
database; install the newer build (or restore the previous installation) and
open it again. Covered by
`frontend/test/core/database/downgrade_protection_test.dart` and the
`UnsupportedDatabaseVersionView` recovery screen
(`frontend/lib/features/startup/unsupported_database_view.dart`), which shows
the detected/supported schema versions, safety-copy status and recovery
steps — widget-tested in
`frontend/test/features/startup/unsupported_database_view_test.dart`.

**Interrupted migrations:** sqflite runs `onUpgrade` inside one transaction,
so a process killed mid-migration rolls back to the complete previous
schema. Verified by killing a real worker process at three checkpoints
(`interrupted_migration_test.dart` + `tool/db_migration_kill_worker.dart`);
the pure-Dart `package:pos_local_engine/database.dart` entry point exists so
the worker can run under the plain Dart VM.

**Native platforms:** `frontend/integration_test/database_migration_test.dart`
runs the same upgrade/downgrade checks through the real sqflite plugin.
CI jobs `android-database` (emulator) and `ios-database` (macOS simulator)
were added to `.github/workflows/ci.yml`; their first execution results are
recorded in `docs/architecture/verification-history.md`.

## Backups

`DataExporter` is owner-only and writes a JSON document at the current schema version containing every table, including `void_requests` and password hashes. `DataImporter` is owner-only, validates required fields and owner retention, writes a recovery snapshot first, replaces all rows in one transaction, and runs `PRAGMA foreign_key_check` before commit. Backups at schema versions 6 through 23 are accepted; v6 rows are normalized to the flexible-quantity shape (integer quantities become `quantity_text`/`billing_quantity_milliunits`), and `finance_categories`/`finance_entries`/`void_requests` are optional in older backups and simply restore empty. Versions older than 6 are rejected rather than guessed at. After a restore the app re-registers the current device row so new sales keep valid foreign keys.

**Restore limitation (by design):** export strips licensing and device-identity secrets — `license_code`, `activation_code`, install/hardware UUIDs, and session material are never written to the backup. A restored installation must re-activate the device and users must log in again; this is intentional (Rule S3 in `docs/architecture/architecture-rules.md`) so a backup file cannot be used to clone a license onto another machine.

## Register cash math

Expected cash for an open shift is `opening + cash_sales + deposits - withdrawals - cross_shift_cash_refunds`. `cash_sales` counts only `COMPLETED` cash sales, so a sale rung up and voided in the **same** shift is a pure no-op (it never entered cash sales, and must not be subtracted again). Only voids of a cash sale whose `shift_id` differs from the currently open `voided_shift_id` genuinely reduce the drawer. `getShiftSummary` and `closeShift` use this identical rule so the on-screen figure and the stored `expected_cash_minor_units` always agree.
