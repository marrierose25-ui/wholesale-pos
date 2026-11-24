-- ============================================================================
-- PRODUCTION SCHEMA BASELINE (Request 2)
-- ============================================================================
--
-- This migration is the authoritative, replayable baseline of the live
-- Supabase schema as of 2026-11-24, captured by a read-only declarative
-- export (`supabase db pull --remote --declarative --strict-coverage`,
-- project ref in backend/supabase/.temp/linked-project.json).
--
-- It represents the schema BEFORE the three pending H1 migrations
-- (20261125000000, 20261126000000, 20261127000000), which remain active
-- forward migrations AFTER this baseline, followed by the Request-2
-- licensing/rate-limit migrations.
--
-- FAIL-CLOSED GUARD: this file is intended for an EMPTY database only. If
-- the application schema is already populated (e.g. production, which
-- already contains this schema plus applied historical migrations), the
-- guard below aborts the migration with instructions to reconcile the
-- migration history instead of re-running baseline DDL.
--
-- Ordering note: the declarative export stores objects per-file; this
-- baseline re-orders them so a cold replay succeeds:
--   extensions -> functions -> tables (FK order) -> views -> event trigger
--   -> default privileges. `check_function_bodies` is disabled for the
--   duration because pos_is_demo (LANGUAGE sql) references pos_users,
--   which is created later; its body is still valid at runtime.
-- ============================================================================

SET check_function_bodies = off;

DO $$
DECLARE
  v_populated text;
BEGIN
  SELECT string_agg(t, ', ') INTO v_populated
  FROM (VALUES
    ('public.customers'), ('public.licenses'), ('public.pos_users'),
    ('public.sales'), ('public.sync_mirror')
  ) AS v(t)
  WHERE to_regclass(v.t) IS NOT NULL;
  IF v_populated IS NOT NULL THEN
    RAISE EXCEPTION
      'production_baseline: application schema already exists (%). This '
      'baseline is for EMPTY databases only. On an existing database, mark '
      'this migration applied via `supabase migration repair` and follow '
      'docs/architecture/migration-history-repair.md — do NOT execute the '
      'baseline DDL.', v_populated;
  END IF;
END $$;

-- ---- public schema grants (from schemas/public/schema.sql) ----
COMMENT ON SCHEMA "public" IS 'standard public schema';

REVOKE ALL ON SCHEMA "public" FROM PUBLIC;

GRANT USAGE ON SCHEMA "public" TO PUBLIC;

REVOKE ALL ON SCHEMA "public" FROM "anon";

GRANT USAGE ON SCHEMA "public" TO "anon";

REVOKE ALL ON SCHEMA "public" FROM "authenticated";

GRANT USAGE ON SCHEMA "public" TO "authenticated";

REVOKE ALL ON SCHEMA "public" FROM "pg_database_owner";

GRANT CREATE, USAGE ON SCHEMA "public" TO "pg_database_owner";

REVOKE ALL ON SCHEMA "public" FROM "postgres";

GRANT USAGE ON SCHEMA "public" TO "postgres";

REVOKE ALL ON SCHEMA "public" FROM "service_role";

GRANT USAGE ON SCHEMA "public" TO "service_role";

-- ---- default-privilege wipes (adp_wipes.sql) ----
-- Clears assumed destination defaults before creating objects.
-- Safe to load on a project that does not have those defaults.

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" REVOKE ALL ON SEQUENCES FROM "anon";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" REVOKE ALL ON SEQUENCES FROM "authenticated";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" REVOKE ALL ON SEQUENCES FROM "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" REVOKE ALL ON FUNCTIONS FROM "anon";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" REVOKE ALL ON FUNCTIONS FROM "authenticated";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" REVOKE ALL ON FUNCTIONS FROM "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" REVOKE ALL ON TABLES FROM "anon";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" REVOKE ALL ON TABLES FROM "authenticated";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" REVOKE ALL ON TABLES FROM "service_role";

-- ---- _cluster/extensions/pgcrypto.sql ----
CREATE EXTENSION "pgcrypto" SCHEMA "extensions";

COMMENT ON EXTENSION "pgcrypto" IS 'cryptographic functions';

-- ---- _cluster/extensions/uuid-ossp.sql ----
CREATE EXTENSION "uuid-ossp" SCHEMA "extensions";

COMMENT ON EXTENSION "uuid-ossp" IS 'generate universally unique identifiers (UUIDs)';

