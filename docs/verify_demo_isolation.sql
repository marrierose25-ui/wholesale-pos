-- ===========================================================================
-- Live proof: training-account data cannot reach the cloud, and real money can.
--
-- The client guard (`SyncOutbox`) and the report filters have unit tests, but
-- the gateway refusal only exists once it is deployed — a till running an older
-- build still pushes its demo sales, and the cloud is what decides whether they
-- land. This probe stages exactly those rows and shows the door is shut.
--
--   cd <repo root>
--   supabase db query --linked -f docs/verify_demo_isolation.sql
--
-- The CLI only prints the LAST statement of a file, so every check writes a
-- line into a temp table and one final SELECT shows them all:
--   C  the tenant, demo account and owner used
--   I  probe rows staged
--   A  what pos_sync_apply reported
--   V  did a probe row land? (all must be false)
--   M  how the gateway filed the two probe rows
--   R  does the cloud report agree with a hand-computed real-only sum?
--   Q  positive control: the flag discriminates demo from owner
--   W  the direct door: a browser sale posted as the demo account
--   D  cleanup
--
-- The probe touches only its own rows, is scoped to the first tenant that has a
-- demo account, and deletes everything it staged — including anything that
-- landed by mistake. Running pos_sync_apply also drains any other pending row
-- for that tenant, which is what the sync gateway does on every push anyway.
-- ===========================================================================

DROP TABLE IF EXISTS pg_temp.probe_results;
CREATE TEMP TABLE probe_results (ord int, line text);

-- The tenant to probe, with one real owner to use as the positive control.
DROP TABLE IF EXISTS pg_temp.probe_ctx;
CREATE TEMP TABLE probe_ctx AS
SELECT u.customer_id,
       u.id AS demo_id,
       (SELECT o.id FROM public.pos_users o
         WHERE o.customer_id = u.customer_id AND o.role = 'OWNER' AND NOT o.is_demo
         ORDER BY o.username LIMIT 1) AS owner_id
FROM public.pos_users u
WHERE u.is_demo
ORDER BY u.customer_id
LIMIT 1;

INSERT INTO probe_results
SELECT 1, 'C tenant=' || left(c.customer_id::text, 8)
            || ' demo=' || left(c.demo_id, 8)
            || ' owner=' || COALESCE(left(c.owner_id, 8), 'none')
FROM pg_temp.probe_ctx c;

-- Row 1: a 100 Br sale pushed by a till whose cashier is the demo account.
INSERT INTO public.sync_mirror
  (customer_id, entity_type, entity_id, operation, device_id, payload)
SELECT c.customer_id, 'sale', 'PROBE-DEMO-SALE', 'UPSERT', 'isolation-probe',
  jsonb_build_object(
    'sale', jsonb_build_object(
      'id', 'PROBE-DEMO-SALE',
      'cashier_id', c.demo_id,
      'device_id', 'isolation-probe',
      'shift_id', 'PROBE-DEMO-SHIFT',
      'receipt_number', 'PROBE-0001',
      'status', 'COMPLETED',
      'payment_method', 'CASH',
      'subtotal_minor_units', 10000,
      'discount_minor_units', 0,
      'total_minor_units', 10000,
      'amount_paid_minor_units', 10000,
      'change_minor_units', 0,
      'created_at', to_char(now() AT TIME ZONE 'utc',
        'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')),
    'items', jsonb_build_array(jsonb_build_object(
      'id', 'PROBE-DEMO-ITEM',
      'sale_id', 'PROBE-DEMO-SALE',
      'product_id', 'PROBE-PRODUCT',
      'product_name_snapshot', 'Isolation Probe',
      'unit_price_snapshot_minor_units', 10000,
      'quantity_text', '1',
      'billing_quantity_milliunits', 1000,
      'line_total_minor_units', 10000))
  )
FROM pg_temp.probe_ctx c;

-- Row 2: a collection a real owner recorded but the demo account completed.
-- Both halves of a collection have to stay together, so a demo hand on either
-- end keeps the entry home — see `SyncOutbox._ledgerOwners`.
INSERT INTO public.sync_mirror
  (customer_id, entity_type, entity_id, operation, device_id, payload)
