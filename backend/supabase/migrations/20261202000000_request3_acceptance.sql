-- Request 3 final acceptance — corrections on top of the actor-authorization
-- migration (20261201000000_actor_authorization.sql).
--
--   1. ACL closure: renaming the money RPCs to `*_unchecked` did NOT remove the
--      service_role EXECUTE grant the Stage 5 baseline gave the originals.
--      service_role could still call the unchecked implementations directly,
--      bypassing the feature wrappers entirely. Revoke it explicitly; the
--      wrappers are SECURITY DEFINER owned by the migration role, so they keep
--      working.
--   2. Sync outcomes: `WHEN OTHERS` used to label EVERY failure REJECTED,
--      turning a deadlock/serialization/connection blip into a permanent
--      rejection the client would ack and prune. Transient SQLSTATEs now leave
--      the row PENDING with a `RETRYABLE:` marker; only genuine validation /
--      authorization failures become REJECTED.
--   3. Multi-actor finance: one grant per staged row cannot represent "A
--      created, B completed". `sync_mirror.actor_grant_hashes` now carries a
--      per-actor-slot map of grant digests; pos_sync_apply resolves the
--      creator, the completer/deleter, and (through the separate
--      cash_movement entity) the deposit actor independently.
--   4. First-owner bootstrap: pos_setup_owner gains a tenant advisory lock so
--      concurrent bootstrap attempts cannot both observe "no users" and insert
--      two owners, and becomes idempotent for a retry of the SAME owner id
--      (crash between commit and response). pos-api passes the native till's
--      owner id through so local and cloud identities match.
--
-- Policy unchanged: ONE activation code = ONE business, UNLIMITED devices.

-- ===========================================================================
-- 1. service_role can no longer reach the unchecked money implementations
-- ===========================================================================
-- The function OWNER keeps EXECUTE implicitly (ownership cannot be revoked),
-- which is exactly what the SECURITY DEFINER wrappers need. service_role keeps
-- EXECUTE on the checked wrappers only.

REVOKE ALL ON FUNCTION public.pos_create_sale_unchecked(
  uuid, text, text, text, text, jsonb, text, bigint, bigint, text, text)
  FROM "service_role";
REVOKE ALL ON FUNCTION public.pos_add_cash_movement_unchecked(
  uuid, text, text, text, bigint, text, text, text, text)
  FROM "service_role";
REVOKE ALL ON FUNCTION public.pos_complete_finance_unchecked(uuid, text, text)
  FROM "service_role";
REVOKE ALL ON FUNCTION public.pos_delete_finance_entry_unchecked(uuid, text, text)
  FROM "service_role";
REVOKE ALL ON FUNCTION public.pos_delete_finance_category_unchecked(uuid, text, text)
  FROM "service_role";
REVOKE ALL ON FUNCTION public.pos_open_shift_unchecked(uuid, text, text, bigint)
  FROM "service_role";
REVOKE ALL ON FUNCTION public.pos_close_shift_unchecked(uuid, text, text, bigint)
  FROM "service_role";

-- Defence in depth: assert the boundary is really closed. If a future grant
-- statement re-opens it, this migration fails loudly instead of shipping an
-- unauthenticated money path.
DO $$
DECLARE fn text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'public.pos_create_sale_unchecked(uuid,text,text,text,text,jsonb,text,bigint,bigint,text,text)',
    'public.pos_add_cash_movement_unchecked(uuid,text,text,text,bigint,text,text,text,text)',
    'public.pos_complete_finance_unchecked(uuid,text,text)',
    'public.pos_delete_finance_entry_unchecked(uuid,text,text)',
    'public.pos_delete_finance_category_unchecked(uuid,text,text)',
    'public.pos_open_shift_unchecked(uuid,text,text,bigint)',
    'public.pos_close_shift_unchecked(uuid,text,text,bigint)']
  LOOP
    IF has_function_privilege('service_role', fn, 'EXECUTE')
       OR has_function_privilege('anon', fn, 'EXECUTE')
       OR has_function_privilege('authenticated', fn, 'EXECUTE') THEN
      RAISE EXCEPTION 'unchecked money RPC still executable: %', fn;
    END IF;
  END LOOP;
END $$;

-- ===========================================================================
-- 2. Per-actor grant digests on the staging row
-- ===========================================================================
-- `actor_grant_hash` stays the PRIMARY actor (the grant the pushing operator
-- presented). `actor_grant_hashes` is a jsonb map of slot-key -> SHA-256
-- digest, where the key is the actor id claimed inside the payload
-- (created_by / completed_by / deleted_by / cashier_id / ...). The key only
-- SELECTS which digest to resolve; the resolved user id — never the key — is
-- what lands in the ledger, so a forged key cannot impersonate anyone.

