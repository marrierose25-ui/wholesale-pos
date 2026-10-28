-- Wholesale POS — tenant-scoped cashier accounts for the web/PWA (M2)
-- ---------------------------------------------------------------------------
-- Backs the `pos-api` Edge Function's per-cashier login. One Supabase project
-- hosts many shops; every account belongs to exactly one customer (tenant),
-- resolved from the shop's activation code via the licensing `customers` table.
--
-- Access model — identical posture to the analytics mirror tables
-- (docs/supabase_sync_multi_tenant.sql):
--   * RLS is enabled with ZERO policies for anon/authenticated.
--   * The ONLY reader/writer is the `pos-api` Edge Function, which holds the
--     service role and is the single authentication authority. The browser never
--     receives a key that can bypass RLS — it only ever holds an Edge-Function-
--     signed session JWT. A forged or cross-tenant request cannot read or write
--     another shop's rows because customer_id is carved from the verified JWT,
--     never from the request body.
--
-- Column notes:
--   * pw_salt / pw_hash store PBKDF2-HMAC-SHA256 exactly as pos-api derives it
--     (210k rounds, matching UserRepository.defaultIterations on the client).
--     The plaintext password is never stored or logged.
--   * role mirrors the client vocabulary {'OWNER','CASHIER'}; pos-api enforces
--     owner-only actions server-side, not by hiding navigation.
--   * active=false soft-deletes an account; login and every authed action
--     reject inactive users, so a revoked cashier cannot reuse an old JWT.
--   * deleted_at marks an account the owner deleted. Deleting is only allowed
--     for a deactivated account: one that never recorded a sale, shift, cash
--     movement, finance entry or void request is removed outright, while one
--     that did keeps its row flagged so history keeps its cashier name. Every
--     list/login/lookup filters `deleted_at IS NULL`.
--   * (customer_id, id) is the PK so ids stay local-uuid-shaped but are
--     namespaced per shop; the unique username index is case-insensitive per
--     shop, matching the client's `LOWER(username)` lookups.
--   * username is the login identifier: the account's phone number in one
--     canonical Ethiopian mobile form (0 + 9/7 + 8 digits). pos-api normalises
--     any spelling it accepts; the seeded training account keeps the literal
--     'demo'.
--
-- Non-destructive: safe to run alongside the existing licensing + mirror
-- schema. Run in the Supabase SQL Editor.
-- ---------------------------------------------------------------------------

BEGIN;

CREATE TABLE IF NOT EXISTS pos_users (
  id          text        NOT NULL,
  customer_id uuid        NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  username    text        NOT NULL,
  role        text        NOT NULL CHECK (role IN ('OWNER', 'CASHIER')),
  pw_salt     text        NOT NULL,
  pw_hash     text        NOT NULL,
  active      boolean     NOT NULL DEFAULT true,
  is_demo     boolean     NOT NULL DEFAULT false,
  deleted_at  timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (customer_id, id)
);

-- Case-insensitive username uniqueness, scoped to the shop. pos-api folds the
-- typed phone number to its canonical form and looks it up with
-- `lower(username) = lower(...)`, so the index matches the query shape.
CREATE UNIQUE INDEX IF NOT EXISTS pos_users_customer_username
  ON pos_users (customer_id, LOWER(username));

-- Fast per-tenant listing (dashboard "Users" screen, provisioning scans).
CREATE INDEX IF NOT EXISTS pos_users_customer_active
  ON pos_users (customer_id, active);

-- Delta-feed support (multi-device sync). The `sync` gateway pages a tenant's
-- rows by (received_at, id), the same keyset every operational table uses, so
-- a till can download the shop's accounts the same way it downloads sales.
-- Additive and idempotent: existing rows are stamped at migration time and
-- ordered by id, which is enough for a strictly monotonic walk.
ALTER TABLE pos_users
  ADD COLUMN IF NOT EXISTS received_at timestamptz NOT NULL DEFAULT now();

CREATE INDEX IF NOT EXISTS pos_users_customer_received
  ON pos_users (customer_id, received_at, id);

