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
  ADD COLUMN IF NOT EXISTS image_data text;

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
    selling_price_minor_units, bought_price_minor_units, image_data,
    is_active, created_at, updated_at)
  VALUES (
    v_product_id, p_customer, v_name, v_code,
    NULLIF(p_product->>'category', ''), v_unit,
    v_sell, v_buy, NULLIF(p_product->>'image_data', ''),
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

-- 5. Re-publish pos_sync_apply with two additions:
--      * the product branch carries bought_price_minor_units + image_data;
--      * new store / store_inventory branches (mutable, newest-wins, with
--        the same defer-when-parent-missing rule picklist_item uses).
--    Everything else is byte-identical to 20261111000000.

CREATE OR REPLACE FUNCTION pos_sync_apply(
  p_customer uuid,
  p_limit    int DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  rec       record;
  applied   int := 0;
  rejected  int := 0;
  left_over int := 0;
  s         jsonb;
  items     jsonb;
  shift_id  text;
  cashier   text;
  device    text;
  actor     text;
  mv        jsonb;
  vr        jsonb;
  us        jsonb;
  pr        jsonb;
  fc        jsonb;
  fe        jsonb;
  pk        jsonb;
  pi        jsonb;
  st        jsonb;
  si        jsonb;
  sale_row  record;
  cat_row   record;
  user_row  record;
  pl_row    text;
  perms     jsonb;
  skipped   int := 0;
BEGIN
  FOR rec IN
    SELECT entity_type, entity_id, operation, device_id, payload
    FROM public.sync_mirror
    WHERE customer_id = p_customer AND apply_status = 'PENDING'
    ORDER BY CASE entity_type
        WHEN 'user'              THEN 0
        WHEN 'product'           THEN 1
        WHEN 'store'             THEN 2
        WHEN 'finance_category'  THEN 3
        WHEN 'shift'             THEN 4
        WHEN 'sale'              THEN 5
        WHEN 'cash_movement'     THEN 6
        WHEN 'void_request'      THEN 7
        WHEN 'finance_entry'     THEN 8
        WHEN 'picklist'          THEN 9
        WHEN 'picklist_item'     THEN 10
        WHEN 'store_inventory'   THEN 11
        ELSE 12
      END, received_at, entity_id
    LIMIT COALESCE(NULLIF(p_limit, 0), 200)
    FOR UPDATE SKIP LOCKED
  LOOP
    BEGIN
      IF upper(rec.operation) = 'DELETE'
         AND rec.entity_type <> 'finance_category' THEN
        RAISE EXCEPTION 'A device cannot delete a cloud record.';
      END IF;

      IF rec.entity_type IN (
           'sale', 'shift', 'cash_movement', 'void_request', 'finance_entry') THEN
        actor := COALESCE(
          rec.payload->'sale'->>'cashier_id',
          rec.payload->'shift'->>'cashier_id',
          rec.payload->'cash_movement'->>'user_id',
          rec.payload->'void_request'->>'requested_by',
          rec.payload->'finance_entry'->>'created_by',
          '');
        IF rec.entity_type = 'finance_entry'
           AND NOT public.pos_is_demo(p_customer, actor) THEN
          actor := COALESCE(
            rec.payload->'finance_entry'->>'completed_by', '');
        END IF;
        IF public.pos_is_demo(p_customer, actor) THEN
          skipped := skipped + 1;
          UPDATE public.sync_mirror
          SET apply_status = 'APPLIED', applied_at = now(),
              apply_error = 'Training-account data stays on the till that made it.'
          WHERE customer_id = p_customer
            AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
          CONTINUE;
        END IF;
      END IF;

      IF rec.entity_type = 'sale' THEN
        s := rec.payload->'sale';
        items := rec.payload->'items';
        IF s IS NULL OR jsonb_typeof(s) <> 'object' THEN
          RAISE EXCEPTION 'Sale payload is missing its header.';
        END IF;
        IF items IS NULL OR jsonb_typeof(items) <> 'array'
           OR jsonb_array_length(items) = 0 THEN
          RAISE EXCEPTION 'Sale payload has no line items.';
        END IF;
        cashier := COALESCE(s->>'cashier_id', '');
        device  := COALESCE(NULLIF(s->>'device_id', ''), NULLIF(rec.device_id, ''), 'sync');
        shift_id := public.pos_ensure_shift(p_customer, cashier, NULL);
        PERFORM public.pos_create_sale(
          p_customer,
          cashier,
          device,
          shift_id,
          s->>'receipt_number',
          items,
          upper(COALESCE(s->>'payment_method', 'CASH')),
          COALESCE((s->>'discount_minor_units')::bigint, 0),
          COALESCE((s->>'amount_paid_minor_units')::bigint, 0),
          NULLIF(s->>'customer_name', ''),
          rec.entity_id);

      ELSIF rec.entity_type = 'cash_movement' THEN
        mv := rec.payload->'cash_movement';
        IF mv IS NULL OR jsonb_typeof(mv) <> 'object' THEN
          RAISE EXCEPTION 'Cash movement payload is missing.';
        END IF;
        shift_id := public.pos_ensure_shift(
          p_customer, COALESCE(mv->>'user_id', ''), NULL);
        PERFORM public.pos_add_cash_movement(
          p_customer,
          COALESCE(mv->>'user_id', ''),
          shift_id,
          upper(COALESCE(mv->>'type', '')),
          abs(COALESCE((mv->>'amount_minor_units')::bigint, 0)),
          mv->>'reason',
          NULLIF(mv->>'photo', ''),
          rec.entity_id,
          NULLIF(mv->>'source_finance_entry_id', ''));

      ELSIF rec.entity_type = 'void_request' THEN
        vr := rec.payload->'void_request';
        IF vr IS NULL OR jsonb_typeof(vr) <> 'object' THEN
          RAISE EXCEPTION 'Void request payload is missing.';
        END IF;
        SELECT id, status INTO sale_row FROM public.sales
        WHERE customer_id = p_customer AND id = vr->>'sale_id';
        IF NOT FOUND THEN
          RAISE EXCEPTION 'The sale this void request names is not in the cloud.';
        END IF;
        IF sale_row.status <> 'COMPLETED' THEN
          RAISE EXCEPTION 'Sale % is not voidable.', sale_row.id;
        END IF;
        INSERT INTO public.void_requests (id, customer_id, sale_id, requested_by,
          reason, status, created_at, received_at)
        VALUES (rec.entity_id, p_customer, sale_row.id, COALESCE(vr->>'requested_by', ''),
          COALESCE(vr->>'reason', ''), 'PENDING',
          COALESCE((vr->>'created_at')::timestamptz, now()), now())
        ON CONFLICT (customer_id, id) DO NOTHING;

      ELSIF rec.entity_type = 'shift' THEN
        us := rec.payload->'shift';
        IF us IS NULL OR jsonb_typeof(us) <> 'object' THEN
          RAISE EXCEPTION 'Shift payload is missing.';
        END IF;
        IF upper(COALESCE(us->>'status', 'OPEN')) = 'OPEN' THEN
          PERFORM public.pos_ensure_shift(
            p_customer,
            COALESCE(us->>'cashier_id', ''),
            COALESCE(NULLIF(us->>'device_id', ''), NULLIF(rec.device_id, ''), 'sync'));
        END IF;

      -- =========================================================================
      -- Master data: mutable rows, applied newest-wins.
      -- =========================================================================

      ELSIF rec.entity_type = 'user' THEN
        us := rec.payload->'user';
        IF us IS NULL OR jsonb_typeof(us) <> 'object' THEN
          RAISE EXCEPTION 'User payload is missing.';
        END IF;
        IF NULLIF(us->>'username', '') IS NULL THEN
          RAISE EXCEPTION 'Account payload has no login name.';
        END IF;
        IF EXISTS (SELECT 1 FROM public.pos_users
                   WHERE customer_id = p_customer AND id = rec.entity_id) THEN
          DECLARE
            v_cur_active bool; v_cur_demo bool;
            v_cur_deleted timestamptz; v_cur_perms jsonb;
            v_new_active bool; v_new_demo bool;
            v_new_deleted timestamptz; v_new_perms jsonb;
          BEGIN
            SELECT active, is_demo, deleted_at, permissions
              INTO v_cur_active, v_cur_demo, v_cur_deleted, v_cur_perms
            FROM public.pos_users
            WHERE customer_id = p_customer AND id = rec.entity_id;

            v_new_active := COALESCE((us->>'is_active')::int, 1) = 1;
            v_new_demo := COALESCE((us->>'is_demo')::int, 0) = 1;
            v_new_deleted := (us->>'deleted_at')::timestamptz;
            v_new_perms := CASE
              WHEN btrim(COALESCE(us->>'permissions', '')) = '' THEN '[]'::jsonb
              WHEN left(btrim(us->>'permissions'), 1) IN ('[', '{')
                THEN btrim(us->>'permissions')::jsonb
              ELSE '[]'::jsonb
            END;

            IF v_new_active <> v_cur_active
               OR v_new_demo <> v_cur_demo
               OR v_new_deleted IS DISTINCT FROM v_cur_deleted
               OR v_new_perms IS DISTINCT FROM v_cur_perms
            THEN
              RAISE EXCEPTION 'Device cannot change account permissions, status, or deletion state.';
            END IF;
          END;
        END IF;
        perms := CASE
          WHEN btrim(COALESCE(us->>'permissions', '')) = '' THEN '[]'::jsonb
          WHEN left(btrim(us->>'permissions'), 1) IN ('[', '{')
            THEN btrim(us->>'permissions')::jsonb
          ELSE '[]'::jsonb
        END;
        IF us->>'role' = 'OWNER' THEN
          SELECT id INTO user_row FROM public.pos_users
          WHERE customer_id = p_customer AND role = 'OWNER'
            AND deleted_at IS NULL AND id <> rec.entity_id
          LIMIT 1;
          IF FOUND THEN
            skipped := skipped + 1;
            UPDATE public.sync_mirror
            SET apply_status = 'APPLIED', applied_at = now(),
                apply_error = 'The tenant already has its owner; the role was not changed.'
            WHERE customer_id = p_customer
              AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
            applied := applied + 1;
            CONTINUE;
          END IF;
        END IF;
        SELECT id INTO user_row FROM public.pos_users
        WHERE customer_id = p_customer
          AND lower(username) = lower(us->>'username')
          AND id <> rec.entity_id
        LIMIT 1;
        IF FOUND THEN
          RAISE EXCEPTION 'That login is already in use by another account.';
        END IF;
        INSERT INTO public.pos_users (
          id, customer_id, username, role, pw_salt, pw_hash, active,
          permissions, is_demo, deleted_at, created_at, updated_at)
        VALUES (
          rec.entity_id, p_customer, us->>'username',
          CASE WHEN us->>'role' IN ('OWNER', 'CASHIER') THEN us->>'role' ELSE 'CASHIER' END,
          COALESCE(NULLIF(us->>'pw_salt', ''), gen_random_uuid()::text),
          COALESCE(NULLIF(us->>'pw_hash', ''), md5(random()::text || clock_timestamp()::text)),
          COALESCE((us->>'is_active')::int, 1) = 1,
          perms,
          COALESCE((us->>'is_demo')::int, 0) = 1,
          (us->>'deleted_at')::timestamptz,
          COALESCE((us->>'created_at')::timestamptz, now()),
          COALESCE((us->>'updated_at')::timestamptz, now()))
        ON CONFLICT (customer_id, id) DO UPDATE SET
          username    = EXCLUDED.username,
          active      = EXCLUDED.active,
          permissions = EXCLUDED.permissions,
          is_demo     = EXCLUDED.is_demo,
          deleted_at  = EXCLUDED.deleted_at,
          pw_hash     = COALESCE(NULLIF(EXCLUDED.pw_hash, ''), public.pos_users.pw_hash),
          pw_salt     = COALESCE(NULLIF(EXCLUDED.pw_salt, ''), public.pos_users.pw_salt),
          updated_at  = EXCLUDED.updated_at
        WHERE public.pos_users.updated_at IS NULL
           OR public.pos_users.updated_at <
              COALESCE((us->>'updated_at')::timestamptz,
                       public.pos_users.updated_at + interval '1 second');

      ELSIF rec.entity_type = 'product' THEN
        pr := rec.payload->'product';
        IF pr IS NULL OR jsonb_typeof(pr) <> 'object' THEN
          RAISE EXCEPTION 'Product payload is missing.';
        END IF;
        IF NULLIF(pr->>'name', '') IS NULL THEN
          RAISE EXCEPTION 'A saved name needs a name.';
        END IF;
        IF EXISTS (
          SELECT 1 FROM public.pos_products
          WHERE customer_id = p_customer AND is_active = 1
            AND lower(name) = lower(pr->>'name') AND id <> rec.entity_id) THEN
          RAISE EXCEPTION 'A saved name "%" already exists.', pr->>'name';
        END IF;
        INSERT INTO public.pos_products (
          id, customer_id, name, code, category, unit,
          selling_price_minor_units, bought_price_minor_units, image_data,
          is_active, created_at, updated_at)
        VALUES (
          rec.entity_id, p_customer, pr->>'name', pr->>'code', pr->>'category',
          pr->>'unit', COALESCE((pr->>'selling_price_minor_units')::bigint, 0),
          COALESCE((pr->>'bought_price_minor_units')::bigint, 0),
          NULLIF(pr->>'image_data', ''),
          COALESCE((pr->>'is_active')::int, 1),
          COALESCE((pr->>'created_at')::timestamptz, now()),
          COALESCE((pr->>'updated_at')::timestamptz, now()))
        ON CONFLICT (customer_id, id) DO UPDATE SET
          name                     = EXCLUDED.name,
          code                     = EXCLUDED.code,
          category                 = EXCLUDED.category,
          unit                     = EXCLUDED.unit,
          selling_price_minor_units = EXCLUDED.selling_price_minor_units,
          bought_price_minor_units  = EXCLUDED.bought_price_minor_units,
          image_data               = EXCLUDED.image_data,
          is_active                = EXCLUDED.is_active,
          updated_at               = EXCLUDED.updated_at
        WHERE public.pos_products.updated_at IS NULL
           OR public.pos_products.updated_at < EXCLUDED.updated_at;

      ELSIF rec.entity_type = 'store' THEN
        st := rec.payload->'store';
        IF st IS NULL OR jsonb_typeof(st) <> 'object' THEN
          RAISE EXCEPTION 'Store payload is missing.';
        END IF;
        IF NULLIF(btrim(st->>'name'), '') IS NULL THEN
          RAISE EXCEPTION 'A store needs a name.';
        END IF;
        -- Same rule as the local stores_name_unique index: live stores may
        -- not share a name ignoring case and surrounding whitespace. The
        -- partial unique index is the backstop; this check returns the
        -- readable message first.
        IF EXISTS (
          SELECT 1 FROM public.stores
          WHERE customer_id = p_customer AND id <> rec.entity_id
            AND deleted_at IS NULL
            AND lower(btrim(name)) = lower(btrim(st->>'name'))) THEN
          RAISE EXCEPTION 'A store named "%" already exists.', btrim(st->>'name');
        END IF;
        INSERT INTO public.stores (
          id, customer_id, name, created_at, updated_at, deleted_at)
        VALUES (
          rec.entity_id, p_customer, btrim(st->>'name'),
          COALESCE((st->>'created_at')::timestamptz, now()),
          COALESCE((st->>'updated_at')::timestamptz, now()),
          NULLIF(st->>'deleted_at', '')::timestamptz)
        ON CONFLICT (customer_id, id) DO UPDATE SET
          name       = EXCLUDED.name,
          deleted_at = EXCLUDED.deleted_at,
          updated_at = EXCLUDED.updated_at
        WHERE public.stores.updated_at IS NULL
           OR public.stores.updated_at < EXCLUDED.updated_at;

      ELSIF rec.entity_type = 'store_inventory' THEN
        si := rec.payload->'store_inventory';
        IF si IS NULL OR jsonb_typeof(si) <> 'object' THEN
          RAISE EXCEPTION 'Store inventory payload is missing.';
        END IF;
        -- Both parents are foreign keys. `store` (2) and `product` (1) are
        -- walked before this branch, so a parent that has landed is here;
        -- one that has not leaves the row PENDING for a later pass, exactly
        -- like a picklist item waiting for its header.
        IF NOT EXISTS (
          SELECT 1 FROM public.stores
          WHERE customer_id = p_customer AND id = COALESCE(si->>'store_id', '')
            AND deleted_at IS NULL) THEN
          skipped := skipped + 1;
          CONTINUE;
        END IF;
        IF NOT EXISTS (
          SELECT 1 FROM public.pos_products
          WHERE customer_id = p_customer AND id = COALESCE(si->>'product_id', '')) THEN
          skipped := skipped + 1;
          CONTINUE;
        END IF;
        -- Upsert on the (store, product) pair, not the row id: two devices
        -- stocking the same product in the same store must converge on ONE
        -- cloud row, and the partial unique index is what enforces it.
        INSERT INTO public.store_inventory (
          id, customer_id, store_id, product_id,
          on_hand_milliunits, reorder_milliunits,
          created_at, updated_at, deleted_at)
        VALUES (
          rec.entity_id, p_customer,
          si->>'store_id', si->>'product_id',
          COALESCE((si->>'on_hand_milliunits')::bigint, 0),
          COALESCE((si->>'reorder_milliunits')::bigint, 0),
          COALESCE((si->>'created_at')::timestamptz, now()),
          COALESCE((si->>'updated_at')::timestamptz, now()),
          NULLIF(si->>'deleted_at', '')::timestamptz)
        ON CONFLICT (customer_id, store_id, product_id)
          WHERE deleted_at IS NULL
        DO UPDATE SET
          on_hand_milliunits  = EXCLUDED.on_hand_milliunits,
          reorder_milliunits  = EXCLUDED.reorder_milliunits,
          deleted_at          = EXCLUDED.deleted_at,
          updated_at          = EXCLUDED.updated_at
        WHERE public.store_inventory.updated_at IS NULL
           OR public.store_inventory.updated_at < EXCLUDED.updated_at;

      ELSIF rec.entity_type = 'finance_category' THEN
        IF upper(rec.operation) = 'DELETE' THEN
          IF NOT EXISTS (SELECT 1 FROM public.pos_finance_categories
                         WHERE customer_id = p_customer AND id = rec.entity_id) THEN
            NULL;
          ELSE
            UPDATE public.pos_finance_categories
            SET deleted_at = COALESCE(deleted_at, now())
            WHERE customer_id = p_customer AND id = rec.entity_id;
            PERFORM public.pos_delete_finance_category(
              p_customer, rec.entity_id, COALESCE(rec.device_id, 'sync'));
          END IF;
        ELSE
          fc := rec.payload->'finance_category';
          IF fc IS NULL OR jsonb_typeof(fc) <> 'object' THEN
            RAISE EXCEPTION 'Finance category payload is missing.';
          END IF;
          IF NULLIF(fc->>'name', '') IS NULL THEN
            RAISE EXCEPTION 'A person needs a name.';
          END IF;
          INSERT INTO public.pos_finance_categories (
            id, customer_id, name, created_at, updated_at, deleted_at)
          VALUES (
            rec.entity_id, p_customer, fc->>'name',
            COALESCE((fc->>'created_at')::timestamptz, now()),
            COALESCE((fc->>'updated_at')::timestamptz, now()),
            (fc->>'deleted_at')::timestamptz)
          ON CONFLICT (customer_id, id) DO UPDATE SET
            name       = EXCLUDED.name,
            deleted_at = EXCLUDED.deleted_at,
            updated_at = EXCLUDED.updated_at
          WHERE public.pos_finance_categories.updated_at IS NULL
             OR public.pos_finance_categories.updated_at < EXCLUDED.updated_at;
        END IF;

      ELSIF rec.entity_type = 'finance_entry' THEN
        fe := rec.payload->'finance_entry';
        IF fe IS NULL OR jsonb_typeof(fe) <> 'object' THEN
          RAISE EXCEPTION 'Finance entry payload is missing.';
        END IF;
        SELECT id, deleted_at INTO cat_row FROM public.pos_finance_categories
        WHERE customer_id = p_customer AND id = COALESCE(fe->>'category_id', '');
        IF NOT FOUND THEN
          skipped := skipped + 1;
          CONTINUE;
        END IF;
        IF cat_row.deleted_at IS NOT NULL THEN
          RAISE EXCEPTION 'The person this collection belongs to is in the recycle bin.';
        END IF;
        INSERT INTO public.pos_finance_entries (
          id, customer_id, category_id, source, amount_minor_units, description,
          status, entry_date, created_at, created_by, completed_at, completed_by,
          updated_at, payment_method)
        VALUES (
          rec.entity_id, p_customer, cat_row.id,
          COALESCE(fe->>'source', ''),
          COALESCE((fe->>'amount_minor_units')::bigint, 0),
          fe->>'description',
          upper(COALESCE(NULLIF(fe->>'status', ''), 'PENDING')),
          COALESCE((fe->>'entry_date')::timestamptz, now()),
          COALESCE((fe->>'created_at')::timestamptz, now()),
          NULLIF(fe->>'created_by', ''),
          (fe->>'completed_at')::timestamptz,
          NULLIF(fe->>'completed_by', ''),
          COALESCE((fe->>'updated_at')::timestamptz, now()),
          NULLIF(fe->>'payment_method', ''))
        ON CONFLICT (customer_id, id) DO UPDATE SET
          source             = EXCLUDED.source,
          amount_minor_units = EXCLUDED.amount_minor_units,
          description        = EXCLUDED.description,
          status             = EXCLUDED.status,
          entry_date         = EXCLUDED.entry_date,
          completed_at       = EXCLUDED.completed_at,
          completed_by       = EXCLUDED.completed_by,
          payment_method     = EXCLUDED.payment_method,
          updated_at         = EXCLUDED.updated_at
        WHERE public.pos_finance_entries.updated_at IS NULL
           OR public.pos_finance_entries.updated_at < EXCLUDED.updated_at;

      ELSIF rec.entity_type = 'picklist' THEN
        pk := rec.payload->'picklist';
        IF pk IS NULL OR jsonb_typeof(pk) <> 'object' THEN
          RAISE EXCEPTION 'Picklist payload is missing.';
        END IF;
        IF NULLIF(pk->>'customer_name', '') IS NULL THEN
          RAISE EXCEPTION 'A picklist needs a customer name.';
        END IF;
        INSERT INTO public.picklists (
          id, customer_id, customer_name, status, created_by,
          created_at, updated_at, deleted_at, received_at)
        VALUES (
          rec.entity_id, p_customer, pk->>'customer_name',
          upper(COALESCE(NULLIF(pk->>'status', ''), 'PENDING')),
          COALESCE(pk->>'created_by', ''),
          COALESCE((pk->>'created_at')::timestamptz, now()),
          COALESCE((pk->>'updated_at')::timestamptz, now()),
          NULLIF(pk->>'deleted_at', '')::timestamptz,
          now())
        ON CONFLICT (customer_id, id) DO UPDATE SET
          customer_name = EXCLUDED.customer_name,
          status        = EXCLUDED.status,
          updated_at    = EXCLUDED.updated_at,
          deleted_at    = COALESCE(EXCLUDED.deleted_at, public.picklists.deleted_at)
        WHERE public.picklists.updated_at IS NULL
           OR public.picklists.updated_at < EXCLUDED.updated_at;

      ELSIF rec.entity_type = 'picklist_item' THEN
        pi := rec.payload->'picklist_item';
        IF pi IS NULL OR jsonb_typeof(pi) <> 'object' THEN
          RAISE EXCEPTION 'Picklist item payload is missing.';
        END IF;
        SELECT id INTO pl_row FROM public.picklists
        WHERE customer_id = p_customer AND id = COALESCE(pi->>'picklist_id', '');
        IF pl_row IS NULL THEN
          skipped := skipped + 1;
          CONTINUE;
        END IF;
        INSERT INTO public.picklist_items (
          id, customer_id, picklist_id, product_name, requested_qty,
          taken_qty, unit, unit_price_minor_units, line_total_minor_units,
          updated_at, deleted_at, received_at)
        VALUES (
          rec.entity_id, p_customer, pl_row,
          COALESCE(pi->>'product_name', ''),
          COALESCE((pi->>'requested_qty')::int, 0),
          COALESCE((pi->>'taken_qty')::int, 0),
          COALESCE(pi->>'unit', ''),
          COALESCE((pi->>'unit_price_minor_units')::int, 0),
          COALESCE((pi->>'line_total_minor_units')::int, 0),
          COALESCE((pi->>'updated_at')::timestamptz, now()),
          NULLIF(pi->>'deleted_at', '')::timestamptz,
          now())
        ON CONFLICT (customer_id, id) DO UPDATE SET
          product_name  = EXCLUDED.product_name,
          requested_qty = EXCLUDED.requested_qty,
          taken_qty     = EXCLUDED.taken_qty,
          unit = EXCLUDED.unit,
          unit_price_minor_units = EXCLUDED.unit_price_minor_units,
          line_total_minor_units = EXCLUDED.line_total_minor_units,
          updated_at    = EXCLUDED.updated_at,
          deleted_at    = COALESCE(EXCLUDED.deleted_at, public.picklist_items.deleted_at)
        WHERE public.picklist_items.updated_at IS NULL
           OR public.picklist_items.updated_at < EXCLUDED.updated_at;

      ELSE
        RAISE EXCEPTION 'Unknown entity type: %', rec.entity_type;
      END IF;

      UPDATE public.sync_mirror
      SET apply_status = 'APPLIED', applied_at = now(), apply_error = NULL
      WHERE customer_id = p_customer
        AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
      applied := applied + 1;

    EXCEPTION WHEN OTHERS THEN
      UPDATE public.sync_mirror
      SET apply_status = 'REJECTED', applied_at = now(), apply_error = SQLERRM
      WHERE customer_id = p_customer
        AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
      rejected := rejected + 1;
    END;
  END LOOP;

  SELECT count(*) INTO left_over FROM public.sync_mirror
  WHERE customer_id = p_customer AND apply_status = 'PENDING';

  RETURN jsonb_build_object(
    'applied', applied, 'rejected', rejected, 'pending', left_over,
    'deferred', skipped);
END;
$$;
REVOKE ALL ON FUNCTION pos_sync_apply(uuid, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION pos_sync_apply(uuid, int) TO service_role;
