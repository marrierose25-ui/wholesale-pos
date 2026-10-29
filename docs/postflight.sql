-- Check 1: Is the fixed owner index present?
SELECT indexname, indexdef FROM pg_indexes
WHERE tablename = 'pos_users' AND indexname = 'pos_users_one_owner';

-- Check 2: Is the idempotency marker present?
SELECT key, applied_at FROM migration_markers WHERE key = 'cashier_permissions_backfill_v1';

-- Check 3: Was the C1 fix (deleted_at filter) applied?
SELECT
  CASE
    WHEN indexdef LIKE '%deleted_at IS NULL%' THEN 'C1 APPLIED ✓'
    WHEN indexdef IS NULL THEN 'C1 NOT APPLIED — index missing entirely'
    ELSE 'C1 NOT APPLIED — old index (no deleted_at filter)'
  END AS c1_status
FROM pg_indexes
WHERE tablename = 'pos_users' AND indexname = 'pos_users_one_owner';

-- Check 4: Are the hardened functions live?
SELECT proname,
       has_function_privilege('anon', oid, 'EXECUTE') AS anon_can_execute,
       has_function_privilege('service_role', oid, 'EXECUTE') AS svc_can_execute
FROM pg_proc
WHERE proname IN (
  'pos_create_sale','pos_approve_void','pos_ensure_shift','pos_void_sale',
  'pos_add_cash_movement','pos_setup_owner','pos_delete_finance_category'
)
ORDER BY proname;
