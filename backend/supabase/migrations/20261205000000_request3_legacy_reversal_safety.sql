-- Request 3 legacy reversal safety — bidirectional uniqueness, safe link
-- adoption, fail-safe text mismatch, and real actor evidence.
--
-- Builds on 20261204000000_request3_financial_integrity (atomic leg index,
-- session-less owner bootstrap — both preserved unchanged).
--
--   1. `pos_legacy_actor_ok` is the single actor-evidence rule: a movement
--      actor must equal a NON-NULL deleted_by, completed_by, or the
--      delete-time actor. The old `deleted_by IS NULL` bypass is gone —
--      missing evidence is ambiguity, never a silent match.
--   2. Candidate selection is bidirectional: a movement is adopted only
--      when it strongly matches THIS entry AND this entry is the ONLY
--      finance collection that movement could belong to (strong AND weak
--      candidate counts must both be exactly one). Processing order can no
--      longer decide which collection receives a legacy reversal.
--   3. The link UPDATE uses RETURNING; a lost race re-reads the movement's
--      real association and recomputes candidates (bounded), never treats
--      a movement claimed by another collection as this entry's reversal.
--   4. Exact-reason matching is no longer the only evidence: when zero
--      strong candidates exist, plausible unlinked reversals (same amount,
--      reversal-shaped reason — catches category renames) block the
--      server-written fallback and defer the delete instead of risking a
--      duplicate drawer movement.
--
-- Policy unchanged: ONE activation code = ONE business, UNLIMITED devices.

-- ===========================================================================
-- 1. Actor-evidence rule
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.pos_legacy_actor_ok (
  p_user        text,
  p_deleted_by  text,
  p_completed_by text,
  p_actor       text
)
  RETURNS boolean
  LANGUAGE sql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
  SELECT p_user IS NOT NULL AND btrim(p_user) <> ''
    AND (
      (p_deleted_by IS NOT NULL AND btrim(p_deleted_by) <> ''
        AND p_user = p_deleted_by)
      OR (p_completed_by IS NOT NULL AND btrim(p_completed_by) <> ''
        AND p_user = p_completed_by)
      OR (p_actor IS NOT NULL AND btrim(p_actor) <> ''
        AND p_user = p_actor)
    );
$function$;

REVOKE ALL ON FUNCTION public.pos_legacy_actor_ok(text, text, text, text)
  FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION public.pos_legacy_actor_ok(text, text, text, text)
  TO "service_role";

-- ===========================================================================
-- 2. Candidate helpers — strong (actor-verified) and weak (text-only)
-- ===========================================================================
-- Strong movements for ONE finance entry: exact generated reason + amount +
-- CASH + unlinked + no already-linked reversal + VERIFIED actor. The actor
-- must equal the entry's deleted_by, completed_by, or the delete-time actor;
-- there is no "no evidence means match" path anymore.
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
    AND NOT EXISTS (
      SELECT 1 FROM public.cash_movements linked
      WHERE linked.customer_id = e.customer_id
        AND linked.source_finance_entry_id = e.id
        AND linked.type = 'WITHDRAWAL'
    )
    AND public.pos_legacy_actor_ok(
      m.user_id, e.deleted_by, e.completed_by, p_actor)
  ORDER BY m.created_at, m.id;
$function$;

-- Strong finance entries for ONE movement: the movement's actor must equal
-- the entry's deleted_by or completed_by. p_actor here IS the movement's
-- user_id (fixed evidence), so there is no delete-time actor to borrow.
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
    AND public.pos_legacy_actor_ok(
      p_actor, e.deleted_by, e.completed_by, NULL::text)
  ORDER BY e.updated_at, e.id;
$function$;

