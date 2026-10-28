-- Wholesale POS — multi-tenant "analytics mirror" schema (Phase 18)
-- ---------------------------------------------------------------------------
-- Replaces the single-shop docs/supabase_schema.sql once sync is sold to
-- customers. Every mirrored row carries the `customer_id` of the shop that
-- owns it, so one Supabase project can host many shops without leakage.
--
-- Access model — the anon key can read/write NOTHING here:
--   * RLS is enabled with zero policies for anon/authenticated.
--   * The ONLY writer/reader is the `sync` Edge Function, which holds the
--     service role and gates every request on a valid signed license
--     (Ed25519 signature + unexpired + fingerprint matches a registered
--     active seat). Clients never see any key that bypasses RLS.
--
-- Diff vs the old single-shop schema:
--   * + customer_id uuid NOT NULL on every table (FK to customers.id — the
--     licensing table, so a mirror row can only ever belong to a real shop).
--   * PKs stay plain `text` ids (local SQLite ids), now namespaced per shop:
--     uniqueness is (customer_id, id) not global id.
--   * + read-path indexes include customer_id (every cloud query filters
--     by shop first).
--
-- Destructive: drops the old tables (they held only the Phase-12 verification
-- row). Run this in Supabase SQL Editor.
-- ---------------------------------------------------------------------------

BEGIN;

DROP TABLE IF EXISTS sale_items;
DROP TABLE IF EXISTS void_requests;
DROP TABLE IF EXISTS cash_movements;
DROP TABLE IF EXISTS sales;
DROP TABLE IF EXISTS shifts;

CREATE TABLE shifts (
  id                        text NOT NULL,
  customer_id               uuid NOT NULL REFERENCES public.customers(id),
  cashier_id                text NOT NULL,
  opening_cash_minor_units  bigint NOT NULL,
  closing_cash_minor_units  bigint,
  expected_cash_minor_units bigint,
  status                    text NOT NULL,
  opened_at                 timestamptz NOT NULL,
  closed_at                 timestamptz,
  origin_device_id          text,
  received_at               timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (customer_id, id)
);

CREATE TABLE sales (
  id                        text NOT NULL,
  customer_id               uuid NOT NULL REFERENCES public.customers(id),
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
  received_at               timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (customer_id, id)
);

CREATE TABLE sale_items (
  id                              text NOT NULL,
  customer_id                     uuid NOT NULL REFERENCES public.customers(id),
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
  received_at                     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (customer_id, id)
);

CREATE TABLE cash_movements (
  id                  text NOT NULL,
  customer_id         uuid NOT NULL REFERENCES public.customers(id),
  shift_id            text NOT NULL,
  type                text NOT NULL,
  amount_minor_units  bigint NOT NULL,
  reason              text,
  created_at          timestamptz NOT NULL,
  user_id             text,
  photo               text,
  origin_device_id    text,
  received_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (customer_id, id)
);

CREATE TABLE void_requests (
  id               text NOT NULL,
  customer_id      uuid NOT NULL REFERENCES public.customers(id),
  sale_id          text NOT NULL,
  requested_by     text NOT NULL,
  reason           text NOT NULL,
  status           text NOT NULL DEFAULT 'PENDING',
  created_at       timestamptz NOT NULL,
  decided_by       text,
  decided_at       timestamptz,
  origin_device_id text,
  received_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (customer_id, id)
);

-- Read paths always filter by shop first, then the reporting dimension.
CREATE INDEX IF NOT EXISTS sales_customer_created ON sales(customer_id, created_at);
CREATE INDEX IF NOT EXISTS sales_customer_shift   ON sales(customer_id, shift_id);
CREATE INDEX IF NOT EXISTS items_customer_sale    ON sale_items(customer_id, sale_id);
CREATE INDEX IF NOT EXISTS cm_customer_shift      ON cash_movements(customer_id, shift_id);
CREATE INDEX IF NOT EXISTS vr_customer_sale       ON void_requests(customer_id, sale_id);
CREATE INDEX IF NOT EXISTS vr_customer_status     ON void_requests(customer_id, status);

-- Lock the tables down. RLS with no policies = anon/authenticated see zero
-- rows and write nothing; only service_role (the sync Edge Function) passes.
ALTER TABLE shifts         ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales          ENABLE ROW LEVEL SECURITY;
ALTER TABLE sale_items     ENABLE ROW LEVEL SECURITY;
ALTER TABLE cash_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE void_requests  ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON shifts, sales, sale_items, cash_movements, void_requests FROM anon, authenticated;

COMMIT;
