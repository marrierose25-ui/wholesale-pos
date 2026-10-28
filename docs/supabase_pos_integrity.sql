-- Wholesale POS — Cloud Integrity Migration (audit remediation)
-- ---------------------------------------------------------------------------
-- Brings the shared Postgres tables (used by pos-api AND native tills) toward
-- the same safety bar the native SQLite path enforces. NON-DESTRUCTIVE: every
-- ALTER / CREATE INDEX / CREATE FUNCTION uses IF NOT EXISTS or OR REPLACE, and
-- the guarded indexes only build when no pre-existing duplicates violate them.
-- Safe to re-run.
--
-- DO NOT confuse this with the destructive schema-reset scripts
-- (docs/supabase_schema.sql / docs/supabase_sync_multi_tenant.sql) that DROP
-- and recreate tables. Those must NEVER be executed against a live tenant.
--
-- Apply via:
--   supabase db query --linked --project-ref <ref> --file docs/supabase_pos_integrity.sql
--
-- DELIBATELY DEFERRED (see plan notes; need native-client changes first):
--   * Unique (customer_id, receipt_number): would hard-fail native sync whose
--     tills allocate receipts from their OWN local counter and can overlap the
--     cloud counter. Needs a single cloud receipt authority across tills.
--   * sync revision conflict guard: needs every till to stamp a monotonic
--     per-row revision, which the outbox does not carry yet.
-- ---------------------------------------------------------------------------

BEGIN;

-- ===========================================================================
-- 1. ADDITIVE COLUMNS
-- ===========================================================================

-- D1: per-device shift scoping. Existing OPEN shifts keep NULL device_id;
-- NULLs are distinct in the partial unique index below, so historical rows are
-- unaffected. New pos-api shifts stamp the device_id.
ALTER TABLE shifts ADD COLUMN IF NOT EXISTS device_id text;

-- D: session revocation via token_version. Tokens signed before this migration
-- carry no tv claim; pos-api treats a missing tv as 0, matching this default,
-- so existing persistent sessions survive. Any password change bumps the row's
-- token_version and invalidates every previously issued token for that account.
ALTER TABLE pos_users ADD COLUMN IF NOT EXISTS token_version int NOT NULL DEFAULT 0;

-- Feature permissions: replace the fixed Owner/Cashier nav split with a
-- per-account tick list. jsonb array of feature keys (dashboard/pos/register/
-- finance/history/reports/users/audit/register_history). OWNER rows stay '[]'
-- and bypass the list server-side; existing CASHIER rows are backfilled with
-- the tabs they already saw so an upgrade never strips a cashier's access.
ALTER TABLE pos_users ADD COLUMN IF NOT EXISTS permissions jsonb NOT NULL DEFAULT '[]';
UPDATE pos_users SET permissions = '["pos", "register", "history"]'::jsonb
  WHERE role = 'CASHIER' AND permissions = '[]'::jsonb;

-- Demo/training account: exactly one perpetually-active CASHIER per tenant that
-- cannot be deactivated, whose feature permissions the owner edits like any
-- staff account. pos-api seeds it lazily on login/setup_owner; native schema v13
-- mirrors this as an INTEGER 0/1 column. Default false so existing rows are
-- unaffected.
ALTER TABLE pos_users ADD COLUMN IF NOT EXISTS is_demo boolean NOT NULL DEFAULT false;

-- Account deletion (native schema v14 mirrors this). Only a deactivated account
-- can be deleted. One that never recorded a sale, shift, cash movement, finance
-- entry or void request is removed outright — freeing its phone number; one that
-- did keeps its row with deleted_at set, so those records still resolve a
-- cashier name. Every list/login/lookup in pos-api filters `deleted_at IS NULL`.
ALTER TABLE pos_users ADD COLUMN IF NOT EXISTS deleted_at timestamptz;

-- Register proof photos: optional base64 image attached to a cash movement
-- (mainly debits — withdrawal evidence). Native schema v12 mirrors this as a
-- TEXT column, so the outbox row payload carries it through sync unchanged.
ALTER TABLE cash_movements ADD COLUMN IF NOT EXISTS photo text;

-- ===========================================================================
-- 2. INVARIANT INDEXES (built only when current data already satisfies them)
-- ===========================================================================

