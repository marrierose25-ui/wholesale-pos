-- ===========================================================================
-- One-time repair: cash movements double-paid by a completed collection.
--
-- A CASH collection must put money in the drawer exactly once. Until this fix
-- the two writers never saw each other: the till pushed its own DEPOSIT and
-- `pos_complete_finance` (or a second till completing the same entry) wrote
-- another. The two rows share nothing but their meaning - different uuids,
-- different timestamps - and the pushed row carried NULL in
-- `source_finance_entry_id`, the only column
-- `cash_movements_one_per_finance_entry` can compare. An untagged deposit is
-- therefore both a possible duplicate and invisible to the guard that would
-- stop the next one.
--
-- The repair does two things, in two passes:
--   1. deletes the newer row of any pair that is one collection paid twice
--   2. stamps `source_finance_entry_id` on the surviving deposit, so the unique
--      index and `pos_add_cash_movement` can protect it from now on
--
-- Pass 2 re-reads pass 1's result, which is what makes the "the untagged copy is
-- actually the older one" case work: once the tagged twin is gone the survivor
-- falls into the untagged bucket and gets the entry id.
--
-- Nothing here guesses when it is not sure. Two collections from the same person
-- for the same amount are ordinary, so a pair is only acted on when the deposit
-- and the collection choose each other as the nearest clock (mutual nearest),
-- and only within a day of the completion. Anything ambiguous is left alone.
--
--   supabase db query --linked -f docs/supabase_finance_movement_dedupe.sql
--   supabase db query --linked "SELECT * FROM public.pos_finance_movement_actions ORDER BY 1"
--   supabase db query --linked "SELECT public.pos_dedupe_finance_movements()"
--
-- Then drop both objects - they exist only for this repair:
--
--   supabase db query --linked "DROP FUNCTION public.pos_dedupe_finance_movements(); DROP VIEW public.pos_finance_movement_actions"
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. What is wrong, as one row per action.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.pos_finance_movement_actions AS
WITH e AS (
  -- Completed cash collections, and the reason text both writers produce for
  -- them: 'Collected from ' || the person's name.
  SELECT f.customer_id, f.id AS entry_id, f.amount_minor_units, f.completed_at,
         'Collected from ' || COALESCE(c.name, 'a person') AS deposit_reason
  FROM public.pos_finance_entries f
  LEFT JOIN public.pos_finance_categories c
         ON c.customer_id = f.customer_id AND c.id = f.category_id
  WHERE f.status = 'COMPLETED' AND f.payment_method = 'CASH'
),
tagged AS (
  -- Deposits that already name their collection. rn = 1 is the oldest of them.
  SELECT m.customer_id, m.source_finance_entry_id AS entry_id, m.id,
         m.created_at,
         row_number() OVER (PARTITION BY m.customer_id, m.source_finance_entry_id
                            ORDER BY m.created_at, m.id) AS rn,
         count(*) OVER (PARTITION BY m.customer_id, m.source_finance_entry_id) AS n
  FROM public.cash_movements m
  WHERE m.source_finance_entry_id IS NOT NULL
),
candidate AS (
  -- Untagged deposits that could be this collection's money: same tenant, same
  -- type, same amount, same reason, within a day of the completion. Each is
  -- ranked by how close its clock sits to the moment the collection completed.
  SELECT e.customer_id, e.entry_id, m.id AS mv_id, m.created_at,
         row_number() OVER (PARTITION BY e.customer_id, e.entry_id
            ORDER BY abs(extract(epoch FROM (m.created_at - e.completed_at))), m.id)
           AS r_entry,
         row_number() OVER (PARTITION BY m.customer_id, m.id
            ORDER BY abs(extract(epoch FROM (m.created_at - e.completed_at))), e.entry_id)
           AS r_mv
  FROM e
  JOIN public.cash_movements m
    ON m.customer_id = e.customer_id
   AND m.source_finance_entry_id IS NULL
   AND m.type = 'DEPOSIT'
   AND m.amount_minor_units = e.amount_minor_units
   AND m.reason = e.deposit_reason
   AND abs(extract(epoch FROM (m.created_at - e.completed_at))) < 86400
),
mutual AS (
  -- r_entry = 1 says the collection picked this row; r_mv = 1 says the row
  -- picked this collection back. Only a pair that chooses each other counts,
  -- which is what keeps two identical collections from sharing one deposit.
  SELECT c.customer_id, c.entry_id, c.mv_id, c.created_at
  FROM candidate c
  WHERE c.r_entry = 1 AND c.r_mv = 1
)
-- A. One collection, several tagged deposits. Everything after the oldest goes.
--    The unique index makes this impossible today; it is here for a database
--    where the index landed after the damage.
SELECT t.customer_id, t.entry_id, t.id AS movement_id, 'DELETE' AS action,
       'extra deposit tagged for a collection that was paid once' AS detail
