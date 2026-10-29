SELECT 'C1_owner_index_deleted_filter' AS check_name,
  CASE
    WHEN EXISTS (SELECT 1 FROM pg_indexes
                 WHERE tablename='pos_users' AND indexname='pos_users_one_owner'
                   AND indexdef LIKE '%deleted_at IS NULL%') THEN 'PASS'
    WHEN EXISTS (SELECT 1 FROM pg_indexes
                 WHERE tablename='pos_users' AND indexname='pos_users_one_owner')
      THEN 'FAIL: old index, no deleted_at filter'
    ELSE 'FAIL: index missing'
  END AS result
UNION ALL
SELECT 'C2_idempotency_marker',
  CASE
    WHEN EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema='public' AND table_name='migration_markers') THEN
      CASE WHEN EXISTS (SELECT 1 FROM public.migration_markers
                        WHERE key='cashier_permissions_backfill_v1')
           THEN 'PASS' ELSE 'FAIL: table exists, marker missing' END
    ELSE 'FAIL: migration_markers table does not exist'
  END
UNION ALL
SELECT 'C3_sale_shape_validation',
  CASE WHEN pg_get_functiondef('public.pos_create_sale'::regproc)
            LIKE '%Items must be a JSON array%' THEN 'PASS'
       ELSE 'FAIL: pos_create_sale not updated' END
UNION ALL
SELECT 'C4_approve_void_for_update',
  CASE WHEN pg_get_functiondef('public.pos_approve_void'::regproc)
            LIKE '%FOR UPDATE%' THEN 'PASS'
       ELSE 'FAIL: pos_approve_void not updated' END
UNION ALL
SELECT 'C5_ensure_shift_null_guard',
  CASE WHEN pg_get_functiondef('public.pos_ensure_shift'::regproc)
            LIKE '%Failed to ensure shift after unique violation%' THEN 'PASS'
       ELSE 'FAIL: pos_ensure_shift not updated' END
UNION ALL
SELECT 'C6_void_sale_reason_check',
  CASE WHEN pg_get_functiondef('public.pos_void_sale'::regproc)
            LIKE '%Void requires a reason%' THEN 'PASS'
       ELSE 'FAIL: pos_void_sale not updated' END
UNION ALL
SELECT 'C7_cash_movement_photo_cap',
  CASE WHEN pg_get_functiondef('public.pos_add_cash_movement'::regproc)
            LIKE '%Photo too large%' THEN 'PASS'
       ELSE 'FAIL: pos_add_cash_movement not updated' END
UNION ALL
SELECT 'C8_setup_owner_race_guard',
  CASE WHEN pg_get_functiondef('public.pos_setup_owner'::regproc)
            LIKE '%Owner already exists%'
       AND pg_get_functiondef('public.pos_setup_owner'::regproc)
            LIKE '%EXCEPTION WHEN unique_violation%' THEN 'PASS'
       ELSE 'FAIL: pos_setup_owner not updated' END
UNION ALL
SELECT 'C9_finance_delete_guard',
  CASE WHEN pg_get_functiondef('public.pos_delete_finance_category'::regproc)
            LIKE '%completed financial entries%' THEN 'PASS'
       ELSE 'FAIL: pos_delete_finance_category not updated' END
;
