-- Wholesale POS — Commercial Stability Fixes v1
-- Apply AFTER supabase_pos_integrity.sql. Idempotent. Safe to re-run.
--
-- Fixes C1-C9 from the integrity review. See comments inline.
BEGIN;

-- C1: pos_users_one_owner must ignore soft-deleted owners
DROP INDEX IF EXISTS public.pos_users_one_owner_v2;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.pos_users
    WHERE role = 'OWNER' AND deleted_at IS NULL
    GROUP BY customer_id HAVING count(*) > 1
  ) THEN
    CREATE UNIQUE INDEX pos_users_one_owner_v2
      ON public.pos_users (customer_id)
      WHERE role = 'OWNER' AND deleted_at IS NULL;
    DROP INDEX IF EXISTS public.pos_users_one_owner;
    ALTER INDEX public.pos_users_one_owner_v2 RENAME TO pos_users_one_owner;
    RAISE NOTICE 'C1: pos_users_one_owner updated to ignore deleted owners.';
  ELSE
    RAISE NOTICE 'C1 SKIPPED: active duplicate owners exist. Reconcile then re-run.';
  END IF;
END $$;

-- C2: make the cashier permissions backfill idempotent
CREATE TABLE IF NOT EXISTS public.migration_markers (
  key text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.migration_markers
                 WHERE key = 'cashier_permissions_backfill_v1') THEN
    UPDATE public.pos_users
      SET permissions = '["pos","register","history"]'::jsonb
      WHERE role = 'CASHIER' AND permissions = '[]'::jsonb;
    INSERT INTO public.migration_markers (key)
      VALUES ('cashier_permissions_backfill_v1');
    RAISE NOTICE 'C2: permissions backfill applied (first run).';
  ELSE
    RAISE NOTICE 'C2: permissions backfill already applied, skipping.';
  END IF;
END $$;

