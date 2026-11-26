-- Request 3 financial integrity — atomic cash-leg dedup and safe legacy
-- reversal reconciliation.
--
--   1. `cash_movements` now has ONE unique key per financial leg:
--      (customer_id, source_finance_entry_id, type) for every linked row.
--      A duplicate diagnostic runs first; if legacy data already contains
--      duplicates the migration stops with a non-destructive remediation
--      instead of silently deleting or merging money rows.
--   2. `pos_add_cash_movement_unchecked` inserts atomically. Two concurrent
--      pushes of the same leg (different movement ids) can no longer both
--      pass a read-then-insert check: the loser gets the existing row back.
--      A legacy reversal without `source_finance_entry_id` is linked when the
--      exact generated reason, amount and actor identify one collection.
--   3. `pos_complete_finance_unchecked` and
--      `pos_delete_finance_entry_unchecked` use ON CONFLICT DO NOTHING, so the
--      device leg and the server fallback converge on one row per leg.
--   4. `pos_delete_finance_entry_unchecked` records `deleted_by` and links a
--      unique legacy reversal instead of writing a second one. More than one
--      matching unlinked reversal is ambiguous: the delete refuses (and
--      `pos_sync_apply` leaves the finance entry PENDING with
--      `LEGACY_REVERSAL_AMBIGUOUS`) rather than guessing or discarding money.
--
-- Policy unchanged: ONE activation code = ONE business, UNLIMITED devices.

-- ===========================================================================
-- 1. Diagnostic: refuse to create the leg index over duplicate money rows
-- ===========================================================================
DO $$
DECLARE
  v_groups bigint;
  v_rows   bigint;
  v_sample text;
BEGIN
  SELECT count(*), COALESCE(sum(n), 0)::bigint
    INTO v_groups, v_rows
  FROM (
    SELECT customer_id, source_finance_entry_id, type, count(*) AS n
    FROM public.cash_movements
    WHERE source_finance_entry_id IS NOT NULL
    GROUP BY customer_id, source_finance_entry_id, type
    HAVING count(*) > 1
  ) d;

  IF v_groups > 0 THEN
    SELECT string_agg(
             format('customer=%s source=%s type=%s rows=%s',
                    customer_id, source_finance_entry_id, type, n),
             '; ')
      INTO v_sample
    FROM (
      SELECT customer_id, source_finance_entry_id, type, count(*) AS n
      FROM public.cash_movements
      WHERE source_finance_entry_id IS NOT NULL
      GROUP BY customer_id, source_finance_entry_id, type
      HAVING count(*) > 1
      ORDER BY customer_id, source_finance_entry_id, type
      LIMIT 10
    ) s;

    RAISE EXCEPTION
      'cash_movements_one_per_finance_leg cannot be created: % duplicate (customer_id, source_finance_entry_id, type) group(s) covering % row(s). Sample: %',
      v_groups, v_rows, v_sample
      USING DETAIL = 'No rows were changed. Inspect the duplicates, decide which row is the real leg (or link the correct source), and re-run the migration.',
            HINT = 'Example inspection: SELECT customer_id, source_finance_entry_id, type, id, amount_minor_units, reason, created_at FROM public.cash_movements WHERE source_finance_entry_id IS NOT NULL ORDER BY customer_id, source_finance_entry_id, type, created_at;';
  END IF;
END $$;

-- ===========================================================================
-- 2. Preserve who deleted a collection (needed for reversal identity)
-- ===========================================================================
ALTER TABLE public.pos_finance_entries
  ADD COLUMN IF NOT EXISTS deleted_by text;

-- ===========================================================================
-- 3. One row per linked financial leg
-- ===========================================================================
-- The previous index only protected DEPOSIT rows, so two concurrent or
-- legacy reversals for the same collection could both land. The leg is
-- (collection, direction): one deposit and one withdrawal per collection.
DROP INDEX IF EXISTS public.cash_movements_one_per_finance_entry;
DROP INDEX IF EXISTS public.cash_movements_one_per_finance_leg;
CREATE UNIQUE INDEX cash_movements_one_per_finance_leg
  ON public.cash_movements USING btree
    (customer_id, source_finance_entry_id, type)
  WHERE source_finance_entry_id IS NOT NULL;

