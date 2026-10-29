-- Wholesale POS — sync every master-data entity, and stop rejecting shifts
-- ---------------------------------------------------------------------------
-- Two gaps this file closes:
--
--   1. **Rejections that were never meant to happen.** `pos_sync_apply` answered
--      every `shift` entry with `Shift changes are not applied from a device.`,
--      so opening a drawer at the till wrote a REJECTED row into `sync_mirror`
--      every time. A rejection is acked by the client and pruned, so the operator
--      never saw it — the queue just quietly swallowed a verdict per shift.
--   2. **Entities that could not sync at all.** Users, saved names and the
--      money tracker existed in the cloud (`pos_users`, `pos_products`,
--      `pos_finance_categories`, `pos_finance_entries`) and the PWA reads and
--      writes them directly, but the sync gateway had no vocabulary for them:
--      a device push was refused as `unknown entity type` on the client side and
--      the pull never offered the tables, so a cashier created at the till could
--      not appear in the browser and a product created in the browser could not
--      appear at the till.
--
-- Design, and why it is safe:
--
--   * A push still only ever APPENDS to `sync_mirror`. Nothing here lets a
--     device write an operational table directly; every branch below goes
--     through the same RPCs the tills and the PWA call, or through an upsert
--     onto a tenant-scoped primary key with a `updated_at` guard.
--   * Ledger entries (sale / cash_movement / void_request) keep the old rule:
--     staged once, replayed through `pos_create_sale` and friends, never
--     restated. Master data (user / product / finance_category / finance_entry)
--     is mutable, so a newer payload re-stages and is applied newest-wins.
--   * Pending entries are walked in dependency order rather than arrival order,
--     which is the shift-before-sale guarantee the gateway cannot make itself:
--     a push stamps every row it stages with one `received_at`, so two entries
--     that arrived together were previously ordered by a random uuid.
--
-- Re-runnable: safe to paste over an existing project.
-- ---------------------------------------------------------------------------

-- ===========================================================================
-- 1. The delta feed has to cover the master-data tables.
--
-- The pull is a keyset walk over (received_at, id). These three tables were
-- created for the PWA and never needed a cursor, so they have no `received_at`
-- at all: a product saved in the browser would be invisible to every till
-- forever. `DEFAULT now()` stamps the INSERT; the BEFORE UPDATE trigger in
-- pos_sync_delta re-stamps an edit so a rename or a mark-completed re-enters
-- the feed instead of changing in place and being skipped.
-- ===========================================================================
ALTER TABLE public.pos_products
  ADD COLUMN IF NOT EXISTS received_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE public.pos_finance_categories
  ADD COLUMN IF NOT EXISTS received_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE public.pos_finance_entries
  ADD COLUMN IF NOT EXISTS received_at timestamptz NOT NULL DEFAULT now();

CREATE INDEX IF NOT EXISTS pos_products_customer_received
  ON public.pos_products (customer_id, received_at, id);
CREATE INDEX IF NOT EXISTS pos_finance_categories_customer_received
  ON public.pos_finance_categories (customer_id, received_at, id);
CREATE INDEX IF NOT EXISTS pos_finance_entries_customer_received
  ON public.pos_finance_entries (customer_id, received_at, id);

-- `pos_users` needs the mirror image of that: an `updated_at` the sync apply can
-- compare against. The table had `received_at` (when the cloud last changed the
-- row) but no version of *what the device thinks* the row's last edit was, and
-- two surfaces editing one account need one agreed clock to resolve in. Existing
-- rows are backfilled from their own history so a first comparison is never
-- working against a NULL.
ALTER TABLE public.pos_users ADD COLUMN IF NOT EXISTS updated_at timestamptz;
UPDATE public.pos_users
  SET updated_at = COALESCE(deleted_at, received_at, created_at)
  WHERE updated_at IS NULL;

-- Every edit has to move `updated_at` forward, including the PWA's own — which
-- does not write the column at all (`pos-api` stamps `userStamp`, which only
-- touches `received_at`), and which is why this is a trigger rather than
-- something each caller remembers to write.
--
-- The trigger must not BLINDLY overwrite, though: a sync apply arrives carrying
-- the device's own `updated_at`, and stomping it with server time would make the
-- cloud look permanently newer than a register whose clock lags a minute — that
-- register's edits would then be refused forever, silently. So the version is
-- advanced only when the incoming row does not already carry a newer one.
CREATE OR REPLACE FUNCTION public.pos_touch_user_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
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
$$;
DROP TRIGGER IF EXISTS touch_user_updated_at ON public.pos_users;
CREATE TRIGGER touch_user_updated_at
  BEFORE INSERT OR UPDATE ON public.pos_users
  FOR EACH ROW EXECUTE FUNCTION public.pos_touch_user_updated_at();

-- Re-stamp the delta trigger with the widened table list. Idempotent: the
-- function is replaced and every trigger is dropped and recreated.
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
  DECLARE tbl text;
  BEGIN
    FOREACH tbl IN ARRAY ARRAY[
      'sales', 'sale_items', 'shifts', 'cash_movements', 'void_requests',
      'pos_users', 'pos_products', 'pos_finance_categories',
      'pos_finance_entries'
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

REVOKE ALL ON FUNCTION public.pos_touch_received_at() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.pos_touch_user_updated_at() FROM PUBLIC, anon, authenticated;
GRANT ALL ON FUNCTION public.pos_touch_received_at() TO service_role;
GRANT ALL ON FUNCTION public.pos_touch_user_updated_at() TO service_role;

-- ===========================================================================
-- 2. pos_sync_apply — dependency order, plus one branch per master-data type.
-- ===========================================================================
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
  actor     text;
  mv        jsonb;
  vr        jsonb;
  us        jsonb;
  pr        jsonb;
  fc        jsonb;
  fe        jsonb;
  sale_row  record;
  cat_row   record;
  user_row  record;
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
        ELSE 8
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
        -- edit against it forever, while still answering APPLIED.
        WHERE public.pos_users.updated_at IS NULL
           OR public.pos_users.updated_at < EXCLUDED.updated_at;

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
$$;
-- Supabase's default privileges grant EXECUTE to anon/authenticated directly,
-- so revoking from PUBLIC alone leaves the RPC callable with the published
-- anon key — which would let an outsider force-apply another tenant's staged
-- entries. Name the roles explicitly (audit 2 #27).
REVOKE ALL ON FUNCTION pos_sync_apply(uuid, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION pos_sync_apply(uuid, int) TO service_role;
