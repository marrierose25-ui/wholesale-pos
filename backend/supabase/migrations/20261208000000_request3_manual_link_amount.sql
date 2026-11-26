-- Request 3 manual-link amount integrity.
--
-- pos_link_legacy_reversal validated shape (unlinked WITHDRAWAL,
-- COMPLETED CASH collection, deposit leg, no existing reversal) but never
-- checked that the withdrawal amount equals the collection amount — an
-- operator could link a 5,000 withdrawal to a 7,000 collection and the
-- system would treat it as the completed reversal. This migration adds the
-- exact-equality requirement before the link UPDATE: mismatch raises,
-- nothing is written, both records stay untouched. No tolerance, no
-- rounding, no amount-only auto-matching — the amount check is one more
-- required condition on an already operator-attested, audited action.

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

  SELECT id, type, source_finance_entry_id, amount_minor_units
    INTO v_movement
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

  SELECT id, status, payment_method, amount_minor_units INTO v_entry
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

  -- Amount integrity: a reversal must return EXACTLY what the collection
  -- took. Mismatch refuses before any write — no link, no audit, both
  -- records untouched.
  IF v_movement.amount_minor_units IS DISTINCT FROM v_entry.amount_minor_units THEN
    RAISE EXCEPTION
      'Amount mismatch: withdrawal % cannot reverse collection % (% vs % minor units).',
      p_movement_id, p_entry_id,
      v_movement.amount_minor_units, v_entry.amount_minor_units;
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

REVOKE ALL ON FUNCTION public.pos_link_legacy_reversal(uuid, text, text, text, text)
  FROM PUBLIC, "anon", "authenticated";
GRANT EXECUTE ON FUNCTION public.pos_link_legacy_reversal(uuid, text, text, text, text)
  TO "service_role";