ALTER TABLE public.sync_mirror
  ADD COLUMN IF NOT EXISTS actor_grant_hashes jsonb;

-- Resolve one actor slot: the digest staged under p_key, falling back to the
-- row's primary digest when the slot carries none (pre-Request-3 rows, or a
-- single-actor entity). Returns no row when the grant is missing, expired,
-- revoked, cross-device, or cross-tenant — callers treat that as deferred.
CREATE OR REPLACE FUNCTION public.pos_resolve_staged_actor(
  p_customer       uuid,
  p_hashes         jsonb,
  p_key            text,
  p_primary_hash   text,
  p_device         text
)
  RETURNS TABLE (user_id text, role text, permissions jsonb)
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  SELECT r.user_id, r.role, r.permissions
  FROM public.pos_resolve_actor_grant(
    p_customer,
    CASE
      -- No slot claimed (or a legacy row with no per-actor map at all): the
      -- row's primary grant is the actor, exactly as before this migration.
      WHEN p_key IS NULL OR btrim(p_key) = '' THEN p_primary_hash
      WHEN p_hashes IS NULL THEN p_primary_hash
      -- A per-actor map WAS staged: a missing key means that actor's grant
      -- was never presented — resolve nothing and let the caller defer.
      ELSE NULLIF(p_hashes ->> p_key, '')
    END,
    p_device) r;
$function$;

REVOKE ALL ON FUNCTION public.pos_resolve_staged_actor(uuid, jsonb, text, text, text)
  FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION public.pos_resolve_staged_actor(uuid, jsonb, text, text, text)
  TO "service_role";
REVOKE ALL ON FUNCTION public.pos_resolve_staged_actor(uuid, jsonb, text, text, text)
  FROM "postgres";
GRANT EXECUTE ON FUNCTION public.pos_resolve_staged_actor(uuid, jsonb, text, text, text)
  TO "postgres";

-- Is this SQLSTATE a transient infrastructure/transaction failure rather
-- than a verdict on the record? Kept as a function so the classification is
-- directly regression-testable (request3_acceptance_test.sql).
CREATE OR REPLACE FUNCTION public.pos_sync_error_retryable(p_sqlstate text)
  RETURNS boolean
  LANGUAGE sql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
  SELECT p_sqlstate IN (
    '40001',  -- serialization_failure
    '40P01',  -- deadlock_detected
    '55P03',  -- lock_not_available
    '57014',  -- query_canceled
    '57P01', '57P02', '57P03',  -- admin_shutdown / crash_shutdown / cannot_connect_now
    '53300',  -- too_many_connections
    '53400',  -- configuration_limit_exceeded
    '08000', '08001', '08003', '08004', '08006', '08007', '08P01'
  );
$function$;

REVOKE ALL ON FUNCTION public.pos_sync_error_retryable(text)
  FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION public.pos_sync_error_retryable(text) TO "service_role";
REVOKE ALL ON FUNCTION public.pos_sync_error_retryable(text) FROM "postgres";
GRANT EXECUTE ON FUNCTION public.pos_sync_error_retryable(text) TO "postgres";

