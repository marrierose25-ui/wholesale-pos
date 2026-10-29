-- Wholesale POS — delta feed: an UPDATE must move the row forward
-- ---------------------------------------------------------------------------
-- The `sync` gateway hands every device the shop's ledger as a keyset walk over
-- (received_at, id), per table. `received_at` is a DEFAULT now(), so it is
-- stamped when a row is INSERTED and never again: a void, a decided void
-- request or a closed drawer changed the row in place, kept its original
-- timestamp, and therefore never entered the feed again.
--
-- What that cost, on the second device:
--   * a sale voided on till A (or in the PWA) stayed COMPLETED on till B, so
--     B's takings and reports disagreed with the shop's;
--   * a void request approved in the browser stayed PENDING on every till;
--   * a drawer closed elsewhere stayed OPEN here — and because this database
--     allows exactly one OPEN shift, the register could not open another one
--     and was locked out of selling.
--
-- `pos-api` was patched to stamp pos_users itself, but the mirror tables have no
-- such write path of their own. A trigger is the one place that covers every
-- writer (pos-api, pos_sync_apply, pos_void_sale, pos_close_shift, the SQL
-- editor) without one of them being able to forget it.
--
-- Safe for the walk: an update only ever moves a row LATER in the ordering, so
-- a row cannot slip behind a cursor and be missed — the worst case is that it is
-- delivered twice, and applying a known row is a no-op.
--
-- Re-runnable: the function is replaced and the triggers are dropped/recreated.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.pos_touch_received_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.received_at := now();
  RETURN NEW;
END;
$$;

DO $$
DECLARE
  tbl text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY[
    'sales', 'sale_items', 'shifts', 'cash_movements', 'void_requests', 'pos_users'
  ]
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', 'touch_received_at', tbl);
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE UPDATE ON public.%I '
      'FOR EACH ROW EXECUTE FUNCTION public.pos_touch_received_at()',
      'touch_received_at', tbl);
  END LOOP;
END;
$$;

-- Trigger functions are not callable from SQL, but keep the surface closed.
REVOKE ALL ON FUNCTION public.pos_touch_received_at() FROM PUBLIC, anon, authenticated;