-- ===========================================================================
-- 4. Legacy reversal identity helpers
-- ===========================================================================
-- A pre-20261204 reversal was written with no `source_finance_entry_id`, but
-- its reason was generated from the category name and collection source:
--   Reversal: deleted cash collection from <category> (<source>)
-- Identity evidence is the EXACT generated reason, the amount, and the actor
-- (deleter when known, otherwise the completer). Amount alone is never enough.

CREATE OR REPLACE FUNCTION public.pos_legacy_reversal_candidates (
  p_customer uuid,
  p_entry_id text,
  p_actor    text DEFAULT NULL
)
  RETURNS TABLE (movement_id text)
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  SELECT m.id
  FROM public.cash_movements m
  JOIN public.pos_finance_entries e
    ON e.customer_id = m.customer_id
   AND e.id = p_entry_id
  LEFT JOIN public.pos_finance_categories c
    ON c.customer_id = e.customer_id
   AND c.id = e.category_id
  WHERE m.customer_id = p_customer
    AND m.type = 'WITHDRAWAL'
    AND m.source_finance_entry_id IS NULL
    AND upper(COALESCE(e.payment_method, '')) = 'CASH'
    AND m.amount_minor_units = e.amount_minor_units
    AND btrim(m.reason) = 'Reversal: deleted cash collection from '
        || COALESCE(c.name, 'a person')
        || ' (' || COALESCE(e.source, '') || ')'
    -- If the collection already has a linked reversal, an unlinked twin is
    -- not a candidate: linking it would create a second reversal.
    AND NOT EXISTS (
      SELECT 1 FROM public.cash_movements linked
      WHERE linked.customer_id = e.customer_id
        AND linked.source_finance_entry_id = e.id
        AND linked.type = 'WITHDRAWAL'
    )
    -- A legacy entry has no stored deleter; in that case actor evidence is
    -- unavailable and the exact reason + amount decide. When the deleter is
    -- known, the movement must belong to the deleter or the completer.
    AND (
      e.deleted_by IS NULL
      OR m.user_id = e.deleted_by
      OR m.user_id = e.completed_by
      OR (p_actor IS NOT NULL AND m.user_id = p_actor)
    )
  ORDER BY m.created_at, m.id;
$function$;

CREATE OR REPLACE FUNCTION public.pos_legacy_reversal_entry_candidates (
  p_customer uuid,
  p_amount   bigint,
  p_reason   text,
  p_actor    text
)
  RETURNS TABLE (entry_id text)
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  SELECT e.id
  FROM public.pos_finance_entries e
  LEFT JOIN public.pos_finance_categories c
    ON c.customer_id = e.customer_id
   AND c.id = e.category_id
  WHERE e.customer_id = p_customer
    AND upper(COALESCE(e.payment_method, '')) = 'CASH'
    AND e.amount_minor_units = p_amount
    AND e.status IN ('COMPLETED', 'DELETED')
    AND btrim(p_reason) = 'Reversal: deleted cash collection from '
        || COALESCE(c.name, 'a person')
        || ' (' || COALESCE(e.source, '') || ')'
    AND NOT EXISTS (
      SELECT 1 FROM public.cash_movements linked
      WHERE linked.customer_id = e.customer_id
        AND linked.source_finance_entry_id = e.id
        AND linked.type = 'WITHDRAWAL'
    )
    AND (
      e.deleted_by IS NULL
      OR p_actor IS NULL
      OR p_actor = e.deleted_by
      OR p_actor = e.completed_by
    )
  ORDER BY e.updated_at, e.id;
$function$;

REVOKE ALL ON FUNCTION public.pos_legacy_reversal_candidates(uuid, text, text)
  FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION public.pos_legacy_reversal_entry_candidates(uuid, bigint, text, text)
  FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION public.pos_legacy_reversal_candidates(uuid, text, text)
  TO "service_role";
GRANT EXECUTE ON FUNCTION public.pos_legacy_reversal_entry_candidates(uuid, bigint, text, text)
  TO "service_role";