-- Weak finance entries for ONE movement: exact reason + amount only, NO
-- actor requirement. Used ONLY to prove a movement is not uniquely
-- attributable — a weak count above one (or a strong count of zero against
-- a weak count of one) is ambiguity, never a match.
CREATE OR REPLACE FUNCTION public.pos_legacy_reversal_entry_candidates_weak (
  p_customer uuid,
  p_amount   bigint,
  p_reason   text
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
  ORDER BY e.updated_at, e.id;
$function$;

REVOKE ALL ON FUNCTION public.pos_legacy_reversal_candidates(uuid, text, text)
  FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION public.pos_legacy_reversal_entry_candidates(uuid, bigint, text, text)
  FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION public.pos_legacy_reversal_entry_candidates_weak(uuid, bigint, text)
  FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION public.pos_legacy_reversal_candidates(uuid, text, text)
  TO "service_role";
GRANT EXECUTE ON FUNCTION public.pos_legacy_reversal_entry_candidates(uuid, bigint, text, text)
  TO "service_role";
GRANT EXECUTE ON FUNCTION public.pos_legacy_reversal_entry_candidates_weak(uuid, bigint, text)
  TO "service_role";

-- ===========================================================================
-- 3. Atomic cash-movement insert — bidirectional legacy inference
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
  v_entry_weak       int;
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

  -- A pre-20261204 till wrote the reversal without the collection link. Link
  -- it ONLY when the exact generated reason, amount and actor identify ONE
  -- collection AND that collection is the movement's ONLY possible owner —
  -- strong candidate count AND weak (actor-free) candidate count must both
  -- be exactly one. Anything less stays unlinked for the delete path to
  -- reconcile or defer; processing order never assigns the leg.
  IF v_source IS NULL AND p_type = 'WITHDRAWAL' THEN
    SELECT array_agg(c.entry_id) INTO v_entry_candidates
    FROM public.pos_legacy_reversal_entry_candidates(
      p_customer, p_amount, v_reason, p_user) c;
    SELECT count(*) INTO v_entry_weak
    FROM public.pos_legacy_reversal_entry_candidates_weak(
      p_customer, p_amount, v_reason) c;
    IF v_entry_candidates IS NOT NULL
       AND array_length(v_entry_candidates, 1) = 1
       AND v_entry_weak = 1 THEN
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
-- 4. Reversal delete: bidirectional adoption, safe link, fail-safe fallback
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
  entry         record;
  cat_name      text;
  shift_found   text;
  updated       int;
  v_candidates  text[];
  v_cand_n      int;
  v_try         int;
  v_adopted     boolean := false;
  v_linked      text;
  v_now         text;
  v_m_amount    bigint;
  v_m_reason    text;
  v_m_user      text;
  v_es          int;
  v_ew          int;
  v_es_id       text;
  v_plausible   int;
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
  -- link; adopt it only when evidence identifies it UNIQUELY in BOTH
  -- directions. Never match on amount alone; never let arrival order pick
  -- the winner.
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
        -- Bounded adoption loop: each iteration re-reads candidates, so a
        -- movement claimed by a concurrent delete is simply absent next pass.
        FOR v_try IN 1..3 LOOP
          SELECT COALESCE(array_agg(c.movement_id), '{}'::text[])
            INTO v_candidates
          FROM public.pos_legacy_reversal_candidates(
            p_customer, p_entry_id, p_user) c;
          v_cand_n := COALESCE(array_length(v_candidates, 1), 0);
          EXIT WHEN v_cand_n <> 1;

          -- Reverse direction: this movement must belong to THIS entry and
          -- NO OTHER. Strong (actor-verified) and weak (text-only) entry
          -- candidate counts must both be exactly one, and the strong one
          -- must be this entry.
          SELECT m.amount_minor_units, m.reason, m.user_id
            INTO v_m_amount, v_m_reason, v_m_user
          FROM public.cash_movements m
          WHERE m.customer_id = p_customer AND m.id = v_candidates[1];
          SELECT count(*) INTO v_es
          FROM public.pos_legacy_reversal_entry_candidates(
            p_customer, v_m_amount, v_m_reason, v_m_user) e;
          SELECT count(*) INTO v_ew
          FROM public.pos_legacy_reversal_entry_candidates_weak(
            p_customer, v_m_amount, v_m_reason) e;
          SELECT e.entry_id INTO v_es_id
          FROM public.pos_legacy_reversal_entry_candidates(
            p_customer, v_m_amount, v_m_reason, v_m_user) e
          LIMIT 1;
          IF v_es <> 1 OR v_ew <> 1
             OR v_es_id IS DISTINCT FROM p_entry_id THEN
            RAISE EXCEPTION
              'LEGACY_REVERSAL_AMBIGUOUS: candidate movement % matches % verified / % total finance collections; it is not uniquely attributable to collection %.',
              v_candidates[1], v_es, v_ew, p_entry_id
              USING ERRCODE = 'P0001';
          END IF;

          -- Claim the movement atomically. RETURNING tells us whether THIS
          -- transaction won; a concurrent claimer shows up as zero rows.
          UPDATE public.cash_movements
          SET source_finance_entry_id = p_entry_id
          WHERE customer_id = p_customer
            AND id = v_candidates[1]
            AND source_finance_entry_id IS NULL
          RETURNING id INTO v_linked;
          IF v_linked IS NOT NULL THEN
            v_adopted := true;
            EXIT;
          END IF;

          -- Lost the race: re-read what the movement actually points at.
          SELECT source_finance_entry_id INTO v_now
          FROM public.cash_movements
          WHERE customer_id = p_customer AND id = v_candidates[1];
          IF v_now IS NOT DISTINCT FROM p_entry_id THEN
            -- A concurrent delete of THIS SAME entry linked it first.
            v_linked := v_candidates[1];
            v_adopted := true;
            EXIT;
          END IF;
          IF v_now IS NULL THEN
            RAISE EXCEPTION
              'LEGACY_REVERSAL_AMBIGUOUS: link update for movement % affected no row and it remains unlinked.',
              v_candidates[1]
              USING ERRCODE = 'P0001';
          END IF;
          -- Otherwise the movement now belongs to a DIFFERENT collection:
          -- it is not this entry's reversal. Loop and recompute candidates.
        END LOOP;

        IF NOT v_adopted AND v_cand_n = 1 THEN
          RAISE EXCEPTION
            'LEGACY_REVERSAL_AMBIGUOUS: candidate movement for collection % could not be securely adopted after concurrent claims.',
            p_entry_id
            USING ERRCODE = 'P0001';
        END IF;

        IF v_adopted THEN
          INSERT INTO public.pos_audit_logs
            (id, customer_id, user_id, action, details, created_at)
          VALUES (gen_random_uuid(), p_customer, p_user,
            'LEGACY_REVERSAL_LINKED',
            'Movement ' || v_linked || ' linked to collection ' || p_entry_id || '.',
            now());
        ELSE
          IF v_cand_n > 1 THEN
            RAISE EXCEPTION
              'LEGACY_REVERSAL_AMBIGUOUS: % unlinked reversal movements match collection %; link the correct movement before deleting.',
              v_cand_n, p_entry_id
              USING ERRCODE = 'P0001';
          END IF;

          -- Zero adoptable candidates. Exact-text matching failing does NOT
          -- prove no reversal exists — a category rename while the device
          -- was offline makes a genuine old reversal unrecognizable. Detect
          -- plausible leftovers (same amount, reversal-shaped reason, still
          -- unlinked) and defer rather than write a second drawer movement.
          SELECT count(*) INTO v_plausible
          FROM public.cash_movements m
          WHERE m.customer_id = p_customer
            AND m.type = 'WITHDRAWAL'
            AND m.source_finance_entry_id IS NULL
            AND m.amount_minor_units = entry.amount_minor_units
            AND btrim(COALESCE(m.reason, ''))
                LIKE 'Reversal: deleted cash collection from%';
          IF v_plausible > 0 THEN
            RAISE EXCEPTION
              'LEGACY_REVERSAL_AMBIGUOUS: % plausible unlinked reversal movement(s) match the amount of collection % but cannot be uniquely attributed (reason/actor evidence insufficient); link the correct movement before deleting.',
              v_plausible, p_entry_id
              USING ERRCODE = 'P0001';
          END IF;

          -- Absence is now sufficiently established: write exactly one
          -- server reversal for the collection.
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
-- 5. Privileges
-- ===========================================================================
REVOKE ALL ON FUNCTION public.pos_add_cash_movement_unchecked(uuid, text, text, text, bigint, text, text, text, text)
  FROM PUBLIC, "anon", "authenticated", "service_role";
REVOKE ALL ON FUNCTION public.pos_delete_finance_entry_unchecked(uuid, text, text)
  FROM PUBLIC, "anon", "authenticated", "service_role";