-- C3: pos_create_sale — shape validation, item id uniqueness, overflow, cap
CREATE OR REPLACE FUNCTION pos_create_sale(
  p_customer uuid, p_cashier text, p_device text, p_shift_id text,
  p_receipt text, p_items jsonb, p_payment text, p_discount bigint,
  p_amount_paid bigint, p_customer_name text DEFAULT NULL,
  p_sale_id text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  item jsonb; computed bigint; line_disc bigint; bq bigint; price bigint;
  subtotal bigint := 0; total_val bigint; chg bigint; sale_id text;
  n int := 0; seen_ids text[] := ARRAY[]::text[]; item_id text; res jsonb;
BEGIN
  IF p_payment NOT IN ('CASH','BANK','LOAN') THEN
    RAISE EXCEPTION 'Invalid payment method: %', p_payment; END IF;
  IF p_discount IS NULL OR p_discount < 0 THEN
    RAISE EXCEPTION 'Discount must be a non-negative integer.'; END IF;
  IF p_device IS NULL OR p_device = '' THEN
    RAISE EXCEPTION 'Sale requires a device id.'; END IF;
  IF p_receipt IS NULL OR p_receipt = '' THEN
    RAISE EXCEPTION 'Sale requires a receipt number.'; END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'Items must be a JSON array.'; END IF;
  IF jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Sale must have at least one line item.'; END IF;
  IF jsonb_array_length(p_items) > 500 THEN
    RAISE EXCEPTION 'Sale has too many line items (max 500).'; END IF;

  IF p_sale_id IS NOT NULL AND btrim(p_sale_id) <> '' THEN
    SELECT jsonb_build_object('id', s.id, 'receipt_number', s.receipt_number,
        'subtotal_minor_units', s.subtotal_minor_units,
        'total_minor_units', s.total_minor_units,
        'amount_paid_minor_units', s.amount_paid_minor_units,
        'change_minor_units', s.change_minor_units, 'duplicate', true)
      INTO res FROM public.sales s
      WHERE s.customer_id = p_customer AND s.id = p_sale_id;
    IF res IS NOT NULL THEN RETURN res; END IF;
  END IF;

  PERFORM 1 FROM public.shifts
    WHERE customer_id = p_customer AND id = p_shift_id AND status = 'OPEN'
    FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sale requires an open shift.'; END IF;

  sale_id := COALESCE(NULLIF(btrim(p_sale_id), ''), gen_random_uuid()::text);

  FOR item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    n := n + 1;
    item_id := item->>'id';
    IF item_id IS NULL OR btrim(item_id) = '' THEN
      RAISE EXCEPTION 'Line %: missing id.', n; END IF;
    IF item_id = ANY(seen_ids) THEN
      RAISE EXCEPTION 'Line %: duplicate item id %.', n, item_id; END IF;
    seen_ids := array_append(seen_ids, item_id);
    IF item->>'product_id' IS NULL OR btrim(item->>'product_id') = '' THEN
      RAISE EXCEPTION 'Line %: missing product_id.', n; END IF;
    IF item->>'product_name_snapshot' IS NULL
       OR btrim(item->>'product_name_snapshot') = '' THEN
      RAISE EXCEPTION 'Line %: missing product name.', n; END IF;

    price := COALESCE((item->>'unit_price_snapshot_minor_units')::bigint, 0);
    IF item ? 'billing_quantity_milliunits'
       AND jsonb_typeof(item->'billing_quantity_milliunits') = 'number' THEN
      bq := (item->>'billing_quantity_milliunits')::bigint;
      IF price < 0 OR bq < 0 THEN
        RAISE EXCEPTION 'Line %: negative price or quantity.', n; END IF;
      IF price > 0 AND bq > (9223372036854775807 - 500) / price THEN
        RAISE EXCEPTION 'Line %: numeric overflow.', n; END IF;
      computed := (price * bq + 500) / 1000;
      line_disc := COALESCE((item->>'line_discount_minor_units')::bigint, 0);
      IF line_disc < 0 OR line_disc > computed THEN
        RAISE EXCEPTION 'Line %: discount out of range.', n; END IF;
      computed := computed - line_disc;
      IF COALESCE((item->>'line_total_minor_units')::bigint, -1) <> computed THEN
        RAISE EXCEPTION 'Line %: total mismatch (server %, client %).',
          n, computed, COALESCE((item->>'line_total_minor_units')::bigint, -1);
      END IF;
    ELSE
      computed := COALESCE((item->>'line_total_minor_units')::bigint, -1);
      IF computed < 0 THEN
        RAISE EXCEPTION 'Line %: negative manual total.', n; END IF;
    END IF;
    subtotal := subtotal + computed;
    IF subtotal > 9007199254740991 THEN
      RAISE EXCEPTION 'Sale subtotal exceeds safe integer range.'; END IF;
  END LOOP;

  IF p_discount > subtotal THEN
    RAISE EXCEPTION 'Discount exceeds subtotal.'; END IF;
  total_val := subtotal - p_discount;

  IF p_payment = 'CASH' THEN
    IF p_amount_paid IS NULL OR p_amount_paid < total_val THEN
      RAISE EXCEPTION 'Insufficient amount paid for cash sale.'; END IF;
    chg := p_amount_paid - total_val;
  ELSE
    p_amount_paid := total_val; chg := 0;
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
    SELECT jsonb_build_object('id', s.id, 'receipt_number', s.receipt_number,
        'subtotal_minor_units', s.subtotal_minor_units,
        'total_minor_units', s.total_minor_units,
        'amount_paid_minor_units', s.amount_paid_minor_units,
        'change_minor_units', s.change_minor_units, 'duplicate', true)
      INTO res FROM public.sales s
      WHERE s.customer_id = p_customer AND s.id = sale_id;
    IF res IS NOT NULL THEN RETURN res; END IF;
    RAISE EXCEPTION 'Receipt % is already used by another sale.', p_receipt
      USING ERRCODE = 'unique_violation';
  END;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO public.sale_items (id, customer_id, sale_id, product_id,
      product_name_snapshot, unit_price_snapshot_minor_units, quantity_text,
      billing_quantity_milliunits, line_discount_minor_units,
      line_total_minor_units, notes)
    VALUES ((item->>'id'), p_customer, sale_id,
      (item->>'product_id'), (item->>'product_name_snapshot'),
      COALESCE((item->>'unit_price_snapshot_minor_units')::bigint, 0),
      (item->>'quantity_text'),
      CASE WHEN jsonb_typeof(item->'billing_quantity_milliunits') = 'number'
           THEN (item->>'billing_quantity_milliunits')::bigint ELSE NULL END,
      COALESCE((item->>'line_discount_minor_units')::bigint, 0),
      (item->>'line_total_minor_units')::bigint, (item->>'notes'));
  END LOOP;

  INSERT INTO public.pos_audit_logs (id, customer_id, user_id, action, details, created_at)
  VALUES (gen_random_uuid(), p_customer, p_cashier, 'SALE_COMPLETED',
    'Total: ' || total_val || ' minor units, Lines: ' || n, now());

  RETURN jsonb_build_object('id', sale_id, 'receipt_number', p_receipt,
    'subtotal_minor_units', subtotal, 'total_minor_units', total_val,
    'amount_paid_minor_units', p_amount_paid, 'change_minor_units', chg);
END; $$;
REVOKE ALL ON FUNCTION pos_create_sale FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION pos_create_sale TO service_role;

-- C4: pos_approve_void — FOR UPDATE (double-void guard)
CREATE OR REPLACE FUNCTION pos_approve_void(
  p_customer uuid, p_user text, p_request_id text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE vr record; active_shift text; sale_updated int; decided int;
BEGIN
  SELECT * INTO vr FROM public.void_requests
  WHERE customer_id = p_customer AND id = p_request_id AND status = 'PENDING'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Void request not found or already decided.'; END IF;

  UPDATE public.void_requests
  SET status = 'APPROVED', decided_by = p_user, decided_at = now()
  WHERE customer_id = p_customer AND id = p_request_id AND status = 'PENDING';
  GET DIAGNOSTICS decided = ROW_COUNT;
  IF decided <> 1 THEN
    RAISE EXCEPTION 'Void request was decided by someone else.'; END IF;

  SELECT id INTO active_shift FROM public.shifts
  WHERE customer_id = p_customer AND status = 'OPEN' LIMIT 1 FOR SHARE;

  UPDATE public.sales
  SET status = 'VOIDED', void_reason = vr.reason, voided_at = now(),
      voided_by = p_user, voided_shift_id = active_shift
  WHERE customer_id = p_customer AND id = vr.sale_id AND status = 'COMPLETED';
  GET DIAGNOSTICS sale_updated = ROW_COUNT;
  IF sale_updated = 0 THEN
    RAISE EXCEPTION 'Sale is no longer voidable (not COMPLETED).'; END IF;

  INSERT INTO public.pos_audit_logs (id, customer_id, user_id, action, details, created_at)
  VALUES (gen_random_uuid(), p_customer, p_user, 'VOID_APPROVED',
    'Request ' || p_request_id || ' approved.', now());
END; $$;
REVOKE ALL ON FUNCTION pos_approve_void FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION pos_approve_void TO service_role;

-- C5: pos_ensure_shift — NULL guard after unique_violation
CREATE OR REPLACE FUNCTION pos_ensure_shift(
  p_customer uuid, p_user text, p_device text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE shift_found text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext(p_customer::text));
  SELECT id INTO shift_found FROM public.shifts
  WHERE customer_id = p_customer AND status = 'OPEN' LIMIT 1;
  IF shift_found IS NOT NULL THEN RETURN shift_found; END IF;
  shift_found := gen_random_uuid()::text;
  INSERT INTO public.shifts (id, customer_id, cashier_id, opening_cash_minor_units,
    status, opened_at, device_id)
  VALUES (shift_found, p_customer, p_user, 0, 'OPEN', now(), p_device);
  RETURN shift_found;
EXCEPTION WHEN unique_violation THEN
  SELECT id INTO shift_found FROM public.shifts
  WHERE customer_id = p_customer AND status = 'OPEN' LIMIT 1;
  IF shift_found IS NULL THEN
    RAISE EXCEPTION 'Failed to ensure shift after unique violation.'; END IF;
  RETURN shift_found;
END; $$;
REVOKE ALL ON FUNCTION pos_ensure_shift FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION pos_ensure_shift TO service_role;

-- C6: pos_void_sale — validate reason
CREATE OR REPLACE FUNCTION pos_void_sale(
  p_customer uuid, p_user text, p_sale_id text, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE active_shift text; updated int;
BEGIN
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'Void requires a reason.'; END IF;

  SELECT id INTO active_shift FROM public.shifts
  WHERE customer_id = p_customer AND status = 'OPEN' LIMIT 1 FOR SHARE;

  UPDATE public.sales
  SET status = 'VOIDED', void_reason = btrim(p_reason), voided_at = now(),
      voided_by = p_user, voided_shift_id = active_shift
  WHERE customer_id = p_customer AND id = p_sale_id AND status <> 'VOIDED';
  GET DIAGNOSTICS updated = ROW_COUNT;
  IF updated = 0 THEN
    RAISE EXCEPTION 'Sale not found or already voided.'; END IF;

  INSERT INTO public.pos_audit_logs (id, customer_id, user_id, action, details, created_at)
  VALUES (gen_random_uuid(), p_customer, p_user, 'SALE_VOIDED',
    'Sale ' || p_sale_id || ' — ' || btrim(p_reason), now());
END; $$;
REVOKE ALL ON FUNCTION pos_void_sale FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION pos_void_sale TO service_role;

-- C7: pos_add_cash_movement — 5MB photo cap
CREATE OR REPLACE FUNCTION pos_add_cash_movement(
  p_customer uuid, p_user text, p_shift_id text, p_type text,
  p_amount bigint, p_reason text, p_photo text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE mv_id text;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be positive.'; END IF;
  IF p_type NOT IN ('WITHDRAWAL','DEPOSIT','EXPENSE') THEN
    RAISE EXCEPTION 'Invalid movement type.'; END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'A reason is required.'; END IF;
  IF p_photo IS NOT NULL AND length(p_photo) > 5000000 THEN
    RAISE EXCEPTION 'Photo too large (max 5MB).'; END IF;

  PERFORM 1 FROM public.shifts
    WHERE customer_id = p_customer AND id = p_shift_id AND status = 'OPEN'
    FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Movement requires an open shift.'; END IF;

  mv_id := gen_random_uuid()::text;
  INSERT INTO public.cash_movements (id, customer_id, shift_id, user_id, type,
    amount_minor_units, reason, photo, created_at)
  VALUES (mv_id, p_customer, p_shift_id, p_user, p_type, p_amount,
    btrim(p_reason), NULLIF(p_photo, ''), now());

  INSERT INTO public.pos_audit_logs (id, customer_id, user_id, action, details, created_at)
  VALUES (gen_random_uuid(), p_customer, p_user, 'CASH_MOVEMENT_ADDED',
    p_type || ' ' || p_amount, now());
  RETURN jsonb_build_object('id', mv_id);
END; $$;
REVOKE ALL ON FUNCTION pos_add_cash_movement FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION pos_add_cash_movement TO service_role;

-- C8: pos_setup_owner — friendly race error
CREATE OR REPLACE FUNCTION pos_setup_owner(
  p_customer uuid, p_id text, p_username text, p_pw_salt text, p_pw_hash text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE existing_count int;
BEGIN
  SELECT count(*) INTO existing_count FROM public.pos_users
   WHERE customer_id = p_customer AND deleted_at IS NULL;
  IF existing_count > 0 THEN RAISE EXCEPTION 'Owner already exists.'; END IF;
  INSERT INTO public.pos_users (id, customer_id, username, role,
    pw_salt, pw_hash, active, token_version)
  VALUES (p_id, p_customer, p_username, 'OWNER', p_pw_salt, p_pw_hash, true, 0);
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'Owner already exists.';
END; $$;
REVOKE ALL ON FUNCTION pos_setup_owner FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION pos_setup_owner TO service_role;

-- C9: pos_delete_finance_category — refuse if completed entries exist
CREATE OR REPLACE FUNCTION pos_delete_finance_category(
  p_customer uuid, p_id text, p_user text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE cat record;
BEGIN
  SELECT id, name, deleted_at INTO cat FROM public.pos_finance_categories
  WHERE customer_id = p_customer AND id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Person not found.'; END IF;
  IF cat.deleted_at IS NULL THEN
    RAISE EXCEPTION 'Move the person to the recycle bin first.'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.pos_finance_entries
    WHERE customer_id = p_customer AND category_id = p_id AND status = 'COMPLETED'
  ) THEN
    RAISE EXCEPTION 'Cannot delete: person has completed financial entries. Reconcile or archive them first.';
  END IF;

  DELETE FROM public.pos_finance_entries
  WHERE customer_id = p_customer AND category_id = p_id;
  DELETE FROM public.pos_finance_categories
  WHERE customer_id = p_customer AND id = p_id;

  INSERT INTO public.pos_audit_logs (id, customer_id, user_id, action, details, created_at)
  VALUES (gen_random_uuid(), p_customer, p_user, 'FINANCE_CATEGORY_PERMANENTLY_DELETED',
    'Person "' || cat.name || '" and their entries permanently deleted.', now());
END; $$;
REVOKE ALL ON FUNCTION pos_delete_finance_category FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION pos_delete_finance_category TO service_role;

-- Re-apply privilege hardening to ALL pos_* functions (safety net for future)
DO $$
DECLARE fn record;
BEGIN
  FOR fn IN
    SELECT p.oid::regprocedure AS sig FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname LIKE 'pos\_%'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', fn.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', fn.sig);
  END LOOP;
END $$;

COMMIT;
