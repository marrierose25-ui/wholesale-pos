-- Warehouse Picklist upgrade — line pricing + a reusable customer directory.
--
-- Purely additive to 20261105000000_picklists.sql: the existing picklist rows
-- keep working (pricing columns default to 0/null), and nothing here joins to
-- sales / shifts / cash_movements / finance. The same columns are added to the
-- cloud `picklist_items` as to the native SQLite table so a picklist created on
-- the PWA carries a value and reads back identically on a till.
--
-- `picklist_customers` is the cloud mirror of the native customer directory.
-- Like every other mirrored table it is carved to the verified tenant via
-- `customer_id` (the pos-api handlers filter on it and never trust a
-- client-supplied value), and carries the `received_at` watermark the pull
-- cursor would page on if this table is ever synced (today it is read/written
-- only through pos-api, so the column is simply reserved for parity).
ALTER TABLE public.picklist_items ADD COLUMN IF NOT EXISTS unit text;
ALTER TABLE public.picklist_items
  ADD COLUMN IF NOT EXISTS unit_price_minor_units int NOT NULL DEFAULT 0;
ALTER TABLE public.picklist_items
  ADD COLUMN IF NOT EXISTS line_total_minor_units int NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS public.picklist_customers (
  id text PRIMARY KEY,
  customer_id uuid REFERENCES public.customers(id) NOT NULL,
  name text NOT NULL,
  phone text,
  created_at timestamptz NOT NULL DEFAULT now(),
  received_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.picklist_customers ENABLE ROW LEVEL SECURITY;

-- Tenant-scoped unique key, mirroring picklists / picklist_items so a crafted
-- insert can never collide across shops and lookups stay index-backed.
CREATE UNIQUE INDEX IF NOT EXISTS picklist_customers_customer_id
  ON public.picklist_customers (customer_id, id);
CREATE INDEX IF NOT EXISTS picklist_customers_customer_name
  ON public.picklist_customers (customer_id, lower(name));
