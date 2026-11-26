-- Request 3 late legacy reversal dedup + operator resolution.
--
-- Builds on 20261204000000/20261205000000 (atomic leg index, bidirectional
-- adoption, actor evidence, session-less bootstrap — all preserved).
--
--   1. LATE ARRIVAL: an old-format unlinked WITHDRAWAL can reach the cloud
--      AFTER the collection's reversal already exists (server-written or
--      device-written then linked). The entry->movement candidate helpers
--      exclude entries that already have a linked reversal, so the old
--      inference left v_source NULL and inserted a SECOND unlinked
--      movement — the leg index cannot see it. Now, before inserting an
--      unlinked legacy withdrawal, the insert path checks whether exactly
--      one LINKED reversal represents it (same reason text, amount, actor
--      evidence). One match -> return the existing movement as the
--      duplicate. Conflicting/ambiguous evidence -> raise
--      LEGACY_REVERSAL_AMBIGUOUS so pos_sync_apply defers the row PENDING
--      with a durable marker instead of acknowledging an uncertain
--      financial outcome. Nothing is deleted or rewritten.
--
--   2. OPERATOR RESOLUTION: the plausible-reversal blocker used to defer a
--      delete forever when an operator determined an unlinked movement did
--      NOT belong to the collection — there was no way to say so. New
--      table cash_movement_reconciliations records an explicit, audited
--      UNRELATED verdict per (movement, collection) pair via
--      pos_mark_movement_unrelated. The plausible check excludes resolved
--      pairs; the movement itself is never touched. Manual source-linking
--      (the existing operator path) is unchanged for real matches.
--
-- Policy unchanged: ONE activation code = ONE business, UNLIMITED devices.

-- ===========================================================================
-- 1. Reconciliation records — durable, audited operator verdicts
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.cash_movement_reconciliations (
  customer_id       uuid                     NOT NULL,
  movement_id       text                     NOT NULL,
  finance_entry_id  text                     NOT NULL,
  resolution        text                     NOT NULL,
  resolved_by       text                     NOT NULL,
  note              text,
  created_at        timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT cash_movement_reconciliations_pkey
    PRIMARY KEY (customer_id, movement_id, finance_entry_id),
  CONSTRAINT cash_movement_reconciliations_customer_fkey
    FOREIGN KEY (customer_id) REFERENCES public.customers(id),
  CONSTRAINT cash_movement_reconciliations_movement_fkey
    FOREIGN KEY (customer_id, movement_id)
    REFERENCES public.cash_movements(customer_id, id),
  CONSTRAINT cash_movement_reconciliations_entry_fkey
    FOREIGN KEY (customer_id, finance_entry_id)
    REFERENCES public.pos_finance_entries(customer_id, id)
);

ALTER TABLE public.cash_movement_reconciliations ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.cash_movement_reconciliations
  FROM PUBLIC, "anon", "authenticated";
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.cash_movement_reconciliations
  TO "service_role";
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.cash_movement_reconciliations
  TO "postgres";

-- ===========================================================================
-- 2. Late-arrival candidate helpers — linked reversals only
-- ===========================================================================
-- Strong: a LINKED withdrawal whose stored reason text and amount equal the
-- incoming legacy movement's, with verified actor evidence (incoming actor
-- must equal the entry's deleted_by/completed_by or the recorded reversal's
-- own user — the delete-time actor).
CREATE OR REPLACE FUNCTION public.pos_legacy_linked_reversal_candidates (
  p_customer uuid,
  p_amount   bigint,
  p_reason   text,
  p_actor    text
)
  RETURNS TABLE (movement_id text)
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  SELECT w.id
  FROM public.cash_movements w
  JOIN public.pos_finance_entries e
    ON e.customer_id = w.customer_id
   AND e.id = w.source_finance_entry_id
  WHERE w.customer_id = p_customer
    AND w.type = 'WITHDRAWAL'
    AND w.source_finance_entry_id IS NOT NULL
    AND upper(COALESCE(e.payment_method, '')) = 'CASH'
    AND w.amount_minor_units = p_amount
    AND btrim(w.reason) = btrim(p_reason)
    AND public.pos_legacy_actor_ok(
      p_actor, e.deleted_by, e.completed_by, w.user_id)
  ORDER BY w.created_at, w.id;
