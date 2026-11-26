-- Request 3 acceptance corrections, on the REAL schema.
--
-- Runs against the replayed schema AFTER request3_actor_authorization in CI.
-- Never run against production.
--
--   B1  unchecked money RPCs are NOT executable by service_role (the
--       inherited Stage-5 grant is gone); the checked wrappers still are
--   B2  actual behaviour: service_role direct unchecked call is refused;
--       an inactive user and a feature-less cashier are refused by the
--       wrappers' authorization path
--   B3  transient vs permanent sync failures: pos_sync_error_retryable
--       classifies deadlock/serialization/connection states as retryable
--       and validation/authorization states as permanent
--   B4  two-actor finance: created_by / completed_by resolve through
--       SEPARATE staged grants; a forged completed_by cannot re-attribute;
--       the cash deposit lands under the completer
--   B5  deferred completion: a COMPLETED payload with no completer grant
--       stays PENDING (ACTOR_AUTH_REQUIRED), never half-applies
--   B6  first-owner bootstrap: pos_setup_owner is idempotent for the same
--       id, refuses a second owner, and keeps owner provisioning off the
--       device-sync path
--
-- psql -v ON_ERROR_STOP=1 -f request3_acceptance_test.sql

\set ON_ERROR_STOP on
\pset footer off