-- ---- functions/apply_seat_voucher.sql ----
CREATE OR REPLACE FUNCTION public.apply_seat_voucher (
  p_voucher_code    text,
  p_activation_code text
)
  RETURNS TABLE (
    new_seat_limit integer,
    seats_added    integer
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
declare
  v_row record;
  v_current_limit int;
begin
  select * into v_row from public.seat_vouchers
    where voucher_code = p_voucher_code
      and activation_code = p_activation_code   -- tenant binding
      and redeemed_at is null
    for update;
  if not found then
    raise exception 'Voucher not found or already redeemed.';
  end if;

  update public.licenses
    set seat_limit = seat_limit + v_row.seats_added
    where activation_code = v_row.activation_code
    returning seat_limit into v_current_limit;

  update public.seat_vouchers
    set redeemed_at = now()
    where voucher_code = p_voucher_code;

  return query select v_current_limit, v_row.seats_added;
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."apply_seat_voucher"(text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."apply_seat_voucher"(text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."apply_seat_voucher"(text, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."apply_seat_voucher"(text, text) FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_add_cash_movement.sql ----
CREATE OR REPLACE FUNCTION public.pos_add_cash_movement (
  p_customer                uuid,
  p_user                    text,
  p_shift_id                text,
  p_type                    text,
  p_amount                  bigint,
  p_reason                  text,
  p_photo                   text,
  p_movement_id             text   DEFAULT NULL::text,
  p_source_finance_entry_id text   DEFAULT NULL::text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_add_cash_movement"(uuid, text, text, text, bigint, text, text, text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_add_cash_movement"(uuid, text, text, text, bigint, text, text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_add_cash_movement"(uuid, text, text, text, bigint, text, text, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_add_cash_movement"(uuid, text, text, text, bigint, text, text, text, text) FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_approve_void.sql ----
CREATE OR REPLACE FUNCTION public.pos_approve_void (
  p_customer   uuid,
  p_user       text,
  p_request_id text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
DECLARE
  vr            record;
  active_shift  text;
  sale_updated  int;
  decided       int;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.pos_users
    WHERE customer_id = p_customer AND id = p_user
      AND role = 'OWNER' AND active = true AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Void requires owner authorization.';
  END IF;

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
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_approve_void"(uuid, text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_approve_void"(uuid, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_approve_void"(uuid, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_approve_void"(uuid, text, text) FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_cashier_performance.sql ----
CREATE OR REPLACE FUNCTION public.pos_cashier_performance (
  p_customer uuid,
  p_start    timestamp with time zone,
  p_end      timestamp with time zone
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_cashier_performance"(uuid, timestamp WITH time zone, timestamp WITH time zone) TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_cashier_performance"(uuid, timestamp WITH time zone, timestamp WITH time zone) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_cashier_performance"(uuid, timestamp WITH time zone, timestamp WITH time zone) TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_cashier_performance"(uuid, timestamp WITH time zone, timestamp WITH time zone) FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_close_shift.sql ----
CREATE OR REPLACE FUNCTION public.pos_close_shift (
  p_customer uuid,
  p_user     text,
  p_shift_id text,
  p_closing  bigint
)
  RETURNS bigint
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_close_shift"(uuid, text, text, bigint) TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_close_shift"(uuid, text, text, bigint) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_close_shift"(uuid, text, text, bigint) TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_close_shift"(uuid, text, text, bigint) FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_complete_finance.sql ----
CREATE OR REPLACE FUNCTION public.pos_complete_finance (
  p_customer uuid,
  p_user     text,
  p_entry_id text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_complete_finance"(uuid, text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_complete_finance"(uuid, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_complete_finance"(uuid, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_complete_finance"(uuid, text, text) FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_create_sale.sql ----
CREATE OR REPLACE FUNCTION public.pos_create_sale (
  p_customer      uuid,
  p_cashier       text,
  p_device        text,
  p_shift_id      text,
  p_receipt       text,
  p_items         jsonb,
  p_payment       text,
  p_discount      bigint,
  p_amount_paid   bigint,
  p_customer_name text   DEFAULT NULL::text,
  p_sale_id       text   DEFAULT NULL::text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_create_sale"(uuid, text, text, text, text, jsonb, text, bigint, bigint, text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_create_sale"(uuid, text, text, text, text, jsonb, text, bigint, bigint, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_create_sale"(uuid, text, text, text, text, jsonb, text, bigint, bigint, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_create_sale"(uuid, text, text, text, text, jsonb, text, bigint, bigint, text, text) FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_delete_finance_category.sql ----
CREATE OR REPLACE FUNCTION public.pos_delete_finance_category (
  p_customer uuid,
  p_id       text,
  p_user     text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_delete_finance_category"(uuid, text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_delete_finance_category"(uuid, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_delete_finance_category"(uuid, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_delete_finance_category"(uuid, text, text) FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_delete_finance_entry.sql ----
CREATE OR REPLACE FUNCTION public.pos_delete_finance_entry (
  p_customer uuid,
  p_user     text,
  p_entry_id text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
DECLARE
  entry        record;
  cat_name     text;
  shift_found  text;
  updated      int;
BEGIN
  -- Same refusal as every other finance RPC: a training account cannot move the
  -- shop's money in the cloud.
  IF public.pos_is_demo(p_customer, p_user) THEN
    RAISE EXCEPTION 'Training-account data stays on the till that made it.';
  END IF;

  SELECT * INTO entry FROM public.pos_finance_entries
  WHERE customer_id = p_customer AND id = p_entry_id AND status <> 'DELETED'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Entry not found.';
  END IF;

  -- Only a completed CASH collection touched the drawer. If its deposit is
  -- still there, post the opposite leg on the open shift. If there is no open
  -- shift we refuse rather than delete the entry with its money still in the
  -- current drawer and no way to reconcile it.
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
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_delete_finance_entry"(uuid, text, text) TO "anon", "authenticated";

GRANT EXECUTE ON FUNCTION "public"."pos_delete_finance_entry"(uuid, text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_delete_finance_entry"(uuid, text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."pos_delete_finance_entry"(uuid, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_delete_finance_entry"(uuid, text, text) TO "postgres";

-- ---- functions/pos_demo_ledger_report.sql ----
CREATE OR REPLACE FUNCTION public.pos_demo_ledger_report()
  RETURNS TABLE (
    tenant  text,
    what    text,
    n_rows  bigint,
    n_units bigint
  )
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_demo_ledger_report"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_demo_ledger_report"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_demo_ledger_report"() TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_demo_ledger_report"() FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_ensure_shift.sql ----
CREATE OR REPLACE FUNCTION public.pos_ensure_shift (
  p_customer uuid,
  p_user     text,
  p_device   text
)
  RETURNS text
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_ensure_shift"(uuid, text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_ensure_shift"(uuid, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_ensure_shift"(uuid, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_ensure_shift"(uuid, text, text) FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_expected_cash.sql ----
CREATE OR REPLACE FUNCTION public.pos_expected_cash (
  p_customer uuid,
  p_shift_id text
)
  RETURNS bigint
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_expected_cash"(uuid, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_expected_cash"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_expected_cash"(uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_expected_cash"(uuid, text) FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_finance_person_totals.sql ----
CREATE OR REPLACE FUNCTION public.pos_finance_person_totals (
  p_customer    uuid,
  p_category_id text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_finance_person_totals"(uuid, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_finance_person_totals"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_finance_person_totals"(uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_finance_person_totals"(uuid, text) FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_is_demo.sql ----
CREATE OR REPLACE FUNCTION public.pos_is_demo (
  p_customer uuid,
  p_user     text
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.pos_users u
    WHERE u.customer_id = p_customer AND u.id = p_user AND u.is_demo
  );
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_is_demo"(uuid, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_is_demo"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_is_demo"(uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_is_demo"(uuid, text) FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_next_receipt.sql ----
CREATE OR REPLACE FUNCTION public.pos_next_receipt (
  p_customer uuid,
  p_day      text
)
  RETURNS text
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
DECLARE v bigint;
BEGIN
  INSERT INTO public.pos_counters (customer_id, name, value)
  VALUES (p_customer, 'receipt-' || p_day, 1)
  ON CONFLICT (customer_id, name)
  DO UPDATE SET value = public.pos_counters.value + 1
  RETURNING value INTO v;
  RETURN 'REC-' || p_day || '-' || lpad(v::text, 4, '0');
END;
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_next_receipt"(uuid, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_next_receipt"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_next_receipt"(uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_next_receipt"(uuid, text) FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_open_shift.sql ----
CREATE OR REPLACE FUNCTION public.pos_open_shift (
  p_customer uuid,
  p_user     text,
  p_device   text,
  p_opening  bigint
)
  RETURNS text
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_open_shift"(uuid, text, text, bigint) TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_open_shift"(uuid, text, text, bigint) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_open_shift"(uuid, text, text, bigint) TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_open_shift"(uuid, text, text, bigint) FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_product_summary.sql ----
CREATE OR REPLACE FUNCTION public.pos_product_summary (
  p_customer uuid,
  p_start    timestamp with time zone,
  p_end      timestamp with time zone
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_product_summary"(uuid, timestamp WITH time zone, timestamp WITH time zone) TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_product_summary"(uuid, timestamp WITH time zone, timestamp WITH time zone) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_product_summary"(uuid, timestamp WITH time zone, timestamp WITH time zone) TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_product_summary"(uuid, timestamp WITH time zone, timestamp WITH time zone) FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_purge_demo_ledger.sql ----
CREATE OR REPLACE FUNCTION public.pos_purge_demo_ledger()
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_purge_demo_ledger"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_purge_demo_ledger"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_purge_demo_ledger"() TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_purge_demo_ledger"() FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_reject_void.sql ----
CREATE OR REPLACE FUNCTION public.pos_reject_void (
  p_customer   uuid,
  p_user       text,
  p_request_id text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.pos_users
    WHERE customer_id = p_customer AND id = p_user
      AND role = 'OWNER' AND active = true AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Void requires owner authorization.';
  END IF;

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
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_reject_void"(uuid, text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_reject_void"(uuid, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_reject_void"(uuid, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_reject_void"(uuid, text, text) FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_revenue_trend.sql ----
CREATE OR REPLACE FUNCTION public.pos_revenue_trend (
  p_customer uuid,
  p_start    timestamp with time zone,
  p_end      timestamp with time zone
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_revenue_trend"(uuid, timestamp WITH time zone, timestamp WITH time zone) TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_revenue_trend"(uuid, timestamp WITH time zone, timestamp WITH time zone) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_revenue_trend"(uuid, timestamp WITH time zone, timestamp WITH time zone) TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_revenue_trend"(uuid, timestamp WITH time zone, timestamp WITH time zone) FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_sales_totals.sql ----
CREATE OR REPLACE FUNCTION public.pos_sales_totals (
  p_customer uuid,
  p_start    timestamp with time zone,
  p_end      timestamp with time zone
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_sales_totals"(uuid, timestamp WITH time zone, timestamp WITH time zone) TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_sales_totals"(uuid, timestamp WITH time zone, timestamp WITH time zone) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_sales_totals"(uuid, timestamp WITH time zone, timestamp WITH time zone) TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_sales_totals"(uuid, timestamp WITH time zone, timestamp WITH time zone) FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_setup_owner.sql ----
CREATE OR REPLACE FUNCTION public.pos_setup_owner (
  p_customer uuid,
  p_id       text,
  p_username text,
  p_pw_salt  text,
  p_pw_hash  text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_setup_owner"(uuid, text, text, text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_setup_owner"(uuid, text, text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_setup_owner"(uuid, text, text, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_setup_owner"(uuid, text, text, text, text) FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_shift_counters.sql ----
CREATE OR REPLACE FUNCTION public.pos_shift_counters (
  p_customer uuid,
  p_shift_id text,
  p_start    timestamp with time zone,
  p_end      timestamp with time zone
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_shift_counters"(uuid, text, timestamp WITH time zone, timestamp WITH time zone) TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_shift_counters"(uuid, text, timestamp WITH time zone, timestamp WITH time zone) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_shift_counters"(uuid, text, timestamp WITH time zone, timestamp WITH time zone) TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_shift_counters"(uuid, text, timestamp WITH time zone, timestamp WITH time zone) FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_shift_summary.sql ----
CREATE OR REPLACE FUNCTION public.pos_shift_summary (
  p_customer uuid,
  p_shift_id text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_shift_summary"(uuid, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_shift_summary"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_shift_summary"(uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_shift_summary"(uuid, text) FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_sync_apply.sql ----
CREATE OR REPLACE FUNCTION public.pos_sync_apply (
  p_customer uuid,
  p_limit    integer DEFAULT 200
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
DECLARE
  rec       record;
  applied   int := 0;
  rejected  int := 0;
  left_over int := 0;
  s         jsonb;
  items     jsonb;
  shift_id  text;
  cashier   text;
  device    text;
  actor     text;
  mv        jsonb;
  vr        jsonb;
  us        jsonb;
  pr        jsonb;
  fc        jsonb;
  fe        jsonb;
  pk        jsonb;
  pi        jsonb;
  sale_row  record;
  cat_row   record;
  user_row  record;
  pl_row    text;
  perms     jsonb;
  skipped   int := 0;
BEGIN
  FOR rec IN
    SELECT entity_type, entity_id, operation, device_id, payload
    FROM public.sync_mirror
    WHERE customer_id = p_customer AND apply_status = 'PENDING'
    -- Parents before children, whatever order they arrived in. A push stamps
    -- every row it stages with the same received_at, so ordering by arrival
    -- alone left a sale and its shift to be sequenced by a random uuid — and a
    -- collection ahead of the person it belongs to.
    ORDER BY CASE entity_type
        WHEN 'user'              THEN 0
        WHEN 'product'           THEN 1
        WHEN 'finance_category'  THEN 2
        WHEN 'shift'             THEN 3
        WHEN 'sale'              THEN 4
        WHEN 'cash_movement'     THEN 5
        WHEN 'void_request'      THEN 6
        WHEN 'finance_entry'     THEN 7
        WHEN 'picklist'          THEN 8
        WHEN 'picklist_item'     THEN 9
        ELSE 10
      END, received_at, entity_id
    LIMIT COALESCE(NULLIF(p_limit, 0), 200)
    FOR UPDATE SKIP LOCKED
  LOOP
    BEGIN
      -- A device may only delete master data it owns the lifecycle of. Ledger
      -- rows are immutable money and are refused below as they always were.
      IF upper(rec.operation) = 'DELETE'
         AND rec.entity_type <> 'finance_category' THEN
        RAISE EXCEPTION 'A device cannot delete a cloud record.';
      END IF;

      -- A training account's money stays on the till that rang it up. Clients
      -- enforce the same rule in `SyncOutbox`, but a till still running an older
      -- build keeps pushing its demo sales, and once they are in the cloud they
      -- are in every device's reports — so the gateway refuses them at the door
      -- and marks the row APPLIED, which lets that outbox entry finally leave
      -- the queue instead of being re-pushed on every sync. Master data is
      -- deliberately not covered: the demo account's own row must keep syncing,
      -- because that is how its login works on every device.
      IF rec.entity_type IN (
           'sale', 'shift', 'cash_movement', 'void_request', 'finance_entry') THEN
        actor := COALESCE(
          rec.payload->'sale'->>'cashier_id',
          rec.payload->'shift'->>'cashier_id',
          rec.payload->'cash_movement'->>'user_id',
          rec.payload->'void_request'->>'requested_by',
          rec.payload->'finance_entry'->>'created_by',
          '');
        -- A collection is two rows: the entry and the deposit that pays it. The
        -- deposit is written by whoever completed it, so if that hand was the
        -- demo account the entry has to stay too — otherwise the cloud keeps a
        -- collection marked taken with no money behind it, the exact hole
        -- `supabase_finance_movement_dedupe.sql` closed.
        IF rec.entity_type = 'finance_entry'
           AND NOT public.pos_is_demo(p_customer, actor) THEN
          actor := COALESCE(
            rec.payload->'finance_entry'->>'completed_by', '');
        END IF;
        IF public.pos_is_demo(p_customer, actor) THEN
          skipped := skipped + 1;
          UPDATE public.sync_mirror
          SET apply_status = 'APPLIED', applied_at = now(),
              apply_error = 'Training-account data stays on the till that made it.'
          WHERE customer_id = p_customer
            AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
          CONTINUE;
        END IF;
      END IF;

      IF rec.entity_type = 'sale' THEN
        s := rec.payload->'sale';
        items := rec.payload->'items';
        IF s IS NULL OR jsonb_typeof(s) <> 'object' THEN
          RAISE EXCEPTION 'Sale payload is missing its header.';
        END IF;
        IF items IS NULL OR jsonb_typeof(items) <> 'array'
           OR jsonb_array_length(items) = 0 THEN
          RAISE EXCEPTION 'Sale payload has no line items.';
        END IF;
        cashier := COALESCE(s->>'cashier_id', '');
        device  := COALESCE(NULLIF(s->>'device_id', ''), NULLIF(rec.device_id, ''), 'sync');
        -- The till owns the drawer: land the device's sale on the tenant's
        -- current open shift. pos_create_sale then recomputes every figure,
        -- checks the receipt is free and replays a repeated sale id.
        shift_id := public.pos_ensure_shift(p_customer, cashier, NULL);
        PERFORM public.pos_create_sale(
          p_customer,
          cashier,
          device,
          shift_id,
          s->>'receipt_number',
          items,
          upper(COALESCE(s->>'payment_method', 'CASH')),
          COALESCE((s->>'discount_minor_units')::bigint, 0),
          COALESCE((s->>'amount_paid_minor_units')::bigint, 0),
          NULLIF(s->>'customer_name', ''),
          rec.entity_id);

      ELSIF rec.entity_type = 'cash_movement' THEN
        mv := rec.payload->'cash_movement';
        IF mv IS NULL OR jsonb_typeof(mv) <> 'object' THEN
          RAISE EXCEPTION 'Cash movement payload is missing.';
        END IF;
        shift_id := public.pos_ensure_shift(
          p_customer, COALESCE(mv->>'user_id', ''), NULL);
        -- Both keys are handed on: the device's own movement id, so the row the
        -- till holds and the row it downloads are the same row (minting a new
        -- uuid here made the register list the deposit twice), and the collection
        -- it belongs to, so `pos_complete_finance` and this path refuse to pay
        -- the drawer twice for one collection. A movement from an older outbox
        -- carries neither, and behaves exactly as it did before.
        PERFORM public.pos_add_cash_movement(
          p_customer,
          COALESCE(mv->>'user_id', ''),
          shift_id,
          upper(COALESCE(mv->>'type', '')),
          abs(COALESCE((mv->>'amount_minor_units')::bigint, 0)),
          mv->>'reason',
          NULLIF(mv->>'photo', ''),
          rec.entity_id,
          NULLIF(mv->>'source_finance_entry_id', ''));

      ELSIF rec.entity_type = 'void_request' THEN
        vr := rec.payload->'void_request';
        IF vr IS NULL OR jsonb_typeof(vr) <> 'object' THEN
          RAISE EXCEPTION 'Void request payload is missing.';
        END IF;
        SELECT id, status INTO sale_row FROM public.sales
        WHERE customer_id = p_customer AND id = vr->>'sale_id';
        IF NOT FOUND THEN
          RAISE EXCEPTION 'The sale this void request names is not in the cloud.';
        END IF;
        IF sale_row.status <> 'COMPLETED' THEN
          RAISE EXCEPTION 'Sale % is not voidable.', sale_row.id;
        END IF;
        INSERT INTO public.void_requests (id, customer_id, sale_id, requested_by,
          reason, status, created_at, received_at)
        VALUES (rec.entity_id, p_customer, sale_row.id, COALESCE(vr->>'requested_by', ''),
          COALESCE(vr->>'reason', ''), 'PENDING',
          COALESCE((vr->>'created_at')::timestamptz, now()), now())
        ON CONFLICT (customer_id, id) DO NOTHING;

      ELSIF rec.entity_type = 'shift' THEN
        -- A device does not open or close the shop's drawer: there is one OPEN
        -- shift per tenant (shifts_one_open_per_tenant) and it belongs to the
        -- cloud, which counts it from the sales and movements it actually
        -- holds. So an OPEN report is resolved by making sure the tenant has a
        -- drawer — the identical call a sale makes, and idempotent — and a
        -- CLOSE is acknowledged without touching it. What this branch used to do
        -- is raise, which wrote a REJECTED mirror row for every shift ever
        -- opened at a till; the client acked and pruned the verdict, so the
        -- queue just grew a scar nobody could see.
        us := rec.payload->'shift';
        IF us IS NULL OR jsonb_typeof(us) <> 'object' THEN
          RAISE EXCEPTION 'Shift payload is missing.';
        END IF;
        IF upper(COALESCE(us->>'status', 'OPEN')) = 'OPEN' THEN
          PERFORM public.pos_ensure_shift(
            p_customer,
            COALESCE(us->>'cashier_id', ''),
            COALESCE(NULLIF(us->>'device_id', ''), NULLIF(rec.device_id, ''), 'sync'));
        END IF;

      -- =========================================================================
      -- Master data: mutable rows, applied newest-wins.
      -- =========================================================================

      ELSIF rec.entity_type = 'user' THEN
        us := rec.payload->'user';
        IF us IS NULL OR jsonb_typeof(us) <> 'object' THEN
          RAISE EXCEPTION 'User payload is missing.';
        END IF;
        -- The till publishes only the credential the web can verify, written by
        -- `pos-api`'s own format. Its local PBKDF2 pair never leaves the device.
        -- With no cloud credential there is nothing to publish into, so an
        -- existing row keeps the browser's password and a new row gets an
        -- unguessable one the owner has to reset.
        IF NULLIF(us->>'username', '') IS NULL THEN
          RAISE EXCEPTION 'Account payload has no login name.';
        END IF;
        -- A device may not re-privilege an account. The role is already immune
        -- (see the ON CONFLICT list); this closes the same door on status,
        -- permissions and deletion, which used to travel in the payload and let
        -- a till un-bin an operator or tick a cashier into the register audits.
        IF EXISTS (SELECT 1 FROM public.pos_users
                   WHERE customer_id = p_customer AND id = rec.entity_id) THEN
          DECLARE
            v_cur_active bool; v_cur_demo bool;
            v_cur_deleted timestamptz; v_cur_perms jsonb;
            v_new_active bool; v_new_demo bool;
            v_new_deleted timestamptz; v_new_perms jsonb;
          BEGIN
            SELECT active, is_demo, deleted_at, permissions
              INTO v_cur_active, v_cur_demo, v_cur_deleted, v_cur_perms
            FROM public.pos_users
            WHERE customer_id = p_customer AND id = rec.entity_id;

            v_new_active := COALESCE((us->>'is_active')::int, 1) = 1;
            v_new_demo := COALESCE((us->>'is_demo')::int, 0) = 1;
            v_new_deleted := (us->>'deleted_at')::timestamptz;
            v_new_perms := CASE
              WHEN btrim(COALESCE(us->>'permissions', '')) = '' THEN '[]'::jsonb
              WHEN left(btrim(us->>'permissions'), 1) IN ('[', '{')
                THEN btrim(us->>'permissions')::jsonb
              ELSE '[]'::jsonb
            END;

            IF v_new_active <> v_cur_active
               OR v_new_demo <> v_cur_demo
               OR v_new_deleted IS DISTINCT FROM v_cur_deleted
               OR v_new_perms IS DISTINCT FROM v_cur_perms
            THEN
              RAISE EXCEPTION 'Device cannot change account permissions, status, or deletion state.';
            END IF;
          END;
        END IF;
        perms := CASE
          WHEN btrim(COALESCE(us->>'permissions', '')) = '' THEN '[]'::jsonb
          WHEN left(btrim(us->>'permissions'), 1) IN ('[', '{')
            THEN btrim(us->>'permissions')::jsonb
          ELSE '[]'::jsonb
        END;
        -- `pos_users_one_owner` allows one live OWNER per tenant and the browser
        -- minted this shop's when the owner signed up there. A till cannot
        -- promote itself into that seat, so a second OWNER is acknowledged and
        -- dropped rather than rejected — it is a row the cloud already has.
        IF us->>'role' = 'OWNER' THEN
          SELECT id INTO user_row FROM public.pos_users
          WHERE customer_id = p_customer AND role = 'OWNER'
            AND deleted_at IS NULL AND id <> rec.entity_id
          LIMIT 1;
          IF FOUND THEN
            skipped := skipped + 1;
            UPDATE public.sync_mirror
            SET apply_status = 'APPLIED', applied_at = now(),
                apply_error = 'The tenant already has its owner; the role was not changed.'
            WHERE customer_id = p_customer
              AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
            applied := applied + 1;
            CONTINUE;
          END IF;
        END IF;
        -- `pos_users_customer_username` is unique per tenant: the same phone
        -- under a second id is a real collision, not a transient one, so it is
        -- reported the way the PWA reports it.
        SELECT id INTO user_row FROM public.pos_users
        WHERE customer_id = p_customer
          AND lower(username) = lower(us->>'username')
          AND id <> rec.entity_id
        LIMIT 1;
        IF FOUND THEN
          RAISE EXCEPTION 'That login is already in use by another account.';
        END IF;
        INSERT INTO public.pos_users (
          id, customer_id, username, role, pw_salt, pw_hash, active,
          permissions, is_demo, deleted_at, created_at, updated_at)
        VALUES (
          rec.entity_id, p_customer, us->>'username',
          CASE WHEN us->>'role' IN ('OWNER', 'CASHIER') THEN us->>'role' ELSE 'CASHIER' END,
          COALESCE(NULLIF(us->>'pw_salt', ''), gen_random_uuid()::text),
          COALESCE(NULLIF(us->>'pw_hash', ''), md5(random()::text || clock_timestamp()::text)),
          COALESCE((us->>'is_active')::int, 1) = 1,
          perms,
          COALESCE((us->>'is_demo')::int, 0) = 1,
          (us->>'deleted_at')::timestamptz,
          COALESCE((us->>'created_at')::timestamptz, now()),
          COALESCE((us->>'updated_at')::timestamptz, now()))
        ON CONFLICT (customer_id, id) DO UPDATE SET
          username    = EXCLUDED.username,
          -- `role` is deliberately not taken from a device: promoting a cashier
          -- is the owner's decision in the browser, and the one-owner index
          -- would reject the attempt with a confusing message anyway.
          active      = EXCLUDED.active,
          permissions = EXCLUDED.permissions,
          is_demo     = EXCLUDED.is_demo,
          deleted_at  = EXCLUDED.deleted_at,
          pw_hash     = COALESCE(NULLIF(EXCLUDED.pw_hash, ''), public.pos_users.pw_hash),
          pw_salt     = COALESCE(NULLIF(EXCLUDED.pw_salt, ''), public.pos_users.pw_salt),
          updated_at  = EXCLUDED.updated_at
        -- `IS NULL` first: a row minted before this column existed has no version
        -- at all, and `NULL < x` is NULL — which would have refused every device
        -- edit against it forever, while still answering APPLIED. The stamp now
        -- comes from the payload rather than EXCLUDED.updated_at, which the
        -- INSERT above fills with `now()` when the device sent none: that made
        -- every stamp-less push look newest and overwrite a fresher browser
        -- edit. With no stamp at all the device edit is placed one second ahead
        -- of the cloud row, so it lands but does not outrank the next real one.
        WHERE public.pos_users.updated_at IS NULL
           OR public.pos_users.updated_at <
              COALESCE((us->>'updated_at')::timestamptz,
                       public.pos_users.updated_at + interval '1 second');

      ELSIF rec.entity_type = 'product' THEN
        pr := rec.payload->'product';
        IF pr IS NULL OR jsonb_typeof(pr) <> 'object' THEN
          RAISE EXCEPTION 'Product payload is missing.';
        END IF;
        IF NULLIF(pr->>'name', '') IS NULL THEN
          RAISE EXCEPTION 'A saved name needs a name.';
        END IF;
        IF EXISTS (
          SELECT 1 FROM public.pos_products
          WHERE customer_id = p_customer AND is_active = 1
            AND lower(name) = lower(pr->>'name') AND id <> rec.entity_id) THEN
          RAISE EXCEPTION 'A saved name "%" already exists.', pr->>'name';
        END IF;
        INSERT INTO public.pos_products (
          id, customer_id, name, code, category, unit,
          selling_price_minor_units, is_active, created_at, updated_at)
        VALUES (
          rec.entity_id, p_customer, pr->>'name', pr->>'code', pr->>'category',
          pr->>'unit', COALESCE((pr->>'selling_price_minor_units')::bigint, 0),
          COALESCE((pr->>'is_active')::int, 1),
          COALESCE((pr->>'created_at')::timestamptz, now()),
          COALESCE((pr->>'updated_at')::timestamptz, now()))
        ON CONFLICT (customer_id, id) DO UPDATE SET
          name                     = EXCLUDED.name,
          code                     = EXCLUDED.code,
          category                 = EXCLUDED.category,
          unit                     = EXCLUDED.unit,
          selling_price_minor_units = EXCLUDED.selling_price_minor_units,
          is_active                = EXCLUDED.is_active,
          updated_at               = EXCLUDED.updated_at
        WHERE public.pos_products.updated_at IS NULL
           OR public.pos_products.updated_at < EXCLUDED.updated_at;

      ELSIF rec.entity_type = 'finance_category' THEN
        IF upper(rec.operation) = 'DELETE' THEN
          -- A permanent purge. `pos_delete_finance_category` is the same RPC the
          -- PWA's own permanent delete calls, so the server re-checks what it
          -- always checks and writes the audit line itself. It requires the row
          -- to be binned first, which is exactly what happened on the device —
          -- but the bin and the purge share one mirror key, so the binning
          -- re-staged as a DELETE never landed on its own. Bin it here, then
          -- purge. An unknown id is already gone: that is success, not a
          -- rejection.
          IF NOT EXISTS (SELECT 1 FROM public.pos_finance_categories
                         WHERE customer_id = p_customer AND id = rec.entity_id) THEN
            NULL;
          ELSE
            UPDATE public.pos_finance_categories
            SET deleted_at = COALESCE(deleted_at, now())
            WHERE customer_id = p_customer AND id = rec.entity_id;
            PERFORM public.pos_delete_finance_category(
              p_customer, rec.entity_id, COALESCE(rec.device_id, 'sync'));
          END IF;
        ELSE
          fc := rec.payload->'finance_category';
          IF fc IS NULL OR jsonb_typeof(fc) <> 'object' THEN
            RAISE EXCEPTION 'Finance category payload is missing.';
          END IF;
          IF NULLIF(fc->>'name', '') IS NULL THEN
            RAISE EXCEPTION 'A person needs a name.';
          END IF;
          INSERT INTO public.pos_finance_categories (
            id, customer_id, name, created_at, updated_at, deleted_at)
          VALUES (
            rec.entity_id, p_customer, fc->>'name',
            COALESCE((fc->>'created_at')::timestamptz, now()),
            COALESCE((fc->>'updated_at')::timestamptz, now()),
            (fc->>'deleted_at')::timestamptz)
          ON CONFLICT (customer_id, id) DO UPDATE SET
            name       = EXCLUDED.name,
            deleted_at = EXCLUDED.deleted_at,
            updated_at = EXCLUDED.updated_at
          WHERE public.pos_finance_categories.updated_at IS NULL
             OR public.pos_finance_categories.updated_at < EXCLUDED.updated_at;
        END IF;

      ELSIF rec.entity_type = 'finance_entry' THEN
        fe := rec.payload->'finance_entry';
        IF fe IS NULL OR jsonb_typeof(fe) <> 'object' THEN
          RAISE EXCEPTION 'Finance entry payload is missing.';
        END IF;
        SELECT id, deleted_at INTO cat_row FROM public.pos_finance_categories
        WHERE customer_id = p_customer AND id = COALESCE(fe->>'category_id', '');
        IF NOT FOUND THEN
          -- Not a refusal: the person has simply not landed yet. Leaving the
          -- entry PENDING keeps it in the mirror, where the next push's apply
          -- pass picks it up after the category branch has run. Raising here
          -- would prune it out of the device's outbox and lose a collection.
          skipped := skipped + 1;
          CONTINUE;
        END IF;
        IF cat_row.deleted_at IS NOT NULL THEN
          RAISE EXCEPTION 'The person this collection belongs to is in the recycle bin.';
        END IF;
        INSERT INTO public.pos_finance_entries (
          id, customer_id, category_id, source, amount_minor_units, description,
          status, entry_date, created_at, created_by, completed_at, completed_by,
          updated_at, payment_method)
        VALUES (
          rec.entity_id, p_customer, cat_row.id,
          COALESCE(fe->>'source', ''),
          COALESCE((fe->>'amount_minor_units')::bigint, 0),
          fe->>'description',
          upper(COALESCE(NULLIF(fe->>'status', ''), 'PENDING')),
          COALESCE((fe->>'entry_date')::timestamptz, now()),
          COALESCE((fe->>'created_at')::timestamptz, now()),
          NULLIF(fe->>'created_by', ''),
          (fe->>'completed_at')::timestamptz,
          NULLIF(fe->>'completed_by', ''),
          COALESCE((fe->>'updated_at')::timestamptz, now()),
          NULLIF(fe->>'payment_method', ''))
        ON CONFLICT (customer_id, id) DO UPDATE SET
          source             = EXCLUDED.source,
          amount_minor_units = EXCLUDED.amount_minor_units,
          description        = EXCLUDED.description,
          status             = EXCLUDED.status,
          entry_date         = EXCLUDED.entry_date,
          completed_at       = EXCLUDED.completed_at,
          completed_by       = EXCLUDED.completed_by,
          payment_method     = EXCLUDED.payment_method,
          updated_at         = EXCLUDED.updated_at
        WHERE public.pos_finance_entries.updated_at IS NULL
           OR public.pos_finance_entries.updated_at < EXCLUDED.updated_at;

      -- =========================================================================
      -- Warehouse Picklists (Digital Fulfillment): mutable rows, newest-wins.
      -- Independent of the ledger — no drawer, no revenue, no money touch.
      -- =========================================================================

      ELSIF rec.entity_type = 'picklist' THEN
        pk := rec.payload->'picklist';
        IF pk IS NULL OR jsonb_typeof(pk) <> 'object' THEN
          RAISE EXCEPTION 'Picklist payload is missing.';
        END IF;
        IF NULLIF(pk->>'customer_name', '') IS NULL THEN
          RAISE EXCEPTION 'A picklist needs a customer name.';
        END IF;
        INSERT INTO public.picklists (
          id, customer_id, customer_name, status, created_by,
          created_at, updated_at, deleted_at, received_at)
        VALUES (
          rec.entity_id, p_customer, pk->>'customer_name',
          upper(COALESCE(NULLIF(pk->>'status', ''), 'PENDING')),
          COALESCE(pk->>'created_by', ''),
          COALESCE((pk->>'created_at')::timestamptz, now()),
          COALESCE((pk->>'updated_at')::timestamptz, now()),
          NULLIF(pk->>'deleted_at', '')::timestamptz,
          now())
        ON CONFLICT (customer_id, id) DO UPDATE SET
          customer_name = EXCLUDED.customer_name,
          status        = EXCLUDED.status,
          updated_at    = EXCLUDED.updated_at,
          -- A payload without a tombstone must never clear one that already
          -- landed from another device.
          deleted_at    = COALESCE(EXCLUDED.deleted_at, public.picklists.deleted_at)
        WHERE public.picklists.updated_at IS NULL
           OR public.picklists.updated_at < EXCLUDED.updated_at;

      ELSIF rec.entity_type = 'picklist_item' THEN
        pi := rec.payload->'picklist_item';
        IF pi IS NULL OR jsonb_typeof(pi) <> 'object' THEN
          RAISE EXCEPTION 'Picklist item payload is missing.';
        END IF;
        -- `picklist_id` is a NOT NULL foreign key. The ORDER BY walks `picklist`
        -- (8) before `picklist_item` (9), so a header that arrived in this batch
        -- has already been applied. If it still is not here, the item has simply
        -- not caught up with its parent yet: leave it PENDING (deferred, not
        -- rejected) so a later apply pass picks it up once the header lands,
        -- exactly as a collection waits for its person.
        SELECT id INTO pl_row FROM public.picklists
        WHERE customer_id = p_customer AND id = COALESCE(pi->>'picklist_id', '');
        IF pl_row IS NULL THEN
          skipped := skipped + 1;
          CONTINUE;
        END IF;
        -- The pricing columns (schema 21) ride the same newest-wins row as the
        -- quantities. `unit` is a nullable label, so an absent/blank unit lands
        -- as ''; the two money columns are minor-unit integers defaulting to 0.
        INSERT INTO public.picklist_items (
          id, customer_id, picklist_id, product_name, requested_qty,
          taken_qty, unit, unit_price_minor_units, line_total_minor_units,
          updated_at, deleted_at, received_at)
        VALUES (
          rec.entity_id, p_customer, pl_row,
          COALESCE(pi->>'product_name', ''),
          COALESCE((pi->>'requested_qty')::int, 0),
          COALESCE((pi->>'taken_qty')::int, 0),
          COALESCE(pi->>'unit', ''),
          COALESCE((pi->>'unit_price_minor_units')::int, 0),
          COALESCE((pi->>'line_total_minor_units')::int, 0),
          COALESCE((pi->>'updated_at')::timestamptz, now()),
          NULLIF(pi->>'deleted_at', '')::timestamptz,
          now())
        ON CONFLICT (customer_id, id) DO UPDATE SET
          product_name  = EXCLUDED.product_name,
          requested_qty = EXCLUDED.requested_qty,
          taken_qty     = EXCLUDED.taken_qty,
          unit = EXCLUDED.unit,
          unit_price_minor_units = EXCLUDED.unit_price_minor_units,
          line_total_minor_units = EXCLUDED.line_total_minor_units,
          updated_at    = EXCLUDED.updated_at,
          deleted_at    = COALESCE(EXCLUDED.deleted_at, public.picklist_items.deleted_at)
        WHERE public.picklist_items.updated_at IS NULL
           OR public.picklist_items.updated_at < EXCLUDED.updated_at;

      ELSE
        RAISE EXCEPTION 'Unknown entity type: %', rec.entity_type;
      END IF;

      UPDATE public.sync_mirror
      SET apply_status = 'APPLIED', applied_at = now(), apply_error = NULL
      WHERE customer_id = p_customer
        AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
      applied := applied + 1;

    EXCEPTION WHEN OTHERS THEN
      UPDATE public.sync_mirror
      SET apply_status = 'REJECTED', applied_at = now(), apply_error = SQLERRM
      WHERE customer_id = p_customer
        AND entity_type = rec.entity_type AND entity_id = rec.entity_id;
      rejected := rejected + 1;
    END;
  END LOOP;

  SELECT count(*) INTO left_over FROM public.sync_mirror
  WHERE customer_id = p_customer AND apply_status = 'PENDING';

  RETURN jsonb_build_object(
    'applied', applied, 'rejected', rejected, 'pending', left_over,
    'deferred', skipped);
END;
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_sync_apply"(uuid, integer) TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_sync_apply"(uuid, integer) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_sync_apply"(uuid, integer) TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_sync_apply"(uuid, integer) FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_touch_received_at.sql ----
CREATE OR REPLACE FUNCTION public.pos_touch_received_at()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  AS $function$
BEGIN
  NEW.received_at := now();
  RETURN NEW;
END;
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_touch_received_at"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_touch_received_at"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_touch_received_at"() TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_touch_received_at"() FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_touch_user_updated_at.sql ----
CREATE OR REPLACE FUNCTION public.pos_touch_user_updated_at()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.updated_at IS NULL
       OR NEW.updated_at <= COALESCE(NEW.created_at, now()) THEN
      NEW.updated_at := now();
    END IF;
  ELSIF NEW.updated_at IS NULL
        OR OLD.updated_at IS NULL
        OR NEW.updated_at <= OLD.updated_at THEN
    NEW.updated_at := now();
  END IF;
  RETURN NEW;
END;
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_touch_user_updated_at"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_touch_user_updated_at"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_touch_user_updated_at"() TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_touch_user_updated_at"() FROM PUBLIC, "anon", "authenticated";

-- ---- functions/pos_void_sale.sql ----
CREATE OR REPLACE FUNCTION public.pos_void_sale (
  p_customer uuid,
  p_user     text,
  p_sale_id  text,
  p_reason   text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
DECLARE
  active_shift text;
  updated      int;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.pos_users
    WHERE customer_id = p_customer AND id = p_user
      AND role = 'OWNER' AND active = true AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Void requires owner authorization.';
  END IF;

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
$function$;

GRANT EXECUTE ON FUNCTION "public"."pos_void_sale"(uuid, text, text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."pos_void_sale"(uuid, text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."pos_void_sale"(uuid, text, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."pos_void_sale"(uuid, text, text, text) FROM PUBLIC, "anon", "authenticated";

-- ---- functions/rls_auto_enable.sql ----
CREATE OR REPLACE FUNCTION public.rls_auto_enable()
  RETURNS event_trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'pg_catalog'
  AS $function$
DECLARE
  cmd record;
  tbl name;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        SELECT c.relname INTO tbl FROM pg_catalog.pg_class c WHERE c.oid = cmd.objid;
        EXECUTE format('alter table if exists %I.%I enable row level security', cmd.schema_name, tbl);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$function$;

GRANT EXECUTE ON FUNCTION "public"."rls_auto_enable"() TO PUBLIC, "anon", "authenticated";

GRANT EXECUTE ON FUNCTION "public"."rls_auto_enable"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."rls_auto_enable"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."rls_auto_enable"() TO "postgres";

-- ---- functions/try_reserve_seat.sql ----
CREATE OR REPLACE FUNCTION public.try_reserve_seat (
  p_activation_code    text,
  p_device_fingerprint text,
  p_device_name        text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
declare
  v_license public.licenses%rowtype;
  v_reg     public.device_registrations%rowtype;
  v_used    int;
begin
  -- Serialize all activations for THIS code behind the license row lock.
  select * into v_license from public.licenses
    where activation_code = p_activation_code
    for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if v_license.revoked_at is not null then
    return jsonb_build_object('status', 'revoked');
  end if;
  if v_license.expires_at is not null and v_license.expires_at < now() then
    return jsonb_build_object('status', 'expired');
  end if;

  -- Existing (code, fingerprint) slot? Reuse it; never consumes a new seat.
  select * into v_reg from public.device_registrations
    where activation_code = p_activation_code
      and device_fingerprint = p_device_fingerprint;
  if found then
    if v_reg.revoked_at is null then
      update public.device_registrations
        set last_heartbeat = now(), device_name = p_device_name
        where id = v_reg.id;
      select count(*) into v_used from public.device_registrations
        where activation_code = p_activation_code and revoked_at is null;
      return jsonb_build_object('status', 'refreshed', 'seats_used', v_used,
        'seat_limit', v_license.seat_limit, 'customer_id', v_license.customer_id,
        'expires_at', v_license.expires_at);
    else
      update public.device_registrations
        set revoked_at = null, last_heartbeat = now(), device_name = p_device_name
        where id = v_reg.id;
      select count(*) into v_used from public.device_registrations
        where activation_code = p_activation_code and revoked_at is null;
      return jsonb_build_object('status', 'reactivated', 'seats_used', v_used,
        'seat_limit', v_license.seat_limit, 'customer_id', v_license.customer_id,
        'expires_at', v_license.expires_at);
    end if;
  end if;

  -- Brand-new device: count under the held lock, then decide.
  select count(*) into v_used from public.device_registrations
    where activation_code = p_activation_code and revoked_at is null;
  if v_used >= v_license.seat_limit then
    return jsonb_build_object('status', 'seat_limit', 'seats_used', v_used,
      'seat_limit', v_license.seat_limit);
  end if;

  insert into public.device_registrations
    (activation_code, device_fingerprint, device_name, last_heartbeat)
    values (p_activation_code, p_device_fingerprint, p_device_name, now());
  return jsonb_build_object('status', 'activated', 'seats_used', v_used + 1,
    'seat_limit', v_license.seat_limit, 'customer_id', v_license.customer_id,
    'expires_at', v_license.expires_at);
end;
$function$;

GRANT EXECUTE ON FUNCTION "public"."try_reserve_seat"(text, text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."try_reserve_seat"(text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."try_reserve_seat"(text, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "public"."try_reserve_seat"(text, text, text) FROM PUBLIC, "anon", "authenticated";

-- ---- tables/users.sql ----
CREATE TABLE "public"."users" (
  "id"               uuid                     NOT NULL,
  "username"         text                     NOT NULL,
  "password_hash"    text                     NOT NULL,
  "salt"             text                     NOT NULL,
  "role"             text                     NOT NULL,
  "is_active"        boolean                  NOT NULL DEFAULT true,
  "created_at"       timestamp with time zone NOT NULL,
  "origin_device_id" uuid,
  "received_at"      timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "users_pkey" PRIMARY KEY (id),
  CONSTRAINT "users_role_check" CHECK ((role = ANY (ARRAY['OWNER'::text, 'CASHIER'::text]))),
  CONSTRAINT "users_username_key" UNIQUE (username)
);

ALTER TABLE "public"."users"
  ENABLE ROW LEVEL SECURITY;

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."users" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."users" TO "service_role";

REVOKE ALL ON TABLE "public"."users" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."users" TO "postgres";

-- ---- tables/customers.sql ----
CREATE TABLE "public"."customers" (
  "id"         uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "name"       text                     NOT NULL,
  "contact"    text,
  "notes"      text,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "customers_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."customers"
  ENABLE ROW LEVEL SECURITY;

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."customers" TO "service_role";

REVOKE ALL ON TABLE "public"."customers" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."customers" TO "postgres";

REVOKE ALL ON TABLE "public"."customers" FROM "anon", "authenticated";

-- ---- tables/licenses.sql ----
CREATE TABLE "public"."licenses" (
  "activation_code" text                     NOT NULL,
  "customer_id"     uuid                     NOT NULL,
  "seat_limit"      integer                  NOT NULL DEFAULT 3,
  "expires_at"      timestamp with time zone,
  "revoked_at"      timestamp with time zone,
  "created_at"      timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "licenses_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE,
  CONSTRAINT "licenses_pkey" PRIMARY KEY (activation_code),
  CONSTRAINT "licenses_seat_limit_check" CHECK ((seat_limit >= 1))
);

ALTER TABLE "public"."licenses"
  ENABLE ROW LEVEL SECURITY;

CREATE INDEX licenses_customer_idx ON public.licenses USING btree (customer_id);

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."licenses" TO "service_role";

REVOKE ALL ON TABLE "public"."licenses" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."licenses" TO "postgres";

REVOKE ALL ON TABLE "public"."licenses" FROM "anon", "authenticated";

-- ---- tables/finance_categories.sql ----
CREATE TABLE "public"."finance_categories" (
  "id"               uuid                     NOT NULL,
  "name"             text                     NOT NULL,
  "created_at"       timestamp with time zone NOT NULL,
  "updated_at"       timestamp with time zone NOT NULL,
  "origin_device_id" uuid,
  "received_at"      timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "finance_categories_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."finance_categories"
  ENABLE ROW LEVEL SECURITY;

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."finance_categories" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."finance_categories" TO "service_role";

REVOKE ALL ON TABLE "public"."finance_categories" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."finance_categories" TO "postgres";

-- ---- tables/audit_logs.sql ----
CREATE TABLE "public"."audit_logs" (
  "id"               uuid                     NOT NULL,
  "user_id"          uuid,
  "action"           text                     NOT NULL,
  "details"          text,
  "created_at"       timestamp with time zone NOT NULL,
  "origin_device_id" uuid,
  "received_at"      timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "audit_logs_pkey" PRIMARY KEY (id),
  CONSTRAINT "audit_logs_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.users(id)
);

ALTER TABLE "public"."audit_logs"
  ENABLE ROW LEVEL SECURITY;

CREATE INDEX audit_logs_created_at ON public.audit_logs USING btree (created_at);

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."audit_logs" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."audit_logs" TO "service_role";

REVOKE ALL ON TABLE "public"."audit_logs" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."audit_logs" TO "postgres";

-- ---- tables/cash_movements.sql ----
CREATE TABLE "public"."cash_movements" (
  "id"                      text                     NOT NULL,
  "customer_id"             uuid                     NOT NULL,
  "shift_id"                text                     NOT NULL,
  "type"                    text                     NOT NULL,
  "amount_minor_units"      bigint                   NOT NULL,
  "reason"                  text,
  "created_at"              timestamp with time zone NOT NULL,
  "user_id"                 text,
  "origin_device_id"        text,
  "received_at"             timestamp with time zone NOT NULL DEFAULT now(),
  "photo"                   text,
  "source_finance_entry_id" text,
  CONSTRAINT "cash_movements_pkey" PRIMARY KEY (customer_id, id),
  CONSTRAINT "cash_movements_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(id)
);

ALTER TABLE "public"."cash_movements"
  ENABLE ROW LEVEL SECURITY;

CREATE UNIQUE INDEX cash_movements_one_per_finance_entry ON public.cash_movements USING btree (customer_id, source_finance_entry_id)
  WHERE (source_finance_entry_id IS NOT NULL);

CREATE INDEX cm_customer_shift ON public.cash_movements USING btree (customer_id, shift_id);

CREATE TRIGGER touch_received_at
  BEFORE UPDATE ON public.cash_movements
  FOR EACH ROW
  EXECUTE FUNCTION public.pos_touch_received_at();

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."cash_movements" TO "service_role";

REVOKE ALL ON TABLE "public"."cash_movements" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."cash_movements" TO "postgres";

REVOKE ALL ON TABLE "public"."cash_movements" FROM "anon", "authenticated";

-- ---- tables/demo_purge_rows.sql ----
CREATE TABLE "public"."demo_purge_rows" (
  "purge_customer" uuid                     NOT NULL,
  "entity"         text                     NOT NULL,
  "row_id"         text                     NOT NULL,
  "data"           jsonb                    NOT NULL,
  "archived_at"    timestamp with time zone NOT NULL DEFAULT now()
);

ALTER TABLE "public"."demo_purge_rows"
  ENABLE ROW LEVEL SECURITY;

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."demo_purge_rows" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."demo_purge_rows" TO "service_role";

REVOKE ALL ON TABLE "public"."demo_purge_rows" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."demo_purge_rows" TO "postgres";

-- ---- tables/device_registrations.sql ----
CREATE TABLE "public"."device_registrations" (
  "id"                 uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "activation_code"    text                     NOT NULL,
  "device_fingerprint" text                     NOT NULL,
  "device_name"        text,
  "first_seen"         timestamp with time zone NOT NULL DEFAULT now(),
  "last_heartbeat"     timestamp with time zone,
  "revoked_at"         timestamp with time zone,
  CONSTRAINT "device_registrations_pkey" PRIMARY KEY (id),
  CONSTRAINT "device_registrations_activation_code_fkey" FOREIGN KEY (activation_code) REFERENCES public.licenses(activation_code) ON DELETE CASCADE
);

ALTER TABLE "public"."device_registrations"
  ENABLE ROW LEVEL SECURITY;

CREATE UNIQUE INDEX device_reg_active_unique ON public.device_registrations USING btree (activation_code, device_fingerprint)
  WHERE (revoked_at IS NULL);

CREATE INDEX device_reg_code_idx ON public.device_registrations USING btree (activation_code)
  WHERE (revoked_at IS NULL);

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."device_registrations" TO "service_role";

REVOKE ALL ON TABLE "public"."device_registrations" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."device_registrations" TO "postgres";

REVOKE ALL ON TABLE "public"."device_registrations" FROM "anon", "authenticated";

-- ---- tables/devices.sql ----
CREATE TABLE "public"."devices" (
  "id"           uuid                     NOT NULL,
  "name"         text                     NOT NULL,
  "platform"     text                     NOT NULL,
  "license_key"  text,
  "last_sync_at" timestamp with time zone,
  "received_at"  timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "devices_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."devices"
  ENABLE ROW LEVEL SECURITY;

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."devices" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."devices" TO "service_role";

REVOKE ALL ON TABLE "public"."devices" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."devices" TO "postgres";

-- ---- tables/finance_entries.sql ----
CREATE TABLE "public"."finance_entries" (
  "id"                 uuid                     NOT NULL,
  "category_id"        uuid                     NOT NULL,
  "source"             text                     NOT NULL,
  "amount_minor_units" bigint                   NOT NULL,
  "description"        text,
  "status"             text                     NOT NULL DEFAULT 'PENDING'::text,
  "entry_date"         timestamp with time zone NOT NULL,
  "created_at"         timestamp with time zone NOT NULL,
  "created_by"         uuid                     NOT NULL,
  "completed_at"       timestamp with time zone,
  "completed_by"       uuid,
  "updated_at"         timestamp with time zone NOT NULL,
  "origin_device_id"   uuid,
  "received_at"        timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "finance_entries_category_id_fkey" FOREIGN KEY (category_id) REFERENCES public.finance_categories(id),
  CONSTRAINT "finance_entries_pkey" PRIMARY KEY (id),
  CONSTRAINT "finance_entries_completed_by_fkey" FOREIGN KEY (completed_by) REFERENCES public.users(id),
  CONSTRAINT "finance_entries_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public.users(id)
);

ALTER TABLE "public"."finance_entries"
  ENABLE ROW LEVEL SECURITY;

CREATE INDEX finance_entries_cat ON public.finance_entries USING btree (category_id);

CREATE INDEX finance_entries_date ON public.finance_entries USING btree (entry_date);

CREATE INDEX finance_entries_status ON public.finance_entries USING btree (status);

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."finance_entries" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."finance_entries" TO "service_role";

REVOKE ALL ON TABLE "public"."finance_entries" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."finance_entries" TO "postgres";

-- ---- tables/license_audit.sql ----
CREATE TABLE "public"."license_audit" (
  "id"                 bigint                   GENERATED ALWAYS AS IDENTITY NOT NULL,
  "activation_code"    text                     NOT NULL,
  "device_fingerprint" text,
  "event"              text                     NOT NULL,
  "detail"             jsonb,
  "occurred_at"        timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "license_audit_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."license_audit"
  ENABLE ROW LEVEL SECURITY;

CREATE INDEX license_audit_code_idx ON public.license_audit USING btree (activation_code, occurred_at DESC);

REVOKE ALL ON SEQUENCE "public"."license_audit_id_seq" FROM "anon";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE "public"."license_audit_id_seq" TO "anon";

REVOKE ALL ON SEQUENCE "public"."license_audit_id_seq" FROM "authenticated";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE "public"."license_audit_id_seq" TO "authenticated";

REVOKE ALL ON SEQUENCE "public"."license_audit_id_seq" FROM "postgres";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE "public"."license_audit_id_seq" TO "postgres";

REVOKE ALL ON SEQUENCE "public"."license_audit_id_seq" FROM "service_role";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE "public"."license_audit_id_seq" TO "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."license_audit" TO "service_role";

REVOKE ALL ON TABLE "public"."license_audit" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."license_audit" TO "postgres";

REVOKE ALL ON TABLE "public"."license_audit" FROM "anon", "authenticated";

-- ---- tables/migration_markers.sql ----
CREATE TABLE "public"."migration_markers" (
  "key"        text                     NOT NULL,
  "applied_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "migration_markers_pkey" PRIMARY KEY (key)
);

ALTER TABLE "public"."migration_markers"
  ENABLE ROW LEVEL SECURITY;

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."migration_markers" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."migration_markers" TO "service_role";

REVOKE ALL ON TABLE "public"."migration_markers" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."migration_markers" TO "postgres";

-- ---- tables/picklist_customers.sql ----
CREATE TABLE "public"."picklist_customers" (
  "id"          text                     NOT NULL,
  "customer_id" uuid                     NOT NULL,
  "name"        text                     NOT NULL,
  "phone"       text,
  "created_at"  timestamp with time zone NOT NULL DEFAULT now(),
  "received_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "picklist_customers_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(id),
  CONSTRAINT "picklist_customers_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."picklist_customers"
  ENABLE ROW LEVEL SECURITY;

CREATE UNIQUE INDEX picklist_customers_customer_id ON public.picklist_customers USING btree (customer_id, id);

CREATE INDEX picklist_customers_customer_name ON public.picklist_customers USING btree (customer_id, lower(name));

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."picklist_customers" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."picklist_customers" TO "service_role";

REVOKE ALL ON TABLE "public"."picklist_customers" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."picklist_customers" TO "postgres";

-- ---- tables/picklists.sql ----
CREATE TABLE "public"."picklists" (
  "id"            text                     NOT NULL,
  "customer_id"   uuid                     NOT NULL,
  "customer_name" text                     NOT NULL,
  "status"        text                     NOT NULL DEFAULT 'PENDING'::text,
  "created_by"    text                     NOT NULL,
  "created_at"    timestamp with time zone NOT NULL DEFAULT now(),
  "updated_at"    timestamp with time zone NOT NULL DEFAULT now(),
  "received_at"   timestamp with time zone NOT NULL DEFAULT now(),
  "deleted_at"    timestamp with time zone,
  CONSTRAINT "picklists_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(id),
  CONSTRAINT "picklists_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."picklists"
  ENABLE ROW LEVEL SECURITY;

CREATE UNIQUE INDEX picklists_customer_id ON public.picklists USING btree (customer_id, id);

CREATE INDEX picklists_customer_received ON public.picklists USING btree (customer_id, received_at, id);

CREATE TRIGGER touch_received_at
  BEFORE UPDATE ON public.picklists
  FOR EACH ROW
  EXECUTE FUNCTION public.pos_touch_received_at();

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."picklists" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."picklists" TO "service_role";

REVOKE ALL ON TABLE "public"."picklists" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."picklists" TO "postgres";

-- ---- tables/picklist_items.sql ----
CREATE TABLE "public"."picklist_items" (
  "id"                     text                     NOT NULL,
  "customer_id"            uuid                     NOT NULL,
  "picklist_id"            text                     NOT NULL,
  "product_name"           text                     NOT NULL,
  "requested_qty"          integer                  NOT NULL,
  "taken_qty"              integer                  NOT NULL DEFAULT 0,
  "updated_at"             timestamp with time zone NOT NULL DEFAULT now(),
  "received_at"            timestamp with time zone NOT NULL DEFAULT now(),
  "unit"                   text,
  "unit_price_minor_units" integer                  NOT NULL DEFAULT 0,
  "line_total_minor_units" integer                  NOT NULL DEFAULT 0,
  "deleted_at"             timestamp with time zone,
  CONSTRAINT "picklist_items_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(id),
  CONSTRAINT "picklist_items_pkey" PRIMARY KEY (id),
  CONSTRAINT "picklist_items_picklist_id_fkey" FOREIGN KEY (picklist_id) REFERENCES public.picklists(id) ON DELETE CASCADE
);

ALTER TABLE "public"."picklist_items"
  ENABLE ROW LEVEL SECURITY;

CREATE UNIQUE INDEX picklist_items_customer_id ON public.picklist_items USING btree (customer_id, id);

CREATE INDEX picklist_items_customer_received ON public.picklist_items USING btree (customer_id, received_at, id);

CREATE TRIGGER touch_received_at
  BEFORE UPDATE ON public.picklist_items
  FOR EACH ROW
  EXECUTE FUNCTION public.pos_touch_received_at();

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."picklist_items" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."picklist_items" TO "service_role";

REVOKE ALL ON TABLE "public"."picklist_items" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."picklist_items" TO "postgres";

-- ---- tables/pos_audit_logs.sql ----
CREATE TABLE "public"."pos_audit_logs" (
  "id"          text                     NOT NULL,
  "customer_id" uuid                     NOT NULL,
  "user_id"     text,
  "action"      text                     NOT NULL,
  "details"     text,
  "created_at"  timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "pos_audit_logs_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE,
  CONSTRAINT "pos_audit_logs_pkey" PRIMARY KEY (customer_id, id)
);

ALTER TABLE "public"."pos_audit_logs"
  ENABLE ROW LEVEL SECURITY;

CREATE INDEX pos_audit_logs_customer_created ON public.pos_audit_logs USING btree (customer_id, created_at DESC);

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."pos_audit_logs" TO "service_role";

REVOKE ALL ON TABLE "public"."pos_audit_logs" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."pos_audit_logs" TO "postgres";

REVOKE ALL ON TABLE "public"."pos_audit_logs" FROM "anon", "authenticated";

-- ---- tables/pos_counters.sql ----
CREATE TABLE "public"."pos_counters" (
  "customer_id" uuid   NOT NULL,
  "name"        text   NOT NULL,
  "value"       bigint NOT NULL,
  CONSTRAINT "pos_counters_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE,
  CONSTRAINT "pos_counters_pkey" PRIMARY KEY (customer_id, name)
);

ALTER TABLE "public"."pos_counters"
  ENABLE ROW LEVEL SECURITY;

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."pos_counters" TO "service_role";

REVOKE ALL ON TABLE "public"."pos_counters" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."pos_counters" TO "postgres";

REVOKE ALL ON TABLE "public"."pos_counters" FROM "anon", "authenticated";

-- ---- tables/pos_finance_categories.sql ----
CREATE TABLE "public"."pos_finance_categories" (
  "id"          text                     NOT NULL,
  "customer_id" uuid                     NOT NULL,
  "name"        text                     NOT NULL,
  "created_at"  timestamp with time zone NOT NULL,
  "updated_at"  timestamp with time zone,
  "deleted_at"  timestamp with time zone,
  "received_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "pos_finance_categories_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE,
  CONSTRAINT "pos_finance_categories_pkey" PRIMARY KEY (customer_id, id)
);

ALTER TABLE "public"."pos_finance_categories"
  ENABLE ROW LEVEL SECURITY;

CREATE INDEX pos_finance_categories_customer_received ON public.pos_finance_categories USING btree (customer_id, received_at, id);

CREATE TRIGGER touch_received_at
  BEFORE UPDATE ON public.pos_finance_categories
  FOR EACH ROW
  EXECUTE FUNCTION public.pos_touch_received_at();

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."pos_finance_categories" TO "service_role";

REVOKE ALL ON TABLE "public"."pos_finance_categories" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."pos_finance_categories" TO "postgres";

REVOKE ALL ON TABLE "public"."pos_finance_categories" FROM "anon", "authenticated";

-- ---- tables/pos_finance_entries.sql ----
CREATE TABLE "public"."pos_finance_entries" (
  "id"                 text                     NOT NULL,
  "customer_id"        uuid                     NOT NULL,
  "category_id"        text                     NOT NULL,
  "source"             text                     NOT NULL,
  "amount_minor_units" bigint                   NOT NULL,
  "description"        text,
  "status"             text                     NOT NULL DEFAULT 'PENDING'::text,
  "entry_date"         timestamp with time zone NOT NULL,
  "created_at"         timestamp with time zone NOT NULL,
  "created_by"         text,
  "completed_at"       timestamp with time zone,
  "completed_by"       text,
  "updated_at"         timestamp with time zone,
  "payment_method"     text,
  "received_at"        timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "pos_finance_entries_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE,
  CONSTRAINT "pos_finance_entries_pkey" PRIMARY KEY (customer_id, id)
);

ALTER TABLE "public"."pos_finance_entries"
  ENABLE ROW LEVEL SECURITY;

CREATE INDEX pos_finance_entries_customer_cat ON public.pos_finance_entries USING btree (customer_id, category_id);

CREATE INDEX pos_finance_entries_customer_received ON public.pos_finance_entries USING btree (customer_id, received_at, id);

CREATE TRIGGER touch_received_at
  BEFORE UPDATE ON public.pos_finance_entries
  FOR EACH ROW
  EXECUTE FUNCTION public.pos_touch_received_at();

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."pos_finance_entries" TO "service_role";

REVOKE ALL ON TABLE "public"."pos_finance_entries" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."pos_finance_entries" TO "postgres";

REVOKE ALL ON TABLE "public"."pos_finance_entries" FROM "anon", "authenticated";

-- ---- tables/pos_products.sql ----
CREATE TABLE "public"."pos_products" (
  "id"                        text                     NOT NULL,
  "customer_id"               uuid                     NOT NULL,
  "name"                      text                     NOT NULL,
  "code"                      text,
  "category"                  text,
  "unit"                      text,
  "selling_price_minor_units" bigint                   NOT NULL DEFAULT 0,
  "is_active"                 integer                  NOT NULL DEFAULT 1,
  "created_at"                timestamp with time zone NOT NULL,
  "updated_at"                timestamp with time zone,
  "received_at"               timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "pos_products_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE,
  CONSTRAINT "pos_products_pkey" PRIMARY KEY (customer_id, id)
);

ALTER TABLE "public"."pos_products"
  ENABLE ROW LEVEL SECURITY;

CREATE INDEX pos_products_customer_active ON public.pos_products USING btree (customer_id, is_active);

CREATE UNIQUE INDEX pos_products_customer_name_active ON public.pos_products USING btree (customer_id, lower(name))
  WHERE (is_active = 1);

CREATE INDEX pos_products_customer_received ON public.pos_products USING btree (customer_id, received_at, id);

CREATE TRIGGER touch_received_at
  BEFORE UPDATE ON public.pos_products
  FOR EACH ROW
  EXECUTE FUNCTION public.pos_touch_received_at();

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."pos_products" TO "service_role";

REVOKE ALL ON TABLE "public"."pos_products" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."pos_products" TO "postgres";

REVOKE ALL ON TABLE "public"."pos_products" FROM "anon", "authenticated";

-- ---- tables/pos_settings.sql ----
CREATE TABLE "public"."pos_settings" (
  "customer_id" uuid NOT NULL,
  "key"         text NOT NULL,
  "value"       text,
  CONSTRAINT "pos_settings_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE,
  CONSTRAINT "pos_settings_pkey" PRIMARY KEY (customer_id, key)
);

ALTER TABLE "public"."pos_settings"
  ENABLE ROW LEVEL SECURITY;

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."pos_settings" TO "service_role";

REVOKE ALL ON TABLE "public"."pos_settings" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."pos_settings" TO "postgres";

REVOKE ALL ON TABLE "public"."pos_settings" FROM "anon", "authenticated";

-- ---- tables/pos_users.sql ----
CREATE TABLE "public"."pos_users" (
  "id"            text                     NOT NULL,
  "customer_id"   uuid                     NOT NULL,
  "username"      text                     NOT NULL,
  "role"          text                     NOT NULL,
  "pw_salt"       text                     NOT NULL,
  "pw_hash"       text                     NOT NULL,
  "active"        boolean                  NOT NULL DEFAULT true,
  "created_at"    timestamp with time zone NOT NULL DEFAULT now(),
  "token_version" integer                  NOT NULL DEFAULT 0,
  "permissions"   jsonb                    NOT NULL DEFAULT '[]'::jsonb,
  "is_demo"       boolean                  NOT NULL DEFAULT false,
  "deleted_at"    timestamp with time zone,
  "received_at"   timestamp with time zone NOT NULL DEFAULT now(),
  "updated_at"    timestamp with time zone,
  CONSTRAINT "pos_users_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE,
  CONSTRAINT "pos_users_pkey" PRIMARY KEY (customer_id, id),
  CONSTRAINT "pos_users_role_check" CHECK ((role = ANY (ARRAY['OWNER'::text, 'CASHIER'::text])))
);

ALTER TABLE "public"."pos_users"
  ENABLE ROW LEVEL SECURITY;

CREATE INDEX pos_users_customer_active ON public.pos_users USING btree (customer_id, active);

CREATE INDEX pos_users_customer_received ON public.pos_users USING btree (customer_id, received_at, id);

CREATE UNIQUE INDEX pos_users_customer_username ON public.pos_users USING btree (customer_id, lower(username));

CREATE UNIQUE INDEX pos_users_one_owner ON public.pos_users USING btree (customer_id)
  WHERE ((ROLE = 'OWNER'::text) AND (deleted_at IS NULL));

CREATE TRIGGER touch_received_at
  BEFORE UPDATE ON public.pos_users
  FOR EACH ROW
  EXECUTE FUNCTION public.pos_touch_received_at();

CREATE TRIGGER touch_user_updated_at
  BEFORE INSERT OR UPDATE ON public.pos_users
  FOR EACH ROW
  EXECUTE FUNCTION public.pos_touch_user_updated_at();

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."pos_users" TO "service_role";

REVOKE ALL ON TABLE "public"."pos_users" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."pos_users" TO "postgres";

REVOKE ALL ON TABLE "public"."pos_users" FROM "anon", "authenticated";

-- ---- tables/products.sql ----
CREATE TABLE "public"."products" (
  "id"                        uuid                     NOT NULL,
  "name"                      text                     NOT NULL,
  "code"                      text                     NOT NULL,
  "category"                  text,
  "unit"                      text                     NOT NULL,
  "selling_price_minor_units" bigint                   NOT NULL,
  "is_active"                 boolean                  NOT NULL DEFAULT true,
  "created_at"                timestamp with time zone NOT NULL,
  "updated_at"                timestamp with time zone NOT NULL,
  "origin_device_id"          uuid,
  "received_at"               timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "products_code_key" UNIQUE (code),
  CONSTRAINT "products_pkey" PRIMARY KEY (id),
  CONSTRAINT "products_selling_price_minor_units_check" CHECK ((selling_price_minor_units >= 0))
);

ALTER TABLE "public"."products"
  ENABLE ROW LEVEL SECURITY;

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."products" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."products" TO "service_role";

REVOKE ALL ON TABLE "public"."products" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."products" TO "postgres";

-- ---- tables/sale_items.sql ----
CREATE TABLE "public"."sale_items" (
  "id"                              text                     NOT NULL,
  "customer_id"                     uuid                     NOT NULL,
  "sale_id"                         text                     NOT NULL,
  "product_id"                      text                     NOT NULL,
  "product_name_snapshot"           text                     NOT NULL,
  "unit_price_snapshot_minor_units" bigint                   NOT NULL,
  "quantity_text"                   text                     NOT NULL,
  "billing_quantity_milliunits"     bigint,
  "line_discount_minor_units"       bigint                   NOT NULL DEFAULT 0,
  "line_total_minor_units"          bigint                   NOT NULL,
  "notes"                           text,
  "origin_device_id"                text,
  "received_at"                     timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "sale_items_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(id),
  CONSTRAINT "sale_items_pkey" PRIMARY KEY (customer_id, id)
);

ALTER TABLE "public"."sale_items"
  ENABLE ROW LEVEL SECURITY;

CREATE INDEX items_customer_sale ON public.sale_items USING btree (customer_id, sale_id);

CREATE TRIGGER touch_received_at
  BEFORE UPDATE ON public.sale_items
  FOR EACH ROW
  EXECUTE FUNCTION public.pos_touch_received_at();

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."sale_items" TO "service_role";

REVOKE ALL ON TABLE "public"."sale_items" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."sale_items" TO "postgres";

REVOKE ALL ON TABLE "public"."sale_items" FROM "anon", "authenticated";

-- ---- tables/sales.sql ----
CREATE TABLE "public"."sales" (
  "id"                      text                     NOT NULL,
  "customer_id"             uuid                     NOT NULL,
  "receipt_number"          text                     NOT NULL,
  "cashier_id"              text                     NOT NULL,
  "device_id"               text                     NOT NULL,
  "shift_id"                text                     NOT NULL,
  "customer_name"           text,
  "payment_method"          text                     NOT NULL DEFAULT 'CASH'::text,
  "subtotal_minor_units"    bigint                   NOT NULL,
  "discount_minor_units"    bigint                   NOT NULL,
  "total_minor_units"       bigint                   NOT NULL,
  "amount_paid_minor_units" bigint                   NOT NULL,
  "change_minor_units"      bigint                   NOT NULL,
  "status"                  text                     NOT NULL,
  "void_reason"             text,
  "voided_at"               timestamp with time zone,
  "voided_by"               text,
  "voided_shift_id"         text,
  "created_at"              timestamp with time zone NOT NULL,
  "synced_at"               timestamp with time zone,
  "origin_device_id"        text,
  "received_at"             timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "sales_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(id),
  CONSTRAINT "sales_pkey" PRIMARY KEY (customer_id, id)
);

ALTER TABLE "public"."sales"
  ENABLE ROW LEVEL SECURITY;

CREATE INDEX sales_customer_created ON public.sales USING btree (customer_id, created_at);

CREATE INDEX sales_customer_shift ON public.sales USING btree (customer_id, shift_id);

CREATE UNIQUE INDEX sales_receipt_per_device ON public.sales USING btree (customer_id, device_id, receipt_number);

CREATE TRIGGER touch_received_at
  BEFORE UPDATE ON public.sales
  FOR EACH ROW
  EXECUTE FUNCTION public.pos_touch_received_at();

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."sales" TO "service_role";

REVOKE ALL ON TABLE "public"."sales" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."sales" TO "postgres";

REVOKE ALL ON TABLE "public"."sales" FROM "anon", "authenticated";

-- ---- tables/seat_vouchers.sql ----
CREATE TABLE "public"."seat_vouchers" (
  "voucher_code"    text                     NOT NULL,
  "activation_code" text                     NOT NULL,
  "seats_added"     integer                  NOT NULL,
  "created_at"      timestamp with time zone NOT NULL DEFAULT now(),
  "redeemed_at"     timestamp with time zone,
  CONSTRAINT "seat_vouchers_activation_code_fkey" FOREIGN KEY (activation_code) REFERENCES public.licenses(activation_code) ON DELETE CASCADE,
  CONSTRAINT "seat_vouchers_pkey" PRIMARY KEY (voucher_code),
  CONSTRAINT "seat_vouchers_seats_added_check" CHECK ((seats_added >= 1))
);

ALTER TABLE "public"."seat_vouchers"
  ENABLE ROW LEVEL SECURITY;

CREATE INDEX seat_voucher_code_idx ON public.seat_vouchers USING btree (activation_code)
  WHERE (redeemed_at IS NULL);

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."seat_vouchers" TO "service_role";

REVOKE ALL ON TABLE "public"."seat_vouchers" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."seat_vouchers" TO "postgres";

REVOKE ALL ON TABLE "public"."seat_vouchers" FROM "anon", "authenticated";

-- ---- tables/shifts.sql ----
CREATE TABLE "public"."shifts" (
  "id"                        text                     NOT NULL,
  "customer_id"               uuid                     NOT NULL,
  "cashier_id"                text                     NOT NULL,
  "opening_cash_minor_units"  bigint                   NOT NULL,
  "closing_cash_minor_units"  bigint,
  "expected_cash_minor_units" bigint,
  "status"                    text                     NOT NULL,
  "opened_at"                 timestamp with time zone NOT NULL,
  "closed_at"                 timestamp with time zone,
  "origin_device_id"          text,
  "received_at"               timestamp with time zone NOT NULL DEFAULT now(),
  "device_id"                 text,
  CONSTRAINT "shifts_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(id),
  CONSTRAINT "shifts_pkey" PRIMARY KEY (customer_id, id)
);

ALTER TABLE "public"."shifts"
  ENABLE ROW LEVEL SECURITY;

CREATE UNIQUE INDEX shifts_one_open_per_device ON public.shifts USING btree (customer_id, device_id)
  WHERE ((status = 'OPEN'::text) AND (device_id IS NOT NULL));

CREATE UNIQUE INDEX shifts_one_open_per_tenant ON public.shifts USING btree (customer_id)
  WHERE (status = 'OPEN'::text);

CREATE TRIGGER touch_received_at
  BEFORE UPDATE ON public.shifts
  FOR EACH ROW
  EXECUTE FUNCTION public.pos_touch_received_at();

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."shifts" TO "service_role";

REVOKE ALL ON TABLE "public"."shifts" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."shifts" TO "postgres";

REVOKE ALL ON TABLE "public"."shifts" FROM "anon", "authenticated";

-- ---- tables/sync_mirror.sql ----
CREATE TABLE "public"."sync_mirror" (
  "customer_id"  uuid                     NOT NULL,
  "entity_type"  text                     NOT NULL,
  "entity_id"    text                     NOT NULL,
  "operation"    text                     NOT NULL DEFAULT 'UPSERT'::text,
  "device_id"    text,
  "payload"      jsonb                    NOT NULL,
  "received_at"  timestamp with time zone NOT NULL DEFAULT now(),
  "apply_status" text                     NOT NULL DEFAULT 'PENDING'::text,
  "apply_error"  text,
  "applied_at"   timestamp with time zone,
  CONSTRAINT "sync_mirror_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(id),
  CONSTRAINT "sync_mirror_operation_check" CHECK ((operation = ANY (ARRAY['UPSERT'::text, 'DELETE'::text]))),
  CONSTRAINT "sync_mirror_pkey" PRIMARY KEY (customer_id, entity_type, entity_id)
);

ALTER TABLE "public"."sync_mirror"
  ENABLE ROW LEVEL SECURITY;

CREATE INDEX sync_mirror_pending ON public.sync_mirror USING btree (customer_id, received_at)
  WHERE (apply_status = 'PENDING'::text);

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."sync_mirror" TO "service_role";

REVOKE ALL ON TABLE "public"."sync_mirror" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."sync_mirror" TO "postgres";

REVOKE ALL ON TABLE "public"."sync_mirror" FROM "anon", "authenticated";

-- ---- tables/void_requests.sql ----
CREATE TABLE "public"."void_requests" (
  "id"               text                     NOT NULL,
  "customer_id"      uuid                     NOT NULL,
  "sale_id"          text                     NOT NULL,
  "requested_by"     text                     NOT NULL,
  "reason"           text                     NOT NULL,
  "status"           text                     NOT NULL DEFAULT 'PENDING'::text,
  "created_at"       timestamp with time zone NOT NULL,
  "decided_by"       text,
  "decided_at"       timestamp with time zone,
  "origin_device_id" text,
  "received_at"      timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "void_requests_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(id),
  CONSTRAINT "void_requests_pkey" PRIMARY KEY (customer_id, id)
);

ALTER TABLE "public"."void_requests"
  ENABLE ROW LEVEL SECURITY;

CREATE INDEX vr_customer_sale ON public.void_requests USING btree (customer_id, sale_id);

CREATE INDEX vr_customer_status ON public.void_requests USING btree (customer_id, status);

CREATE TRIGGER touch_received_at
  BEFORE UPDATE ON public.void_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.pos_touch_received_at();

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."void_requests" TO "service_role";

REVOKE ALL ON TABLE "public"."void_requests" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."void_requests" TO "postgres";

REVOKE ALL ON TABLE "public"."void_requests" FROM "anon", "authenticated";

-- ---- views/license_seat_usage.sql ----
CREATE VIEW "public"."license_seat_usage" WITH (security_invoker=true) AS  SELECT l.activation_code,
    l.customer_id,
    c.name AS customer_name,
    l.seat_limit,
    count(d.id) FILTER (WHERE (d.revoked_at IS NULL)) AS seats_used,
    l.expires_at,
    l.revoked_at,
    l.created_at
   FROM ((public.licenses l
     JOIN public.customers c ON ((c.id = l.customer_id)))
     LEFT JOIN public.device_registrations d ON ((d.activation_code = l.activation_code)))
  GROUP BY l.activation_code, l.customer_id, c.name, l.seat_limit, l.expires_at, l.revoked_at, l.created_at;

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."license_seat_usage" TO "service_role";

REVOKE ALL ON TABLE "public"."license_seat_usage" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."license_seat_usage" TO "postgres";

REVOKE ALL ON TABLE "public"."license_seat_usage" FROM "anon", "authenticated";

-- ---- _cluster/event_triggers.sql ----
CREATE EVENT TRIGGER "ensure_rls"
  ON ddl_command_end
  WHEN TAG IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
  EXECUTE FUNCTION "public"."rls_auto_enable"();

SET check_function_bodies = on;

-- ---- public/default_privileges.sql ----
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT SELECT, UPDATE, USAGE ON SEQUENCES TO "anon";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT SELECT, UPDATE, USAGE ON SEQUENCES TO "authenticated";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT SELECT, UPDATE, USAGE ON SEQUENCES TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" REVOKE ALL ON FUNCTIONS FROM PUBLIC;

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT EXECUTE ON FUNCTIONS TO "anon";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT EXECUTE ON FUNCTIONS TO "authenticated";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT EXECUTE ON FUNCTIONS TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLES TO "anon";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLES TO "authenticated";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLES TO "service_role";