-- Lock the table down. RLS with no policies = anon/authenticated see zero rows
-- and write nothing; only service_role (the pos-api Edge Function) passes.
ALTER TABLE pos_users ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON pos_users FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- Operational tables the PWA needs that the analytics mirror does NOT carry.
-- The mirror (sales/sale_items/shifts/cash_movements/void_requests) is
-- write-only from native tills. For the web to be a full, authoritative front
-- end, these supporting tables live cloud-side too, with the same RLS +
-- service_role-only posture and (customer_id, id) namespacing.
-- ---------------------------------------------------------------------------

-- Saved names / products (POS search shortcuts). Columns mirror the local
-- `products` table exactly (Product.toMap) so the cloud repos can reuse the
-- same fromMap/toMap without a translation layer.
CREATE TABLE IF NOT EXISTS pos_products (
  id                      text        NOT NULL,
  customer_id             uuid        NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  name                    text        NOT NULL,
  code                    text,
  category                text,
  unit                    text,
  selling_price_minor_units bigint    NOT NULL DEFAULT 0,
  is_active               integer     NOT NULL DEFAULT 1,
  created_at              timestamptz NOT NULL,
  updated_at              timestamptz,
  PRIMARY KEY (customer_id, id)
);
CREATE INDEX IF NOT EXISTS pos_products_customer_active
  ON pos_products (customer_id, is_active);

-- Owner's private money tracking (people + entries).
CREATE TABLE IF NOT EXISTS pos_finance_categories (
  id          text        NOT NULL,
  customer_id uuid        NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  name        text        NOT NULL,
  created_at  timestamptz NOT NULL,
  updated_at  timestamptz,
  deleted_at  timestamptz,
  PRIMARY KEY (customer_id, id)
);
CREATE TABLE IF NOT EXISTS pos_finance_entries (
  id                  text        NOT NULL,
  customer_id         uuid        NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  category_id         text        NOT NULL,
  source              text        NOT NULL,
  amount_minor_units  bigint      NOT NULL,
  description         text,
  status              text        NOT NULL DEFAULT 'PENDING',
  entry_date          timestamptz NOT NULL,
  created_at          timestamptz NOT NULL,
  created_by          text,
  completed_at        timestamptz,
  completed_by        text,
  updated_at          timestamptz,
  payment_method      text,
  PRIMARY KEY (customer_id, id)
);
CREATE INDEX IF NOT EXISTS pos_finance_entries_customer_cat
  ON pos_finance_entries (customer_id, category_id);

-- Idempotent upgrade for databases created before the recycle-bin / cash-deposit
-- redesign: pos-api reads categories with .is('deleted_at', null) and stores a
-- payment_method on entries. Fresh installs already have both from the CREATE
-- TABLE above; pre-existing tables gain the columns here.
ALTER TABLE pos_finance_categories ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE pos_finance_entries    ADD COLUMN IF NOT EXISTS payment_method text;

-- The web's tamper-evident trail. pos-api writes one row per meaningful action
-- (login-adjacent, sale, shift, void, finance) and lists them back for the
-- owner's Audit screen. Columns match the local `audit_logs` table plus the
-- tenant id; `username` is never stored, it is joined from pos_users on read.
CREATE TABLE IF NOT EXISTS pos_audit_logs (
  id          text        NOT NULL,
  customer_id uuid        NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  user_id     text,
  action      text        NOT NULL,
  details     text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (customer_id, id)
);
CREATE INDEX IF NOT EXISTS pos_audit_logs_customer_created
  ON pos_audit_logs (customer_id, created_at DESC);

-- Tenant-scoped key/value settings (theme, per-shop prefs) and sequential
-- receipt-number counters (one row per shop per day). pos_settings and
-- pos_counters use a single-column (customer_id, key) / (customer_id, name) PK.
CREATE TABLE IF NOT EXISTS pos_settings (
  customer_id uuid NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  key         text NOT NULL,
  value       text,
  PRIMARY KEY (customer_id, key)
);
CREATE TABLE IF NOT EXISTS pos_counters (
  customer_id uuid    NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  name        text    NOT NULL,
  value       bigint  NOT NULL,
  PRIMARY KEY (customer_id, name)
);

ALTER TABLE pos_products         ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos_finance_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos_finance_entries  ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos_audit_logs       ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos_settings         ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos_counters         ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON pos_products, pos_finance_categories, pos_finance_entries,
  pos_audit_logs, pos_settings, pos_counters FROM anon, authenticated;

COMMIT;
