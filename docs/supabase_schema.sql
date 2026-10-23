-- Wholesale POS — Supabase "analytics mirror" schema
-- ---------------------------------------------------------------------------
-- Run THIS in the Supabase SQL Editor instead of docs/postgres_schema.sql.
--
-- Why it differs:
--   * NO foreign keys. The till only pushes transactions (sales, shift
--     register data, cash movements, void requests) — never user accounts or
--     passwords. With FKs removed, a sale can land even though the cloud does
--     not hold the cashier/device rows. This keeps credentials ON THE PC.
--   * id columns are `text`, not `uuid`, so any id format inserts cleanly.
--   * Only the five tables the app actually syncs are created here.
--
-- It is idempotent: safe to run more than once (drops + recreates the five).
-- ---------------------------------------------------------------------------

BEGIN;

-- Drop in dependency order, then recreate without foreign keys.
DROP TABLE IF EXISTS sale_items;
DROP TABLE IF EXISTS void_requests;
DROP TABLE IF EXISTS cash_movements;
DROP TABLE IF EXISTS sales;
DROP TABLE IF EXISTS shifts;

CREATE TABLE shifts (
  id                        text PRIMARY KEY,
  cashier_id                text NOT NULL,
  opening_cash_minor_units  bigint NOT NULL,
  closing_cash_minor_units  bigint,
  expected_cash_minor_units bigint,
  status                    text NOT NULL,
  opened_at                 timestamptz NOT NULL,
  closed_at                 timestamptz,
  origin_device_id          text,
  received_at               timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE sales (
  id                        text PRIMARY KEY,
  receipt_number            text NOT NULL,
  cashier_id                text NOT NULL,
  device_id                 text NOT NULL,
  shift_id                  text NOT NULL,
  customer_name             text,
  payment_method            text NOT NULL DEFAULT 'CASH',
  subtotal_minor_units      bigint NOT NULL,
  discount_minor_units      bigint NOT NULL,
  total_minor_units         bigint NOT NULL,
  amount_paid_minor_units   bigint NOT NULL,
  change_minor_units        bigint NOT NULL,
  status                    text NOT NULL,
  void_reason               text,
  voided_at                 timestamptz,
  voided_by                 text,
  voided_shift_id           text,
  created_at                timestamptz NOT NULL,
  synced_at                 timestamptz,
  origin_device_id          text,
  received_at               timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE sale_items (
  id                              text PRIMARY KEY,
  sale_id                         text NOT NULL,
  product_id                      text NOT NULL,
  product_name_snapshot           text NOT NULL,
  unit_price_snapshot_minor_units bigint NOT NULL,
  quantity_text                   text NOT NULL,
  billing_quantity_milliunits     bigint,
  line_discount_minor_units       bigint NOT NULL DEFAULT 0,
  line_total_minor_units          bigint NOT NULL,
  notes                           text,
  origin_device_id                text,
  received_at                     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE cash_movements (
  id                  text PRIMARY KEY,
  shift_id            text NOT NULL,
  type                text NOT NULL,
  amount_minor_units  bigint NOT NULL,
  reason              text,
  created_at          timestamptz NOT NULL,
  user_id             text,
  origin_device_id    text,
  received_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE void_requests (
  id               text PRIMARY KEY,
  sale_id          text NOT NULL,
  requested_by     text NOT NULL,
  reason           text NOT NULL,
  status           text NOT NULL DEFAULT 'PENDING',
  created_at       timestamptz NOT NULL,
  decided_by       text,
  decided_at       timestamptz,
  origin_device_id text,
  received_at      timestamptz NOT NULL DEFAULT now()
);

-- Read-path indexes for the reporting queries the cloud dashboard will run.
CREATE INDEX IF NOT EXISTS sales_created_at       ON sales(created_at);
CREATE INDEX IF NOT EXISTS sales_shift_id         ON sales(shift_id);
CREATE INDEX IF NOT EXISTS sale_items_sale_id     ON sale_items(sale_id);
CREATE INDEX IF NOT EXISTS cash_movements_shift   ON cash_movements(shift_id);
CREATE INDEX IF NOT EXISTS void_requests_sale     ON void_requests(sale_id);
CREATE INDEX IF NOT EXISTS void_requests_status   ON void_requests(status);

COMMIT;
