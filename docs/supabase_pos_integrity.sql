-- ⚠️ SUPERSEDED. Current version lives in supabase/migrations/.
-- Applied in production via supabase/migrations/20261031000000_void_owner_check.sql
-- Do not apply this file to production. Last synced: 2026-10-31.
-- The pos_void_sale, pos_approve_void, pos_reject_void functions below
-- are PRE-FIX bodies. Production has the owner check applied.

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
-- DELIBERATELY DEFERRED (see plan notes; need native-client changes first):
--   * sync revision conflict guard: needs every till to stamp a monotonic
--     per-row revision, which the outbox does not carry yet.
--
-- RECEIPT AUTHORITY: sales_receipt_unique now enforces one receipt number per
-- tenant, so the cloud counter is the single allocator. The native outbox sync
-- is inert today; before it is switched on, an offline till must reserve its
-- receipt range from pos_next_receipt (or prefix by device) instead of using a
-- local counter, or its push will be rejected as a duplicate.
-- ---------------------------------------------------------------------------

BEGIN;

-- ===========================================================================
-- 1. ADDITIVE COLUMNS
-- ===========================================================================

-- D1: shift device stamping. The shop runs ONE shared drawer per tenant, so
-- lookups ignore the device; the column is kept for audit history. Existing OPEN
-- shifts keep NULL device_id. shifts_one_open_per_tenant (section 2) is the
-- real invariant.
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

-- What the flag is for, in one place: a training account's money is practice
-- money, so every report and every drawer reconciliation leaves it out, and the
-- sync gateway refuses it. Answers false for an unknown id — a sale whose
-- cashier has no account row (yet) is real money and must never be hidden.
CREATE OR REPLACE FUNCTION public.pos_is_demo(p_customer uuid, p_user text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.pos_users u
    WHERE u.customer_id = p_customer AND u.id = p_user AND u.is_demo
  );
