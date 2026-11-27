-- Stage 4.1.4 / audit H1: void-request insertion race + attribution guard.
--
-- Two gaps closed here:
--
-- 1) RACE: pos_sync_apply and the PWA requestVoid path check the sale's
--    status and then INSERT the request as separate statements. A direct
--    owner void committing between the check and the insert leaves a
--    PENDING request on a VOIDED sale — the AFTER UPDATE settle trigger
--    (20261125000000) cannot see a row that did not exist yet.
--
--    Fix: a BEFORE INSERT trigger takes SELECT ... FOR UPDATE on the sale
--    row inside the inserting transaction. That serializes against the
--    void's UPDATE on the same row:
--      * insert wins the lock first  -> request commits PENDING, the void's
--        UPDATE then waits, proceeds, and the settle trigger approves it;
--      * void wins first             -> the insert's locked read sees
--        status <> 'COMPLETED' and RAISEs, refusing the request.
--    Either way the final state can never be VOIDED sale + PENDING request.
--
-- 2) ATTRIBUTION: the settle trigger must never manufacture an APPROVED
--    decision with a NULL decided_by. If a sale ever reaches VOIDED without
--    a recorded voidor, its pending requests stay PENDING (visible to the
--    approval queue) instead of becoming unattributed approvals.

CREATE OR REPLACE FUNCTION public.tg_void_request_require_voidable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  sale_status text;
BEGIN
  -- Lock the sale row for the duration of this transaction. Concurrent
  -- voids block on the same row, which is exactly the serialization we need.
  SELECT status INTO sale_status
    FROM public.sales
   WHERE customer_id = NEW.customer_id
     AND id = NEW.sale_id
   FOR UPDATE;

  -- A missing sale is left to the existing foreign-key / app-level checks;
  -- this trigger only polices the voidable-state invariant.
  IF sale_status IS NULL THEN
    RETURN NEW;
  END IF;
  IF sale_status <> 'COMPLETED' THEN
    RAISE EXCEPTION 'Sale % is not voidable (status %).', NEW.sale_id, sale_status;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS void_requests_require_voidable_sale ON public.void_requests;
CREATE TRIGGER void_requests_require_voidable_sale
  BEFORE INSERT ON public.void_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.tg_void_request_require_voidable();

-- Fail-closed attribution: only settle pending requests when the void
-- carries a real actor id.
CREATE OR REPLACE FUNCTION public.tg_settle_pending_void_requests()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status = 'VOIDED'
     AND OLD.status IS DISTINCT FROM 'VOIDED'
     AND NEW.voided_by IS NOT NULL THEN
    UPDATE public.void_requests
       SET status = 'APPROVED',
           decided_by = NEW.voided_by,
           decided_at = COALESCE(NEW.voided_at, now())
     WHERE customer_id = NEW.customer_id
       AND sale_id = NEW.id
       AND status = 'PENDING';
  END IF;
  RETURN NEW;
END;
$$;