$function$;

-- Weak: same text+amount match with NO actor requirement — used only to
-- prove the incoming movement is not uniquely attributable.
CREATE OR REPLACE FUNCTION public.pos_legacy_linked_reversal_candidates_weak (
  p_customer uuid,
  p_amount   bigint,
  p_reason   text
)
  RETURNS TABLE (movement_id text)
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  SELECT w.id
  FROM public.cash_movements w
  JOIN public.pos_finance_entries e
    ON e.customer_id = w.customer_id
   AND e.id = w.source_finance_entry_id
  WHERE w.customer_id = p_customer
    AND w.type = 'WITHDRAWAL'
    AND w.source_finance_entry_id IS NOT NULL
    AND upper(COALESCE(e.payment_method, '')) = 'CASH'
    AND w.amount_minor_units = p_amount
    AND btrim(w.reason) = btrim(p_reason)
  ORDER BY w.created_at, w.id;
$function$;

REVOKE ALL ON FUNCTION public.pos_legacy_linked_reversal_candidates(uuid, bigint, text, text)
  FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION public.pos_legacy_linked_reversal_candidates_weak(uuid, bigint, text)
  FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION public.pos_legacy_linked_reversal_candidates(uuid, bigint, text, text)
  TO "service_role";
GRANT EXECUTE ON FUNCTION public.pos_legacy_linked_reversal_candidates_weak(uuid, bigint, text)
  TO "service_role";

