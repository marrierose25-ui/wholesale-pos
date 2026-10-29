-- 1. Active duplicate owners (should be empty)
SELECT customer_id, count(*) AS active_owners
FROM pos_users WHERE role = 'OWNER' AND deleted_at IS NULL
GROUP BY customer_id HAVING count(*) > 1;

-- 2. Current owner index
SELECT indexname, indexdef FROM pg_indexes
WHERE tablename = 'pos_users' AND indexname LIKE '%owner%';

-- 3. Permissions distribution (to see how many are currently [])
SELECT role, jsonb_array_length(permissions) AS perm_count, count(*)
FROM pos_users GROUP BY 1, 2 ORDER BY 1, 2;

-- 4. FKs on critical columns (this answers whether CASCADE is a risk)
SELECT conname, conrelid::regclass::text AS child,
       confrelid::regclass::text AS parent, confdeltype
FROM pg_constraint
WHERE contype = 'f'
  AND conrelid::regclass::text IN
      ('cash_movements','void_requests','sale_items','sales','shifts')
ORDER BY child, conname;

-- 5. RLS status on critical tables
SELECT tablename, rowsecurity FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN ('sales','sale_items','shifts','cash_movements','pos_users',
                    'pos_finance_entries','pos_finance_categories','void_requests',
                    'pos_products','pos_counters')
ORDER BY tablename;

-- 6. RLS policies
SELECT tablename, policyname, cmd FROM pg_policies
WHERE schemaname = 'public' ORDER BY tablename, policyname;