$$;
REVOKE ALL ON FUNCTION public.pos_is_demo(uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pos_is_demo(uuid, text) TO service_role;

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

-- H (#6, revised for multi-device): one receipt number per DEVICE per
-- tenant. Each till allocates its receipt number locally and OFFLINE, so two
-- registers of the same shop legitimately issue REC-<day>-0001 on the same
-- day. The original tenant-wide index rejected the second one, and that sale
-- stayed rejected in the sync mirror forever — invisible on every other
-- device. The sale `id` is the global identity; the receipt number is a
-- per-till artefact (never shown in the sales-history UI).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM sales
    GROUP BY customer_id, device_id, receipt_number HAVING count(*) > 1
  ) THEN
    DROP INDEX IF EXISTS sales_receipt_unique;
    CREATE UNIQUE INDEX IF NOT EXISTS sales_receipt_per_device
      ON sales (customer_id, device_id, receipt_number);
  ELSE
    RAISE NOTICE 'sales_receipt_per_device SKIPPED: a device has duplicate receipt numbers; reconcile then re-run.';
  END IF;
END $$;

-- I (#5): the shop has ONE drawer. At most one OPEN shift per tenant, so every
-- sale, movement, close and void is guaranteed to reference the same shift and
-- no lookup can pick a stale session. Supersedes the per-device guess.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM shifts WHERE status = 'OPEN'
    GROUP BY customer_id HAVING count(*) > 1
  ) THEN
    CREATE UNIQUE INDEX IF NOT EXISTS shifts_one_open_per_tenant
      ON shifts (customer_id) WHERE status = 'OPEN';
  ELSE
    RAISE NOTICE 'shifts_one_open_per_tenant SKIPPED: a tenant has >1 OPEN shift; close the extras then re-run.';
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
--
-- p_sale_id makes the write idempotent: the client's own sale id is the
-- idempotency key, so a retry after a timeout returns the original sale
-- instead of booking a second one (audit #6). sales_receipt_unique is the
-- backstop for a replayed receipt number.
--
-- The shift row is locked FOR SHARE, which conflicts with pos_close_shift's
-- FOR UPDATE: a sale either commits before the drawer is reconciled or fails
-- with 'Sale requires an open shift.' No sale can land on a closed shift.
-- ---------------------------------------------------------------------------
-- Drop the earlier overloads so the name is unambiguous; no-ops if absent.
DROP FUNCTION IF EXISTS public.pos_create_sale(
  uuid, text, text, text, text, jsonb, text, bigint, bigint, text);
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
  decided       int;
BEGIN
  SELECT * INTO vr FROM public.void_requests
  WHERE customer_id = p_customer AND id = p_request_id AND status = 'PENDING';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Void request not found or already decided.';
  END IF;

  UPDATE public.void_requests
  SET status = 'APPROVED', decided_by = p_user, decided_at = now()
  WHERE customer_id = p_customer AND id = p_request_id AND status = 'PENDING';
  GET DIAGNOSTICS decided = ROW_COUNT;
  IF decided <> 1 THEN
    RAISE EXCEPTION 'Void request was decided by someone else.';
  END IF;

  -- Share-lock the open drawer for the same reason as the sale/movement RPCs:
  -- a close must not reconcile the shift while a void is being attributed to
  -- it. No open shift means an explicit after-close adjustment (NULL), never a
  -- half-attributed one.
  SELECT id INTO active_shift FROM public.shifts
  WHERE customer_id = p_customer AND status = 'OPEN' LIMIT 1 FOR SHARE;

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
  -- Same lock protocol as pos_close_shift / pos_create_sale (audit 2 #6).
  SELECT id INTO active_shift FROM public.shifts
  WHERE customer_id = p_customer AND status = 'OPEN' LIMIT 1 FOR SHARE;

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
-- A completed collection may deposit into the drawer AT MOST ONCE. The row
-- lock below is the primary guard; this partial unique index is the belt: even
-- if a future code path forgets the lock, the second DEPOSIT is refused
-- instead of silently overstating the drawer (audit 2 #5).
ALTER TABLE public.cash_movements
  ADD COLUMN IF NOT EXISTS source_finance_entry_id text;
CREATE UNIQUE INDEX IF NOT EXISTS cash_movements_one_per_finance_entry
  ON public.cash_movements (customer_id, source_finance_entry_id)
  WHERE source_finance_entry_id IS NOT NULL;

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
  updated    int;
BEGIN
  -- Same refusal as the sync gateway: a training account cannot move the shop's
  -- money in the cloud, and the browser has no local books to put it in.
  IF public.pos_is_demo(p_customer, p_user) THEN
    RAISE EXCEPTION 'Training-account data stays on the till that made it.';
  END IF;

  -- FOR UPDATE: two concurrent completions used to both read PENDING, one
  -- updated the row and the loser updated nothing yet still deposited the
  -- collection a second time. Now the loser blocks, re-reads and finds no
  -- pending row (audit 2 #5).
  SELECT * INTO entry FROM public.pos_finance_entries
  WHERE customer_id = p_customer AND id = p_entry_id AND status = 'PENDING'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Entry is not pending.';
  END IF;

  UPDATE public.pos_finance_entries
  SET status = 'COMPLETED', completed_at = now(), completed_by = p_user, updated_at = now()
  WHERE customer_id = p_customer AND id = p_entry_id AND status = 'PENDING';
  GET DIAGNOSTICS updated = ROW_COUNT;
  IF updated <> 1 THEN
    RAISE EXCEPTION 'Entry is not pending.';
  END IF;

  IF entry.payment_method = 'CASH' THEN
    SELECT name INTO cat_name FROM public.pos_finance_categories
    WHERE customer_id = p_customer AND id = entry.category_id;

    -- Follow the shared open-or-create protocol instead of inserting a shift
    -- here: the old code bypassed the tenant advisory lock and could race
    -- pos_open_shift / pos_ensure_shift (audit 2 #6).
    shift_found := public.pos_ensure_shift(p_customer, p_user, NULL);

    -- The till that completed the collection itself deposits the money in the
    -- same push, and `pos_sync_apply` lands that movement before this entry
    -- (cash_movement 5, finance_entry 7). Depositing unconditionally here paid
    -- the drawer twice — the pushed row carries no entry id the unique index
    -- could match against, so nothing refused it. One deposit per collection is
    -- the rule; this function is now the fallback, not the second writer.
    IF NOT EXISTS (SELECT 1 FROM public.cash_movements
                   WHERE customer_id = p_customer
                     AND source_finance_entry_id = p_entry_id) THEN
      INSERT INTO public.cash_movements (id, customer_id, shift_id, user_id,
        type, amount_minor_units, reason, created_at, source_finance_entry_id)
      VALUES (gen_random_uuid(), p_customer, shift_found, p_user,
        'DEPOSIT', entry.amount_minor_units,
        'Collected from ' || COALESCE(cat_name, 'a person'), now(), p_entry_id);
    END IF;
  END IF;

  INSERT INTO public.pos_audit_logs (id, customer_id, user_id, action, details, created_at)
  VALUES (gen_random_uuid(), p_customer, p_user, 'FINANCE_COMPLETED',
    'Entry ' || p_entry_id || ' completed.', now());
END;
$$;
REVOKE ALL ON FUNCTION pos_complete_finance FROM public;
GRANT EXECUTE ON FUNCTION pos_complete_finance TO service_role;

-- ---------------------------------------------------------------------------
-- 3f-1b. pos_delete_finance_entry: soft-delete a collection, reversing a
-- completed CASH deposit with a WITHDRAWAL on the open drawer. Mirrors the
-- native transaction; `status = DELETED` is what the sync pull hides.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pos_delete_finance_entry(
  p_customer uuid,
  p_user     text,
  p_entry_id text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  entry       record;
  cat_name    text;
  shift_found text;
  updated     int;
BEGIN
  IF public.pos_is_demo(p_customer, p_user) THEN
    RAISE EXCEPTION 'Training-account data stays on the till that made it.';
  END IF;

  SELECT * INTO entry FROM public.pos_finance_entries
  WHERE customer_id = p_customer AND id = p_entry_id AND status <> 'DELETED'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Entry not found.';
  END IF;

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
REVOKE ALL ON FUNCTION pos_delete_finance_entry FROM public;
GRANT EXECUTE ON FUNCTION pos_delete_finance_entry TO service_role;

-- ---------------------------------------------------------------------------
-- 3f-2. pos_delete_finance_category: permanent delete of a binned person.
-- Entries and the person must leave together: the client used to send two
-- separate requests, so a failure in between erased a person's ledger while
-- the person stayed visible (audit 2 #15). Mirrors the native transaction.
-- Deliberately NO "has completed entries" guard: native
-- permanentlyDeleteCategory purges completed entries too, and the recycle bin
-- is the single place a permanent delete may happen (behind its own confirm
-- dialog) with the audit line as the record. A guard here only broke the PWA.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pos_delete_finance_category(
  p_customer uuid,
  p_id       text,
  p_user     text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  cat record;
BEGIN
  SELECT id, name, deleted_at INTO cat FROM public.pos_finance_categories
  WHERE customer_id = p_customer AND id = p_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Person not found.';
  END IF;
  IF cat.deleted_at IS NULL THEN
    RAISE EXCEPTION 'Move the person to the recycle bin first.';
  END IF;

  DELETE FROM public.pos_finance_entries
  WHERE customer_id = p_customer AND category_id = p_id;
  DELETE FROM public.pos_finance_categories
  WHERE customer_id = p_customer AND id = p_id;

  INSERT INTO public.pos_audit_logs (id, customer_id, user_id, action, details, created_at)
  VALUES (gen_random_uuid(), p_customer, p_user, 'FINANCE_CATEGORY_PERMANENTLY_DELETED',
    'Person "' || cat.name || '" and their entries permanently deleted.', now());
END;
$$;
REVOKE ALL ON FUNCTION pos_delete_finance_category FROM public;
GRANT EXECUTE ON FUNCTION pos_delete_finance_category TO service_role;

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
  -- cannot both find "no OPEN shift" and both insert. The shop runs ONE shared
  -- drawer, so the lookup ignores the device: whatever shift is open is the
  -- session every till posts to (shifts_one_open_per_tenant enforces it).
  PERFORM pg_advisory_xact_lock(hashtext(p_customer::text));

  SELECT id INTO shift_found FROM public.shifts
  WHERE customer_id = p_customer AND status = 'OPEN'
  LIMIT 1;
  IF shift_found IS NOT NULL THEN
    RETURN shift_found;
  END IF;

  -- Reading the shop's open drawer is harmless, so only the CREATE below is
  -- refused for a training account: an unguarded create would leave the tenant
  -- with a shift that exists purely because somebody practised in a browser.
  IF public.pos_is_demo(p_customer, p_user) THEN
    RAISE EXCEPTION 'Training-account data stays on the till that made it.';
  END IF;

  shift_found := gen_random_uuid()::text;
  INSERT INTO public.shifts (id, customer_id, cashier_id, opening_cash_minor_units,
    status, opened_at, device_id)
  VALUES (shift_found, p_customer, p_user, 0, 'OPEN', now(), p_device);
  RETURN shift_found;
EXCEPTION WHEN unique_violation THEN
  SELECT id INTO shift_found FROM public.shifts
  WHERE customer_id = p_customer AND status = 'OPEN'
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
  IF public.pos_is_demo(p_customer, p_user) THEN
    RAISE EXCEPTION 'Training-account data stays on the till that made it.';
  END IF;
  IF p_opening < 0 THEN
    RAISE EXCEPTION 'Opening cash cannot be negative.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.shifts
    WHERE customer_id = p_customer AND status = 'OPEN'
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
  RAISE EXCEPTION 'A shift is already open.';
END;
$$;
REVOKE ALL ON FUNCTION pos_open_shift FROM public;
GRANT EXECUTE ON FUNCTION pos_open_shift TO service_role;

-- ---------------------------------------------------------------------------
-- 3h2. pos_add_cash_movement: the OPEN check, the insert and the audit row are
-- one transaction, and the shift row is share-locked so the movement can never
-- land on a session pos_close_shift is reconciling (audit #3 + #11).
--
-- Two optional arguments carry what the sync path knows and the browser does
-- not: `p_movement_id` is the uuid the till already wrote on its own device, and
-- `p_source_finance_entry_id` is the collection the deposit came from.
-- Minting a fresh uuid for a synced movement made the till keep its row AND
-- download the cloud's copy of the same money (the register showed the deposit
-- twice while the browser showed it once), and a movement with no entry id is
-- invisible to `cash_movements_one_per_finance_entry` — so the deposit a till
-- makes and the one pos_complete_finance makes for the same collection both
-- landed. Both are idempotent now, and a replay writes no second audit line.
--
-- Adding defaulted arguments changes the signature, and PostgreSQL treats a
-- different argument list as a new function rather than a replacement — the old
-- 7-arg overload would survive and make the name ambiguous for every REVOKE /
-- GRANT / call. Drop it first; a caller that still passes 7 positional
-- arguments resolves to the new one through the defaults.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.pos_add_cash_movement(
  uuid, text, text, text, bigint, text, text);

CREATE OR REPLACE FUNCTION pos_add_cash_movement(
  p_customer uuid,
  p_user     text,
  p_shift_id text,
  p_type     text,
  p_amount   bigint,
  p_reason   text,
  p_photo    text,
  p_movement_id text DEFAULT NULL,
  p_source_finance_entry_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE mv_id text;
  existing  text;
  inserted  boolean;
BEGIN
  IF public.pos_is_demo(p_customer, p_user) THEN
    RAISE EXCEPTION 'Training-account data stays on the till that made it.';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be positive.';
  END IF;
  IF p_type NOT IN ('WITHDRAWAL', 'DEPOSIT', 'EXPENSE') THEN
    RAISE EXCEPTION 'Invalid movement type.';
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'A reason is required.';
  END IF;
  IF p_photo IS NOT NULL AND length(p_photo) > 5000000 THEN
    RAISE EXCEPTION 'Photo too large (max 5MB).';
  END IF;

  -- The same movement, arriving twice (a device retrying a push it never got an
  -- ack for). Answer with the row that exists instead of writing a second one.
  IF p_movement_id IS NOT NULL THEN
    SELECT id INTO existing FROM public.cash_movements
    WHERE customer_id = p_customer AND id = p_movement_id;
    IF FOUND THEN
      RETURN jsonb_build_object('id', existing, 'duplicate', true);
    END IF;
  END IF;

  -- The same collection, deposited by the other path. Skipping is what lets the
  -- outbox row and pos_complete_finance converge on one deposit; the unique
  -- index alone would only turn it into an opaque rejection.
  IF p_source_finance_entry_id IS NOT NULL THEN
    SELECT id INTO existing FROM public.cash_movements
    WHERE customer_id = p_customer
      AND source_finance_entry_id = p_source_finance_entry_id;
    IF FOUND THEN
      RETURN jsonb_build_object('id', existing, 'duplicate', true);
    END IF;
  END IF;

  -- Checked after the replays on purpose: a movement re-sent after its shift
  -- closed is still the same money already in the drawer, not a failure.
  PERFORM 1 FROM public.shifts
    WHERE customer_id = p_customer AND id = p_shift_id AND status = 'OPEN'
    FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Movement requires an open shift.';
  END IF;

  mv_id := COALESCE(p_movement_id, gen_random_uuid()::text);
  INSERT INTO public.cash_movements (id, customer_id, shift_id, user_id, type,
    amount_minor_units, reason, photo, created_at, source_finance_entry_id)
  VALUES (mv_id, p_customer, p_shift_id, p_user, p_type, p_amount,
    btrim(p_reason), NULLIF(p_photo, ''), now(), p_source_finance_entry_id)
  ON CONFLICT (customer_id, id) DO NOTHING;
  GET DIAGNOSTICS inserted = ROW_COUNT;
  IF NOT inserted THEN
    -- A concurrent twin won the same id; report it as the replay it is.
    SELECT id INTO existing FROM public.cash_movements
    WHERE customer_id = p_customer AND id = mv_id;
    RETURN jsonb_build_object('id', COALESCE(existing, mv_id), 'duplicate', true);
  END IF;

  INSERT INTO public.pos_audit_logs (id, customer_id, user_id, action, details, created_at)
  VALUES (gen_random_uuid(), p_customer, p_user, 'CASH_MOVEMENT_ADDED',
    p_type || ' ' || p_amount, now());

  RETURN jsonb_build_object('id', mv_id);
END;
$$;
REVOKE ALL ON FUNCTION pos_add_cash_movement(
  uuid, text, text, text, bigint, text, text, text, text) FROM public;
GRANT EXECUTE ON FUNCTION pos_add_cash_movement(
  uuid, text, text, text, bigint, text, text, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 3h3. pos_shift_counters: today's register counters in SQL, so the snapshot no
-- longer sums a possibly truncated PostgREST page (audit #13). EXPENSE counts
-- as money out, matching the native drawer rule (audit #4).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pos_shift_counters(
  p_customer uuid, p_shift_id text, p_start timestamptz, p_end timestamptz)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE res jsonb;
BEGIN
  SELECT jsonb_build_object(
    'cash_sales', COALESCE(sum(CASE WHEN status = 'COMPLETED' AND payment_method = 'CASH' THEN total_minor_units ELSE 0 END), 0),
    'bank_sales', COALESCE(sum(CASE WHEN status = 'COMPLETED' AND payment_method = 'BANK' THEN total_minor_units ELSE 0 END), 0),
    'deposits', (SELECT COALESCE(sum(amount_minor_units), 0) FROM public.cash_movements
        WHERE customer_id = p_customer AND shift_id = p_shift_id AND type = 'DEPOSIT'
          AND NOT public.pos_is_demo(p_customer, user_id)
          AND (p_start IS NULL OR created_at >= p_start)
          AND (p_end IS NULL OR created_at < p_end)),
    'withdrawals', (SELECT COALESCE(sum(amount_minor_units), 0) FROM public.cash_movements
        WHERE customer_id = p_customer AND shift_id = p_shift_id
          AND type IN ('WITHDRAWAL', 'EXPENSE')
          AND NOT public.pos_is_demo(p_customer, user_id)
          AND (p_start IS NULL OR created_at >= p_start)
          AND (p_end IS NULL OR created_at < p_end))
  ) INTO res
  FROM public.sales
  WHERE customer_id = p_customer AND shift_id = p_shift_id
    AND NOT public.pos_is_demo(p_customer, cashier_id)
    AND (p_start IS NULL OR created_at >= p_start)
    AND (p_end IS NULL OR created_at < p_end);
  RETURN COALESCE(res, '{}'::jsonb);
END;
$$;
REVOKE ALL ON FUNCTION pos_shift_counters FROM public;
GRANT EXECUTE ON FUNCTION pos_shift_counters TO service_role;

-- ---------------------------------------------------------------------------
-- 3h4. pos_shift_summary: one shift's financials as exact SQL aggregates
-- (audit #13) with the same EXPENSE rule and expected-cash function the drawer
-- itself uses, so the screen and the reconciliation can never disagree.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pos_shift_summary(
  p_customer uuid, p_shift_id text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE res jsonb;
BEGIN
  SELECT jsonb_build_object(
    'cash_sales', (SELECT COALESCE(sum(total_minor_units), 0) FROM public.sales
        WHERE customer_id = p_customer AND shift_id = p_shift_id
          AND status = 'COMPLETED' AND payment_method = 'CASH'
          AND NOT public.pos_is_demo(p_customer, cashier_id)),
    'bank_sales', (SELECT COALESCE(sum(total_minor_units), 0) FROM public.sales
        WHERE customer_id = p_customer AND shift_id = p_shift_id
          AND status = 'COMPLETED' AND payment_method = 'BANK'
          AND NOT public.pos_is_demo(p_customer, cashier_id)),
    'voids', (SELECT COALESCE(sum(total_minor_units), 0) FROM public.sales
        WHERE customer_id = p_customer AND status = 'VOIDED'
          AND NOT public.pos_is_demo(p_customer, cashier_id)
          AND (voided_shift_id = p_shift_id
               OR (shift_id = p_shift_id AND voided_shift_id IS NULL))),
    'deposits', (SELECT COALESCE(sum(amount_minor_units), 0) FROM public.cash_movements
        WHERE customer_id = p_customer AND shift_id = p_shift_id AND type = 'DEPOSIT'
          AND NOT public.pos_is_demo(p_customer, user_id)),
    'withdrawals', (SELECT COALESCE(sum(amount_minor_units), 0) FROM public.cash_movements
        WHERE customer_id = p_customer AND shift_id = p_shift_id
          AND type IN ('WITHDRAWAL', 'EXPENSE')
          AND NOT public.pos_is_demo(p_customer, user_id)),
    'cash_refunds', (SELECT COALESCE(sum(total_minor_units), 0) FROM public.sales
        WHERE customer_id = p_customer AND status = 'VOIDED' AND payment_method = 'CASH'
          AND NOT public.pos_is_demo(p_customer, cashier_id)
          AND voided_shift_id = p_shift_id AND shift_id <> p_shift_id),
    'expected_cash', public.pos_expected_cash(p_customer, p_shift_id)
  ) INTO res;
  RETURN COALESCE(res, '{}'::jsonb);
END;
$$;
REVOKE ALL ON FUNCTION pos_shift_summary FROM public;
GRANT EXECUTE ON FUNCTION pos_shift_summary TO service_role;

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
  WHERE customer_id = p_customer AND id = p_shift_id AND status = 'OPEN'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Shift is no longer open.';
  END IF;

  SELECT COALESCE(sum(total_minor_units), 0) INTO cash_total FROM public.sales
  WHERE customer_id = p_customer AND shift_id = p_shift_id
    AND status = 'COMPLETED' AND payment_method = 'CASH'
    AND NOT public.pos_is_demo(p_customer, cashier_id);

  SELECT COALESCE(sum(CASE WHEN type = 'DEPOSIT' THEN amount_minor_units ELSE 0 END), 0),
         COALESCE(sum(CASE WHEN type IN ('WITHDRAWAL', 'EXPENSE') THEN amount_minor_units ELSE 0 END), 0)
  INTO dep, wdr FROM public.cash_movements
  WHERE customer_id = p_customer AND shift_id = p_shift_id
    AND NOT public.pos_is_demo(p_customer, user_id);

  SELECT COALESCE(sum(total_minor_units), 0) INTO refund FROM public.sales
  WHERE customer_id = p_customer AND status = 'VOIDED' AND payment_method = 'CASH'
    AND NOT public.pos_is_demo(p_customer, cashier_id)
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
      AND status = 'COMPLETED' AND payment_method = 'CASH'
      AND NOT public.pos_is_demo(p_customer, cashier_id);
  SELECT
    COALESCE(sum(CASE WHEN type = 'DEPOSIT' THEN amount_minor_units ELSE 0 END), 0),
    COALESCE(sum(CASE WHEN type IN ('WITHDRAWAL', 'EXPENSE') THEN amount_minor_units ELSE 0 END), 0)
  INTO dep, wdr FROM public.cash_movements
    WHERE customer_id = p_customer AND shift_id = p_shift_id
      AND NOT public.pos_is_demo(p_customer, user_id);
  SELECT COALESCE(sum(total_minor_units), 0) INTO refund FROM public.sales
    WHERE customer_id = p_customer AND status = 'VOIDED' AND payment_method = 'CASH'
      AND NOT public.pos_is_demo(p_customer, cashier_id)
      AND voided_shift_id = p_shift_id AND shift_id <> p_shift_id;
  RETURN opening + cash + dep - wdr - refund;
END;
$$;
REVOKE ALL ON FUNCTION pos_expected_cash FROM public;
GRANT EXECUTE ON FUNCTION pos_expected_cash TO service_role;

-- Dashboard headline numbers for a created_at window (nulls = unbounded).
-- Returns revenue / counts / cash+bank split / void count / pending void
-- requests whose target sale falls in the window, all computed in SQL.
-- Loan sales collect no money, so they stay out of every revenue figure, but
-- they are real completed sales and DO count toward sales_count (4 sales of
-- which 1 is a loan: count 4, revenue from 3). Mirrors the native dashboard
-- queries exactly.
--
-- Training-account money is left out of every figure below. A till running an
-- older build still pushes its demo sales, and rows that arrived before the
-- gateway learned to refuse them are still here — one shop held 1,700 demo sales
-- against 427 real ones, so its dashboard reported three times the takings.
-- Mirrored natively by `notDemoOperator()` in core/utils/report_filters.dart.
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
    'sales_count', COALESCE(count(*) FILTER (WHERE status = 'COMPLETED'), 0),
    'cash_revenue', COALESCE(sum(CASE WHEN status = 'COMPLETED' AND payment_method = 'CASH' THEN total_minor_units ELSE 0 END), 0),
    'bank_revenue', COALESCE(sum(CASE WHEN status = 'COMPLETED' AND payment_method = 'BANK' THEN total_minor_units ELSE 0 END), 0),
    'void_count', COALESCE(count(*) FILTER (WHERE status = 'VOIDED'), 0),
    'pending_void_requests', (
      SELECT count(*) FROM public.void_requests vr
        JOIN public.sales s2 ON s2.customer_id = vr.customer_id AND s2.id = vr.sale_id
        WHERE vr.customer_id = p_customer AND vr.status = 'PENDING'
          AND NOT public.pos_is_demo(p_customer, s2.cashier_id)
          AND (p_start IS NULL OR s2.created_at >= p_start)
          AND (p_end IS NULL OR s2.created_at < p_end)
    )
  ) INTO res
  FROM public.sales
  WHERE customer_id = p_customer AND status IN ('COMPLETED', 'VOIDED')
    AND NOT public.pos_is_demo(p_customer, cashier_id)
    AND (p_start IS NULL OR created_at >= p_start)
    AND (p_end IS NULL OR created_at < p_end);
  RETURN COALESCE(res, '{}'::jsonb);
END;
$$;
REVOKE ALL ON FUNCTION pos_sales_totals FROM public;
GRANT EXECUTE ON FUNCTION pos_sales_totals TO service_role;

-- Revenue trend bucketed by calendar day in the shop's timezone, oldest first.
-- created_at is timestamptz (UTC); the substr() form bucketed by UTC date and
-- put sales after local midnight on the wrong day. Loan sales are excluded:
-- they brought no cash in.
CREATE OR REPLACE FUNCTION pos_revenue_trend(
  p_customer uuid, p_start timestamptz, p_end timestamptz)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE res jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(t ORDER BY t.day), '[]'::jsonb) INTO res FROM (
    SELECT ((s.created_at AT TIME ZONE 'Africa/Addis_Ababa')::date)::text AS day,
           count(*)::int AS count,
           COALESCE(sum(s.total_minor_units), 0)::bigint AS total
    FROM public.sales s
    WHERE s.customer_id = p_customer AND s.status = 'COMPLETED'
      AND s.payment_method IN ('CASH', 'BANK')
      AND NOT public.pos_is_demo(p_customer, s.cashier_id)
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
      AND NOT public.pos_is_demo(p_customer, s.cashier_id)
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
      -- The training account is not an operator of the shop, so it never appears
      -- as a row in the cashier league table either.
      AND NOT public.pos_is_demo(p_customer, s.cashier_id)
      AND (p_start IS NULL OR s.created_at >= p_start)
      AND (p_end IS NULL OR s.created_at < p_end)
    GROUP BY 1
  ) t;
  RETURN res;
END;
$$;
REVOKE ALL ON FUNCTION pos_cashier_performance FROM public;
GRANT EXECUTE ON FUNCTION pos_cashier_performance TO service_role;

-- ---------------------------------------------------------------------------
-- 3l. Person (finance category) totals. pos-api used to fetch every entry of a
-- person and sum them in JavaScript, which PostgREST silently truncated at
-- 1,000 rows — a busy person's pending/completed totals were understated. The
-- aggregate lives in SQL so it is exact at any row count, and a binned person
-- answers zeros because every list already hides their entries.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pos_finance_person_totals(
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
REVOKE ALL ON FUNCTION pos_finance_person_totals FROM public;
GRANT EXECUTE ON FUNCTION pos_finance_person_totals TO service_role;

-- ---------------------------------------------------------------------------
-- Privilege hardening for every pos_* RPC (audit 2 #27).
--
-- `REVOKE ... FROM public` alone is NOT enough: Supabase's default privileges
-- hand EXECUTE on new functions to `anon` and `authenticated` directly, so the
-- roles kept executing SECURITY DEFINER RPCs. Any holder of the published
-- anon key (every web build ships it) could therefore pass another tenant's
-- customer uuid to pos_create_sale, pos_open_shift or pos_sales_totals and
-- read or write that shop's books — the definer rights bypass RLS.
--
-- Nothing client-side calls these functions: the till and the PWA go through
-- the pos-api / sync Edge Functions, which hold the service key. So the only
-- executable role is service_role. This block is idempotent and covers future
-- pos_* functions too, so a later migration that forgets its own REVOKE is
-- still closed.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  fn record;
BEGIN
  FOR fn IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname LIKE 'pos\_%'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', fn.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', fn.sig);
  END LOOP;
END;
$$;

COMMIT;