-- ===========================================================================
-- 3. Atomic cash-movement insert — late-arrival convergence
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
  v_late             text[];
  v_late_weak        int;
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
  -- be exactly one. Anything less stays unlinked for the paths below.
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

  -- LATE ARRIVAL: the collection's reversal may ALREADY exist as a linked
  -- row (server-written fallback, or a device leg adopted at delete time)
  -- while this old-format push arrives afterwards — possibly in a later
  -- batch, possibly after the entry reached DELETED. The entry->movement
  -- helpers above exclude entries that already have a linked reversal, so
  -- without this check the movement would insert as a SECOND unlinked leg
  -- the unique index cannot see. Match on the recorded reason text, amount
  -- and actor evidence: exactly one strong AND one weak candidate means
  -- this is the same money already in the drawer — return it as the
  -- duplicate. Any weaker uniqueness is conflicting evidence: raise
  -- LEGACY_REVERSAL_AMBIGUOUS so the sync layer defers the row PENDING with
  -- a durable marker — never acknowledge an uncertain outcome, never
  -- guess, never rewrite the payload.
  IF v_source IS NULL AND p_type = 'WITHDRAWAL' THEN
    SELECT COALESCE(array_agg(l.movement_id), '{}'::text[])
      INTO v_late
    FROM public.pos_legacy_linked_reversal_candidates(
      p_customer, p_amount, v_reason, p_user) l;
    SELECT count(*) INTO v_late_weak
    FROM public.pos_legacy_linked_reversal_candidates_weak(
      p_customer, p_amount, v_reason) l;
    IF COALESCE(array_length(v_late, 1), 0) = 1 AND v_late_weak = 1 THEN
      RETURN jsonb_build_object('id', v_late[1], 'duplicate', true);
    END IF;
    IF v_late_weak > 0 THEN
      RAISE EXCEPTION
        'LEGACY_REVERSAL_AMBIGUOUS: % linked reversal movement(s) match this legacy withdrawal but actor or collection evidence is not unique; preserved for operator review.',
        v_late_weak
        USING ERRCODE = 'P0001';
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
-- 4. Reversal delete — plausible check honours explicit UNRELATED verdicts
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
          -- Movements an operator explicitly marked UNRELATED *for this
          -- collection* no longer block: the verdict is durable and audited.
          SELECT count(*) INTO v_plausible
          FROM public.cash_movements m
          WHERE m.customer_id = p_customer
            AND m.type = 'WITHDRAWAL'
            AND m.source_finance_entry_id IS NULL
            AND m.amount_minor_units = entry.amount_minor_units
            AND btrim(COALESCE(m.reason, ''))
                LIKE 'Reversal: deleted cash collection from%'
            AND NOT EXISTS (
              SELECT 1 FROM public.cash_movement_reconciliations r
              WHERE r.customer_id = m.customer_id
                AND r.movement_id = m.id
                AND r.finance_entry_id = p_entry_id
                AND r.resolution = 'UNRELATED'
            );
          IF v_plausible > 0 THEN
            RAISE EXCEPTION
              'LEGACY_REVERSAL_AMBIGUOUS: % plausible unlinked reversal movement(s) match the amount of collection % but cannot be uniquely attributed (reason/actor evidence insufficient); link the correct movement or record an UNRELATED verdict before deleting.',
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
-- 5. Operator verdict: mark a movement UNRELATED to a collection
-- ===========================================================================
-- Durable, audited, idempotent. The movement row itself is NEVER modified —
-- only the resolution record is written, so the original payload and money
-- history are preserved exactly.
CREATE OR REPLACE FUNCTION public.pos_mark_movement_unrelated (
  p_customer       uuid,
  p_movement_id    text,
  p_entry_id       text,
  p_actor          text,
  p_note           text DEFAULT NULL
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
DECLARE
  v_movement record;
  v_entry    record;
BEGIN
  IF p_customer IS NULL OR p_movement_id IS NULL OR p_entry_id IS NULL
     OR p_actor IS NULL OR btrim(p_actor) = '' THEN
    RAISE EXCEPTION 'Customer, movement, collection and actor are required.';
  END IF;

  SELECT id, type, source_finance_entry_id INTO v_movement
  FROM public.cash_movements
  WHERE customer_id = p_customer AND id = p_movement_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Movement not found.';
  END IF;
  IF v_movement.type <> 'WITHDRAWAL' THEN
    RAISE EXCEPTION 'Only a withdrawal can be a legacy reversal candidate.';
  END IF;
  IF v_movement.source_finance_entry_id IS NOT NULL THEN
    RAISE EXCEPTION 'Movement is already linked to a collection.';
  END IF;

  SELECT id INTO v_entry
  FROM public.pos_finance_entries
  WHERE customer_id = p_customer AND id = p_entry_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Finance collection not found.';
  END IF;

  INSERT INTO public.cash_movement_reconciliations
    (customer_id, movement_id, finance_entry_id, resolution,
     resolved_by, note, created_at)
  VALUES (p_customer, p_movement_id, p_entry_id, 'UNRELATED',
          p_actor, NULLIF(btrim(COALESCE(p_note, '')), ''), now())
  ON CONFLICT (customer_id, movement_id, finance_entry_id) DO NOTHING;

  INSERT INTO public.pos_audit_logs
    (id, customer_id, user_id, action, details, created_at)
  VALUES (gen_random_uuid(), p_customer, p_actor,
    'LEGACY_REVERSAL_MARKED_UNRELATED',
    'Movement ' || p_movement_id || ' marked UNRELATED to collection '
      || p_entry_id || COALESCE(': ' || p_note, '.'), now());
END;
$function$;

-- ===========================================================================
-- 6. Privileges
-- ===========================================================================
REVOKE ALL ON FUNCTION public.pos_add_cash_movement_unchecked(uuid, text, text, text, bigint, text, text, text, text)
  FROM PUBLIC, "anon", "authenticated", "service_role";
REVOKE ALL ON FUNCTION public.pos_delete_finance_entry_unchecked(uuid, text, text)
  FROM PUBLIC, "anon", "authenticated", "service_role";
REVOKE ALL ON FUNCTION public.pos_mark_movement_unrelated(uuid, text, text, text, text)
  FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION public.pos_mark_movement_unrelated(uuid, text, text, text, text)
  TO "service_role";
