-- Wholesale POS — PostgreSQL mirror schema (server side)
-- ---------------------------------------------------------------------------
-- This is the cloud-side counterpart to the local SQLite database (schema v9).
-- It is a MIRROR, not a second source of truth: the desktop app keeps writing
-- to SQLite and appends rows to its transactional `sync_outbox`; a worker
-- replays those rows into the tables below with idempotent upserts.
--
-- Design rules baked in here (see docs/CLOUD_SYNC.md for the full rationale):
--   * Money stays BIGINT in minor units (x100). Billing quantity stays
--     BIGINT in milliunits (x1000). Never floats.
--   * Ids are client-generated UUIDv4 (TEXT/uuid), so a device can insert
--     offline and the id is already globally unique before it ever syncs.
--   * Every synced row carries `origin_device_id` (who wrote it) and
--     `received_at` (when the server saw it). Those two columns plus the
--     client `updated_at`/`created_at` are what resolve duplicates and
--     order events. They are NOT used to merge concurrent edits, because the
--     business runs a SINGLE writer per register — see the doc.
--   * `counters`, `settings` and `sync_outbox` are intentionally NOT mirrored:
--     receipt counters must never cross a network boundary, and settings and
--     the outbox are per-device plumbing.
-- ---------------------------------------------------------------------------

BEGIN;

CREATE EXTENSION IF NOT EXISTS "pgcrypto";  -- gen_random_uuid (unused today, kept for future server rows)

