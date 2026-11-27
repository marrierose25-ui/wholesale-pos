-- Defensive guards for pos_create_sale (Finding #8).
-- ---------------------------------------------------------------------------
-- p_items arrived from the network and was fed straight into
-- jsonb_array_elements. A payload that was not an array (null, an object, a
-- string) crashed inside Postgres with an internal error the gateway reported
-- as a 500, and an empty array fell through to the `n = 0` check only after a
-- pointless share-lock round trip. A line without an id inserted a NULL
-- primary key into sale_items.
--
-- The body below is docs/supabase_pos_integrity.sql's pos_create_sale verbatim
-- (pos_create_sale was never part of the void owner-check change), plus three
-- guards. Nothing else is altered.
--
-- The DROP FUNCTION ... overload statements from that file are intentionally
-- omitted: production has exactly one signature,
--   pos_create_sale(uuid,text,text,text,text,jsonb,text,bigint,bigint,text,text)
-- so CREATE OR REPLACE lands in place and the untyped REVOKE below resolves.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pos_create_sale(
  p_customer    uuid,
  p_cashier     text,
  p_device      text,
  p_shift_id    text,
  p_receipt     text,
  p_items       jsonb,
  p_payment     text,
  p_discount    bigint,
  p_amount_paid bigint,
  p_customer_name text DEFAULT NULL,
  p_sale_id     text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  item       jsonb;
  computed   bigint;
  line_disc  bigint;
  bq         bigint;
  price      bigint;
  subtotal   bigint := 0;
  total_val  bigint;
  chg        bigint;
  sale_id    text;
  n          int := 0;
  res        jsonb;
BEGIN
  -- Defensive: p_items must be a JSON array of at least one object. A
  -- malformed payload previously crashed jsonb_array_elements with a
  -- Postgres internal error instead of a clean 4xx.
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'Sale items must be a JSON array.';
  END IF;
  IF jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Sale must have at least one line item.';
  END IF;

  -- LOAN is money owed, not money collected: it settles in full with nothing
  -- tendered at the till, and the revenue aggregates filter it out. The PWA
  -- offers all three methods, so the server accepts all three.
  IF p_payment NOT IN ('CASH', 'BANK', 'LOAN') THEN
    RAISE EXCEPTION 'Invalid payment method: %', p_payment;
  END IF;
  IF p_discount IS NULL OR p_discount < 0 THEN
    RAISE EXCEPTION 'Discount must be a non-negative integer.';
  END IF;
  IF p_device IS NULL OR p_device = '' THEN
    RAISE EXCEPTION 'Sale requires a device id.';
  END IF;
  IF p_receipt IS NULL OR p_receipt = '' THEN
    RAISE EXCEPTION 'Sale requires a receipt number.';
  END IF;

  -- The browser has no local store, so a sale posted here IS the cloud's sale.
  -- The native `SyncOutbox` and `pos_sync_apply` both refuse the training
  -- account; this is the third door, and it has to be shut or a demo login in a
  -- browser keeps writing practice takings straight into the shop's books.
  IF public.pos_is_demo(p_customer, p_cashier) THEN
    RAISE EXCEPTION 'Training-account data stays on the till that made it.';
  END IF;

  -- Idempotency: a retried sale returns the row that already exists, so a
  -- client timeout followed by a retry can never book the sale twice.
  IF p_sale_id IS NOT NULL AND btrim(p_sale_id) <> '' THEN
    SELECT jsonb_build_object('id', s.id, 'receipt_number', s.receipt_number,
        'subtotal_minor_units', s.subtotal_minor_units,
        'total_minor_units', s.total_minor_units,
        'amount_paid_minor_units', s.amount_paid_minor_units,
        'change_minor_units', s.change_minor_units, 'duplicate', true)
      INTO res
      FROM public.sales s
      WHERE s.customer_id = p_customer AND s.id = p_sale_id;
    IF res IS NOT NULL THEN
      RETURN res;
    END IF;
  END IF;

  -- Share-lock the session row: concurrent sales proceed, a close cannot slip
  -- between this check and the insert.
  PERFORM 1 FROM public.shifts
    WHERE customer_id = p_customer AND id = p_shift_id AND status = 'OPEN'
    FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Sale requires an open shift.';
  END IF;

  sale_id := COALESCE(NULLIF(btrim(p_sale_id), ''), gen_random_uuid()::text);

  -- Recompute subtotal from authoritative line math and verify each derived
  -- line total matches what the client sent (catches tampering).
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    n := n + 1;
    IF (item->>'id') IS NULL OR (item->>'id') = '' THEN
      RAISE EXCEPTION 'Line %: missing item id.', n;
    END IF;
    price := COALESCE((item->>'unit_price_snapshot_minor_units')::bigint, 0);

    IF item ? 'billing_quantity_milliunits'
       AND jsonb_typeof(item->'billing_quantity_milliunits') = 'number' THEN
      bq := (item->>'billing_quantity_milliunits')::bigint;
      IF price < 0 OR bq < 0 THEN
        RAISE EXCEPTION 'Line %: negative price or quantity.', n;
      END IF;
      IF price > 0 AND bq > 9223372036854775807 / price THEN
        RAISE EXCEPTION 'Line %: numeric overflow.', n;
      END IF;
      computed := (price * bq + 500) / 1000;  -- round half up, integer
      -- A line discount is subtracted BEFORE the comparison, exactly as the
      -- native repository does: line_total = base - discount. Storing a
      -- discount while comparing against the undiscounted base let the cloud
      -- persist a discount that was never applied to the total (audit 2 #9).
      line_disc := COALESCE((item->>'line_discount_minor_units')::bigint, 0);
      IF line_disc < 0 OR line_disc > computed THEN
        RAISE EXCEPTION 'Line %: discount must be between 0 and the line total.', n;
      END IF;
      computed := computed - line_disc;
      IF COALESCE((item->>'line_total_minor_units')::bigint, -1) <> computed THEN
        RAISE EXCEPTION 'Line %: total mismatch (server %, client %).',
          n, computed, COALESCE((item->>'line_total_minor_units')::bigint, -1);
      END IF;
    ELSE
      -- Manual line entry: no numeric quantity, so the entered amount stands.
      computed := COALESCE((item->>'line_total_minor_units')::bigint, -1);
      IF computed < 0 THEN
        RAISE EXCEPTION 'Line %: negative manual total.', n;
      END IF;
    END IF;

    subtotal := subtotal + computed;
    IF subtotal > 9007199254740991 THEN
      RAISE EXCEPTION 'Sale subtotal exceeds safe integer range.';
    END IF;
  END LOOP;

  IF n = 0 THEN
    RAISE EXCEPTION 'Sale must have at least one line item.';
  END IF;
  IF p_discount > subtotal THEN
    RAISE EXCEPTION 'Discount exceeds subtotal.';
  END IF;

  total_val := subtotal - p_discount;

  IF p_payment = 'CASH' THEN
    IF p_amount_paid IS NULL OR p_amount_paid < total_val THEN
      RAISE EXCEPTION 'Insufficient amount paid for cash sale.';
    END IF;
    chg := p_amount_paid - total_val;
  ELSE
    p_amount_paid := total_val;
    chg := 0;
  END IF;

  BEGIN
    INSERT INTO public.sales (id, customer_id, receipt_number, cashier_id, device_id,
      shift_id, customer_name, payment_method, subtotal_minor_units,
      discount_minor_units, total_minor_units, amount_paid_minor_units,
      change_minor_units, status, created_at)
    VALUES (sale_id, p_customer, p_receipt, p_cashier, p_device,
      p_shift_id, p_customer_name, p_payment, subtotal,
      p_discount, total_val, p_amount_paid, chg, 'COMPLETED', now());
  EXCEPTION WHEN unique_violation THEN
    -- ONLY the same sale id may be answered as an idempotent replay. A receipt
    -- number that already belongs to a DIFFERENT sale is a real conflict: the
    -- old handler returned that other sale with duplicate:true, so a cashier
    -- was told a sale was saved while its own row and lines were never
    -- inserted (audit 2 #7).
    SELECT jsonb_build_object('id', s.id, 'receipt_number', s.receipt_number,
        'subtotal_minor_units', s.subtotal_minor_units,
        'total_minor_units', s.total_minor_units,
        'amount_paid_minor_units', s.amount_paid_minor_units,
        'change_minor_units', s.change_minor_units, 'duplicate', true)
      INTO res
      FROM public.sales s
      WHERE s.customer_id = p_customer AND s.id = sale_id;
    IF res IS NOT NULL THEN
      RETURN res;
    END IF;
    RAISE EXCEPTION 'Receipt % is already used by another sale.', p_receipt
      USING ERRCODE = 'unique_violation';
  END;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    INSERT INTO public.sale_items (id, customer_id, sale_id, product_id,
      product_name_snapshot, unit_price_snapshot_minor_units, quantity_text,
      billing_quantity_milliunits, line_discount_minor_units,
      line_total_minor_units, notes)
    VALUES (
      (item->>'id'),
      p_customer,
      sale_id,
      (item->>'product_id'),
      (item->>'product_name_snapshot'),
      COALESCE((item->>'unit_price_snapshot_minor_units')::bigint, 0),
      (item->>'quantity_text'),
      CASE WHEN jsonb_typeof(item->'billing_quantity_milliunits') = 'number'
           THEN (item->>'billing_quantity_milliunits')::bigint ELSE NULL END,
      COALESCE((item->>'line_discount_minor_units')::bigint, 0),
      (item->>'line_total_minor_units')::bigint,
      (item->>'notes')
    );
  END LOOP;

  INSERT INTO public.pos_audit_logs (id, customer_id, user_id, action, details, created_at)
  VALUES (gen_random_uuid(), p_customer, p_cashier, 'SALE_COMPLETED',
    'Total: ' || total_val || ' minor units, Lines: ' || n, now());

  RETURN jsonb_build_object('id', sale_id, 'receipt_number', p_receipt,
    'subtotal_minor_units', subtotal, 'total_minor_units', total_val,
    'amount_paid_minor_units', p_amount_paid, 'change_minor_units', chg);
END;
$$;
REVOKE ALL ON FUNCTION pos_create_sale FROM public;
GRANT EXECUTE ON FUNCTION pos_create_sale TO service_role;
