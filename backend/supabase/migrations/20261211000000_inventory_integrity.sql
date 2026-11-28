-- Inventory integrity hardening (follows 20261209000000 + 20261210000000,
-- neither of which has been applied to any environment).
--
--   1. store_inventory gains composite foreign keys to its store and product
--      parents plus non-negative quantity CHECKs. Deletes are RESTRICT: the
--      sync model tombstones, and hard-deleting a parent must never orphan
--      or cascade away stock history.
--   2. pos_delete_store: the atomic server-side store deletion. Locks the
--      store row, refuses while any live store_inventory row references it
--      (zero-quantity counts), then tombstones — one transaction, no
--      check-then-act race for the API path.
--   3. pos_sync_apply: a store tombstone arriving while live inventory
--      still references the store is DEFERRED (stays PENDING) instead of
--      being acknowledged; store_inventory now locks its store parent so a
--      concurrent delete cannot slip between the parent check and the
--      insert; product_image deleted_at follows the newest payload so a
--      newer upload restores an image a newer delete removed.
--   4. pos_create_inventory_product: the store existence check now takes
--      FOR UPDATE, serializing with pos_delete_store.
--
-- Function bodies below are the 20261210000000 versions with only the
-- targeted changes described above; every request3 financial, licensing,
-- authorization, sales, warehouse and sync behaviour is preserved.

-- ===========================================================================
-- 1. Referential integrity on store_inventory
-- ===========================================================================

-- stores needs a real UNIQUE constraint (not just the unique index) before it
-- can be an FK target.
ALTER TABLE public.stores
  ADD CONSTRAINT stores_customer_id_id_key UNIQUE USING INDEX stores_customer_id;

ALTER TABLE public.store_inventory
  ADD CONSTRAINT store_inventory_store_fkey
    FOREIGN KEY (customer_id, store_id)
    REFERENCES public.stores (customer_id, id) ON DELETE RESTRICT,
  ADD CONSTRAINT store_inventory_product_fkey
    FOREIGN KEY (customer_id, product_id)
    REFERENCES public.pos_products (customer_id, id) ON DELETE RESTRICT,
  ADD CONSTRAINT store_inventory_on_hand_nonneg
    CHECK (on_hand_milliunits >= 0),
  ADD CONSTRAINT store_inventory_reorder_nonneg
    CHECK (reorder_milliunits >= 0);