CREATE TABLE IF NOT EXISTS users (
  id                uuid PRIMARY KEY,
  username          text UNIQUE NOT NULL,
  password_hash     text NOT NULL,          -- PBKDF2-SHA256, format 'pbkdf2-sha256$v=1$i=...'
  salt              text NOT NULL,
  role              text NOT NULL CHECK (role IN ('OWNER', 'CASHIER')),
  is_active         boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL,
  origin_device_id  uuid,
  received_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS devices (
  id            uuid PRIMARY KEY,
  name          text NOT NULL,
  platform      text NOT NULL,
  license_key   text,
  last_sync_at  timestamptz,
  received_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS products (
  id                          uuid PRIMARY KEY,
  name                        text NOT NULL,
  code                        text UNIQUE NOT NULL,
  category                    text,
  unit                        text NOT NULL,
  selling_price_minor_units   bigint NOT NULL CHECK (selling_price_minor_units >= 0),
  is_active                   boolean NOT NULL DEFAULT true,
  created_at                  timestamptz NOT NULL,
  updated_at                  timestamptz NOT NULL,
  origin_device_id            uuid,
  received_at                 timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS shifts (
  id                        uuid PRIMARY KEY,
  cashier_id                uuid NOT NULL REFERENCES users(id),
  opening_cash_minor_units  bigint NOT NULL,
  closing_cash_minor_units  bigint,
  expected_cash_minor_units bigint,
  status                    text NOT NULL CHECK (status IN ('OPEN', 'CLOSED')),
  opened_at                 timestamptz NOT NULL,
  closed_at                 timestamptz,
  origin_device_id          uuid,
  received_at               timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS cash_movements (
  id                  uuid PRIMARY KEY,
  shift_id            uuid NOT NULL REFERENCES shifts(id),
  type                text NOT NULL,
  amount_minor_units  bigint NOT NULL,
  reason              text,
  created_at          timestamptz NOT NULL,
  user_id             uuid REFERENCES users(id),
  origin_device_id    uuid,
  received_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS sales (
  id                        uuid PRIMARY KEY,
  receipt_number            text UNIQUE NOT NULL,
  cashier_id                uuid NOT NULL REFERENCES users(id),
  device_id                 uuid NOT NULL REFERENCES devices(id),
  shift_id                  uuid NOT NULL REFERENCES shifts(id),
  customer_name             text,
  payment_method            text NOT NULL DEFAULT 'CASH',
  subtotal_minor_units      bigint NOT NULL,
  discount_minor_units      bigint NOT NULL,
  total_minor_units         bigint NOT NULL,
  amount_paid_minor_units   bigint NOT NULL,
  change_minor_units        bigint NOT NULL,
  status                    text NOT NULL CHECK (status IN ('COMPLETED', 'VOIDED')),
  void_reason               text,
  voided_at                 timestamptz,
  voided_by                 uuid REFERENCES users(id),
  voided_shift_id           uuid REFERENCES shifts(id),
  created_at                timestamptz NOT NULL,
  synced_at                 timestamptz,
  origin_device_id          uuid,
  received_at               timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS sale_items (
  id                             uuid PRIMARY KEY,
  sale_id                        uuid NOT NULL REFERENCES sales(id) ON DELETE CASCADE,
  product_id                     uuid NOT NULL,
  product_name_snapshot          text NOT NULL,
  unit_price_snapshot_minor_units bigint NOT NULL,
  quantity_text                  text NOT NULL,
  billing_quantity_milliunits    bigint,
  line_discount_minor_units      bigint NOT NULL DEFAULT 0,
  line_total_minor_units         bigint NOT NULL,
  notes                          text,
  origin_device_id               uuid,
  received_at                    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS finance_categories (
  id              uuid PRIMARY KEY,
  name            text NOT NULL,
  created_at      timestamptz NOT NULL,
  updated_at      timestamptz NOT NULL,
  origin_device_id uuid,
  received_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS finance_entries (
  id                  uuid PRIMARY KEY,
  category_id         uuid NOT NULL REFERENCES finance_categories(id),
  source              text NOT NULL,
  amount_minor_units  bigint NOT NULL,
  description         text,
  status              text NOT NULL DEFAULT 'PENDING',
  entry_date          timestamptz NOT NULL,
  created_at          timestamptz NOT NULL,
  created_by          uuid NOT NULL REFERENCES users(id),
  completed_at        timestamptz,
  completed_by        uuid REFERENCES users(id),
  updated_at          timestamptz NOT NULL,
  origin_device_id    uuid,
  received_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS void_requests (
  id              uuid PRIMARY KEY,
  sale_id         uuid NOT NULL REFERENCES sales(id),
  requested_by    uuid NOT NULL REFERENCES users(id),
  reason          text NOT NULL,
  status          text NOT NULL DEFAULT 'PENDING',
  created_at      timestamptz NOT NULL,
  decided_by      uuid REFERENCES users(id),
  decided_at      timestamptz,
  origin_device_id uuid,
  received_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS audit_logs (
  id              uuid PRIMARY KEY,
  user_id         uuid REFERENCES users(id),
  action          text NOT NULL,
  details         text,
  created_at      timestamptz NOT NULL,
  origin_device_id uuid,
  received_at     timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Read-path indexes, mirroring the local hot queries (dashboards, reports).
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS sales_created_at       ON sales(created_at);
CREATE INDEX IF NOT EXISTS sales_shift_id         ON sales(shift_id);
CREATE INDEX IF NOT EXISTS sales_device_created   ON sales(device_id, created_at);
CREATE INDEX IF NOT EXISTS sale_items_sale_id     ON sale_items(sale_id);
CREATE INDEX IF NOT EXISTS audit_logs_created_at  ON audit_logs(created_at);
CREATE INDEX IF NOT EXISTS cash_movements_shift   ON cash_movements(shift_id);
CREATE INDEX IF NOT EXISTS finance_entries_cat    ON finance_entries(category_id);
CREATE INDEX IF NOT EXISTS finance_entries_status ON finance_entries(status);
CREATE INDEX IF NOT EXISTS finance_entries_date   ON finance_entries(entry_date);
CREATE INDEX IF NOT EXISTS void_requests_sale     ON void_requests(sale_id);
CREATE INDEX IF NOT EXISTS void_requests_status   ON void_requests(status);

-- ---------------------------------------------------------------------------
-- Idempotent apply pattern.
--
-- The sync worker sends each outbox row as an UPSERT keyed on id. Because a
-- device may re-send the same entity (retry after a dropped connection, or a
-- sale saved then voided producing two writes for one id), the guard is:
-- apply the incoming row only when it is at least as new as what is stored.
-- Example for sales:
--
--   INSERT INTO sales (id, receipt_number, ..., created_at, synced_at,
--                      origin_device_id, received_at)
--   VALUES ($1, $2, ..., $15, now(), $16, now())
--   ON CONFLICT (id) DO UPDATE SET
--     status = EXCLUDED.status,
--     voided_at = EXCLUDED.voided_at,
--     -- ...every mutable column...
--     synced_at = now(),
--     received_at = now()
--   WHERE sales.created_at <= EXCLUDED.created_at;
--
-- Newer-wins on the client timestamp is safe here ONLY because each register
-- is the sole writer of its own sales. Two devices never edit the same row, so
-- there is no true concurrent-write conflict to merge — see docs/CLOUD_SYNC.md.
-- ---------------------------------------------------------------------------

COMMIT;
