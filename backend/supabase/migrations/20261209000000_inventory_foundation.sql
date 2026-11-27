-- Inventory foundation: stores + per-store product stock.
--
-- Mirrors the local schema-23 change: `stores` and `store_inventory` are
-- mutable master data that ride the same sync_mirror -> pos_sync_apply path
-- as products and picklists, and `pos_products` gains the cost price and
-- optional image the creation wizard collects.
--
-- Deletion is a tombstone (`deleted_at`), never a physical delete: the sync
-- feed has no delete channel, so a removed store must stay visible to every
-- device as a deleted row. Store names are unique per tenant ignoring case
-- and surrounding whitespace, enforced by a partial index — the same rule
-- the local `stores_name_unique` index applies.

-- 1. Product catalogue gains cost price + optional image (idempotent).
ALTER TABLE public.pos_products
  ADD COLUMN IF NOT EXISTS bought_price_minor_units bigint NOT NULL DEFAULT 0;
ALTER TABLE public.pos_products

-- 2. Stores.
CREATE TABLE IF NOT EXISTS public.stores (
  id          text                     NOT NULL,
  customer_id uuid                     NOT NULL,
  name        text                     NOT NULL,
  created_at  timestamp with time zone NOT NULL DEFAULT now(),
  updated_at  timestamp with time zone NOT NULL DEFAULT now(),
  deleted_at  timestamp with time zone,
  received_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT stores_customer_id_fkey FOREIGN KEY (customer_id)
    REFERENCES public.customers(id),
  CONSTRAINT stores_pkey PRIMARY KEY (id)
);

ALTER TABLE public.stores ENABLE ROW LEVEL SECURITY;

CREATE UNIQUE INDEX IF NOT EXISTS stores_customer_id
  ON public.stores USING btree (customer_id, id);
CREATE UNIQUE INDEX IF NOT EXISTS stores_name_unique
  ON public.stores USING btree (customer_id, lower(btrim(name)))
  WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS stores_customer_received
  ON public.stores USING btree (customer_id, received_at, id);

DROP TRIGGER IF EXISTS touch_received_at ON public.stores;
CREATE TRIGGER touch_received_at
  BEFORE UPDATE ON public.stores
  FOR EACH ROW EXECUTE FUNCTION public.pos_touch_received_at();

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE
  ON TABLE public.stores TO anon, authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE
  ON TABLE public.stores TO service_role;
REVOKE ALL ON TABLE public.stores FROM postgres;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE
  ON TABLE public.stores TO postgres;

