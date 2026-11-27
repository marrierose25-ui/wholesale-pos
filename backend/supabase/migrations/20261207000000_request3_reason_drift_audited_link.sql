-- Request 3 reason-drift late dedup + audited manual link/revocation.
--
-- Builds on 20261204000000..20261206000000 (leg index, bidirectional
-- adoption, actor evidence, late-arrival dedup, UNRELATED verdicts,
-- session-less bootstrap — all preserved).
--
--   1. REASON DRIFT: the late-arrival helpers require exact reason-text
--      equality, so a category rename between the device write and the
--      cloud reversal leaves a gap — the old-format push inserts a SECOND
--      unlinked withdrawal. Fix: after the exact candidates fail, check
--      for plausible LINKED reversals (same amount, reversal-shaped
--      reason, verified actor). Any hit means the evidence cannot prove
--      the incoming movement is NOT the same money — raise
--      LEGACY_REVERSAL_AMBIGUOUS so the sync layer defers the row PENDING
--      with a durable marker. Nothing is inserted, attached, or guessed;
--      actor-conflicting movements are NOT plausible and still insert
--      normally (they are different actors' money).
--
--   2. AUDITED MANUAL LINK: docs previously told operators to run a bare
--      UPDATE cash_movements SET source_finance_entry_id=..., bypassing
--      the LEGACY_REVERSAL_LINKED audit. pos_link_legacy_reversal performs
--      the same link atomically with full validation and an audit record
--      (operator identity is a SQL parameter — operator-attested, not
--      independently authenticated). pos_revoke_unrelated_verdict replaces
--      the documented "delete the reconciliation row" instruction with an
--      audited revocation that preserves the original audit event.
--
-- Policy unchanged: ONE activation code = ONE business, UNLIMITED devices.

-- ===========================================================================
-- 1. Atomic cash-movement insert — reason-drift plausible deferral
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
  v_drift            int;
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
  -- row while this old-format push arrives afterwards. Exact reason-text
  -- equality is the strongest evidence: exactly one strong AND one weak
  -- candidate means this is the same money already in the drawer — return
  -- it as the duplicate. Anything weaker is conflicting evidence: defer.
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

    -- REASON DRIFT: a category rename between the device write and the
    -- cloud reversal makes the stored reason text differ, so the exact
    -- lookup above finds nothing — yet a plausible linked reversal (same
    -- amount, reversal-shaped reason, VERIFIED actor) may be the same
    -- money. Inserting anyway would write a second drawer movement. The
    -- evidence cannot prove sameness, so defer: the sync layer keeps the
    -- row PENDING with the durable marker for operator resolution. Actor-
    -- conflicting movements are NOT plausible here — they are different
    -- actors' money and still record normally.
    SELECT count(*) INTO v_drift
    FROM public.cash_movements w
    JOIN public.pos_finance_entries e
      ON e.customer_id = w.customer_id
     AND e.id = w.source_finance_entry_id
    WHERE w.customer_id = p_customer
      AND w.type = 'WITHDRAWAL'
      AND w.source_finance_entry_id IS NOT NULL
      AND upper(COALESCE(e.payment_method, '')) = 'CASH'
      AND w.amount_minor_units = p_amount
      AND btrim(COALESCE(w.reason, ''))
          LIKE 'Reversal: deleted cash collection from%'
      AND public.pos_legacy_actor_ok(
        p_user, e.deleted_by, e.completed_by, w.user_id);
    IF v_drift > 0 THEN
      RAISE EXCEPTION
        'LEGACY_REVERSAL_AMBIGUOUS: % linked reversal movement(s) plausibly match this legacy withdrawal (amount + reversal-shaped reason + actor) but the reason text differs — possible category rename; preserved for operator review.',
        v_drift
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
-- 2. Audited manual legacy-reversal link (operator-attested identity)
-- ===========================================================================
-- p_actor is supplied as a SQL parameter: it is OPERATOR-ATTESTED, not
-- independently authenticated — the audit row records who the operator
-- claims to be, for accountability, not proof of identity.
CREATE OR REPLACE FUNCTION public.pos_link_legacy_reversal (
  p_customer    uuid,
  p_movement_id text,
  p_entry_id    text,
  p_actor       text,
  p_note        text DEFAULT NULL
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
DECLARE
  v_movement record;
  v_entry    record;
  v_linked   int;
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
    RAISE EXCEPTION 'Only a withdrawal can be a legacy reversal.';
  END IF;

  -- Idempotent identical retry: already linked to THIS collection -> done,
  -- no second audit, no state change.
  IF v_movement.source_finance_entry_id IS NOT DISTINCT FROM p_entry_id THEN
    RETURN;
  END IF;
  IF v_movement.source_finance_entry_id IS NOT NULL THEN
    RAISE EXCEPTION
      'Movement is already linked to a different collection (%).',
      v_movement.source_finance_entry_id;
  END IF;

  SELECT id, status, payment_method INTO v_entry
  FROM public.pos_finance_entries
  WHERE customer_id = p_customer AND id = p_entry_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Finance collection not found.';
  END IF;
  IF upper(COALESCE(v_entry.status, '')) <> 'COMPLETED'
     OR upper(COALESCE(v_entry.payment_method, '')) <> 'CASH' THEN
    RAISE EXCEPTION
      'Manual linking requires a COMPLETED CASH collection.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.cash_movements
    WHERE customer_id = p_customer
      AND source_finance_entry_id = p_entry_id
      AND type = 'DEPOSIT'
  ) THEN
    RAISE EXCEPTION 'Collection has no deposit leg; not a cash collection.';
  END IF;
  SELECT count(*) INTO v_linked FROM public.cash_movements
  WHERE customer_id = p_customer
    AND source_finance_entry_id = p_entry_id
    AND type = 'WITHDRAWAL';
  IF v_linked > 0 THEN
    RAISE EXCEPTION
      'Collection % already has a reversal leg; refusing a conflicting link.',
      p_entry_id;
  END IF;

  -- Atomic claim: the WHERE clause re-checks the link is still NULL so a
  -- concurrent linker cannot be overwritten.
  UPDATE public.cash_movements
  SET source_finance_entry_id = p_entry_id
  WHERE customer_id = p_customer
    AND id = p_movement_id
    AND source_finance_entry_id IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Movement was linked concurrently; re-check before retry.';
  END IF;

  INSERT INTO public.pos_audit_logs
    (id, customer_id, user_id, action, details, created_at)
  VALUES (gen_random_uuid(), p_customer, p_actor,
    'LEGACY_REVERSAL_LINKED',
    'Manual link: movement ' || p_movement_id || ' -> collection '
      || p_entry_id || ' by ' || p_actor
      || COALESCE(' — ' || p_note, '.') || ' at ' || now()::text,
    now());
END;
$function$;

-- ===========================================================================
-- 3. Audited UNRELATED-verdict revocation
-- ===========================================================================
-- Replaces "delete the reconciliation row": the verdict row is removed AND
-- the revocation is audited, so the original MARKED_UNRELATED event stays
-- in pos_audit_logs forever.
CREATE OR REPLACE FUNCTION public.pos_revoke_unrelated_verdict (
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
  v_deleted int;
BEGIN
  IF p_customer IS NULL OR p_movement_id IS NULL OR p_entry_id IS NULL
     OR p_actor IS NULL OR btrim(p_actor) = '' THEN
    RAISE EXCEPTION 'Customer, movement, collection and actor are required.';
  END IF;

  DELETE FROM public.cash_movement_reconciliations
  WHERE customer_id = p_customer
    AND movement_id = p_movement_id
    AND finance_entry_id = p_entry_id
    AND resolution = 'UNRELATED';
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  IF v_deleted = 0 THEN
    RAISE EXCEPTION 'No UNRELATED verdict exists for this movement/collection.';
  END IF;

  INSERT INTO public.pos_audit_logs
    (id, customer_id, user_id, action, details, created_at)
  VALUES (gen_random_uuid(), p_customer, p_actor,
    'LEGACY_REVERSAL_UNRELATED_REVOKED',
    'UNRELATED verdict revoked: movement ' || p_movement_id
      || ' vs collection ' || p_entry_id || ' by ' || p_actor
      || COALESCE(' — ' || p_note, '.'), now());
END;
$function$;

-- ===========================================================================
-- 4. Privileges — operator functions are service-role only, never anon/auth
-- ===========================================================================
REVOKE ALL ON FUNCTION public.pos_add_cash_movement_unchecked(uuid, text, text, text, bigint, text, text, text, text)
  FROM PUBLIC, "anon", "authenticated", "service_role";
REVOKE ALL ON FUNCTION public.pos_link_legacy_reversal(uuid, text, text, text, text)
  FROM PUBLIC, "anon", "authenticated";
REVOKE ALL ON FUNCTION public.pos_revoke_unrelated_verdict(uuid, text, text, text, text)
  FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION public.pos_link_legacy_reversal(uuid, text, text, text, text)
  TO "service_role";
GRANT EXECUTE ON FUNCTION public.pos_revoke_unrelated_verdict(uuid, text, text, text, text)
  TO "service_role";
