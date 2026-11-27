-- Stage 4.1 closure / audit H1: void_requests referential integrity.
--
-- Verified against the live schema export (supabase db pull --declarative,
-- project aymen): `void_requests.sale_id` carried NO foreign key — the
-- multi-tenant mirror schema keeps tables loosely coupled and the only
-- "sale exists" guards were the app-level checks inside pos_sync_apply and
-- the pos-api requestVoid action. Any insertion path that skipped those
-- checks (a future RPC, a manual service-role write, a bug) could land a
-- request pointing at a sale that does not exist — or at a sale belonging
-- to a different tenant, since nothing tied the two columns together.
--
-- Two invariants are now enforced by the database itself, for EVERY
-- insertion path (trigger-covered or not):
--
-- 1) REFERENTIAL: (customer_id, sale_id) must reference an existing
--    sales(customer_id, id). Composite, so a request can never point across
--    the tenant boundary either. Added NOT VALID so the migration never
--    scans/locks existing rows inside its transaction, then validated
--    immediately when the table is clean; if historical orphans exist the
--    constraint still enforces every NEW write and is left NOT VALID with a
--    warning rather than failing the deploy or silently deleting data.
--
-- 2) SINGLE PENDING REQUEST: at most one PENDING void request per sale.
--    pos-api's requestVoid already answers 409 on a duplicate, but
--    pos_sync_apply inserts without that check, so two devices (or a replay
--    with a fresh request id) could stack PENDING requests on one sale.
--    Approving one would then settle the rest through the void trigger —
--    correct, but the queue showed phantom decisions. The partial unique
--    index makes the invariant structural. Built only when no duplicates
--    already exist; duplicates are warned about, never deleted.

ALTER TABLE public.void_requests
  ADD CONSTRAINT void_requests_sale_fkey
  FOREIGN KEY (customer_id, sale_id)
  REFERENCES public.sales (customer_id, id)
  NOT VALID;

DO $$
DECLARE
  orphan_count int;
BEGIN
  SELECT count(*) INTO orphan_count
  FROM public.void_requests vr
  LEFT JOIN public.sales s
    ON s.customer_id = vr.customer_id
   AND s.id = vr.sale_id
  WHERE s.customer_id IS NULL;

  IF orphan_count = 0 THEN
    ALTER TABLE public.void_requests
      VALIDATE CONSTRAINT void_requests_sale_fkey;
  ELSE
    RAISE WARNING 'void_requests_sale_fkey left NOT VALID: % orphan row(s) reference missing sales; new writes are still enforced', orphan_count;
  END IF;
END $$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.void_requests
    WHERE status = 'PENDING'
    GROUP BY customer_id, sale_id
    HAVING count(*) > 1
  ) THEN
    RAISE WARNING 'void_requests_one_pending_per_sale skipped: duplicate PENDING requests already exist; new duplicates are still rejected only for rows inserted after a manual cleanup';
  ELSE
    CREATE UNIQUE INDEX void_requests_one_pending_per_sale
      ON public.void_requests (customer_id, sale_id)
      WHERE status = 'PENDING';
  END IF;
END $$;
