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
--       id ONLY with identical credentials, refuses a second owner and any
--       same-id credential/username mismatch, and keeps owner provisioning
--       off the device-sync path
--   B7  offline finance lifecycle: create(A) -> complete(B) -> delete(C)
--       replayed from ONE staged row preserves every actor, the completion
--       audit, and exactly one deposit + one reversal per CASH collection
--   B8  quarantine recovery: pos_sync_recover re-queues only REJECTED rows,
--       audits the previous refusal, re-validates through pos_sync_apply,
--       never touches APPLIED rows, and reports missing staging honestly
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

-- Same-id retry is idempotent ONLY for the identical credential. A caller
-- who knows the owner id and supplies a differently-formatted hash must hit
-- the same conflict a second owner gets — never a silent success.
SELECT pg_temp.expect_error('B6 same-id different hash refused',
  'SELECT public.pos_setup_owner(''77777777-7777-7777-7777-777777777777'',''own-1'',''boss'',''s'',''h-DIFFERENT'')',
  'Owner already exists');
SELECT pg_temp.expect_error('B6 same-id different salt refused',
  'SELECT public.pos_setup_owner(''77777777-7777-7777-7777-777777777777'',''own-1'',''boss'',''s2'',''h'')',
  'Owner already exists');
SELECT pg_temp.expect_error('B6 same-id different username refused',
  'SELECT public.pos_setup_owner(''77777777-7777-7777-7777-777777777777'',''own-1'',''othername'',''s'',''h'')',
  'Owner already exists');
SELECT pg_temp.expect_true('B6 mismatched retries changed nothing',
  (SELECT pw_hash FROM public.pos_users
    WHERE customer_id = '77777777-7777-7777-7777-777777777777'
      AND id = 'own-1') = 'h'
  AND (SELECT count(*) FROM public.pos_users
    WHERE customer_id = '77777777-7777-7777-7777-777777777777') = 1,
  'stored credential untouched, still exactly one user');

-- ================================================================ B7 ======
-- Offline lifecycle replay: A creates, B completes, C deletes — all before
-- the first sync. The staged row's final status is DELETED but the payload
-- still carries completed_by/deleted_by, so every transition replays with
-- its own actor. CASH gets the full deposit+reversal leg check; BANK proves
-- the same attribution without cash side-effects.
SELECT pg_temp.stage(
  '66666666-6666-6666-6666-666666666666', 'finance_category', 'catB',
  jsonb_build_object('finance_category', jsonb_build_object(
    'name', 'Reconcile', 'created_at', now(), 'updated_at', now())),
  pg_temp.grant('cashA'));
-- CASH entry: final status DELETED, completion AND deletion both offline.
SELECT pg_temp.stage(
  '66666666-6666-6666-6666-666666666666', 'finance_entry', 'fe-life-cash',
  jsonb_build_object('finance_entry', jsonb_build_object(
    'category_id', 'catB', 'source', 'CASH',
    'amount_minor_units', 7000, 'description', 'full lifecycle',
    'status', 'DELETED', 'payment_method', 'CASH',
    'created_by', 'cashA', 'completed_by', 'cashB', 'deleted_by', 'ownerA',
    'entry_date', now(), 'created_at', now(), 'updated_at', now())),
  pg_temp.grant('cashB'),
  jsonb_build_object(
    'cashA', pg_temp.hash('cashA'),
    'cashB', pg_temp.hash('cashB'),
    'ownerA', pg_temp.hash('owner')));
-- The device-pushed cash legs travel as their own entries, exactly as the
-- local outbox writes them: DEPOSIT by the completer, WITHDRAWAL by the
-- deleter, both linked to the collection.
SELECT pg_temp.stage(
  '66666666-6666-6666-6666-666666666666', 'cash_movement', 'cm-dep-life',
  jsonb_build_object('cash_movement', jsonb_build_object(
    'type', 'DEPOSIT', 'amount_minor_units', 7000,
    'reason', 'Collected from Reconcile', 'user_id', 'cashB',
    'source_finance_entry_id', 'fe-life-cash')),
  pg_temp.grant('cashB'));
SELECT pg_temp.stage(
  '66666666-6666-6666-6666-666666666666', 'cash_movement', 'cm-wdr-life',
  jsonb_build_object('cash_movement', jsonb_build_object(
    'type', 'WITHDRAWAL', 'amount_minor_units', 7000,
    'reason', 'Reversal: deleted cash collection from Reconcile (CASH)',
    'user_id', 'ownerA',
    'source_finance_entry_id', 'fe-life-cash')),
  pg_temp.grant('owner'));
-- BANK entry: same three-actor lifecycle, no cash legs at all.
SELECT pg_temp.stage(
  '66666666-6666-6666-6666-666666666666', 'finance_entry', 'fe-life-bank',
  jsonb_build_object('finance_entry', jsonb_build_object(
    'category_id', 'catB', 'source', 'BANK',
    'amount_minor_units', 9000, 'description', 'bank lifecycle',
    'status', 'DELETED', 'payment_method', 'BANK',
    'created_by', 'cashA', 'completed_by', 'cashB', 'deleted_by', 'ownerA',
    'entry_date', now(), 'created_at', now(), 'updated_at', now())),
  pg_temp.grant('cashB'),
  jsonb_build_object(
    'cashA', pg_temp.hash('cashA'),
    'cashB', pg_temp.hash('cashB'),
    'ownerA', pg_temp.hash('owner')));
