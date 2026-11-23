-- Warehouse Picklists (Digital Fulfillment) — cloud mirror tables.
--
-- An independent feature: these tables never join to sales / shifts /
-- cash_movements / finance. A picklist is a fulfillment instruction (pull N of
-- X for a customer) that its warehouse ticks off, so both rows are mutable and
-- carry an `updated_at` the sync compares newest-wins, plus the `received_at`
-- keyset watermark the pull cursor pages on.
CREATE TABLE public.picklists (
  id text PRIMARY KEY,
  customer_id uuid REFERENCES public.customers(id) NOT NULL,
  customer_name text NOT NULL,
  status text NOT NULL DEFAULT 'PENDING',
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  received_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.picklist_items (
  id text PRIMARY KEY,
  customer_id uuid REFERENCES public.customers(id) NOT NULL,
  picklist_id text REFERENCES public.picklists(id) ON DELETE CASCADE NOT NULL,
  product_name text NOT NULL,
  requested_qty int NOT NULL,
  taken_qty int NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  received_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.picklists ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.picklist_items ENABLE ROW LEVEL SECURITY;

CREATE INDEX picklists_customer_received ON public.picklists (customer_id, received_at, id);
CREATE INDEX picklist_items_customer_received ON public.picklist_items (customer_id, received_at, id);

-- `pos_sync_apply` upserts device rows on `ON CONFLICT (customer_id, id)`, the
-- same tenant-scoped key every other mirrored table uses (pos_products,
-- pos_finance_entries, …). The PRIMARY KEY above is on `id` alone, which does
-- not satisfy that conflict target, so the tenant-scoped unique key has to
-- exist explicitly — otherwise the apply pass errors the moment a picklist is
-- actually pushed.
CREATE UNIQUE INDEX picklists_customer_id ON public.picklists (customer_id, id);
CREATE UNIQUE INDEX picklist_items_customer_id ON public.picklist_items (customer_id, id);