-- ===========================================================================
-- 3. pos_sync_apply — transient vs permanent failure, per-actor finance
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
  v_closer_id      text;
  v_closer_role    text;
  v_closer_perms   jsonb;
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
        WHEN 'finance_category'  THEN 2
        WHEN 'shift'             THEN 3
        WHEN 'sale'              THEN 4
        WHEN 'cash_movement'     THEN 5
        WHEN 'void_request'      THEN 6
        WHEN 'finance_entry'     THEN 7
        WHEN 'picklist'          THEN 8
        WHEN 'picklist_item'     THEN 9
        ELSE 10
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

        -- A requested COMPLETED/DELETED transition needs its own actor: the
        -- completer (completed_by) or, for a delete, the deleter (deleted_by,
        -- falling back to completed_by for rows written before the column
        -- existed, then to the primary grant). Resolve it BEFORE writing so a
        -- missing grant defers the whole row instead of half-applying it.
        IF upper(COALESCE(fe->>'status', '')) IN ('COMPLETED', 'DELETED') THEN
          SELECT g.user_id, g.role, g.permissions
            INTO v_closer_id, v_closer_role, v_closer_perms
          FROM public.pos_resolve_staged_actor(
            p_customer, rec.actor_grant_hashes,
            CASE WHEN upper(fe->>'status') = 'DELETED'
                 THEN COALESCE(fe->>'deleted_by', fe->>'completed_by')
                 ELSE fe->>'completed_by' END,
            rec.actor_grant_hash, p_device_fingerprint) g;
          IF v_closer_id IS NULL THEN
            UPDATE public.sync_mirror
            SET apply_error =
                  'ACTOR_AUTH_REQUIRED: completion grant is expired, revoked, or invalid.',
                received_at = now()
            WHERE customer_id = p_customer
              AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
            deferred := deferred + 1;
            CONTINUE;
          END IF;
          PERFORM public.pos_require_feature(p_customer, v_closer_id, 'finance');
        ELSE
          v_closer_id := NULL;
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
        -- row is always PENDING until the locked RPC transitions it.
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

        -- A client may REQUEST a transition, never author it. Both calls use
        -- the independently resolved actor and their own row locks, so
        -- created_by stays the creator while completed_by/completed_at (and
        -- the cash deposit's user_id) belong to the completer.
        IF upper(COALESCE(fe->>'status', '')) = 'COMPLETED'
           AND v_entry_status = 'PENDING' THEN
          PERFORM public.pos_complete_finance(
            p_customer, v_closer_id, rec.entity_id);
        ELSIF upper(COALESCE(fe->>'status', '')) = 'DELETED'
              AND v_entry_status <> 'DELETED' THEN
          PERFORM public.pos_delete_finance_entry(
            p_customer, v_closer_id, rec.entity_id);
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

      ELSE
        RAISE EXCEPTION 'Unknown entity type: %', rec.entity_type;
      END IF;

      UPDATE public.sync_mirror
      SET apply_status = 'APPLIED', applied_at = now(), apply_error = NULL
      WHERE customer_id = p_customer
        AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
      applied := applied + 1;

    EXCEPTION WHEN OTHERS THEN
      -- Transient infrastructure/transaction failures must NOT become
      -- permanent rejections: a deadlock, serialization failure, lock timeout,
      -- cancelled query, dropped connection, or server shutdown says nothing
      -- about the record's validity. Leave the row PENDING with a RETRYABLE
      -- marker so the next apply pass (or the client's next push) tries again.
      -- Everything else — validation, authorization, FK/check violations,
      -- our own RAISE EXCEPTION business refusals (P0001) — is a permanent
      -- REJECTED the client quarantines for the operator.
      IF public.pos_sync_error_retryable(SQLSTATE) THEN
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
-- 4. First-owner bootstrap hardening
-- ===========================================================================
-- Two concurrent setup_owner calls could both observe "no users" and insert
-- two OWNER rows. Serialize bootstrap per tenant with a transaction-scoped
-- advisory lock, and make a retry of the SAME owner id a no-op so a client
-- that crashed between commit and response converges instead of failing.

CREATE OR REPLACE FUNCTION public.pos_setup_owner (
  p_customer uuid,
  p_id       text,
  p_username text,
  p_pw_salt  text,
  p_pw_hash  text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
DECLARE existing_count int;
BEGIN
  -- Serialize first-owner creation per tenant: without this, two concurrent
  -- bootstrap attempts (two tills, or a retry racing the original) can both
  -- pass the count check below and insert two owners.
  PERFORM pg_advisory_xact_lock(
    hashtext('pos_setup_owner'), hashtext(p_customer::text));

  -- Idempotent retry: the same owner id already present means a previous
  -- attempt committed and only the response was lost.
  IF EXISTS (
    SELECT 1 FROM public.pos_users
    WHERE customer_id = p_customer AND id = p_id
      AND role = 'OWNER' AND deleted_at IS NULL
  ) THEN
    RETURN;
  END IF;

  SELECT count(*) INTO existing_count FROM public.pos_users
   WHERE customer_id = p_customer AND deleted_at IS NULL;
  IF existing_count > 0 THEN
    RAISE EXCEPTION 'Owner already exists.';
  END IF;
  INSERT INTO public.pos_users (id, customer_id, username, role, pw_salt, pw_hash, active, token_version)
  VALUES (p_id, p_customer, p_username, 'OWNER', p_pw_salt, p_pw_hash, true, 0);
END;
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_setup_owner"(uuid, text, text, text, text) TO "service_role";
REVOKE ALL ON FUNCTION "public"."pos_setup_owner"(uuid, text, text, text, text) FROM "anon", "authenticated";