SELECT c.customer_id, 'finance_entry', 'PROBE-DEMO-FE', 'UPSERT',
       'isolation-probe',
  jsonb_build_object('finance_entry', jsonb_build_object(
    'id', 'PROBE-DEMO-FE',
    'category_id', 'PROBE-CATEGORY',
    'source', 'Isolation Probe',
    'description', 'must never be applied',
    'amount_minor_units', 10000,
    'status', 'COMPLETED',
    'payment_method', 'BANK',
    'entry_date', to_char(current_date, 'YYYY-MM-DD'),
    'created_by', c.owner_id,
    'completed_by', c.demo_id,
    'created_at', to_char(now() AT TIME ZONE 'utc',
      'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'updated_at', to_char(now() AT TIME ZONE 'utc',
      'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
  ))
FROM pg_temp.probe_ctx c;

INSERT INTO probe_results
SELECT 2, 'I staged=' || count(*)::text
FROM public.sync_mirror m
JOIN pg_temp.probe_ctx c ON c.customer_id = m.customer_id
WHERE m.entity_id LIKE 'PROBE-DEMO-%';

-- The gateway reads the queue. The two probe rows must be refused; anything
-- else the tenant had pending is applied as usual.
INSERT INTO probe_results
SELECT 3, 'A apply=' || public.pos_sync_apply(c.customer_id, 500)::text
FROM pg_temp.probe_ctx c;

INSERT INTO probe_results
SELECT 4, 'V sale_landed=' ||
  EXISTS (SELECT 1 FROM public.sales s
          WHERE s.id LIKE 'PROBE-DEMO-%'
            AND s.customer_id = c.customer_id)::text
  || ' item_landed=' ||
  EXISTS (SELECT 1 FROM public.sale_items i
          WHERE i.id LIKE 'PROBE-DEMO-%'
            AND i.customer_id = c.customer_id)::text
  || ' entry_landed=' ||
  EXISTS (SELECT 1 FROM public.pos_finance_entries f
          WHERE f.id LIKE 'PROBE-DEMO-%'
            AND f.customer_id = c.customer_id)::text
FROM pg_temp.probe_ctx c;

INSERT INTO probe_results
SELECT 5, 'M ' || m.entity_type || ' status=' || m.apply_status
             || ' error=' || COALESCE(m.apply_error, '-')
FROM public.sync_mirror m
JOIN pg_temp.probe_ctx c ON c.customer_id = m.customer_id
WHERE m.entity_id LIKE 'PROBE-DEMO-%'
ORDER BY m.entity_type;

-- The read side, live: the dashboard aggregate must equal a hand-computed sum
-- over the non-demo sales of the same tenant.
INSERT INTO probe_results
SELECT 6, 'R revenue_match='
             || ((x.tot ->> 'revenue')::bigint = r.rev)::text
             || ' rpc=' || (x.tot ->> 'revenue')
             || ' real_sum=' || r.rev::text
             || ' practice_sales=' || p.n::text
FROM pg_temp.probe_ctx c
CROSS JOIN LATERAL (
  SELECT public.pos_sales_totals(c.customer_id, NULL, NULL) AS tot
) x
CROSS JOIN LATERAL (
  SELECT COALESCE(sum(s.total_minor_units), 0) AS rev
  FROM public.sales s
  WHERE s.customer_id = c.customer_id AND s.status = 'COMPLETED'
    AND s.payment_method IN ('CASH', 'BANK')
    AND NOT public.pos_is_demo(c.customer_id, s.cashier_id)
) r
CROSS JOIN LATERAL (
  SELECT count(*) AS n FROM public.sales s
  WHERE s.customer_id = c.customer_id
    AND public.pos_is_demo(c.customer_id, s.cashier_id)
) p;

-- Positive control: the flag says yes for the demo and no for the owner, so a
-- refusal above is discrimination rather than a blanket "reject everything".
INSERT INTO probe_results
SELECT 7, 'Q is_demo(demo)=' || public.pos_is_demo(c.customer_id, c.demo_id)::text
             || ' is_demo(owner)='
             || COALESCE(public.pos_is_demo(c.customer_id, c.owner_id), false)::text
             || ' is_demo(unknown)='
             || public.pos_is_demo(c.customer_id, 'no-such-user')::text
FROM pg_temp.probe_ctx c;

-- The direct door. `pos_create_sale` is how the PWA books a sale — it has no
-- local store, so what it posts IS the cloud's row, and it never passes through
-- the sync gateway. Three practice receipts reached this tenant that way.
-- The owner half is the control: a real cashier must fail on the open shift,
-- not on the training flag, so the guard below is discrimination, not a wall.
DO $$
DECLARE
  c    record;
  msg  text;
BEGIN
  SELECT * INTO c FROM pg_temp.probe_ctx;
  BEGIN
    PERFORM public.pos_create_sale(c.customer_id, c.demo_id, 'isolation-probe',
      'PROBE-SHIFT', 'PROBE-DIRECT-SALE', '[]'::jsonb, 'CASH', 0, 10000);
    INSERT INTO probe_results VALUES (9, 'W demo_sale=ACCEPTED (regression!)');
  EXCEPTION WHEN OTHERS THEN
    msg := SQLERRM;
    INSERT INTO probe_results VALUES (9, 'W demo_sale=' ||
      CASE WHEN msg LIKE '%Training-account data stays%'
           THEN 'refused' ELSE 'WRONG ERROR: ' || msg END);
  END;
  BEGIN
    PERFORM public.pos_create_sale(c.customer_id, c.owner_id, 'isolation-probe',
      'PROBE-SHIFT', 'PROBE-DIRECT-REAL', '[]'::jsonb, 'CASH', 0, 10000);
    INSERT INTO probe_results VALUES (10, 'W owner_sale=ACCEPTED (unexpected)');
  EXCEPTION WHEN OTHERS THEN
    msg := SQLERRM;
    INSERT INTO probe_results VALUES (10, 'W owner_sale=' ||
      CASE WHEN msg LIKE '%Training-account%'
           THEN 'WRONGLY REFUSED: ' || msg
           ELSE 'passed the flag, failed later: ' || left(msg, 34) END);
  END;
END
$$;

-- Leave nothing behind. The ledger deletes run first so a refused-but-landed
-- row (a regression) cannot outlive the probe that created it.
DELETE FROM public.sale_items i
WHERE i.id LIKE 'PROBE-%'
  AND EXISTS (SELECT 1 FROM pg_temp.probe_ctx c WHERE c.customer_id = i.customer_id);
DELETE FROM public.sales s
WHERE s.id LIKE 'PROBE-%'
  AND EXISTS (SELECT 1 FROM pg_temp.probe_ctx c WHERE c.customer_id = s.customer_id);
DELETE FROM public.pos_finance_entries f
WHERE f.id LIKE 'PROBE-%'
  AND EXISTS (SELECT 1 FROM pg_temp.probe_ctx c WHERE c.customer_id = f.customer_id);
DELETE FROM public.shifts h
WHERE h.id LIKE 'PROBE-%'
  AND EXISTS (SELECT 1 FROM pg_temp.probe_ctx c WHERE c.customer_id = h.customer_id);
DELETE FROM public.sync_mirror m
WHERE m.entity_id LIKE 'PROBE-%'
  AND EXISTS (SELECT 1 FROM pg_temp.probe_ctx c WHERE c.customer_id = m.customer_id);

INSERT INTO probe_results
SELECT 8, 'D probes_left=' || count(*)::text
FROM public.sync_mirror m
JOIN pg_temp.probe_ctx c ON c.customer_id = m.customer_id
WHERE m.entity_id LIKE 'PROBE-DEMO-%';

SELECT line FROM probe_results ORDER BY ord, line;

DROP TABLE IF EXISTS pg_temp.probe_results;
DROP TABLE IF EXISTS pg_temp.probe_ctx;
