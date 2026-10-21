# Database Schema (SQLite, schema version 6)

This document describes the local SQLite database used by the desktop app. There is no backend in this repository.

## Conventions

- **Money:** stored as `INTEGER` minor units (e.g., `1250` = 12.50 ETB). Never floating point.
- **IDs:** UUID strings generated on the device.
- **Snapshots:** `sale_items` stores the product name and price at sale time; it never joins to the current product price.
- **Timestamps:** ISO-8601 strings (`DateTime.toIso8601String()`), compared as strings for ranges and sorted descending for history.
- **Foreign keys:** enabled with `PRAGMA foreign_keys = ON` on every connection.

## Tables

### `users`
- `id` TEXT PK
- `username` TEXT UNIQUE NOT NULL (case-insensitive login)
- `password_hash` TEXT NOT NULL (`pbkdf2-sha256$v=1$i=<iterations>$<base64>`)
- `salt` TEXT NOT NULL (random per user)
- `role` TEXT NOT NULL (`OWNER` or `CASHIER`)
- `is_active` INTEGER NOT NULL DEFAULT 1
- `created_at` TEXT NOT NULL

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
- `customer_name`, `payment_method` (`CASH`/`BANK`)
- `subtotal_minor_units`, `discount_minor_units`, `total_minor_units`
- `amount_paid_minor_units`, `change_minor_units`
- `status` (`COMPLETED`/`VOIDED`), `void_reason`, `voided_at`, `voided_by`, `voided_shift_id`
- `created_at`, `synced_at`

Voids are soft deletes. `voided_shift_id` attributes the cash refund to the shift that was open when the void happened; refunds fall back to the original `shift_id` for legacy voids.

### `sale_items`
- `id` TEXT PK, `sale_id` FK -> sales ON DELETE CASCADE
- `product_id` TEXT (catalog ID, or `MANUAL` for free-form items)
- `product_name_snapshot`, `unit_price_snapshot_minor_units`, `quantity`
- `line_discount_minor_units`, `line_total_minor_units`

### `audit_logs`
- `id` TEXT PK, `user_id` TEXT (nullable for unknown login attempts)
- `action` TEXT (e.g. `LOGIN_SUCCEEDED`, `LOGIN_FAILED`, `SALE_COMPLETED`, `SALE_VOIDED`, `SHIFT_OPENED`, `SHIFT_CLOSED`, `CASH_MOVEMENT_ADDED`, `PASSWORD_CHANGED`, `PASSWORD_RESET`, `USER_CREATED`, `USER_ACTIVATED`, `USER_DEACTIVATED`, `BACKUP_EXPORTED`, `BACKUP_RESTORED`)
- `details` TEXT, `created_at` TEXT

### `counters`
- `name` TEXT PK (e.g. `receipt-20261021`), `value` INTEGER — sequential receipt allocation.

### `settings`
- `key` TEXT PK, `value` TEXT — currently stores `theme_mode` (`light`/`dark`).

## Indexes

- `one_open_shift` (partial unique on `shifts.status WHERE status = 'OPEN'`)
- `sales_shift_id`, `sales_created_at`
- `sale_items_sale_id`
- `audit_logs_created_at`
- `cash_movements_shift_id`

## Migrations

`LocalDatabase.schemaVersion` is the single source of truth (currently `6`). Both `onCreate` and `onUpgrade` build the same final shape:

- v2: shifts
- v3: `sales.payment_method`
- v4: `users.salt`, `sales.shift_id`, `sales.void_reason`, `cash_movements`
- v5: void attribution columns, `cash_movements.user_id`, open-shift index/triggers, shift index
- v6: rebuilds `cash_movements` with a real `user_id` foreign key, adds `counters`/`settings`, and creates all indexes/triggers on upgraded databases

## Backups

`DataExporter` is owner-only and writes a JSON document at the current schema version containing every table, including password hashes. `DataImporter` is owner-only, validates required fields and owner retention, writes a recovery snapshot first, replaces all rows in one transaction, and runs `PRAGMA foreign_key_check` before commit. Older schema versions are rejected rather than guessed at. After a restore the app re-registers the current device row so new sales keep valid foreign keys.