-- ===========================================================================
-- 2. Atomic store deletion (service_role only)
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.pos_delete_store(
  p_customer uuid,
  p_store_id text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_deleted timestamptz;
BEGIN
  -- Lock the store row first: pos_create_inventory_product and the
  -- store_inventory sync branch take the same lock, so a stock write and a
  -- store delete serialize instead of racing past each other.
  SELECT deleted_at INTO v_deleted
  FROM public.stores
  WHERE customer_id = p_customer AND id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Store not found.';
  END IF;
  IF v_deleted IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'already_deleted', true);
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.store_inventory
    WHERE customer_id = p_customer AND store_id = p_store_id
      AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Store still has inventory records.';
  END IF;

  UPDATE public.stores
  SET deleted_at = now(), updated_at = now()
  WHERE customer_id = p_customer AND id = p_store_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION public.pos_delete_store(uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pos_delete_store(uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.pos_delete_store(uuid, text) TO postgres;

-- ===========================================================================
-- 1. Atomic product + opening stock + optional image for pos-api
-- ===========================================================================
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
  v_image      text := NULLIF(p_product->>'image_data', '');
  v_rows       bigint;
BEGIN
  IF v_name = '' THEN RAISE EXCEPTION 'A product name is required.'; END IF;
  IF v_unit = '' THEN RAISE EXCEPTION 'A unit is required.'; END IF;
  IF v_sell < 0 OR v_buy < 0 THEN RAISE EXCEPTION 'Prices cannot be negative.'; END IF;
  IF p_on_hand < 0 OR p_reorder < 0 THEN
    RAISE EXCEPTION 'Quantities cannot be negative.';
  END IF;
  -- Lock the live store row: pos_delete_store takes the same lock before
  -- tombstoning, so stock creation and store deletion serialize on it.
  PERFORM 1 FROM public.stores
  WHERE customer_id = p_customer AND id = p_store_id AND deleted_at IS NULL
  FOR UPDATE;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
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

  -- Same image budget pos_sync_apply enforces: ~190 KB base64 is what the
  -- encodeProof pipeline guarantees; 400k chars leaves headroom.
  IF v_image IS NOT NULL THEN
    IF length(v_image) > 400000
       OR (length(v_image) % 4) <> 0
       OR v_image !~ '^[A-Za-z0-9+/]+={0,2}$' THEN
      RAISE EXCEPTION 'Product image is not valid base64 image data.';
    END IF;
  END IF;

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

  -- Optional photo, same transaction: an invalid image raises above and
  -- rolls the product and its opening stock back with it.
  IF v_image IS NOT NULL THEN
    INSERT INTO public.product_images (
      customer_id, product_id, image_data, created_at, updated_at)
    VALUES (p_customer, v_product_id, v_image, now(), now());
  END IF;

  RETURN jsonb_build_object(
    'product_id', v_product_id, 'inventory_id', v_inv_id);
END;
$$;
REVOKE ALL ON FUNCTION public.pos_create_inventory_product(uuid, text, jsonb, text, bigint, bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pos_create_inventory_product(uuid, text, jsonb, text, bigint, bigint)
  TO service_role;

-- ===========================================================================
-- 2. pos_sync_apply — request3-final body + inventory entity branches
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.pos_sync_apply (
  p_customer            uuid,
  p_limit               integer,
  p_device_fingerprint  text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
DECLARE
  rec              record;
  applied          int := 0;
  rejected         int := 0;
  deferred         int := 0;
  retryable        int := 0;
  left_over        int := 0;
  s                jsonb;
  items            jsonb;
  shift_id         text;
  device           text;
  mv               jsonb;
  vr               jsonb;
  us               jsonb;
  pr               jsonb;
  fc               jsonb;
  fe               jsonb;
  pk               jsonb;
  pi               jsonb;
  sale_row         record;
  cat_row          record;
  user_row         record;
  pl_row           text;
  perms            jsonb;
  skipped          int := 0;
  v_actor_id       text;
  v_actor_role     text;
  v_actor_perms    jsonb;
  v_existing_role  text;
  v_entry_status   text;
  v_new_active     bool;
  v_new_deleted    timestamptz;
  v_defer_reason   text;
  -- Finance attribution: creator, completer and deleter are resolved
  -- independently through their own staged grant digests.
  v_created_id     text;
  v_created_role   text;
  v_created_perms  jsonb;
  v_completer_id   text;
  v_completer_role text;
  v_completer_perms jsonb;
  v_deleter_id     text;
  v_deleter_role   text;
  v_deleter_perms  jsonb;
  v_req_status     text;
  v_want_complete  boolean;
  v_want_delete    boolean;
  v_legacy_count   int;
  st               jsonb;
  si               jsonb;
  pimg             jsonb;
  v_row_count      int;
BEGIN
  FOR rec IN
    SELECT entity_type, entity_id, operation, device_id, payload,
           actor_grant_hash, actor_grant_hashes
    FROM public.sync_mirror
    WHERE customer_id = p_customer AND apply_status = 'PENDING'
    -- Parents before children, whatever order they arrived in.
    ORDER BY CASE entity_type
        WHEN 'user'              THEN 0
        WHEN 'product'           THEN 1
        WHEN 'store'             THEN 2
        WHEN 'product_image'     THEN 3
        WHEN 'store_inventory'   THEN 4
        WHEN 'finance_category'  THEN 5
        WHEN 'shift'             THEN 6
        WHEN 'sale'              THEN 7
        WHEN 'cash_movement'     THEN 8
        WHEN 'void_request'      THEN 9
        WHEN 'finance_entry'     THEN 10
        WHEN 'picklist'          THEN 11
        WHEN 'picklist_item'     THEN 12
        ELSE 13
      END, received_at, entity_id
    LIMIT COALESCE(NULLIF(p_limit, 0), 200)
    FOR UPDATE SKIP LOCKED
  LOOP
    BEGIN
      v_defer_reason := NULL;
      v_actor_id := NULL;
      v_actor_role := NULL;
      v_actor_perms := '[]'::jsonb;

      -- ---------------------------------------------------------------
      -- Resolve the human actor. A licence authenticates the DEVICE, not a
      -- person; only a server-issued grant names the user. The grant must
      -- belong to this tenant, this device, and be live.
      -- ---------------------------------------------------------------
      IF p_device_fingerprint IS NULL
         OR btrim(p_device_fingerprint) = ''
         OR rec.device_id IS DISTINCT FROM p_device_fingerprint THEN
        v_defer_reason :=
          'ACTOR_AUTH_REQUIRED: device identity is not the licensed device.';
      ELSIF rec.actor_grant_hash IS NULL
            OR btrim(rec.actor_grant_hash) = '' THEN
        v_defer_reason :=
          'ACTOR_AUTH_REQUIRED: no actor grant was presented for this entry.';
      ELSE
        SELECT g.user_id, g.role, g.permissions
          INTO v_actor_id, v_actor_role, v_actor_perms
        FROM public.pos_resolve_actor_grant(
          p_customer, rec.actor_grant_hash, p_device_fingerprint) g;
        IF v_actor_id IS NULL THEN
          v_defer_reason :=
            'ACTOR_AUTH_REQUIRED: actor grant is expired, revoked, or invalid.';
        END IF;
      END IF;

      IF v_defer_reason IS NOT NULL THEN
        -- Leave the row PENDING so the client keeps its outbox entry and can
        -- retry after acquiring a grant. Moving received_at to now() keeps a
        -- large deferred backlog from starving later rows.
        UPDATE public.sync_mirror
        SET apply_error = v_defer_reason,
            applied_at = NULL,
            received_at = now()
        WHERE customer_id = p_customer
          AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
        deferred := deferred + 1;
        CONTINUE;
      END IF;

      -- A device may only delete master data it owns the lifecycle of. Ledger
      -- rows are immutable money and are refused below as they always were.
      IF upper(rec.operation) = 'DELETE'
         AND rec.entity_type <> 'finance_category' THEN
        RAISE EXCEPTION 'A device cannot delete a cloud record.';
      END IF;

      -- A training account's money stays on the till that rang it up. The
      -- actor is now the resolved grant user, never a payload claim.
      IF rec.entity_type IN (
           'sale', 'shift', 'cash_movement', 'void_request', 'finance_entry') THEN
        IF public.pos_is_demo(p_customer, v_actor_id) THEN
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
        PERFORM public.pos_require_feature(p_customer, v_actor_id, 'pos');
        s := rec.payload->'sale';
        items := rec.payload->'items';
        IF s IS NULL OR jsonb_typeof(s) <> 'object' THEN
          RAISE EXCEPTION 'Sale payload is missing its header.';
        END IF;
        IF items IS NULL OR jsonb_typeof(items) <> 'array'
           OR jsonb_array_length(items) = 0 THEN
          RAISE EXCEPTION 'Sale payload has no line items.';
        END IF;
        device  := COALESCE(NULLIF(s->>'device_id', ''),
                            NULLIF(rec.device_id, ''), 'sync');
        -- The till owns the drawer: land the device's sale on the tenant's
        -- current open shift. pos_create_sale recomputes every figure.
        shift_id := public.pos_ensure_shift(p_customer, v_actor_id, NULL);
        PERFORM public.pos_create_sale(
          p_customer,
          v_actor_id,
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
        PERFORM public.pos_require_feature(p_customer, v_actor_id, 'register');
        mv := rec.payload->'cash_movement';
        IF mv IS NULL OR jsonb_typeof(mv) <> 'object' THEN
          RAISE EXCEPTION 'Cash movement payload is missing.';
        END IF;
        shift_id := public.pos_ensure_shift(
          p_customer, v_actor_id, NULL);
        PERFORM public.pos_add_cash_movement(
          p_customer,
          v_actor_id,
          shift_id,
          upper(COALESCE(mv->>'type', '')),
          abs(COALESCE((mv->>'amount_minor_units')::bigint, 0)),
          mv->>'reason',
          NULLIF(mv->>'photo', ''),
          rec.entity_id,
          NULLIF(mv->>'source_finance_entry_id', ''));

      ELSIF rec.entity_type = 'void_request' THEN
        PERFORM public.pos_require_any_feature(
          p_customer, v_actor_id,
          ARRAY['pos', 'history', 'register_history']);
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
        VALUES (rec.entity_id, p_customer, sale_row.id, v_actor_id,
          COALESCE(vr->>'reason', ''), 'PENDING',
          COALESCE((vr->>'created_at')::timestamptz, now()), now())
        ON CONFLICT (customer_id, id) DO NOTHING;

      ELSIF rec.entity_type = 'shift' THEN
        PERFORM public.pos_require_feature(p_customer, v_actor_id, 'register');
        us := rec.payload->'shift';
        IF us IS NULL OR jsonb_typeof(us) <> 'object' THEN
          RAISE EXCEPTION 'Shift payload is missing.';
        END IF;
        IF upper(COALESCE(us->>'status', 'OPEN')) = 'OPEN' THEN
          PERFORM public.pos_ensure_shift(
            p_customer, v_actor_id,
            COALESCE(NULLIF(us->>'device_id', ''),
                     NULLIF(rec.device_id, ''), 'sync'));
        END IF;

      -- =====================================================================
      -- Master data
      -- =====================================================================

      ELSIF rec.entity_type = 'user' THEN
        -- Account provisioning is an OWNER action. A device may create a
        -- CASHIER (offline provisioning) and edit non-credential fields of an
        -- existing CASHIER, but it may never create/promote an OWNER, touch an
        -- OWNER row, change the demo account, or replace an existing
        -- credential. Credential changes go through live pos-api only.
        IF v_actor_role IS DISTINCT FROM 'OWNER' THEN
          RAISE EXCEPTION 'Only an owner can provision or change accounts.';
        END IF;
        us := rec.payload->'user';
        IF us IS NULL OR jsonb_typeof(us) <> 'object' THEN
          RAISE EXCEPTION 'User payload is missing.';
        END IF;
        IF NULLIF(us->>'username', '') IS NULL THEN
          RAISE EXCEPTION 'Account payload has no login name.';
        END IF;
        IF upper(COALESCE(us->>'role', 'CASHIER')) = 'OWNER' THEN
          RAISE EXCEPTION 'A device cannot create or promote an owner account.';
        END IF;
        SELECT role INTO v_existing_role FROM public.pos_users
        WHERE customer_id = p_customer AND id = rec.entity_id;
        IF FOUND AND v_existing_role = 'OWNER' THEN
          RAISE EXCEPTION 'Owner accounts cannot be changed by a device.';
        END IF;
        IF EXISTS (
          SELECT 1 FROM public.pos_users
          WHERE customer_id = p_customer AND id = rec.entity_id AND is_demo
        ) THEN
          RAISE EXCEPTION 'The demo account is managed by the server.';
        END IF;
        SELECT id INTO user_row FROM public.pos_users
        WHERE customer_id = p_customer
          AND lower(username) = lower(us->>'username')
          AND id <> rec.entity_id
        LIMIT 1;
        IF FOUND THEN
          RAISE EXCEPTION 'That login is already in use by another account.';
        END IF;
        perms := CASE
          WHEN btrim(COALESCE(us->>'permissions', '')) = '' THEN '[]'::jsonb
          WHEN left(btrim(us->>'permissions'), 1) IN ('[', '{')
            THEN btrim(us->>'permissions')::jsonb
          ELSE '[]'::jsonb
        END;
        v_new_active := COALESCE((us->>'is_active')::int, 1) = 1;
        v_new_deleted := NULLIF(us->>'deleted_at', '')::timestamptz;

        IF v_existing_role IS NOT NULL THEN
          -- Existing CASHIER: apply owner-editable state, never role,
          -- credentials, or is_demo.
          UPDATE public.pos_users
          SET username    = us->>'username',
              permissions = perms,
              active      = v_new_active,
              deleted_at  = v_new_deleted,
              updated_at  = COALESCE((us->>'updated_at')::timestamptz, now())
          WHERE customer_id = p_customer AND id = rec.entity_id
            AND role <> 'OWNER'
            AND (updated_at IS NULL
                 OR updated_at < COALESCE((us->>'updated_at')::timestamptz,
                                          updated_at + interval '1 second'));
        ELSE
          -- New CASHIER only. Credentials are provisioning material and are
          -- accepted here; the role is forced, never taken from the device.
          INSERT INTO public.pos_users (
            id, customer_id, username, role, pw_salt, pw_hash, active,
            permissions, is_demo, deleted_at, created_at, updated_at)
          VALUES (
            rec.entity_id, p_customer, us->>'username', 'CASHIER',
            COALESCE(NULLIF(us->>'pw_salt', ''), gen_random_uuid()::text),
            COALESCE(NULLIF(us->>'pw_hash', ''),
                     md5(random()::text || clock_timestamp()::text)),
            v_new_active,
            perms,
            false,
            NULL,
            COALESCE((us->>'created_at')::timestamptz, now()),
            COALESCE((us->>'updated_at')::timestamptz, now()));
        END IF;

      ELSIF rec.entity_type = 'product' THEN
        PERFORM public.pos_require_feature(p_customer, v_actor_id, 'pos');
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
          selling_price_minor_units, is_active, created_at, updated_at)
        VALUES (
          rec.entity_id, p_customer, pr->>'name', pr->>'code', pr->>'category',
          pr->>'unit', COALESCE((pr->>'selling_price_minor_units')::bigint, 0),
          COALESCE((pr->>'is_active')::int, 1),
          COALESCE((pr->>'created_at')::timestamptz, now()),
          COALESCE((pr->>'updated_at')::timestamptz, now()))
        ON CONFLICT (customer_id, id) DO UPDATE SET
          name                     = EXCLUDED.name,
          code                     = EXCLUDED.code,
          category                 = EXCLUDED.category,
          unit                     = EXCLUDED.unit,
          selling_price_minor_units = EXCLUDED.selling_price_minor_units,
          is_active                = EXCLUDED.is_active,
          updated_at               = EXCLUDED.updated_at
        WHERE public.pos_products.updated_at IS NULL
           OR public.pos_products.updated_at < EXCLUDED.updated_at;

      ELSIF rec.entity_type = 'finance_category' THEN
        PERFORM public.pos_require_feature(p_customer, v_actor_id, 'finance');
        IF upper(rec.operation) = 'DELETE' THEN
          IF NOT EXISTS (SELECT 1 FROM public.pos_finance_categories
                         WHERE customer_id = p_customer AND id = rec.entity_id) THEN
            NULL;
          ELSE
            UPDATE public.pos_finance_categories
            SET deleted_at = COALESCE(deleted_at, now())
            WHERE customer_id = p_customer AND id = rec.entity_id;
            PERFORM public.pos_delete_finance_category(
              p_customer, rec.entity_id, v_actor_id);
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

        -- The CREATOR is resolved through the grant staged under the payload's
        -- created_by key (falling back to the row's primary grant). The key
        -- only selects the digest; the resolved user id is what is recorded.
        SELECT g.user_id, g.role, g.permissions
          INTO v_created_id, v_created_role, v_created_perms
        FROM public.pos_resolve_staged_actor(
          p_customer, rec.actor_grant_hashes,
          fe->>'created_by', rec.actor_grant_hash,
          p_device_fingerprint) g;
        IF v_created_id IS NULL THEN
          UPDATE public.sync_mirror
          SET apply_error =
                'ACTOR_AUTH_REQUIRED: creator grant is expired, revoked, or invalid.',
              received_at = now()
          WHERE customer_id = p_customer
            AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
          deferred := deferred + 1;
          CONTINUE;
        END IF;
        PERFORM public.pos_require_feature(p_customer, v_created_id, 'finance');

        -- The payload's final status is NOT the whole story: creation,
        -- completion and deletion are three independently authorized acts
        -- that can ALL happen while the device is offline. Replay each one
        -- through its own locked RPC with its own resolved actor, so
        -- created_by stays the creator, completed_by/completed_at (and the
        -- FINANCE_COMPLETED audit) belong to the completer, and the delete —
        -- with its own audit — belongs to the deleter.
        v_req_status := upper(COALESCE(fe->>'status', ''));
        -- A completion is requested by a COMPLETED final status, or by a
        -- DELETED final status whose row still carries completed_by (the
        -- local ledger only sets that column inside markCompleted, so its
        -- presence proves the completion happened before the delete).
        v_want_complete := v_req_status = 'COMPLETED'
           OR (v_req_status = 'DELETED'
               AND NULLIF(fe->>'completed_by', '') IS NOT NULL);
        v_want_delete := v_req_status = 'DELETED';

        -- Resolve the COMPLETER through the grant staged under completed_by
        -- (NULL key falls back to the row's primary grant, preserving the
        -- single-actor behaviour for legacy payloads). Resolve BEFORE writing
        -- so a missing grant defers the whole row instead of half-applying it.
        IF v_want_complete THEN
          SELECT g.user_id, g.role, g.permissions
            INTO v_completer_id, v_completer_role, v_completer_perms
          FROM public.pos_resolve_staged_actor(
            p_customer, rec.actor_grant_hashes,
            NULLIF(fe->>'completed_by', ''),
            rec.actor_grant_hash, p_device_fingerprint) g;
          IF v_completer_id IS NULL THEN
            UPDATE public.sync_mirror
            SET apply_error =
                  'ACTOR_AUTH_REQUIRED: completion grant is expired, revoked, or invalid.',
                received_at = now()
            WHERE customer_id = p_customer
              AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
            deferred := deferred + 1;
            CONTINUE;
          END IF;
          PERFORM public.pos_require_feature(p_customer, v_completer_id, 'finance');
        ELSE
          v_completer_id := NULL;
        END IF;

        -- Resolve the DELETER independently: deleted_by first, then
        -- completed_by for rows written before the column existed, then the
        -- primary grant — the same fallback chain as before, but now it is a
        -- separate actor slot rather than the row's only transition.
        IF v_want_delete THEN
          SELECT g.user_id, g.role, g.permissions
            INTO v_deleter_id, v_deleter_role, v_deleter_perms
          FROM public.pos_resolve_staged_actor(
            p_customer, rec.actor_grant_hashes,
            COALESCE(NULLIF(fe->>'deleted_by', ''),
                     NULLIF(fe->>'completed_by', '')),
            rec.actor_grant_hash, p_device_fingerprint) g;
          IF v_deleter_id IS NULL THEN
            UPDATE public.sync_mirror
            SET apply_error =
                  'ACTOR_AUTH_REQUIRED: deletion grant is expired, revoked, or invalid.',
                received_at = now()
            WHERE customer_id = p_customer
              AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
            deferred := deferred + 1;
            CONTINUE;
          END IF;
          PERFORM public.pos_require_feature(p_customer, v_deleter_id, 'finance');
        ELSE
          v_deleter_id := NULL;
        END IF;

        SELECT id, deleted_at INTO cat_row FROM public.pos_finance_categories
        WHERE customer_id = p_customer AND id = COALESCE(fe->>'category_id', '');
        IF NOT FOUND THEN
          -- The person has not landed yet: leave it PENDING for the next pass.
          UPDATE public.sync_mirror
          SET apply_error = 'DEFERRED: finance category has not landed yet.',
              received_at = now()
          WHERE customer_id = p_customer
            AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
          deferred := deferred + 1;
          CONTINUE;
        END IF;
        IF cat_row.deleted_at IS NOT NULL THEN
          RAISE EXCEPTION 'The person this collection belongs to is in the recycle bin.';
        END IF;
        -- Client-supplied status/completed_at/completed_by/created_by are
        -- ignored for the WRITE: created_by is the resolved creator, and a new
        -- row is always PENDING until the locked RPCs transition it.
        INSERT INTO public.pos_finance_entries (
          id, customer_id, category_id, source, amount_minor_units, description,
          status, entry_date, created_at, created_by, completed_at, completed_by,
          updated_at, payment_method)
        VALUES (
          rec.entity_id, p_customer, cat_row.id,
          COALESCE(fe->>'source', ''),
          COALESCE((fe->>'amount_minor_units')::bigint, 0),
          fe->>'description',
          'PENDING',
          COALESCE((fe->>'entry_date')::timestamptz, now()),
          COALESCE((fe->>'created_at')::timestamptz, now()),
          v_created_id,
          NULL,
          NULL,
          COALESCE((fe->>'updated_at')::timestamptz, now()),
          NULLIF(fe->>'payment_method', ''))
        ON CONFLICT (customer_id, id) DO UPDATE SET
          source             = EXCLUDED.source,
          amount_minor_units = EXCLUDED.amount_minor_units,
          description        = EXCLUDED.description,
          entry_date         = EXCLUDED.entry_date,
          payment_method     = EXCLUDED.payment_method,
          updated_at         = EXCLUDED.updated_at
        WHERE public.pos_finance_entries.status = 'PENDING'
          AND (public.pos_finance_entries.updated_at IS NULL
               OR public.pos_finance_entries.updated_at < EXCLUDED.updated_at);

        SELECT status INTO v_entry_status FROM public.pos_finance_entries
        WHERE customer_id = p_customer AND id = rec.entity_id;

        -- Replay the requested transitions in order. Each RPC re-locks the
        -- entry row, re-checks the actor's live permissions, writes its own
        -- audit row, and is idempotent against the device-pushed cash legs
        -- (one deposit and one reversal per collection, never two).
        IF v_want_complete AND v_entry_status = 'PENDING' THEN
          PERFORM public.pos_complete_finance(
            p_customer, v_completer_id, rec.entity_id);
          SELECT status INTO v_entry_status FROM public.pos_finance_entries
          WHERE customer_id = p_customer AND id = rec.entity_id;
        END IF;
        IF v_want_delete AND v_entry_status IS DISTINCT FROM 'DELETED' THEN
          -- A pre-20261204 device queued its reversal without the collection
          -- link. If more than one unlinked reversal matches this collection,
          -- deleting would either duplicate the money or require a guess.
          -- Leave the row PENDING with a durable marker; the payload and the
          -- movements stay exactly as they are for operator resolution.
          SELECT count(*) INTO v_legacy_count
          FROM public.pos_legacy_reversal_candidates(
            p_customer, rec.entity_id, v_deleter_id);
          IF v_legacy_count > 1 THEN
            UPDATE public.sync_mirror
            SET apply_error = 'LEGACY_REVERSAL_AMBIGUOUS: ' || v_legacy_count
                  || ' unlinked reversal movements match this collection; link the correct movement before retrying.',
                applied_at = NULL,
                received_at = now()
            WHERE customer_id = p_customer
              AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
            deferred := deferred + 1;
            CONTINUE;
          END IF;
          PERFORM public.pos_delete_finance_entry(
            p_customer, v_deleter_id, rec.entity_id);
        END IF;

      -- =====================================================================
      -- Warehouse picklists
      -- =====================================================================

      ELSIF rec.entity_type = 'picklist' THEN
        PERFORM public.pos_require_any_feature(
          p_customer, v_actor_id, ARRAY['warehouse', 'warehouse_fill']);
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
          v_actor_id,
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
        PERFORM public.pos_require_any_feature(
          p_customer, v_actor_id, ARRAY['warehouse', 'warehouse_fill']);
        pi := rec.payload->'picklist_item';
        IF pi IS NULL OR jsonb_typeof(pi) <> 'object' THEN
          RAISE EXCEPTION 'Picklist item payload is missing.';
        END IF;
        SELECT id INTO pl_row FROM public.picklists
        WHERE customer_id = p_customer AND id = COALESCE(pi->>'picklist_id', '');
        IF pl_row IS NULL THEN
          UPDATE public.sync_mirror
          SET apply_error = 'DEFERRED: picklist header has not landed yet.',
              received_at = now()
          WHERE customer_id = p_customer
            AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
          deferred := deferred + 1;
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

      -- =====================================================================
      -- Inventory foundation: stores, per-store stock, product images
      -- =====================================================================

      ELSIF rec.entity_type = 'store' THEN
        PERFORM public.pos_require_feature(p_customer, v_actor_id, 'inventory');
        st := rec.payload->'store';
        IF st IS NULL OR jsonb_typeof(st) <> 'object' THEN
          RAISE EXCEPTION 'Store payload is missing.';
        END IF;
        IF NULLIF(btrim(COALESCE(st->>'name', '')), '') IS NULL THEN
          RAISE EXCEPTION 'A store needs a name.';
        END IF;
        -- A store tombstone must not be acknowledged while live per-store
        -- stock still references it: deleting now would orphan live
        -- inventory. Lock the store row FIRST — the same lock
        -- pos_delete_store and the store_inventory writer take — so a
        -- concurrent stock write cannot slip between this check and the
        -- tombstone. Lock order is store-then-inventory everywhere.
        IF NULLIF(st->>'deleted_at', '') IS NOT NULL THEN
          PERFORM 1 FROM public.stores
          WHERE customer_id = p_customer AND id = rec.entity_id
          FOR UPDATE;
          IF FOUND AND EXISTS (
            SELECT 1 FROM public.store_inventory
            WHERE customer_id = p_customer
              AND store_id = rec.entity_id
              AND deleted_at IS NULL
          ) THEN
            UPDATE public.sync_mirror
            SET apply_error = 'DEFERRED: store still has live inventory.',
                received_at = now()
            WHERE customer_id = p_customer
              AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
            deferred := deferred + 1;
            CONTINUE;
          END IF;
        END IF;

        INSERT INTO public.stores (
          id, customer_id, name, created_at, updated_at, deleted_at, received_at)
        VALUES (
          rec.entity_id, p_customer, btrim(st->>'name'),
          COALESCE((st->>'created_at')::timestamptz, now()),
          COALESCE((st->>'updated_at')::timestamptz, now()),
          NULLIF(st->>'deleted_at', '')::timestamptz,
          now())
        ON CONFLICT (id) DO UPDATE SET
          name       = EXCLUDED.name,
          updated_at = EXCLUDED.updated_at,
          deleted_at = COALESCE(EXCLUDED.deleted_at, public.stores.deleted_at)
        WHERE public.stores.customer_id = p_customer
          AND (public.stores.updated_at IS NULL
               OR public.stores.updated_at < EXCLUDED.updated_at);
        GET DIAGNOSTICS v_row_count = ROW_COUNT;
        -- A same-id row under another tenant can never be overwritten: the
        -- conflict target is the global `id` primary key, so the tenant guard
        -- above skips the update. Refuse loudly instead of acking a no-op.
        IF v_row_count = 0 AND EXISTS (
          SELECT 1 FROM public.stores
          WHERE id = rec.entity_id AND customer_id <> p_customer
        ) THEN
          RAISE EXCEPTION 'Store % belongs to another tenant.', rec.entity_id;
        END IF;

      ELSIF rec.entity_type = 'store_inventory' THEN
        PERFORM public.pos_require_feature(p_customer, v_actor_id, 'inventory');
        si := rec.payload->'store_inventory';
        IF si IS NULL OR jsonb_typeof(si) <> 'object' THEN
          RAISE EXCEPTION 'Store inventory payload is missing.';
        END IF;
        -- Both parents are foreign keys. A missing store or product leaves
        -- the row PENDING for the next pass — deferral, never data loss.
        PERFORM 1 FROM public.stores
        WHERE customer_id = p_customer
          AND id = COALESCE(si->>'store_id', '')
          AND deleted_at IS NULL
        FOR UPDATE;
        GET DIAGNOSTICS v_row_count = ROW_COUNT;
        IF v_row_count = 0 THEN
          UPDATE public.sync_mirror
          SET apply_error = 'DEFERRED: store has not landed yet.',
              received_at = now()
          WHERE customer_id = p_customer
            AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
          deferred := deferred + 1;
          CONTINUE;
        END IF;
        IF NOT EXISTS (
          SELECT 1 FROM public.pos_products
          WHERE customer_id = p_customer
            AND id = COALESCE(si->>'product_id', '')
        ) THEN
          UPDATE public.sync_mirror
          SET apply_error = 'DEFERRED: product has not landed yet.',
              received_at = now()
          WHERE customer_id = p_customer
            AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
          deferred := deferred + 1;
          CONTINUE;
        END IF;
        INSERT INTO public.store_inventory (
          id, customer_id, store_id, product_id,
          on_hand_milliunits, reorder_milliunits,
          created_at, updated_at, deleted_at, received_at)
        VALUES (
          rec.entity_id, p_customer,
          si->>'store_id', si->>'product_id',
          COALESCE((si->>'on_hand_milliunits')::bigint, 0),
          COALESCE((si->>'reorder_milliunits')::bigint, 0),
          COALESCE((si->>'created_at')::timestamptz, now()),
          COALESCE((si->>'updated_at')::timestamptz, now()),
          NULLIF(si->>'deleted_at', '')::timestamptz,
          now())
        ON CONFLICT (id) DO UPDATE SET
          store_id            = EXCLUDED.store_id,
          product_id          = EXCLUDED.product_id,
          on_hand_milliunits  = EXCLUDED.on_hand_milliunits,
          reorder_milliunits  = EXCLUDED.reorder_milliunits,
          updated_at          = EXCLUDED.updated_at,
          deleted_at          = COALESCE(EXCLUDED.deleted_at, public.store_inventory.deleted_at)
        WHERE public.store_inventory.customer_id = p_customer
          AND (public.store_inventory.updated_at IS NULL
               OR public.store_inventory.updated_at < EXCLUDED.updated_at);
        GET DIAGNOSTICS v_row_count = ROW_COUNT;
        IF v_row_count = 0 AND EXISTS (
          SELECT 1 FROM public.store_inventory
          WHERE id = rec.entity_id AND customer_id <> p_customer
        ) THEN
          RAISE EXCEPTION 'Store inventory % belongs to another tenant.', rec.entity_id;
        END IF;

      ELSIF rec.entity_type = 'product_image' THEN
        PERFORM public.pos_require_feature(p_customer, v_actor_id, 'inventory');
        pimg := rec.payload->'product_image';
        IF pimg IS NULL OR jsonb_typeof(pimg) <> 'object' THEN
          RAISE EXCEPTION 'Product image payload is missing.';
        END IF;
        IF NULLIF(pimg->>'product_id', '') IS NULL THEN
          RAISE EXCEPTION 'A product image needs a product.';
        END IF;
        IF NOT EXISTS (
          SELECT 1 FROM public.pos_products
          WHERE customer_id = p_customer AND id = pimg->>'product_id'
        ) THEN
          UPDATE public.sync_mirror
          SET apply_error = 'DEFERRED: product has not landed yet.',
              received_at = now()
          WHERE customer_id = p_customer
            AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
          deferred := deferred + 1;
          CONTINUE;
        END IF;
        -- Same budget the proof-photo pipeline guarantees (~190 KB base64);
        -- 400k chars leaves headroom while still refusing blob-sized abuse.
        -- A tombstone (deleted_at, no bytes) skips the payload checks.
        IF NULLIF(pimg->>'image_data', '') IS NOT NULL THEN
          IF length(pimg->>'image_data') > 400000
             OR (length(pimg->>'image_data') % 4) <> 0
             OR pimg->>'image_data' !~ '^[A-Za-z0-9+/]+={0,2}$' THEN
            RAISE EXCEPTION 'Product image is not valid base64 image data.';
          END IF;
        END IF;
        INSERT INTO public.product_images (
          customer_id, product_id, image_data,
          created_at, updated_at, deleted_at, received_at)
        VALUES (
          p_customer, pimg->>'product_id', NULLIF(pimg->>'image_data', ''),
          COALESCE((pimg->>'created_at')::timestamptz, now()),
          COALESCE((pimg->>'updated_at')::timestamptz, now()),
          NULLIF(pimg->>'deleted_at', '')::timestamptz,
          now())
        ON CONFLICT (customer_id, product_id) DO UPDATE SET
          image_data = EXCLUDED.image_data,
          updated_at = EXCLUDED.updated_at,
          deleted_at = EXCLUDED.deleted_at
        WHERE public.product_images.updated_at IS NULL
           OR public.product_images.updated_at < EXCLUDED.updated_at;

      ELSE
        RAISE EXCEPTION 'Unknown entity type: %', rec.entity_type;
      END IF;

      UPDATE public.sync_mirror
      SET apply_status = 'APPLIED', applied_at = now(), apply_error = NULL
      WHERE customer_id = p_customer
        AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
      applied := applied + 1;

    EXCEPTION WHEN OTHERS THEN
      -- An ambiguity discovered after the pre-check (a concurrent link or
      -- delete) is still not a permanent refusal: leave the row PENDING so
      -- the operator can resolve it and the client keeps the outbox entry.
      IF SQLERRM LIKE 'LEGACY_REVERSAL_AMBIGUOUS:%' THEN
        UPDATE public.sync_mirror
        SET apply_error = SQLERRM,
            applied_at = NULL,
            received_at = now()
        WHERE customer_id = p_customer
          AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
        deferred := deferred + 1;
      ELSIF public.pos_sync_error_retryable(SQLSTATE) THEN
        -- Transient infrastructure/transaction failures must NOT become
        -- permanent rejections: a deadlock, serialization failure, lock timeout,
        -- cancelled query, dropped connection, or server shutdown says nothing
        -- about the record's validity. Leave the row PENDING with a RETRYABLE
        -- marker so the next apply pass (or the client's next push) tries again.
        -- Everything else — validation, authorization, FK/check violations,
        -- our own RAISE EXCEPTION business refusals (P0001) — is a permanent
        -- REJECTED the client quarantines for the operator.
        UPDATE public.sync_mirror
        SET apply_error = 'RETRYABLE: ' || SQLERRM,
            applied_at = NULL,
            received_at = now()
        WHERE customer_id = p_customer
          AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
        retryable := retryable + 1;
      ELSE
        UPDATE public.sync_mirror
        SET apply_status = 'REJECTED', applied_at = now(), apply_error = SQLERRM
        WHERE customer_id = p_customer
          AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
        rejected := rejected + 1;
      END IF;
    END;
  END LOOP;

  SELECT count(*) INTO left_over FROM public.sync_mirror
  WHERE customer_id = p_customer AND apply_status = 'PENDING';

  RETURN jsonb_build_object(
    'applied', applied, 'rejected', rejected, 'pending', left_over,
    'deferred', deferred, 'retryable', retryable);
END;
$function$;

-- ===========================================================================
-- 3. Privileges (unchanged surface, re-asserted after CREATE OR REPLACE)
-- ===========================================================================
REVOKE ALL ON FUNCTION public.pos_sync_apply(uuid, integer, text) FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION public.pos_sync_apply(uuid, integer, text) TO "service_role";
GRANT EXECUTE ON FUNCTION public.pos_sync_apply(uuid, integer, text) TO "postgres";
GRANT EXECUTE ON FUNCTION public.pos_sync_apply(uuid, integer) TO "service_role";
GRANT EXECUTE ON FUNCTION public.pos_sync_apply(uuid, integer) TO "postgres";
