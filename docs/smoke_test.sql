-- Smoke test for fixes_v1.sql — runs in a rolled-back transaction, zero side effects.
BEGIN;

DO $$
DECLARE
  tc uuid := gen_random_uuid();
  t_shift text;
  t_sale text;
  t_item text;
  t_result jsonb;
  t_cat text;
  t_entry text;
  passed int := 0;
  failed int := 0;
  err text;
BEGIN
  -- A throwaway tenant: every mirror table carries customer_id REFERENCES
  -- customers(id), so the fixture rows below need a real customer row too.
  INSERT INTO public.customers (id, name) VALUES (tc, 'Smoke Test Tenant');

  -- Setup: create a test shift (will be rolled back at end)
  INSERT INTO shifts (id, customer_id, cashier_id, opening_cash_minor_units,
    status, opened_at, device_id)
  VALUES (gen_random_uuid()::text, tc, 'test-cashier', 0, 'OPEN', now(), 'test-device')
  RETURNING id INTO t_shift;

  -- T1: normal sale succeeds
  BEGIN
    t_sale := gen_random_uuid()::text;
    t_item := gen_random_uuid()::text;
    t_result := pos_create_sale(tc, 'test-cashier', 'test-device', t_shift,
      'REC-TEST-' || substr(t_sale,1,8),
      jsonb_build_array(jsonb_build_object(
        'id', t_item, 'product_id', 'p1', 'product_name_snapshot', 'Widget',
        'unit_price_snapshot_minor_units', 1000, 'billing_quantity_milliunits', 1000,
        'line_discount_minor_units', 0, 'line_total_minor_units', 1000,
        'quantity_text', '1', 'notes', null)),
      'CASH', 0, 1000, NULL, t_sale);
    IF t_result->>'id' = t_sale THEN
      RAISE NOTICE 'PASS T1 normal sale'; passed := passed + 1;
    ELSE
      RAISE NOTICE 'FAIL T1 unexpected result %', t_result; failed := failed + 1;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'FAIL T1 %', SQLERRM; failed := failed + 1;
  END;

  -- T2: idempotency — same sale_id returns duplicate:true
  BEGIN
    t_result := pos_create_sale(tc, 'test-cashier', 'test-device', t_shift,
      'REC-TEST-' || substr(t_sale,1,8),
      jsonb_build_array(jsonb_build_object(
        'id', gen_random_uuid()::text, 'product_id', 'p1', 'product_name_snapshot', 'Widget',
        'unit_price_snapshot_minor_units', 1000, 'billing_quantity_milliunits', 1000,
        'line_discount_minor_units', 0, 'line_total_minor_units', 1000,
        'quantity_text', '1', 'notes', null)),
      'CASH', 0, 1000, NULL, t_sale);
    IF (t_result->>'duplicate')::boolean = true THEN
      RAISE NOTICE 'PASS T2 idempotency'; passed := passed + 1;
    ELSE
      RAISE NOTICE 'FAIL T2 duplicate flag missing'; failed := failed + 1;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'FAIL T2 %', SQLERRM; failed := failed + 1;
  END;

  -- T3: bad items shape rejected with clear message
  BEGIN
    PERFORM pos_create_sale(tc, 'test-cashier', 'test-device', t_shift,
      'REC-BAD-' || substr(gen_random_uuid()::text,1,8),
      '{"x":1}'::jsonb, 'CASH', 0, 1000, NULL, gen_random_uuid()::text);
    RAISE NOTICE 'FAIL T3 no exception'; failed := failed + 1;
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err LIKE '%Items must be a JSON array%' THEN
      RAISE NOTICE 'PASS T3 bad items'; passed := passed + 1;
    ELSE
      RAISE NOTICE 'FAIL T3 wrong error: %', err; failed := failed + 1;
    END IF;
  END;

  -- T4: duplicate item ids rejected
  BEGIN
    t_item := gen_random_uuid()::text;
    PERFORM pos_create_sale(tc, 'test-cashier', 'test-device', t_shift,
      'REC-DUP-' || substr(gen_random_uuid()::text,1,8),
      jsonb_build_array(
        jsonb_build_object('id', t_item, 'product_id', 'p1', 'product_name_snapshot', 'W',
          'unit_price_snapshot_minor_units', 100, 'billing_quantity_milliunits', 1000,
          'line_discount_minor_units', 0, 'line_total_minor_units', 100,
          'quantity_text', '1', 'notes', null),
        jsonb_build_object('id', t_item, 'product_id', 'p2', 'product_name_snapshot', 'X',
          'unit_price_snapshot_minor_units', 100, 'billing_quantity_milliunits', 1000,
          'line_discount_minor_units', 0, 'line_total_minor_units', 100,
          'quantity_text', '1', 'notes', null)),
      'CASH', 0, 200, NULL, gen_random_uuid()::text);
    RAISE NOTICE 'FAIL T4 no exception'; failed := failed + 1;
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err LIKE '%duplicate item id%' THEN
      RAISE NOTICE 'PASS T4 duplicate item id'; passed := passed + 1;
    ELSE
      RAISE NOTICE 'FAIL T4 wrong error: %', err; failed := failed + 1;
    END IF;
  END;

  -- T5: void requires reason
  BEGIN
    PERFORM pos_void_sale(tc, 'test-cashier', t_sale, '');
    RAISE NOTICE 'FAIL T5 no exception'; failed := failed + 1;
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err LIKE '%Void requires a reason%' THEN
      RAISE NOTICE 'PASS T5 void reason required'; passed := passed + 1;
    ELSE
      RAISE NOTICE 'FAIL T5 wrong error: %', err; failed := failed + 1;
    END IF;
  END;

  -- T6: valid void succeeds, then double-void refused
  BEGIN
    PERFORM pos_void_sale(tc, 'test-cashier', t_sale, 'test reason');
    BEGIN
      PERFORM pos_void_sale(tc, 'test-cashier', t_sale, 'again');
      RAISE NOTICE 'FAIL T6 double void allowed'; failed := failed + 1;
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE '%already voided%' THEN
        RAISE NOTICE 'PASS T6 void then double-void refused'; passed := passed + 1;
      ELSE
        RAISE NOTICE 'FAIL T6 wrong error: %', SQLERRM; failed := failed + 1;
      END IF;
    END;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'FAIL T6 initial void failed: %', SQLERRM; failed := failed + 1;
  END;

  -- T7: photo too large rejected
  BEGIN
    PERFORM pos_add_cash_movement(tc, 'test-cashier', t_shift, 'DEPOSIT',
      1000, 'test', repeat('x', 6000000));
    RAISE NOTICE 'FAIL T7 no exception'; failed := failed + 1;
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err LIKE '%Photo too large%' THEN
      RAISE NOTICE 'PASS T7 photo size cap'; passed := passed + 1;
    ELSE
      RAISE NOTICE 'FAIL T7 wrong error: %', err; failed := failed + 1;
    END IF;
  END;

  -- T8: delete finance person with completed entries refused
  BEGIN
    t_cat := gen_random_uuid()::text;
    INSERT INTO pos_finance_categories (id, customer_id, name, deleted_at, created_at)
    VALUES (t_cat, tc, 'Test Person', now(), now());
    t_entry := gen_random_uuid()::text;
    INSERT INTO pos_finance_entries (id, customer_id, category_id, source,
      amount_minor_units, payment_method, status, entry_date, created_at)
    VALUES (t_entry, tc, t_cat, 'Smoke test',
      5000, 'CASH', 'COMPLETED', now()::date, now());
    BEGIN
      PERFORM pos_delete_finance_category(tc, t_cat, 'test-cashier');
      RAISE NOTICE 'FAIL T8 deletion allowed'; failed := failed + 1;
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE '%completed financial entries%' THEN
        RAISE NOTICE 'PASS T8 finance delete guard'; passed := passed + 1;
      ELSE
        RAISE NOTICE 'FAIL T8 wrong error: %', SQLERRM; failed := failed + 1;
      END IF;
    END;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'FAIL T8 setup error: %', SQLERRM; failed := failed + 1;
  END;

  -- The results are raised as an exception on purpose: the SQL endpoint only
  -- returns errors, not NOTICEs, and an exception still rolls the whole
  -- transaction back — so this is the one shape that is both visible and free
  -- of side effects.
  RAISE EXCEPTION 'SMOKE RESULT: % passed, % failed', passed, failed;
END $$;

ROLLBACK;
