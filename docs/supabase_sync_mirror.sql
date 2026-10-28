-- Wholesale POS — device sync staging (Phase 23, wave B / audit 2 #2)
-- ---------------------------------------------------------------------------
-- The `sync` gateway authenticates a device with its SIGNED LICENSE, not with a
-- user session. Until this file it wrote straight into the operational tables
-- (`sales`, `sale_items`, `shifts`, `cash_movements`, `void_requests`) with the
-- service role and with rows built from the device's own payload, and its
-- DELETE branch hard-deleted a sale plus its lines. A licence-bearing device
-- could therefore publish a sale whose totals it chose, or erase another
-- till's sale.
--
-- Now a device can only APPEND to `sync_mirror`. Applying a stored entry is a
-- separate, server-owned step (`pos_sync_apply`) that runs the same RPCs the
-- tills use, so a synced sale is recomputed, receipt-unique and attached to the
-- current open shift — exactly like a sale rung up in the PWA. A device can
-- never delete anything: DELETE entries are stored and rejected.
--
-- Re-runnable: safe to paste over an existing project.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.sync_mirror (
  customer_id  uuid NOT NULL REFERENCES public.customers(id),
  entity_type  text NOT NULL,
  entity_id    text NOT NULL,
  operation    text NOT NULL DEFAULT 'UPSERT',
  device_id    text,
  payload      jsonb NOT NULL,
  received_at  timestamptz NOT NULL DEFAULT now(),
  apply_status text NOT NULL DEFAULT 'PENDING',
  apply_error  text,
  applied_at   timestamptz,
  PRIMARY KEY (customer_id, entity_type, entity_id)
);

CREATE INDEX IF NOT EXISTS sync_mirror_pending
  ON public.sync_mirror (customer_id, received_at)
  WHERE apply_status = 'PENDING';

ALTER TABLE public.sync_mirror ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sync_mirror FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- pos_sync_apply: promote this tenant's pending mirror entries.
-- One entry is one transaction (BEGIN/EXCEPTION block), so a bad row is marked
-- REJECTED with its reason and the rest of the batch still lands.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pos_sync_apply(
  p_customer uuid,
  p_limit    int DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
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
  mv        jsonb;
  vr        jsonb;
  sale_row  record;
BEGIN
  FOR rec IN
    SELECT entity_type, entity_id, operation, device_id, payload
    FROM public.sync_mirror
    WHERE customer_id = p_customer AND apply_status = 'PENDING'
    ORDER BY received_at, entity_id
    LIMIT COALESCE(NULLIF(p_limit, 0), 200)
    FOR UPDATE SKIP LOCKED
  LOOP
    BEGIN
      IF upper(rec.operation) = 'DELETE' THEN
        RAISE EXCEPTION 'A device cannot delete a cloud record.';
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
        PERFORM public.pos_add_cash_movement(
          p_customer,
          COALESCE(mv->>'user_id', ''),
          shift_id,
          upper(COALESCE(mv->>'type', '')),
          abs(COALESCE((mv->>'amount_minor_units')::bigint, 0)),
          mv->>'reason',
          NULLIF(mv->>'photo', ''));

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
        -- shift per tenant and the till owns it (shifts_one_open_per_tenant).
        RAISE EXCEPTION 'Shift changes are not applied from a device.';

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
    'applied', applied, 'rejected', rejected, 'pending', left_over);
END;
$$;
-- Supabase's default privileges grant EXECUTE to anon/authenticated directly,
-- so revoking from PUBLIC alone leaves the RPC callable with the published
-- anon key — which would let an outsider force-apply another tenant's staged
-- entries. Name the roles explicitly (audit 2 #27).
REVOKE ALL ON FUNCTION pos_sync_apply(uuid, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION pos_sync_apply(uuid, int) TO service_role;