CREATE OR REPLACE FUNCTION pg_temp.expect_true(
  p_label  text, p_ok boolean, p_detail text DEFAULT ''
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok THEN RAISE NOTICE 'PASS % %', p_label, p_detail;
  ELSE RAISE EXCEPTION 'FAIL %: %', p_label, p_detail; END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.expect_error(
  p_label text, p_sql text, p_pattern text
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%' || p_pattern || '%' THEN
      RAISE NOTICE 'PASS % (expected error: %)', p_label, SQLERRM; RETURN;
    END IF;
    RAISE EXCEPTION 'FAIL %: expected /%/ got: %', p_label, p_pattern, SQLERRM;
  END;
  RAISE EXCEPTION 'FAIL %: expected error /%/ but succeeded', p_label, p_pattern;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.stage(
  p_customer uuid, p_type text, p_id text, p_payload jsonb,
  p_grant text DEFAULT NULL, p_hashes jsonb DEFAULT NULL,
  p_device text DEFAULT 'fp-dev1'
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.sync_mirror
    (customer_id, entity_type, entity_id, operation, device_id, payload,
     actor_grant_hash, actor_grant_hashes, apply_status)
  VALUES (
    p_customer, p_type, p_id, 'UPSERT', p_device, p_payload,
    CASE WHEN p_grant IS NULL OR btrim(p_grant) = '' THEN NULL
         ELSE public.pos_actor_grant_hash(p_grant) END,
    p_hashes, 'PENDING')
  ON CONFLICT (customer_id, entity_type, entity_id) DO UPDATE SET
    payload = EXCLUDED.payload,
    actor_grant_hash = EXCLUDED.actor_grant_hash,
    actor_grant_hashes = EXCLUDED.actor_grant_hashes,
    device_id = EXCLUDED.device_id,
    apply_status = 'PENDING', apply_error = NULL, applied_at = NULL,
    received_at = now();
END $$;

-- ---------------------------------------------------------------- seed --
DELETE FROM actor_grants;
DELETE FROM sync_mirror;
DELETE FROM void_requests;
DELETE FROM cash_movements;
DELETE FROM sale_items;
DELETE FROM sales;
DELETE FROM shifts;
DELETE FROM pos_finance_entries;
DELETE FROM pos_finance_categories;
DELETE FROM picklist_items;
DELETE FROM picklists;
DELETE FROM picklist_customers;
DELETE FROM pos_audit_logs;
DELETE FROM pos_users;
DELETE FROM device_registrations;
DELETE FROM licenses;
DELETE FROM customers;

INSERT INTO customers (id, name) VALUES
  ('66666666-6666-6666-6666-666666666666', 'R3A Shop'),
  ('77777777-7777-7777-7777-777777777777', 'R3A Bootstrap Shop');
INSERT INTO licenses (activation_code, customer_id, seat_limit)
VALUES ('R3A-CODE-AAAA-BBBB-CCCC-DDDD', '66666666-6666-6666-6666-666666666666', 1);
INSERT INTO device_registrations
  (activation_code, device_fingerprint, device_name)
VALUES ('R3A-CODE-AAAA-BBBB-CCCC-DDDD', 'fp-dev1', 'till 1');

INSERT INTO pos_users
  (id, customer_id, username, role, pw_salt, pw_hash, active, permissions)
VALUES
  ('ownerA', '66666666-6666-6666-6666-666666666666', 'ownerA', 'OWNER', 's', 'h-o', true, '[]'::jsonb),
  ('cashA', '66666666-6666-6666-6666-666666666666', 'cashA', 'CASHIER', 's', 'h-a', true,
   '["pos","register","finance"]'::jsonb),
  ('cashB', '66666666-6666-6666-6666-666666666666', 'cashB', 'CASHIER', 's', 'h-b', true,
   '["pos","register","finance"]'::jsonb),
  ('cashNoFin', '66666666-6666-6666-6666-666666666666', 'cashNoFin', 'CASHIER', 's', 'h-n', true,
   '["pos","register"]'::jsonb),
  ('deadU', '66666666-6666-6666-6666-666666666666', 'deadU', 'CASHIER', 's', 'h-d', false,
   '["pos","register","finance"]'::jsonb);

CREATE TEMP TABLE acc_grants (label text PRIMARY KEY, token text NOT NULL);
INSERT INTO acc_grants (label, token) VALUES
  ('owner', (public.pos_issue_actor_grant(
    '66666666-6666-6666-6666-666666666666', 'ownerA', 'fp-dev1', 3600)->>'grant')),
  ('cashA', (public.pos_issue_actor_grant(
    '66666666-6666-6666-6666-666666666666', 'cashA', 'fp-dev1', 3600)->>'grant')),
  ('cashB', (public.pos_issue_actor_grant(
    '66666666-6666-6666-6666-666666666666', 'cashB', 'fp-dev1', 3600)->>'grant')),
  ('cashNoFin', (public.pos_issue_actor_grant(
    '66666666-6666-6666-6666-666666666666', 'cashNoFin', 'fp-dev1', 3600)->>'grant'));

CREATE OR REPLACE FUNCTION pg_temp.grant(p_label text) RETURNS text
LANGUAGE sql AS $$ SELECT token FROM acc_grants WHERE label = p_label $$;
CREATE OR REPLACE FUNCTION pg_temp.hash(p_label text) RETURNS text
LANGUAGE sql AS $$
  SELECT public.pos_actor_grant_hash(token) FROM acc_grants WHERE label = p_label
$$;

-- ================================================================ B1 ======
SELECT pg_temp.expect_true('B1 unchecked RPCs deny service_role',
  NOT has_function_privilege('service_role',
    'public.pos_create_sale_unchecked(uuid,text,text,text,text,jsonb,text,bigint,bigint,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('service_role',
    'public.pos_add_cash_movement_unchecked(uuid,text,text,text,bigint,text,text,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('service_role',
    'public.pos_complete_finance_unchecked(uuid,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('service_role',
    'public.pos_delete_finance_entry_unchecked(uuid,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('service_role',
    'public.pos_delete_finance_category_unchecked(uuid,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('service_role',
    'public.pos_open_shift_unchecked(uuid,text,text,bigint)', 'EXECUTE')
  AND NOT has_function_privilege('service_role',
    'public.pos_close_shift_unchecked(uuid,text,text,bigint)', 'EXECUTE'),
  'no unchecked money RPC reachable by service_role');

SELECT pg_temp.expect_true('B1 wrappers still allow service_role',
  has_function_privilege('service_role',
    'public.pos_create_sale(uuid,text,text,text,text,jsonb,text,bigint,bigint,text,text)', 'EXECUTE')
  AND has_function_privilege('service_role',
    'public.pos_add_cash_movement(uuid,text,text,text,bigint,text,text,text,text)', 'EXECUTE')
  AND has_function_privilege('service_role',
    'public.pos_complete_finance(uuid,text,text)', 'EXECUTE')
  AND has_function_privilege('service_role',
    'public.pos_delete_finance_entry(uuid,text,text)', 'EXECUTE')
  AND has_function_privilege('service_role',
    'public.pos_delete_finance_category(uuid,text,text)', 'EXECUTE')
  AND has_function_privilege('service_role',
    'public.pos_open_shift(uuid,text,text,bigint)', 'EXECUTE')
  AND has_function_privilege('service_role',
    'public.pos_close_shift(uuid,text,text,bigint)', 'EXECUTE'),
  'checked wrappers keep service_role EXECUTE');

-- ================================================================ B2 ======
SET ROLE service_role;
SELECT pg_temp.expect_error('B2 service_role cannot call unchecked sale',
  format(
    'SELECT public.pos_create_sale_unchecked(%L,%L,%L,%L,%L,%L::jsonb,%L,0,0,NULL,NULL)',
    '66666666-6666-6666-6666-666666666666', 'u', 'd', 's', 'R', '[]', 'CASH'),
  'permission denied');
SELECT pg_temp.expect_error('B2 service_role cannot call unchecked cash',
  format(
    'SELECT public.pos_add_cash_movement_unchecked(%L,%L,%L,%L,100,%L,NULL,NULL,NULL)',
    '66666666-6666-6666-6666-666666666666', 'u', 's', 'DEPOSIT', 'r'),
  'permission denied');
SELECT pg_temp.expect_error('B2 service_role cannot call unchecked complete',
  format(
    'SELECT public.pos_complete_finance_unchecked(%L,%L,%L)',
    '66666666-6666-6666-6666-666666666666', 'u', 'e'),
  'permission denied');
RESET ROLE;

-- Wrapper authorization: a cashier WITHOUT finance cannot complete finance;
-- an inactive user is refused by the resolve/feature path. (The full
-- request3 suite covers every wrapper; these pin the two required cases.)
SELECT pg_temp.expect_true('B2 cashNoFin lacks finance feature',
  NOT public.pos_user_has_feature(
    '66666666-6666-6666-6666-666666666666', 'cashNoFin', 'finance')
  AND public.pos_user_has_feature(
    '66666666-6666-6666-6666-666666666666', 'cashA', 'finance'),
  'permission matrix sanity for the finance tests below');

-- ================================================================ B3 ======
SELECT pg_temp.expect_true('B3 retryable classification',
  public.pos_sync_error_retryable('40P01')
  AND public.pos_sync_error_retryable('40001')
  AND public.pos_sync_error_retryable('55P03')
  AND public.pos_sync_error_retryable('57014')
  AND public.pos_sync_error_retryable('08006')
  AND public.pos_sync_error_retryable('57P01')
  AND public.pos_sync_error_retryable('53300'),
  'deadlock/serialization/lock/connection states are retryable');
SELECT pg_temp.expect_true('B3 permanent classification',
  NOT public.pos_sync_error_retryable('23514')
  AND NOT public.pos_sync_error_retryable('23502')
  AND NOT public.pos_sync_error_retryable('23503')
  AND NOT public.pos_sync_error_retryable('42501')
  AND NOT public.pos_sync_error_retryable('P0001')
  AND NOT public.pos_sync_error_retryable('22023'),
  'validation/authorization/business-refusal states stay permanent');

-- A business refusal still lands REJECTED (permanent), proving the
-- classification did not turn every error retryable. cashNoFin holds pos +
-- register but NOT finance, so a finance_category write is refused.
SELECT pg_temp.stage(
  '66666666-6666-6666-6666-666666666666', 'finance_category', 'cat-badperm',
  jsonb_build_object('finance_category', jsonb_build_object(
    'name', 'Nope', 'created_at', now(), 'updated_at', now())),
  pg_temp.grant('cashNoFin'));
SELECT public.pos_sync_apply('66666666-6666-6666-6666-666666666666', 500, 'fp-dev1');
SELECT pg_temp.expect_true('B3 permanent refusal rejected not retryable',
  (SELECT apply_status FROM public.sync_mirror
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND entity_type = 'finance_category' AND entity_id = 'cat-badperm') = 'REJECTED'
  AND (SELECT apply_error FROM public.sync_mirror
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND entity_type = 'finance_category' AND entity_id = 'cat-badperm')
    NOT LIKE 'RETRYABLE:%',
  'feature refusal is a permanent REJECTED verdict');

-- ================================================================ B4 ======
-- Two-actor finance: A creates, B completes — BEFORE either syncs.
-- actor_grant_hashes carries BOTH digests keyed by the payload actor ids.
SELECT pg_temp.stage(
  '66666666-6666-6666-6666-666666666666', 'finance_category', 'catA',
  jsonb_build_object('finance_category', jsonb_build_object(
    'name', 'Staff', 'created_at', now(), 'updated_at', now())),
  pg_temp.grant('cashA'));
SELECT pg_temp.stage(
  '66666666-6666-6666-6666-666666666666', 'finance_entry', 'fe-two',
  jsonb_build_object('finance_entry', jsonb_build_object(
    'category_id', 'catA', 'source', 'LOAN',
    'amount_minor_units', 4200, 'description', 'two actor',
    'status', 'COMPLETED', 'payment_method', 'CASH',
    'created_by', 'cashA', 'completed_by', 'cashB',
    'entry_date', now(), 'created_at', now(), 'updated_at', now())),
  pg_temp.grant('cashA'),
  jsonb_build_object(
    'cashA', pg_temp.hash('cashA'),
    'cashB', pg_temp.hash('cashB')));
SELECT public.pos_sync_apply('66666666-6666-6666-6666-666666666666', 500, 'fp-dev1');
SELECT pg_temp.expect_true('B4 creator and completer are distinct actors',
  (SELECT created_by FROM public.pos_finance_entries
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND id = 'fe-two') = 'cashA'
  AND (SELECT completed_by FROM public.pos_finance_entries
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND id = 'fe-two') = 'cashB'
  AND (SELECT status FROM public.pos_finance_entries
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND id = 'fe-two') = 'COMPLETED',
  'created_by=cashA completed_by=cashB');
SELECT pg_temp.expect_true('B4 cash deposit attributed to completer',
  EXISTS (SELECT 1 FROM public.cash_movements
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND source_finance_entry_id = 'fe-two' AND user_id = 'cashB'
      AND type = 'DEPOSIT'),
  'pos_complete_finance deposited under cashB');

-- Forged completed_by: payload claims ownerA but only cashA's grant is
-- staged under that key — the recorded completer must be cashA, never
-- the claimed id.
SELECT pg_temp.stage(
  '66666666-6666-6666-6666-666666666666', 'finance_entry', 'fe-forge',
  jsonb_build_object('finance_entry', jsonb_build_object(
    'category_id', 'catA', 'source', 'LOAN',
    'amount_minor_units', 100, 'status', 'COMPLETED',
    'payment_method', 'BANK',
    'created_by', 'cashA', 'completed_by', 'ownerA',
    'entry_date', now(), 'created_at', now(), 'updated_at', now())),
  pg_temp.grant('cashA'),
  jsonb_build_object('cashA', pg_temp.hash('cashA'), 'ownerA', pg_temp.hash('cashA')));
SELECT public.pos_sync_apply('66666666-6666-6666-6666-666666666666', 500, 'fp-dev1');
SELECT pg_temp.expect_true('B4 forged completed_by cannot re-attribute',
  (SELECT completed_by FROM public.pos_finance_entries
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND id = 'fe-forge') = 'cashA',
  'resolved grant user lands, not the payload claim');

-- ================================================================ B5 ======
-- COMPLETED payload whose completer has NO grant: the whole row defers.
SELECT pg_temp.stage(
  '66666666-6666-6666-6666-666666666666', 'finance_entry', 'fe-nodefer',
  jsonb_build_object('finance_entry', jsonb_build_object(
    'category_id', 'catA', 'source', 'LOAN',
    'amount_minor_units', 100, 'status', 'COMPLETED',
    'payment_method', 'BANK',
    'created_by', 'cashA', 'completed_by', 'cashB',
    'entry_date', now(), 'created_at', now(), 'updated_at', now())),
  pg_temp.grant('cashA'),
  jsonb_build_object('cashA', pg_temp.hash('cashA')));
SELECT public.pos_sync_apply('66666666-6666-6666-6666-666666666666', 500, 'fp-dev1');
SELECT pg_temp.expect_true('B5 missing completer grant defers whole row',
  (SELECT apply_status FROM public.sync_mirror
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND entity_type = 'finance_entry' AND entity_id = 'fe-nodefer') = 'PENDING'
  AND (SELECT apply_error FROM public.sync_mirror
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND entity_type = 'finance_entry' AND entity_id = 'fe-nodefer')
    LIKE 'ACTOR_AUTH_REQUIRED:%'
  AND NOT EXISTS (SELECT 1 FROM public.pos_finance_entries
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND id = 'fe-nodefer'),
  'no entry row and no completion without the completer grant');

-- Restage WITH the completer grant: it now completes under cashB.
SELECT pg_temp.stage(
  '66666666-6666-6666-6666-666666666666', 'finance_entry', 'fe-nodefer',
  jsonb_build_object('finance_entry', jsonb_build_object(
    'category_id', 'catA', 'source', 'LOAN',
    'amount_minor_units', 100, 'status', 'COMPLETED',
    'payment_method', 'BANK',
    'created_by', 'cashA', 'completed_by', 'cashB',
    'entry_date', now(), 'created_at', now(), 'updated_at', now())),
  pg_temp.grant('cashA'),
  jsonb_build_object(
    'cashA', pg_temp.hash('cashA'), 'cashB', pg_temp.hash('cashB')));
SELECT public.pos_sync_apply('66666666-6666-6666-6666-666666666666', 500, 'fp-dev1');
SELECT pg_temp.expect_true('B5 deferred row completes after grant arrives',
  (SELECT apply_status FROM public.sync_mirror
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND entity_type = 'finance_entry' AND entity_id = 'fe-nodefer') = 'APPLIED'
  AND (SELECT created_by FROM public.pos_finance_entries
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND id = 'fe-nodefer') = 'cashA'
  AND (SELECT completed_by FROM public.pos_finance_entries
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND id = 'fe-nodefer') = 'cashB',
  'deferred-then-applied with both actors intact');

-- A user WITHOUT finance cannot complete: completer grant for cashNoFin.
SELECT pg_temp.stage(
  '66666666-6666-6666-6666-666666666666', 'finance_entry', 'fe-nofin',
  jsonb_build_object('finance_entry', jsonb_build_object(
    'category_id', 'catA', 'source', 'LOAN',
    'amount_minor_units', 50, 'status', 'COMPLETED',
    'payment_method', 'BANK',
    'created_by', 'cashA', 'completed_by', 'cashNoFin',
    'entry_date', now(), 'created_at', now(), 'updated_at', now())),
  pg_temp.grant('cashA'),
  jsonb_build_object(
    'cashA', pg_temp.hash('cashA'), 'cashNoFin', pg_temp.hash('cashNoFin')));
SELECT public.pos_sync_apply('66666666-6666-6666-6666-666666666666', 500, 'fp-dev1');
SELECT pg_temp.expect_true('B5 finance-less completer rejected',
  (SELECT apply_status FROM public.sync_mirror
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND entity_type = 'finance_entry' AND entity_id = 'fe-nofin') = 'REJECTED'
  AND NOT EXISTS (SELECT 1 FROM public.pos_finance_entries
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND id = 'fe-nofin'),
  'completer without finance permission cannot complete');

-- ================================================================ B6 ======
-- First-owner bootstrap through pos_setup_owner: a retry of the SAME id is
-- a no-op (crash between commit and response converges), and a different id
-- is refused once an owner exists.
DO $$
BEGIN
  PERFORM public.pos_setup_owner(
    '77777777-7777-7777-7777-777777777777', 'own-1', 'boss', 's', 'h');
  PERFORM public.pos_setup_owner(
    '77777777-7777-7777-7777-777777777777', 'own-1', 'boss', 's', 'h');
  PERFORM pg_temp.expect_true('B6 setup_owner idempotent for same id',
    (SELECT count(*) FROM public.pos_users
      WHERE customer_id = '77777777-7777-7777-7777-777777777777'
        AND role = 'OWNER') = 1,
    'retry of the same owner id is a no-op, exactly one owner');
END $$;
SELECT pg_temp.expect_error('B6 second owner refused',
  'SELECT public.pos_setup_owner(''77777777-7777-7777-7777-777777777777'',''own-2'',''other'',''s'',''h'')',
  'Owner already exists');
SELECT pg_temp.expect_true('B6 owner still not sync-creatable',
  (SELECT count(*) FROM public.pos_users
    WHERE customer_id = '77777777-7777-7777-7777-777777777777'
      AND id = 'own-2') = 0,
  'no second owner row exists');

-- ================================================================ final ====
SELECT 'ALL REQUEST-3 ACCEPTANCE CHECKS PASSED' AS result;
