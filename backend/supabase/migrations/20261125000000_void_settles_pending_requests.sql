-- Stage 4.1.3 / audit H1 follow-up: void-request consistency on direct voids.
--
-- Problem: the sync gateway no longer applies payload-driven transitions, so
-- a void request that reaches the cloud as PENDING can outlive the direct
-- owner void that settles it locally. pos_void_sale flips the sale but left
-- sibling requests PENDING forever — the approval queue then shows requests
-- for money that no longer exists, and a later approve_void would try to
-- void an already-voided sale.
--
-- Fix: when a sale transitions to VOIDED, every still-PENDING void request
-- for that sale is settled in the SAME transaction, attributed to the
-- verified actor that voided the sale (sales.voided_by is written by
-- pos_void_sale from the JWT-derived p_user, never from a client payload).
-- This is server-authoritative: no client can mark a request APPROVED by
-- pushing a payload, and requests arriving AFTER the void are already
-- refused by pos_sync_apply's "Sale % is not voidable." guard.
--
-- Idempotent: the UPDATE only touches status='PENDING' rows, so re-running
-- the transition (or a replayed void) settles nothing twice. The existing
-- pos_audit_logs rows written by pos_void_sale are untouched.

CREATE OR REPLACE FUNCTION public.tg_settle_pending_void_requests()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  -- Fires only on the COMPLETED/etc -> VOIDED edge, not on unrelated updates.
  IF NEW.status = 'VOIDED' AND OLD.status IS DISTINCT FROM 'VOIDED' THEN
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

DROP TRIGGER IF EXISTS sales_void_settles_pending_requests ON public.sales;
CREATE TRIGGER sales_void_settles_pending_requests
  AFTER UPDATE OF status ON public.sales
  FOR EACH ROW
  EXECUTE FUNCTION public.tg_settle_pending_void_requests();
