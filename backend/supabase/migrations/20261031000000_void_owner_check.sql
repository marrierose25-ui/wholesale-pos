-- ---------------------------------------------------------------------------
-- Void authorization (audit: void RPCs trusted the caller)
--
-- `pos_void_sale`, `pos_approve_void` and `pos_reject_void` are SECURITY
-- DEFINER and took `p_user` on faith: `pos-api` gates the actions, but the RPC
-- itself was callable with any account — and with the service role from any
-- other code path — so a cashier id voided a sale with no owner in the loop.
-- Each function now refuses to run unless `p_user` is a live OWNER of the
-- tenant it is acting on.
--
-- Bodies are the ones in docs/supabase_pos_integrity.sql, unchanged apart from
-- the guard. CREATE OR REPLACE keeps the existing grants in place; they are
-- restated here so this file stands on its own.
-- ---------------------------------------------------------------------------

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
$$;
REVOKE ALL ON FUNCTION pos_void_sale FROM public;
GRANT EXECUTE ON FUNCTION pos_void_sale TO service_role;
