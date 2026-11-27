-- Delete a money-tracking entry without breaking the append-only ledger.
--
-- The row is marked DELETED (never physically removed) so the deletion can be
-- pulled by every device, and its audit trail survives. When the entry was a
-- completed CASH collection, the deposit it wrote is reversed with a matching
-- WITHDRAWAL on the open drawer instead of deleting that cash row: the ledger
-- stays append-only and `pos_add_cash_movement`/`pos_sync_apply` can still
-- reconcile the same movement everywhere.
--
-- Sync path: the native app writes exactly the same two changes locally (status
-- DELETED + reversal movement) and stages them through the outbox. This RPC is
-- for the PWA's own delete button and must produce the same result.
CREATE OR REPLACE FUNCTION public.pos_delete_finance_entry(
  p_customer uuid,
  p_user     text,
  p_entry_id text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  entry        record;
  cat_name     text;
  shift_found  text;
  updated      int;
BEGIN
  -- Same refusal as every other finance RPC: a training account cannot move the
  -- shop's money in the cloud.
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
  -- still there, post the opposite leg on the open shift. If there is no open
  -- shift we refuse rather than delete the entry with its money still in the
  -- current drawer and no way to reconcile it.
  IF upper(COALESCE(entry.status, '')) = 'COMPLETED'
     AND upper(COALESCE(entry.payment_method, '')) = 'CASH' THEN
    IF EXISTS (
      SELECT 1 FROM public.cash_movements
      WHERE customer_id = p_customer
        AND source_finance_entry_id = p_entry_id
    ) THEN
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
        reason, created_at)
      VALUES (
        gen_random_uuid(), p_customer, shift_found, p_user, 'WITHDRAWAL',
        entry.amount_minor_units,
        'Reversal: deleted cash collection from '
          || COALESCE(cat_name, 'a person') || ' (' || COALESCE(entry.source, '') || ')',
        now());
    END IF;
  END IF;

  UPDATE public.pos_finance_entries
  SET status = 'DELETED', updated_at = now()
  WHERE customer_id = p_customer AND id = p_entry_id AND status <> 'DELETED';
  GET DIAGNOSTICS updated = ROW_COUNT;
  IF updated <> 1 THEN
    RAISE EXCEPTION 'Entry is already deleted.';
  END IF;

  INSERT INTO public.pos_audit_logs (id, customer_id, user_id, action, details, created_at)
  VALUES (gen_random_uuid(), p_customer, p_user, 'FINANCE_ENTRY_DELETED',
    'Entry ' || p_entry_id || ' deleted.', now());
END;
$$;
REVOKE ALL ON FUNCTION public.pos_delete_finance_entry(uuid, text, text) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_delete_finance_entry(uuid, text, text) TO service_role;

-- A deleted entry keeps its row (status DELETED) so the deletion syncs, so the
-- person's completed total must count only COMPLETED. The old `status <>
-- 'PENDING'` would have kept a deleted completed collection in the total.
CREATE OR REPLACE FUNCTION public.pos_finance_person_totals(
  p_customer uuid, p_category_id text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  res  jsonb;
  zero jsonb := jsonb_build_object('pending_total', 0, 'completed_total', 0);
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.pos_finance_categories
    WHERE customer_id = p_customer AND id = p_category_id AND deleted_at IS NULL
  ) THEN
    RETURN zero;
  END IF;
  SELECT jsonb_build_object(
    'pending_total',   COALESCE(sum(amount_minor_units) FILTER (WHERE status = 'PENDING'), 0),
    'completed_total', COALESCE(sum(amount_minor_units) FILTER (WHERE status = 'COMPLETED'), 0)
  ) INTO res
  FROM public.pos_finance_entries
  WHERE customer_id = p_customer AND category_id = p_category_id;
  RETURN COALESCE(res, zero);
END;
$$;
REVOKE ALL ON FUNCTION public.pos_finance_person_totals(uuid, text) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_finance_person_totals(uuid, text) TO service_role;