-- D1: at most one OPEN shift per (tenant, device) where a device is recorded.
-- Always safe: it ignores NULL device_id and each existing tenant has <=1 OPEN.
CREATE UNIQUE INDEX IF NOT EXISTS shifts_one_open_per_device
  ON shifts (customer_id, device_id) WHERE status = 'OPEN' AND device_id IS NOT NULL;

-- F (#15): at most one OWNER per tenant. Guarded so a pre-existing duplicate
-- (which would mean the operator must reconcile first) does not abort the run.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pos_users GROUP BY customer_id, role
    HAVING role = 'OWNER' AND count(*) > 1
  ) THEN
    CREATE UNIQUE INDEX IF NOT EXISTS pos_users_one_owner
      ON pos_users (customer_id) WHERE role = 'OWNER';
  ELSE
    RAISE NOTICE 'pos_users_one_owner SKIPPED: a tenant has >1 OWNER; reconcile then re-run.';
  END IF;
END $$;

-- G (#10): unique active product name per tenant (case-insensitive). Guarded
-- against pre-existing duplicate names.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pos_products WHERE is_active = 1
    GROUP BY customer_id, lower(name) HAVING count(*) > 1
  ) THEN
    CREATE UNIQUE INDEX IF NOT EXISTS pos_products_customer_name_active
      ON pos_products (customer_id, lower(name)) WHERE is_active = 1;
  ELSE
    RAISE NOTICE 'pos_products_customer_name_active SKIPPED: duplicate active names exist; dedupe then re-run.';
  END IF;
END $$;