-- 3. Per-store stock records. Quantities are milliunits, matching the local
--    `billing_quantity_milliunits` convention. One live row per
--    (store, product) pair; tombstones are excluded so a deleted record can
--    be re-created.
CREATE TABLE IF NOT EXISTS public.product_images (
  product_id    uuid PRIMARY KEY REFERENCES public.pos_products(id) ON DELETE CASCADE,
  customer_id   uuid NOT NULL REFERENCES public.customers(id),
  image_data    text NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  received_at   timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.product_images ENABLE ROW LEVEL SECURITY;
CREATE POLICY product_images_tenant ON public.product_images
  FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE TABLE IF NOT EXISTS public.store_inventory (
  id                  text                     NOT NULL,
  customer_id         uuid                     NOT NULL,
  store_id            text                     NOT NULL,
  product_id          text                     NOT NULL,
  on_hand_milliunits  bigint                   NOT NULL DEFAULT 0,
  reorder_milliunits  bigint                   NOT NULL DEFAULT 0,
  created_at          timestamp with time zone NOT NULL DEFAULT now(),
  updated_at          timestamp with time zone NOT NULL DEFAULT now(),
  deleted_at          timestamp with time zone,
  received_at         timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT store_inventory_customer_id_fkey FOREIGN KEY (customer_id)
    REFERENCES public.customers(id),
  CONSTRAINT store_inventory_pkey PRIMARY KEY (id)
);

ALTER TABLE public.store_inventory ENABLE ROW LEVEL SECURITY;

CREATE UNIQUE INDEX IF NOT EXISTS store_inventory_customer_id
  ON public.store_inventory USING btree (customer_id, id);
CREATE UNIQUE INDEX IF NOT EXISTS store_inventory_pair
  ON public.store_inventory USING btree (customer_id, store_id, product_id)
  WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS store_inventory_customer_received
  ON public.store_inventory USING btree (customer_id, received_at, id);
CREATE INDEX IF NOT EXISTS store_inventory_store
  ON public.store_inventory USING btree (customer_id, store_id);
CREATE INDEX IF NOT EXISTS store_inventory_product
  ON public.store_inventory USING btree (customer_id, product_id);

DROP TRIGGER IF EXISTS touch_received_at ON public.store_inventory;
CREATE TRIGGER touch_received_at
  BEFORE UPDATE ON public.store_inventory
  FOR EACH ROW EXECUTE FUNCTION public.pos_touch_received_at();

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE
  ON TABLE public.store_inventory TO anon, authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE
  ON TABLE public.store_inventory TO service_role;
REVOKE ALL ON TABLE public.store_inventory FROM postgres;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE
  ON TABLE public.store_inventory TO postgres;

-- 4. Atomic product + opening stock for pos-api (the web build has no local
--    transaction to lean on). Validates everything the wizard validates,
--    then writes both rows in this one function — a failure leaves neither.
CREATE OR REPLACE FUNCTION public.pos_create_inventory_product(
  p_customer      uuid,
  p_user          text,
  p_product       jsonb,
  p_store_id      text,
  p_on_hand       bigint,
  p_reorder       bigint
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_product_id text := COALESCE(NULLIF(p_product->>'id', ''), gen_random_uuid()::text);
  v_name       text := btrim(COALESCE(p_product->>'name', ''));
  v_unit       text := btrim(COALESCE(p_product->>'unit', ''));
  v_sell       bigint := COALESCE((p_product->>'selling_price_minor_units')::bigint, -1);
  v_buy        bigint := COALESCE((p_product->>'bought_price_minor_units')::bigint, 0);
  v_code       text;
  v_inv_id     text := gen_random_uuid()::text;
BEGIN
  IF v_name = '' THEN RAISE EXCEPTION 'A product name is required.'; END IF;
  IF v_unit = '' THEN RAISE EXCEPTION 'A unit is required.'; END IF;
  IF v_sell < 0 OR v_buy < 0 THEN RAISE EXCEPTION 'Prices cannot be negative.'; END IF;
  IF p_on_hand < 0 OR p_reorder < 0 THEN
    RAISE EXCEPTION 'Quantities cannot be negative.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.stores
    WHERE customer_id = p_customer AND id = p_store_id AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'The selected store does not exist.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.pos_products
    WHERE customer_id = p_customer AND is_active = 1
      AND lower(btrim(name)) = lower(v_name)
  ) THEN
    RAISE EXCEPTION 'A product named "%" already exists.', v_name;
  END IF;
  -- pos_products.code is nullable here but a duplicate would still collide
  -- on the tenant+code index when one exists; fall back to the id.
  v_code := NULLIF(btrim(COALESCE(p_product->>'code', '')), '');
  IF v_code IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.pos_products
    WHERE customer_id = p_customer AND code = v_code AND id <> v_product_id
  ) THEN
    v_code := v_product_id;
  END IF;
  IF v_code IS NULL THEN v_code := v_product_id; END IF;

  INSERT INTO public.pos_products (
    id, customer_id, name, code, category, unit,
    selling_price_minor_units, bought_price_minor_units,
    is_active, created_at, updated_at)
  VALUES (
    v_product_id, p_customer, v_name, v_code,
    NULLIF(p_product->>'category', ''), v_unit,
    v_sell, v_buy,
    1, now(), now());

  INSERT INTO public.store_inventory (
    id, customer_id, store_id, product_id,
    on_hand_milliunits, reorder_milliunits, created_at, updated_at)
  VALUES (
    v_inv_id, p_customer, p_store_id, v_product_id,
    p_on_hand, p_reorder, now(), now());

  RETURN jsonb_build_object(
    'product_id', v_product_id, 'inventory_id', v_inv_id);
END;
$$;
REVOKE ALL ON FUNCTION public.pos_create_inventory_product(uuid, text, jsonb, text, bigint, bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pos_create_inventory_product(uuid, text, jsonb, text, bigint, bigint)
  TO service_role;

-- 5. pos_sync_apply store/store_inventory branches: DEFERRED. The request3
--    hardening series (20261202-20261208) rewrote pos_sync_apply after this
--    file's original baseline; re-publishing an old body here would silently
--    revert those fixes. A follow-up migration must rebase the entity
--    dispatch onto the request3-final function before store sync is enabled
--    server-side. Until then the pull tables in sync/index.ts serve cloud ->
--    device flow; device -> cloud store pushes are not yet applied.