-- ===========================================================================
-- 5. Atomic cash-movement insert + unique legacy inference
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.pos_add_cash_movement_unchecked (
  p_customer                uuid,
  p_user                    text,
  p_shift_id                text,
  p_type                    text,
  p_amount                  bigint,
  p_reason                  text,
  p_photo                   text,
  p_movement_id             text   DEFAULT NULL::text,
  p_source_finance_entry_id text   DEFAULT NULL::text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
DECLARE
  mv_id              text;
  existing           text;
  inserted           boolean;
  v_reason           text;
  v_source           text := NULLIF(btrim(COALESCE(p_source_finance_entry_id, '')), '');
  v_entry_candidates text[];
BEGIN
  IF public.pos_is_demo(p_customer, p_user) THEN
    RAISE EXCEPTION 'Training-account data stays on the till that made it.';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be positive.';
  END IF;
  IF p_type NOT IN ('WITHDRAWAL', 'DEPOSIT', 'EXPENSE') THEN
    RAISE EXCEPTION 'Invalid movement type.';
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'A reason is required.';
  END IF;
  IF p_photo IS NOT NULL AND length(p_photo) > 5000000 THEN
    RAISE EXCEPTION 'Photo too large (max 5MB).';
  END IF;

  v_reason := btrim(p_reason);

  -- The same movement, arriving twice (a device retrying a push it never got
  -- an ack for). Answer with the row that exists instead of writing a second.
  IF p_movement_id IS NOT NULL THEN
    SELECT id INTO existing FROM public.cash_movements
    WHERE customer_id = p_customer AND id = p_movement_id;
    IF FOUND THEN
      RETURN jsonb_build_object('id', existing, 'duplicate', true);
    END IF;
  END IF;

  -- A pre-20261204 till wrote the reversal without the collection link. The
  -- reason is generated from the category name and collection source, and the
  -- movement carries the amount and the deleter: when those identify exactly
  -- ONE collection, link it now. Anything less than exact evidence is left
  -- unlinked for the delete path to reconcile or defer.
  IF v_source IS NULL AND p_type = 'WITHDRAWAL' THEN
    SELECT array_agg(c.entry_id) INTO v_entry_candidates
    FROM public.pos_legacy_reversal_entry_candidates(
      p_customer, p_amount, v_reason, p_user) c;
    IF v_entry_candidates IS NOT NULL
       AND array_length(v_entry_candidates, 1) = 1 THEN
      v_source := v_entry_candidates[1];
    END IF;
  END IF;

  -- The same LEG of the same collection, deposited or reversed by the other
  -- path. Matching on (source entry, type) lets the outbox row and the
  -- finance RPCs converge on one deposit AND one reversal per collection.
  IF v_source IS NOT NULL THEN
    SELECT id INTO existing FROM public.cash_movements
    WHERE customer_id = p_customer
      AND source_finance_entry_id = v_source
      AND type = p_type;
    IF FOUND THEN
      RETURN jsonb_build_object('id', existing, 'duplicate', true);
    END IF;
  END IF;

  -- Checked after the replays on purpose: a movement re-sent after its shift
  -- closed is still the same money already in the drawer, not a failure.
  PERFORM 1 FROM public.shifts
    WHERE customer_id = p_customer AND id = p_shift_id AND status = 'OPEN'
    FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Movement requires an open shift.';
  END IF;

  mv_id := COALESCE(p_movement_id, gen_random_uuid()::text);
  INSERT INTO public.cash_movements (id, customer_id, shift_id, user_id, type,
    amount_minor_units, reason, photo, created_at, source_finance_entry_id)
  VALUES (mv_id, p_customer, p_shift_id, p_user, p_type, p_amount,
    v_reason, NULLIF(p_photo, ''), now(), v_source)
  -- No conflict target: the primary key AND the one-leg index are both
  -- replay guards. A concurrent twin loses here instead of raising.
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS inserted = ROW_COUNT;
  IF NOT inserted THEN
    SELECT id INTO existing FROM public.cash_movements
    WHERE customer_id = p_customer
      AND (id = mv_id
           OR (v_source IS NOT NULL
               AND source_finance_entry_id = v_source
               AND type = p_type))
    ORDER BY (id = mv_id) DESC, created_at
    LIMIT 1;
    RETURN jsonb_build_object('id', COALESCE(existing, mv_id), 'duplicate', true);
  END IF;

  INSERT INTO public.pos_audit_logs (id, customer_id, user_id, action, details, created_at)
  VALUES (gen_random_uuid(), p_customer, p_user, 'CASH_MOVEMENT_ADDED',
    p_type || ' ' || p_amount, now());

  RETURN jsonb_build_object('id', mv_id);
END;
$function$;

-- ===========================================================================
-- 6. Atomic fallback deposit
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.pos_complete_finance_unchecked (
  p_customer uuid,
  p_user     text,
  p_entry_id text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
DECLARE
  entry       record;
  cat_name    text;
  shift_found text;
  updated     int;
BEGIN
  IF public.pos_is_demo(p_customer, p_user) THEN
    RAISE EXCEPTION 'Training-account data stays on the till that made it.';
  END IF;

  SELECT * INTO entry FROM public.pos_finance_entries
  WHERE customer_id = p_customer AND id = p_entry_id AND status = 'PENDING'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Entry is not pending.';
  END IF;

  UPDATE public.pos_finance_entries
  SET status = 'COMPLETED', completed_at = now(), completed_by = p_user, updated_at = now()
  WHERE customer_id = p_customer AND id = p_entry_id AND status = 'PENDING';
  GET DIAGNOSTICS updated = ROW_COUNT;
  IF updated <> 1 THEN
    RAISE EXCEPTION 'Entry is not pending.';
  END IF;

  IF entry.payment_method = 'CASH' THEN
    SELECT name INTO cat_name FROM public.pos_finance_categories
    WHERE customer_id = p_customer AND id = entry.category_id;

    shift_found := public.pos_ensure_shift(p_customer, p_user, NULL);

    -- One deposit per collection. The pre-check avoids a needless insert on
    -- replay; ON CONFLICT DO NOTHING makes the check race-safe when the
    -- device's own deposit lands concurrently.
    IF NOT EXISTS (SELECT 1 FROM public.cash_movements
                   WHERE customer_id = p_customer
                     AND source_finance_entry_id = p_entry_id
                     AND type = 'DEPOSIT') THEN
      INSERT INTO public.cash_movements (id, customer_id, shift_id, user_id,
        type, amount_minor_units, reason, created_at, source_finance_entry_id)
      VALUES (gen_random_uuid(), p_customer, shift_found, p_user,
        'DEPOSIT', entry.amount_minor_units,
        'Collected from ' || COALESCE(cat_name, 'a person'), now(), p_entry_id)
      ON CONFLICT DO NOTHING;
    END IF;
  END IF;

  INSERT INTO public.pos_audit_logs (id, customer_id, user_id, action, details, created_at)
  VALUES (gen_random_uuid(), p_customer, p_user, 'FINANCE_COMPLETED',
    'Entry ' || p_entry_id || ' completed.', now());
END;
$function$;

-- ===========================================================================
-- 7. Reversal delete: link a unique legacy leg, defer an ambiguous one
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.pos_delete_finance_entry_unchecked (
  p_customer uuid,
  p_user     text,
  p_entry_id text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
DECLARE
  entry        record;
  cat_name     text;
  shift_found  text;
  updated      int;
  v_candidates text[];
  v_linked     text;
BEGIN
  IF public.pos_is_demo(p_customer, p_user) THEN
    RAISE EXCEPTION 'Training-account data stays on the till that made it.';
  END IF;

  SELECT * INTO entry FROM public.pos_finance_entries
  WHERE customer_id = p_customer AND id = p_entry_id AND status <> 'DELETED'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Entry not found.';
  END IF;

  -- Only a completed CASH collection touched the drawer. If its deposit is
  -- still there, post the opposite leg on the open shift — unless the device
  -- already queued that exact reversal. A legacy device queued it without the
  -- link; link it only when the exact generated reason, amount and actor
  -- identify one movement. Never match on amount alone.
  IF upper(COALESCE(entry.status, '')) = 'COMPLETED'
     AND upper(COALESCE(entry.payment_method, '')) = 'CASH' THEN
    IF EXISTS (
      SELECT 1 FROM public.cash_movements
      WHERE customer_id = p_customer
        AND source_finance_entry_id = p_entry_id
        AND type = 'DEPOSIT'
    ) THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.cash_movements
        WHERE customer_id = p_customer
          AND source_finance_entry_id = p_entry_id
          AND type = 'WITHDRAWAL'
      ) THEN
        SELECT array_agg(c.movement_id) INTO v_candidates
        FROM public.pos_legacy_reversal_candidates(
          p_customer, p_entry_id, p_user) c;

        IF v_candidates IS NOT NULL
           AND array_length(v_candidates, 1) > 1 THEN
          RAISE EXCEPTION
            'LEGACY_REVERSAL_AMBIGUOUS: % unlinked reversal movements match collection %; link the correct movement before deleting.',
            array_length(v_candidates, 1), p_entry_id
            USING ERRCODE = 'P0001';
        END IF;

        IF v_candidates IS NOT NULL
           AND array_length(v_candidates, 1) = 1 THEN
          v_linked := v_candidates[1];
          UPDATE public.cash_movements
          SET source_finance_entry_id = p_entry_id
          WHERE customer_id = p_customer
            AND id = v_linked
            AND source_finance_entry_id IS NULL;
          IF FOUND THEN
            INSERT INTO public.pos_audit_logs
              (id, customer_id, user_id, action, details, created_at)
            VALUES (gen_random_uuid(), p_customer, p_user,
              'LEGACY_REVERSAL_LINKED',
              'Movement ' || v_linked || ' linked to collection ' || p_entry_id || '.',
              now());
          END IF;
        END IF;

        IF v_linked IS NULL THEN
          SELECT id INTO shift_found FROM public.shifts
          WHERE customer_id = p_customer AND status = 'OPEN'
          LIMIT 1 FOR SHARE;
          IF shift_found IS NULL THEN
            RAISE EXCEPTION
              'Open the register before deleting a completed cash collection.';
          END IF;

          SELECT name INTO cat_name FROM public.pos_finance_categories
          WHERE customer_id = p_customer AND id = entry.category_id;

          INSERT INTO public.cash_movements (
            id, customer_id, shift_id, user_id, type, amount_minor_units,
            reason, created_at, source_finance_entry_id)
          VALUES (
            gen_random_uuid(), p_customer, shift_found, p_user, 'WITHDRAWAL',
            entry.amount_minor_units,
            'Reversal: deleted cash collection from '
              || COALESCE(cat_name, 'a person') || ' (' || COALESCE(entry.source, '') || ')',
            now(), p_entry_id)
          ON CONFLICT DO NOTHING;
        END IF;
      END IF;
    END IF;
  END IF;

  UPDATE public.pos_finance_entries
  SET status = 'DELETED',
      deleted_by = p_user,
      updated_at = now()
  WHERE customer_id = p_customer AND id = p_entry_id AND status <> 'DELETED';
  GET DIAGNOSTICS updated = ROW_COUNT;
  IF updated <> 1 THEN
    RAISE EXCEPTION 'Entry is already deleted.';
  END IF;

  INSERT INTO public.pos_audit_logs (id, customer_id, user_id, action, details, created_at)
  VALUES (gen_random_uuid(), p_customer, p_user, 'FINANCE_ENTRY_DELETED',
    'Entry ' || p_entry_id || ' deleted.', now());
END;
$function$;

-- ===========================================================================
-- 8. pos_sync_apply — defer an ambiguous legacy reversal before deletion
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
-- 9. Privileges
-- ===========================================================================
REVOKE ALL ON FUNCTION public.pos_add_cash_movement_unchecked(uuid, text, text, text, bigint, text, text, text, text)
  FROM PUBLIC, "anon", "authenticated", "service_role";
REVOKE ALL ON FUNCTION public.pos_complete_finance_unchecked(uuid, text, text)
  FROM PUBLIC, "anon", "authenticated", "service_role";
REVOKE ALL ON FUNCTION public.pos_delete_finance_entry_unchecked(uuid, text, text)
  FROM PUBLIC, "anon", "authenticated", "service_role";

GRANT EXECUTE ON FUNCTION public.pos_sync_apply(uuid, integer, text) TO "service_role";
GRANT EXECUTE ON FUNCTION public.pos_sync_apply(uuid, integer, text) TO "postgres";
GRANT EXECUTE ON FUNCTION public.pos_sync_apply(uuid, integer) TO "service_role";
GRANT EXECUTE ON FUNCTION public.pos_sync_apply(uuid, integer) TO "postgres";