FROM tagged t
WHERE t.rn > 1

UNION ALL

-- B. A tagged deposit and an untagged copy of the same money: the drawer was
--    paid twice and the index could only see one of the rows. Keep the older.
SELECT mu.customer_id, mu.entry_id,
       CASE WHEN mu.created_at < t.created_at THEN t.id ELSE mu.mv_id END,
       'DELETE',
       'duplicate of the deposit for this collection, older one kept'
FROM mutual mu
JOIN tagged t
  ON t.customer_id = mu.customer_id
 AND t.entry_id = mu.entry_id
 AND t.rn = 1 AND t.n = 1

UNION ALL

-- C. Nothing names this collection, but exactly one untagged deposit is its
--    money. No cash to remove - the row needs its entry id.
SELECT mu.customer_id, mu.entry_id, mu.mv_id, 'TAG',
       'untagged deposit that belongs to this collection'
FROM mutual mu
WHERE NOT EXISTS (SELECT 1 FROM tagged t
                  WHERE t.customer_id = mu.customer_id
                    AND t.entry_id = mu.entry_id);

-- ---------------------------------------------------------------------------
-- 2. The repair. Delete first, then stamp: while the tagged row exists the
--    unique index would refuse to let the survivor claim the same entry.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pos_dedupe_finance_movements()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  action_found record;
  v_deleted int := 0;
  v_tagged  int := 0;
BEGIN
  FOR action_found IN
    SELECT a.customer_id, a.movement_id, a.entry_id
    FROM public.pos_finance_movement_actions a
    WHERE a.action = 'DELETE'
  LOOP
    -- Both halves of the primary key: `cash_movements.id` is only unique per
    -- tenant.
    DELETE FROM public.cash_movements
    WHERE customer_id = action_found.customer_id
      AND id = action_found.movement_id;
    IF FOUND THEN
      v_deleted := v_deleted + 1;
      INSERT INTO public.pos_audit_logs (id, customer_id, user_id, action,
        details, created_at)
      VALUES (gen_random_uuid(), action_found.customer_id, 'system',
        'CASH_MOVEMENT_DEDUPE',
        'Removed duplicate deposit ' || action_found.movement_id ||
        ' for collection ' || action_found.entry_id || '.', now());
    END IF;
  END LOOP;

  -- Re-read the view: pass 1 may have turned a tagged survivor's untagged twin
  -- into the only deposit for its collection.
  FOR action_found IN
    SELECT a.customer_id, a.movement_id, a.entry_id
    FROM public.pos_finance_movement_actions a
    WHERE a.action = 'TAG'
  LOOP
    UPDATE public.cash_movements
    SET source_finance_entry_id = action_found.entry_id
    WHERE customer_id = action_found.customer_id
      AND id = action_found.movement_id
      AND source_finance_entry_id IS NULL;
    IF FOUND THEN
      v_tagged := v_tagged + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('deleted', v_deleted, 'tagged', v_tagged);
END;
$$;

REVOKE ALL ON FUNCTION public.pos_dedupe_finance_movements FROM public;
GRANT EXECUTE ON FUNCTION public.pos_dedupe_finance_movements TO service_role;
