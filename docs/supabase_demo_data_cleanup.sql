-- ===========================================================================
-- One-time purge: the training account's ledger out of the cloud.
--
-- The demo account exists so a new cashier can practise without touching the
-- shop's books. Until the outbox and `pos_sync_apply` both refused its rows, that
-- practice money was pushed like any other sale, so a real shop's dashboard
-- reported it: the live tenant measured before this script had 1,700 demo sales
-- and 427 real ones, i.e. its reported takings were roughly four times the truth.
--
-- What is removed (per tenant, keyed on the account's `is_demo` flag):
--   sale_items        line items of the demo's sales
--   void_requests     void requests the demo raised
--   sales             the demo's receipts
--   cash_movements    the demo's deposits / withdrawals / expenses
--   shifts            the demo's register sessions
-- What is kept:
--   pos_users         the demo account itself — it must stay so the login works
--   pos_products, pos_finance_categories, pos_finance_entries
--                     master data and the debt ledger, which the shop shares
--   pos_audit_logs    history of who did what, including the training
--
-- One guard worth knowing about: a DEPOSIT carrying `source_finance_entry_id` is
-- the money half of a completed collection. Deleting it while its collection
-- stays would recreate exactly the "completed entry with no deposit" hole that
-- `supabase_finance_movement_dedupe.sql` closed, so a movement is only purged
-- when its entry was created by a demo account too — otherwise it is counted in
-- `kept_movements` and left alone.
--
-- Nothing is thrown away: purging 1,702 receipts is not a change to make without
-- a way back, so every deleted row is copied into `public.demo_purge_rows`
-- first.
--
-- Run the dry report first, then the purge. `docs/supabase_pos_integrity.sql`
-- has to be applied first: this file calls `public.pos_is_demo()`.
--   cd <repo root>
--   supabase db query --linked -f docs/supabase_pos_integrity.sql
--   supabase db query --linked -f docs/supabase_demo_data_cleanup.sql
--   supabase db query --linked "SELECT * FROM public.pos_demo_ledger_report()"
--   supabase db query --linked "SELECT public.pos_purge_demo_ledger()"
-- Afterwards, once the dashboards have been checked (the objects have served
-- their purpose — keep the archive a few days longer if in doubt). The archive
-- is the only copy of what was deleted, so drop it only when the numbers are
-- confirmed:
--   supabase db query --linked "DROP FUNCTION public.pos_purge_demo_ledger();
--     DROP FUNCTION public.pos_demo_ledger_report()"
--   supabase db query --linked "DROP TABLE public.demo_purge_rows"
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Dry report: what each tenant would lose, before anything is deleted.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pos_demo_ledger_report()
RETURNS TABLE (tenant text, what text, n_rows bigint, n_units bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r RECORD;
  c uuid;
BEGIN
  FOR r IN SELECT DISTINCT customer_id FROM public.pos_users WHERE is_demo LOOP
    c := r.customer_id;
    tenant := left(c::text, 8);

    what := 'sales';
    SELECT count(*), COALESCE(sum(total_minor_units), 0) INTO n_rows, n_units
    FROM public.sales s
    WHERE s.customer_id = c AND public.pos_is_demo(c, s.cashier_id);
    RETURN NEXT;

    what := 'sale_items';
    SELECT count(*) INTO n_rows FROM public.sale_items i
    WHERE i.customer_id = c
      AND EXISTS (SELECT 1 FROM public.sales s
                  WHERE s.customer_id = i.customer_id AND s.id = i.sale_id
                    AND public.pos_is_demo(c, s.cashier_id));
    n_units := 0;
    RETURN NEXT;

    what := 'void_requests';
    SELECT count(*) INTO n_rows FROM public.void_requests vr
    WHERE vr.customer_id = c AND public.pos_is_demo(c, vr.requested_by);
    n_units := 0;
    RETURN NEXT;

    what := 'cash_movements';
    SELECT count(*), COALESCE(sum(amount_minor_units), 0) INTO n_rows, n_units
    FROM public.cash_movements m
    WHERE m.customer_id = c AND public.pos_is_demo(c, m.user_id)
      AND (m.source_finance_entry_id IS NULL OR EXISTS (
        SELECT 1 FROM public.pos_finance_entries f
        WHERE f.customer_id = m.customer_id AND f.id = m.source_finance_entry_id
          AND public.pos_is_demo(c, f.created_by)));
    RETURN NEXT;

    what := 'shifts';
    SELECT count(*) INTO n_rows FROM public.shifts h
    WHERE h.customer_id = c AND public.pos_is_demo(c, h.cashier_id);
    n_units := 0;
    RETURN NEXT;
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. The purge. Children first, then the receipts, then the sessions: nothing
--    here has a foreign key between tables (the tenant key is the only one), so
--    the order is for readability and for the counts to stay meaningful.
--
--    Each table's rows are copied into `demo_purge_rows` as jsonb and the DELETE
--    then names that archive as its condition, so exactly what was kept is what
--    goes — the two predicates can never drift apart.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.demo_purge_rows (
  purge_customer uuid        NOT NULL,
  entity         text        NOT NULL,
  row_id         text        NOT NULL,
  data           jsonb       NOT NULL,
  archived_at    timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.pos_purge_demo_ledger()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r          RECORD;
  c          uuid;
  v_tenants  bigint := 0;
  v_items    bigint := 0;
  v_voids    bigint := 0;
  v_sales    bigint := 0;
  v_moves    bigint := 0;
  v_shifts   bigint := 0;
  n          bigint := 0;
  kept       bigint := 0;
  t_items    bigint := 0;
  t_voids    bigint := 0;
  t_sales    bigint := 0;
  t_moves    bigint := 0;
  t_shifts   bigint := 0;
  t_kept     bigint := 0;
BEGIN
  FOR r IN SELECT DISTINCT customer_id FROM public.pos_users WHERE is_demo LOOP
    c := r.customer_id;
    v_tenants := v_tenants + 1;
    t_items := 0; t_voids := 0; t_sales := 0;
    t_moves := 0; t_shifts := 0; t_kept := 0;

    INSERT INTO public.demo_purge_rows (purge_customer, entity, row_id, data)
    SELECT c, 'sale_items', i.id, to_jsonb(i) FROM public.sale_items i
    WHERE i.customer_id = c
      AND EXISTS (SELECT 1 FROM public.sales s
                  WHERE s.customer_id = i.customer_id AND s.id = i.sale_id
                    AND public.pos_is_demo(c, s.cashier_id));

    DELETE FROM public.sale_items i
    WHERE i.customer_id = c
      AND EXISTS (SELECT 1 FROM public.demo_purge_rows p
                  WHERE p.purge_customer = c AND p.entity = 'sale_items'
                    AND p.row_id = i.id);
    GET DIAGNOSTICS n = ROW_COUNT; t_items := n; v_items := v_items + n;

    INSERT INTO public.demo_purge_rows (purge_customer, entity, row_id, data)
    SELECT c, 'void_request', vr.id, to_jsonb(vr) FROM public.void_requests vr
    WHERE vr.customer_id = c AND public.pos_is_demo(c, vr.requested_by);

    DELETE FROM public.void_requests vr
    WHERE vr.customer_id = c
      AND EXISTS (SELECT 1 FROM public.demo_purge_rows p
                  WHERE p.purge_customer = c AND p.entity = 'void_request'
                    AND p.row_id = vr.id);
    GET DIAGNOSTICS n = ROW_COUNT; t_voids := n; v_voids := v_voids + n;

    INSERT INTO public.demo_purge_rows (purge_customer, entity, row_id, data)
    SELECT c, 'cash_movement', m.id, to_jsonb(m) FROM public.cash_movements m
    WHERE m.customer_id = c AND public.pos_is_demo(c, m.user_id)
      -- A deposit that pays a real person's collection stays in the ledger even
      -- though a demo hand rang it in: removing it would break the pair.
      AND (m.source_finance_entry_id IS NULL OR EXISTS (
        SELECT 1 FROM public.pos_finance_entries f
        WHERE f.customer_id = m.customer_id AND f.id = m.source_finance_entry_id
          AND public.pos_is_demo(c, f.created_by)));

    DELETE FROM public.cash_movements m
    WHERE m.customer_id = c
      AND EXISTS (SELECT 1 FROM public.demo_purge_rows p
                  WHERE p.purge_customer = c AND p.entity = 'cash_movement'
                    AND p.row_id = m.id);
    GET DIAGNOSTICS n = ROW_COUNT; t_moves := n; v_moves := v_moves + n;

    SELECT count(*) INTO n FROM public.cash_movements m
    WHERE m.customer_id = c AND public.pos_is_demo(c, m.user_id);
    t_kept := n; kept := kept + n;

    INSERT INTO public.demo_purge_rows (purge_customer, entity, row_id, data)
    SELECT c, 'sale', s.id, to_jsonb(s) FROM public.sales s
    WHERE s.customer_id = c AND public.pos_is_demo(c, s.cashier_id);

    DELETE FROM public.sales s
    WHERE s.customer_id = c
      AND EXISTS (SELECT 1 FROM public.demo_purge_rows p
                  WHERE p.purge_customer = c AND p.entity = 'sale'
                    AND p.row_id = s.id);
    GET DIAGNOSTICS n = ROW_COUNT; t_sales := n; v_sales := v_sales + n;

    INSERT INTO public.demo_purge_rows (purge_customer, entity, row_id, data)
    SELECT c, 'shift', h.id, to_jsonb(h) FROM public.shifts h
    WHERE h.customer_id = c AND public.pos_is_demo(c, h.cashier_id);

    DELETE FROM public.shifts h
    WHERE h.customer_id = c
      AND EXISTS (SELECT 1 FROM public.demo_purge_rows p
                  WHERE p.purge_customer = c AND p.entity = 'shift'
                    AND p.row_id = h.id);
    GET DIAGNOSTICS n = ROW_COUNT; t_shifts := n; v_shifts := v_shifts + n;

    INSERT INTO public.pos_audit_logs (id, customer_id, user_id, action, details, created_at)
    VALUES (gen_random_uuid(), c, NULL, 'DEMO_LEDGER_PURGED',
      'Removed ' || t_sales || ' training sales, ' || t_items || ' line items, '
      || t_moves || ' cash movements, ' || t_shifts || ' shifts, ' || t_voids
      || ' void requests; ' || t_kept || ' demo movements kept on purpose.', now());
  END LOOP;

  RETURN jsonb_build_object(
    'tenants', v_tenants, 'sales', v_sales, 'sale_items', v_items,
    'void_requests', v_voids, 'cash_movements', v_moves,
    'shifts', v_shifts, 'kept_demo_movements', kept);
END;
$$;

REVOKE ALL ON FUNCTION public.pos_demo_ledger_report() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pos_demo_ledger_report() TO service_role;
REVOKE ALL ON FUNCTION public.pos_purge_demo_ledger() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pos_purge_demo_ledger() TO service_role;