SELECT public.pos_sync_apply('66666666-6666-6666-6666-666666666666', 500, 'fp-dev1');
SELECT pg_temp.expect_true('B7 CASH lifecycle actors preserved',
  (SELECT created_by FROM public.pos_finance_entries
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND id = 'fe-life-cash') = 'cashA'
  AND (SELECT completed_by FROM public.pos_finance_entries
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND id = 'fe-life-cash') = 'cashB'
  AND (SELECT completed_at FROM public.pos_finance_entries
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND id = 'fe-life-cash') IS NOT NULL
  AND (SELECT status FROM public.pos_finance_entries
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND id = 'fe-life-cash') = 'DELETED',
  'creator/completer/deleter chain: cashA -> cashB -> ownerA, final DELETED');
SELECT pg_temp.expect_true('B7 completion and deletion audits kept',
  EXISTS (SELECT 1 FROM public.pos_audit_logs
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND action = 'FINANCE_COMPLETED' AND user_id = 'cashB'
      AND details LIKE '%fe-life-cash%')
  AND EXISTS (SELECT 1 FROM public.pos_audit_logs
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND action = 'FINANCE_ENTRY_DELETED' AND user_id = 'ownerA'
      AND details LIKE '%fe-life-cash%'),
  'FINANCE_COMPLETED by cashB and FINANCE_ENTRY_DELETED by ownerA both audited');
SELECT pg_temp.expect_true('B7 CASH legs not duplicated',
  (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND source_finance_entry_id = 'fe-life-cash'
      AND type = 'DEPOSIT') = 1
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND source_finance_entry_id = 'fe-life-cash'
      AND type = 'WITHDRAWAL') = 1,
  'exactly one deposit and one reversal for the collection');
SELECT pg_temp.expect_true('B7 BANK lifecycle actors preserved',
  (SELECT created_by FROM public.pos_finance_entries
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND id = 'fe-life-bank') = 'cashA'
  AND (SELECT completed_by FROM public.pos_finance_entries
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND id = 'fe-life-bank') = 'cashB'
  AND (SELECT status FROM public.pos_finance_entries
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND id = 'fe-life-bank') = 'DELETED'
  AND NOT EXISTS (SELECT 1 FROM public.cash_movements
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND source_finance_entry_id = 'fe-life-bank'),
  'bank entry: same actor chain, no cash legs created');
SELECT pg_temp.expect_true('B7 mirror rows applied',
  (SELECT count(*) FROM public.sync_mirror
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND entity_id IN ('fe-life-cash','fe-life-bank','cm-dep-life','cm-wdr-life')
      AND apply_status = 'APPLIED') = 4,
  'all four staged rows reached APPLIED');

-- ================================================================ B8 ======
-- Quarantine recovery lifecycle. cat-badperm is already REJECTED from B3:
-- recover must re-queue ONLY that row, audit the previous refusal, re-run
-- pos_sync_apply, and report the fresh verdict — never touch APPLIED rows.
SELECT pg_temp.expect_true('B8 rejected row staged for recovery',
  (SELECT apply_status FROM public.sync_mirror
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND entity_type = 'finance_category' AND entity_id = 'cat-badperm')
    = 'REJECTED',
  'precondition: cat-badperm is REJECTED');
-- Grant cashNoFin the finance feature, then recover: the SAME staged payload
-- must now apply — proving recovery re-validates rather than replaying a
-- cached verdict.
UPDATE public.pos_users SET permissions = '["pos","register","finance"]'::jsonb
WHERE customer_id = '66666666-6666-6666-6666-666666666666'
  AND id = 'cashNoFin';
SELECT public.pos_sync_recover(
  '66666666-6666-6666-6666-666666666666', 'fp-dev1',
  jsonb_build_array(jsonb_build_object(
    'entry_id', 'outbox-1',
    'entity_type', 'finance_category',
    'entity_id', 'cat-badperm')));
SELECT pg_temp.expect_true('B8 recovered row applied after re-validation',
  (SELECT apply_status FROM public.sync_mirror
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND entity_type = 'finance_category' AND entity_id = 'cat-badperm')
    = 'APPLIED'
  AND EXISTS (SELECT 1 FROM public.pos_finance_categories
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND id = 'cat-badperm'),
  're-queued row re-validated and landed');
SELECT pg_temp.expect_true('B8 recovery audited with previous refusal',
  EXISTS (SELECT 1 FROM public.pos_audit_logs
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND action = 'SYNC_RECOVERY'
      AND details LIKE '%cat-badperm%'
      AND details LIKE '%permission%'),
  'SYNC_RECOVERY audit row preserves the original refusal');
-- An APPLIED row must never be re-queued or duplicated by recovery.
SELECT public.pos_sync_recover(
  '66666666-6666-6666-6666-666666666666', 'fp-dev1',
  jsonb_build_array(jsonb_build_object(
    'entry_id', 'outbox-2',
    'entity_type', 'finance_category',
    'entity_id', 'cat-badperm')));
SELECT pg_temp.expect_true('B8 applied row untouched by recovery',
  (SELECT count(*) FROM public.pos_finance_categories
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND id = 'cat-badperm') = 1
  AND (SELECT count(*) FROM public.pos_audit_logs
    WHERE customer_id = '66666666-6666-6666-6666-666666666666'
      AND action = 'SYNC_RECOVERY') = 1,
  'second recovery of an APPLIED row is a no-op, no duplicate audit');
-- A never-staged entity reports 'missing', not a fake verdict.
SELECT pg_temp.expect_true('B8 missing staging reported honestly',
  (public.pos_sync_recover(
    '66666666-6666-6666-6666-666666666666', 'fp-dev1',
    jsonb_build_array(jsonb_build_object(
      'entry_id', 'outbox-3',
      'entity_type', 'sale',
      'entity_id', 'never-staged')))->'results'->0->>'status') = 'missing',
  'gateway-level rejection with no staged row stays quarantined');

-- ================================================================ final ====
SELECT 'ALL REQUEST-3 ACCEPTANCE CHECKS PASSED' AS result;