-- ===========================================================================
-- 3. ATOMIC RPCs (SECURITY DEFINER, service_role only)
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 3a. pos_next_receipt: atomic counter increment + formatted receipt number.
-- Replaces the racy read-then-upsert in pos-api (audit #5).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pos_next_receipt(p_customer uuid, p_day text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v bigint;
BEGIN
  INSERT INTO public.pos_counters (customer_id, name, value)
  VALUES (p_customer, 'receipt-' || p_day, 1)
  ON CONFLICT (customer_id, name)
  DO UPDATE SET value = public.pos_counters.value + 1
  RETURNING value INTO v;
  RETURN 'REC-' || p_day || '-' || lpad(v::text, 4, '0');
END;
$$;
REVOKE ALL ON FUNCTION pos_next_receipt FROM public;
GRANT EXECUTE ON FUNCTION pos_next_receipt TO service_role;

-- ---------------------------------------------------------------------------
-- 3b. pos_create_sale: recompute line totals server-side, validate money,
-- insert sale + items + audit in ONE transaction. Stops trusting client
-- subtotal/total/cashier (audit #2 + #4-sale). receipt_number is passed in
-- from pos_next_receipt (already allocated atomically), so the shown receipt
-- always equals the stored one and the counter is never double-incremented.
-- ---------------------------------------------------------------------------
-- Drop the earlier 9-arg overload (before p_receipt was added) so the function
-- name is unambiguous; safe/no-op if it never existed.
DROP FUNCTION IF EXISTS public.pos_create_sale(
  uuid, text, text, text, jsonb, text, bigint, bigint, text);

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
  p_customer_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  item       jsonb;
  computed   bigint;
  bq         bigint;
  price      bigint;
  subtotal   bigint := 0;
  total_val  bigint;
  chg        bigint;
  sale_id    text;
  n          int := 0;
BEGIN
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

  IF NOT EXISTS (
    SELECT 1 FROM public.shifts
    WHERE customer_id = p_customer AND id = p_shift_id AND status = 'OPEN'
  ) THEN
    RAISE EXCEPTION 'Sale requires an open shift.';
  END IF;

  sale_id := gen_random_uuid()::text;

  -- Recompute subtotal from authoritative line math and verify each derived
  -- line total matches what the client sent (catches tampering).
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    n := n + 1;
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

  INSERT INTO public.sales (id, customer_id, receipt_number, cashier_id, device_id,
    shift_id, customer_name, payment_method, subtotal_minor_units,
    discount_minor_units, total_minor_units, amount_paid_minor_units,
    change_minor_units, status, created_at)
  VALUES (sale_id, p_customer, p_receipt, p_cashier, p_device,
    p_shift_id, p_customer_name, p_payment, subtotal,
    p_discount, total_val, p_amount_paid, chg, 'COMPLETED', now());

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

-- ---------------------------------------------------------------------------
-- 3c. pos_approve_void: request APPROVED + sale VOIDED atomically (audit #4).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pos_approve_void(
  p_customer   uuid,
  p_user       text,
  p_request_id text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  vr            record;
  active_shift  text;
  sale_updated  int;
BEGIN
  SELECT * INTO vr FROM public.void_requests
  WHERE customer_id = p_customer AND id = p_request_id AND status = 'PENDING';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Void request not found or already decided.';
  END IF;

  UPDATE public.void_requests
  SET status = 'APPROVED', decided_by = p_user, decided_at = now()
  WHERE customer_id = p_customer AND id = p_request_id AND status = 'PENDING';

  SELECT id INTO active_shift FROM public.shifts
  WHERE customer_id = p_customer AND status = 'OPEN' LIMIT 1;

  UPDATE public.sales
  SET status = 'VOIDED', void_reason = vr.reason, voided_at = now(),
      voided_by = p_user, voided_shift_id = active_shift
  WHERE customer_id = p_customer AND id = vr.sale_id AND status = 'COMPLETED';
  GET DIAGNOSTICS sale_updated = ROW_COUNT;
  IF sale_updated = 0 THEN
    RAISE EXCEPTION 'Sale is no longer voidable (not COMPLETED).';
  END IF;

  INSERT INTO public.pos_audit_logs (id, customer_id, user_id, action, details, created_at)
  VALUES (gen_random_uuid(), p_customer, p_user, 'VOID_APPROVED',
    'Request ' || p_request_id || ' approved.', now());
END;
$$;
REVOKE ALL ON FUNCTION pos_approve_void FROM public;
GRANT EXECUTE ON FUNCTION pos_approve_void TO service_role;

-- ---------------------------------------------------------------------------
-- 3d. pos_reject_void: mark request REJECTED + audit, atomically.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pos_reject_void(
  p_customer   uuid,
  p_user       text,
  p_request_id text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.void_requests
  SET status = 'REJECTED', decided_by = p_user, decided_at = now()
  WHERE customer_id = p_customer AND id = p_request_id AND status = 'PENDING';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Void request not found or already decided.';
  END IF;
  INSERT INTO public.pos_audit_logs (id, customer_id, user_id, action, details, created_at)
  VALUES (gen_random_uuid(), p_customer, p_user, 'VOID_REJECTED',
    'Request ' || p_request_id || ' rejected.', now());
END;
$$;
REVOKE ALL ON FUNCTION pos_reject_void FROM public;
GRANT EXECUTE ON FUNCTION pos_reject_void TO service_role;

-- ---------------------------------------------------------------------------
-- 3e. pos_void_sale: owner direct void (no request). Sale -> VOIDED + audit in
-- one transaction. Mirrors the requestless voidSale action.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pos_void_sale(
  p_customer uuid,
  p_user     text,
  p_sale_id  text,
  p_reason   text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  active_shift text;
  updated      int;
BEGIN
  SELECT id INTO active_shift FROM public.shifts
  WHERE customer_id = p_customer AND status = 'OPEN' LIMIT 1;

  UPDATE public.sales
  SET status = 'VOIDED', void_reason = p_reason, voided_at = now(),
      voided_by = p_user, voided_shift_id = active_shift
  WHERE customer_id = p_customer AND id = p_sale_id AND status <> 'VOIDED';
  GET DIAGNOSTICS updated = ROW_COUNT;
  IF updated = 0 THEN
    RAISE EXCEPTION 'Sale not found or already voided.';
  END IF;

  INSERT INTO public.pos_audit_logs (id, customer_id, user_id, action, details, created_at)
  VALUES (gen_random_uuid(), p_customer, p_user, 'SALE_VOIDED',
    'Sale ' || p_sale_id, now());
END;
$$;
REVOKE ALL ON FUNCTION pos_void_sale FROM public;
GRANT EXECUTE ON FUNCTION pos_void_sale TO service_role;

-- ---------------------------------------------------------------------------
-- 3f. pos_complete_finance: entry COMPLETED + (for CASH) DEPOSIT movement +
-- audit, atomically (audit #4-finance).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pos_complete_finance(
  p_customer uuid,
  p_user     text,
  p_entry_id text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  entry      record;
  cat_name   text;
  shift_found text;
BEGIN
  SELECT * INTO entry FROM public.pos_finance_entries
  WHERE customer_id = p_customer AND id = p_entry_id AND status = 'PENDING';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Entry is not pending.';
  END IF;

  UPDATE public.pos_finance_entries
  SET status = 'COMPLETED', completed_at = now(), completed_by = p_user, updated_at = now()
  WHERE customer_id = p_customer AND id = p_entry_id AND status = 'PENDING';

  IF entry.payment_method = 'CASH' THEN
    SELECT name INTO cat_name FROM public.pos_finance_categories
    WHERE customer_id = p_customer AND id = entry.category_id;

    SELECT id INTO shift_found FROM public.shifts
    WHERE customer_id = p_customer AND status = 'OPEN' LIMIT 1;

    IF shift_found IS NULL THEN
      shift_found := gen_random_uuid()::text;
      INSERT INTO public.shifts (id, customer_id, cashier_id, opening_cash_minor_units,
        status, opened_at, device_id)
      VALUES (shift_found, p_customer, p_user, 0, 'OPEN', now(), NULL);
    END IF;

    INSERT INTO public.cash_movements (id, customer_id, shift_id, user_id,
      type, amount_minor_units, reason, created_at)
    VALUES (gen_random_uuid(), p_customer, shift_found, p_user,
      'DEPOSIT', entry.amount_minor_units,
      'Collected from ' || COALESCE(cat_name, 'a person'), now());
  END IF;

  INSERT INTO public.pos_audit_logs (id, customer_id, user_id, action, details, created_at)
  VALUES (gen_random_uuid(), p_customer, p_user, 'FINANCE_COMPLETED',
    'Entry ' || p_entry_id || ' completed.', now());
END;
$$;
REVOKE ALL ON FUNCTION pos_complete_finance FROM public;
GRANT EXECUTE ON FUNCTION pos_complete_finance TO service_role;

-- ---------------------------------------------------------------------------
-- 3g. pos_ensure_shift: find or atomically create the OPEN shift (audit #3).
-- On a unique-violation from a racing insert, returns the winner's row.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pos_ensure_shift(
  p_customer uuid,
  p_user     text,
  p_device   text
)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE shift_found text;
BEGIN
  -- Serialize open-or-create per tenant so two concurrent ensure_shift calls
  -- cannot both find "no OPEN shift" and both insert (closes audit #3 race even
  -- for the shared perpetual shift, which carries a NULL device_id and is
  -- therefore outside the partial unique index).
  PERFORM pg_advisory_xact_lock(hashtext(p_customer::text));

  SELECT id INTO shift_found FROM public.shifts
  WHERE customer_id = p_customer AND status = 'OPEN'
    AND (p_device IS NULL OR device_id = p_device OR device_id IS NULL)
  LIMIT 1;
  IF shift_found IS NOT NULL THEN
    RETURN shift_found;
  END IF;

  shift_found := gen_random_uuid()::text;
  INSERT INTO public.shifts (id, customer_id, cashier_id, opening_cash_minor_units,
    status, opened_at, device_id)
  VALUES (shift_found, p_customer, p_user, 0, 'OPEN', now(), p_device);
  RETURN shift_found;
EXCEPTION WHEN unique_violation THEN
  SELECT id INTO shift_found FROM public.shifts
  WHERE customer_id = p_customer AND status = 'OPEN'
    AND (p_device IS NULL OR device_id = p_device OR device_id IS NULL)
  LIMIT 1;
  RETURN shift_found;
END;
$$;
REVOKE ALL ON FUNCTION pos_ensure_shift FROM public;
GRANT EXECUTE ON FUNCTION pos_ensure_shift TO service_role;

-- ---------------------------------------------------------------------------
-- 3h. pos_open_shift: explicit open, atomic. The partial unique index rejects
-- a second concurrent OPEN for the same device (audit #3).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pos_open_shift(
  p_customer uuid,
  p_user     text,
  p_device   text,
  p_opening  bigint
)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE shift_new text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext(p_customer::text));
  IF p_opening < 0 THEN
    RAISE EXCEPTION 'Opening cash cannot be negative.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.shifts
    WHERE customer_id = p_customer AND status = 'OPEN'
      AND (p_device IS NULL OR device_id = p_device OR device_id IS NULL)
  ) THEN
    RAISE EXCEPTION 'A shift is already open.';
  END IF;
  shift_new := gen_random_uuid()::text;
  INSERT INTO public.shifts (id, customer_id, cashier_id, opening_cash_minor_units,
    status, opened_at, device_id)
  VALUES (shift_new, p_customer, p_user, p_opening, 'OPEN', now(), p_device);

  INSERT INTO public.pos_audit_logs (id, customer_id, user_id, action, details, created_at)
  VALUES (gen_random_uuid(), p_customer, p_user, 'SHIFT_OPENED',
    'Shift ' || shift_new || ' opened.', now());
  RETURN shift_new;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'A shift is already open for this device.';
END;
$$;
REVOKE ALL ON FUNCTION pos_open_shift FROM public;
GRANT EXECUTE ON FUNCTION pos_open_shift TO service_role;

-- ---------------------------------------------------------------------------
-- 3i. pos_close_shift: reconcile expected cash + close, atomically. A movement
-- that raced in between is counted because the sum query runs inside this tx.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pos_close_shift(
  p_customer  uuid,
  p_user      text,
  p_shift_id  text,
  p_closing   bigint
)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  shift_row   public.shifts%ROWTYPE;
  cash_total  bigint := 0;
  dep         bigint := 0;
  wdr         bigint := 0;
  refund      bigint := 0;
  expected    bigint;
  updated     int;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext(p_customer::text));
  IF p_closing < 0 THEN
    RAISE EXCEPTION 'Closing cash cannot be negative.';
  END IF;

  SELECT * INTO shift_row FROM public.shifts
  WHERE customer_id = p_customer AND id = p_shift_id AND status = 'OPEN';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Shift is no longer open.';
  END IF;

  SELECT COALESCE(sum(total_minor_units), 0) INTO cash_total FROM public.sales
  WHERE customer_id = p_customer AND shift_id = p_shift_id
    AND status = 'COMPLETED' AND payment_method = 'CASH';

  SELECT COALESCE(sum(CASE WHEN type = 'DEPOSIT' THEN amount_minor_units ELSE 0 END), 0),
         COALESCE(sum(CASE WHEN type = 'WITHDRAWAL' THEN amount_minor_units ELSE 0 END), 0)
  INTO dep, wdr FROM public.cash_movements
  WHERE customer_id = p_customer AND shift_id = p_shift_id;

  SELECT COALESCE(sum(total_minor_units), 0) INTO refund FROM public.sales
  WHERE customer_id = p_customer AND status = 'VOIDED' AND payment_method = 'CASH'
    AND voided_shift_id = p_shift_id AND shift_id <> p_shift_id;

  expected := shift_row.opening_cash_minor_units + cash_total + dep - wdr - refund;

  UPDATE public.shifts
  SET closing_cash_minor_units = p_closing, expected_cash_minor_units = expected,
      status = 'CLOSED', closed_at = now()
  WHERE customer_id = p_customer AND id = p_shift_id AND status = 'OPEN';
  GET DIAGNOSTICS updated = ROW_COUNT;
  IF updated = 0 THEN
    RAISE EXCEPTION 'Shift is no longer open.';
  END IF;

  INSERT INTO public.pos_audit_logs (id, customer_id, user_id, action, details, created_at)
  VALUES (gen_random_uuid(), p_customer, p_user, 'SHIFT_CLOSED',
    'Expected ' || expected || ', Counted ' || p_closing ||
    ', Difference ' || (p_closing - expected), now());
  RETURN expected;
END;
$$;
REVOKE ALL ON FUNCTION pos_close_shift FROM public;
GRANT EXECUTE ON FUNCTION pos_close_shift TO service_role;

-- ---------------------------------------------------------------------------
-- 3j. pos_setup_owner: atomic first-owner bootstrap (audit #15). The count
-- check and insert are one tx; the one-owner unique index is the backstop.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pos_setup_owner(
  p_customer uuid,
  p_id       text,
  p_username text,
  p_pw_salt  text,
  p_pw_hash  text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE existing_count int;
BEGIN
  SELECT count(*) INTO existing_count FROM public.pos_users
   WHERE customer_id = p_customer AND deleted_at IS NULL;
  IF existing_count > 0 THEN
    RAISE EXCEPTION 'Owner already exists.';
  END IF;
  INSERT INTO public.pos_users (id, customer_id, username, role, pw_salt, pw_hash, active, token_version)
  VALUES (p_id, p_customer, p_username, 'OWNER', p_pw_salt, p_pw_hash, true, 0);
END;
$$;
REVOKE ALL ON FUNCTION pos_setup_owner FROM public;
GRANT EXECUTE ON FUNCTION pos_setup_owner TO service_role;

-- ---------------------------------------------------------------------------
-- 3k. Reporting aggregates (audit #9). pos-api previously fetched raw sales
-- rows and summed them in JavaScript, but PostgREST caps a select at 1000 rows,
-- so any tenant with >1000 sales in a period got silently-wrong totals. These
-- RPCs do the aggregation in SQL, which is exact regardless of row count.
-- ---------------------------------------------------------------------------

-- Exact register balance (expected cash) for one shift, matching the native
-- reconciliation rule (opening + cash sales + deposits - withdrawals -
-- cross-shift cash refunds).
CREATE OR REPLACE FUNCTION pos_expected_cash(p_customer uuid, p_shift_id text)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  opening bigint := 0; cash bigint := 0; dep bigint := 0;
  wdr bigint := 0; refund bigint := 0;
BEGIN
  SELECT COALESCE(opening_cash_minor_units, 0) INTO opening
    FROM public.shifts WHERE customer_id = p_customer AND id = p_shift_id;
  SELECT COALESCE(sum(total_minor_units), 0) INTO cash FROM public.sales
    WHERE customer_id = p_customer AND shift_id = p_shift_id
      AND status = 'COMPLETED' AND payment_method = 'CASH';
  SELECT
    COALESCE(sum(CASE WHEN type = 'DEPOSIT' THEN amount_minor_units ELSE 0 END), 0),
    COALESCE(sum(CASE WHEN type = 'WITHDRAWAL' THEN amount_minor_units ELSE 0 END), 0)
  INTO dep, wdr FROM public.cash_movements
    WHERE customer_id = p_customer AND shift_id = p_shift_id;
  SELECT COALESCE(sum(total_minor_units), 0) INTO refund FROM public.sales
    WHERE customer_id = p_customer AND status = 'VOIDED' AND payment_method = 'CASH'
      AND voided_shift_id = p_shift_id AND shift_id <> p_shift_id;
  RETURN opening + cash + dep - wdr - refund;
END;
$$;
REVOKE ALL ON FUNCTION pos_expected_cash FROM public;
GRANT EXECUTE ON FUNCTION pos_expected_cash TO service_role;

-- Dashboard headline numbers for a created_at window (nulls = unbounded).
-- Returns revenue / counts / cash+bank split / void count / pending void
-- requests whose target sale falls in the window, all computed in SQL.
-- Loan sales are recorded but collect no money, so they never count toward
-- any revenue figure and are not part of sales_count either — the average
-- sale is revenue / sales_count, so counting them would dilute it (mirrors
-- the native dashboard queries exactly).
CREATE OR REPLACE FUNCTION pos_sales_totals(
  p_customer uuid, p_start timestamptz, p_end timestamptz)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE res jsonb;
BEGIN
  SELECT jsonb_build_object(
    'revenue', COALESCE(sum(CASE WHEN status = 'COMPLETED' AND payment_method IN ('CASH', 'BANK') THEN total_minor_units ELSE 0 END), 0),
    'sales_count', COALESCE(count(*) FILTER (WHERE status = 'COMPLETED' AND payment_method IN ('CASH', 'BANK')), 0),
    'cash_revenue', COALESCE(sum(CASE WHEN status = 'COMPLETED' AND payment_method = 'CASH' THEN total_minor_units ELSE 0 END), 0),
    'bank_revenue', COALESCE(sum(CASE WHEN status = 'COMPLETED' AND payment_method = 'BANK' THEN total_minor_units ELSE 0 END), 0),
    'void_count', COALESCE(count(*) FILTER (WHERE status = 'VOIDED'), 0),
    'pending_void_requests', (
      SELECT count(*) FROM public.void_requests vr
        JOIN public.sales s2 ON s2.customer_id = vr.customer_id AND s2.id = vr.sale_id
        WHERE vr.customer_id = p_customer AND vr.status = 'PENDING'
          AND (p_start IS NULL OR s2.created_at >= p_start)
          AND (p_end IS NULL OR s2.created_at < p_end)
    )
  ) INTO res
  FROM public.sales
  WHERE customer_id = p_customer AND status IN ('COMPLETED', 'VOIDED')
    AND (p_start IS NULL OR created_at >= p_start)
    AND (p_end IS NULL OR created_at < p_end);
  RETURN COALESCE(res, '{}'::jsonb);
END;
$$;
REVOKE ALL ON FUNCTION pos_sales_totals FROM public;
GRANT EXECUTE ON FUNCTION pos_sales_totals TO service_role;

-- Revenue trend bucketed by calendar day, oldest first. Loan sales are
-- excluded: they brought no cash in.
CREATE OR REPLACE FUNCTION pos_revenue_trend(
  p_customer uuid, p_start timestamptz, p_end timestamptz)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE res jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(t ORDER BY t.day), '[]'::jsonb) INTO res FROM (
    SELECT substr(s.created_at::text, 1, 10) AS day,
           count(*)::int AS count,
           COALESCE(sum(s.total_minor_units), 0)::bigint AS total
    FROM public.sales s
    WHERE s.customer_id = p_customer AND s.status = 'COMPLETED'
      AND s.payment_method IN ('CASH', 'BANK')
      AND (p_start IS NULL OR s.created_at >= p_start)
      AND (p_end IS NULL OR s.created_at < p_end)
    GROUP BY 1
  ) t;
  RETURN res;
END;
$$;
REVOKE ALL ON FUNCTION pos_revenue_trend FROM public;
GRANT EXECUTE ON FUNCTION pos_revenue_trend TO service_role;

-- Product mix by revenue, exact across all matching line items. Loan sales
-- are excluded from the money totals (never collected).
CREATE OR REPLACE FUNCTION pos_product_summary(
  p_customer uuid, p_start timestamptz, p_end timestamptz)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE res jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(t ORDER BY t.revenue DESC), '[]'::jsonb) INTO res FROM (
    SELECT it.product_name_snapshot AS product_name_snapshot,
           COALESCE(sum(it.billing_quantity_milliunits), 0)::bigint AS qty,
           count(*)::int AS lines,
           COALESCE(sum(it.line_total_minor_units), 0)::bigint AS revenue
    FROM public.sale_items it
    JOIN public.sales s ON s.customer_id = it.customer_id AND s.id = it.sale_id
    WHERE it.customer_id = p_customer AND s.status = 'COMPLETED'
      AND s.payment_method IN ('CASH', 'BANK')
      AND (p_start IS NULL OR s.created_at >= p_start)
      AND (p_end IS NULL OR s.created_at < p_end)
    GROUP BY 1
  ) t;
  RETURN res;
END;
$$;
REVOKE ALL ON FUNCTION pos_product_summary FROM public;
GRANT EXECUTE ON FUNCTION pos_product_summary TO service_role;

-- Sales count + revenue per cashier, highest revenue first. Usernames are
-- hydrated in pos-api (cashier_id is the join key). Loan sales are excluded
-- from the revenue totals (their money was never collected).
CREATE OR REPLACE FUNCTION pos_cashier_performance(
  p_customer uuid, p_start timestamptz, p_end timestamptz)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE res jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(t ORDER BY t.total_revenue DESC), '[]'::jsonb) INTO res FROM (
    SELECT s.cashier_id::text AS cashier_id,
           count(*)::int AS total_sales,
           COALESCE(sum(s.total_minor_units), 0)::bigint AS total_revenue
    FROM public.sales s
    WHERE s.customer_id = p_customer AND s.status = 'COMPLETED'
      AND s.payment_method IN ('CASH', 'BANK')
      AND (p_start IS NULL OR s.created_at >= p_start)
      AND (p_end IS NULL OR s.created_at < p_end)
    GROUP BY 1
  ) t;
  RETURN res;
END;
$$;
REVOKE ALL ON FUNCTION pos_cashier_performance FROM public;
GRANT EXECUTE ON FUNCTION pos_cashier_performance TO service_role;

COMMIT;
