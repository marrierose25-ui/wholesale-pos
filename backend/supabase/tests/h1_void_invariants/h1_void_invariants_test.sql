-- H1 closure — void_request / sale-void database invariants.
--
-- Runs against the replayed schema (replay_migrations.sh output) in CI.
-- Never run against production.
--
-- Scenario coverage:
--   S1  direct owner void settles PENDING requests, attributed to voider
--   S2  request insert on a VOIDED sale is rejected (BEFORE INSERT trigger)
--   S3  concurrent insert-vs-void — run via concurrency.sh (two sessions;
--       both orderings verified, plus a true parallel race whose invariant
--       is asserted regardless of which side wins)
--   S4  missing sale reference rejected (composite FK)
--   S5  VOIDED sale with NULL voided_by creates NO unattributed approval
--   S6  every insertion path obeys the invariant: pos_sync_apply path,
--       duplicate PENDING request, non-owner void refusal, EXECUTE grants
--
-- Every expected outcome is ASSERTED: pg_temp.expect_error requires the
-- statement to fail with a matching message, pg_temp.expect_state raises on
-- any deviation. Run with ON_ERROR_STOP=1 — an unexpected SQL error aborts
-- the script with a non-zero exit.

\set ON_ERROR_STOP on
\pset footer off

-- ------------------------------------------------------------- helpers --
-- Assert that executing p_sql raises an error whose message contains
-- p_pattern. A statement that SUCCEEDS is itself a failure.
CREATE OR REPLACE FUNCTION pg_temp.expect_error(
  p_label   text,
  p_sql     text,
  p_pattern text
) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%' || p_pattern || '%' THEN
      RAISE NOTICE 'PASS % (expected error: %)', p_label, SQLERRM;
      RETURN;
    END IF;
    RAISE EXCEPTION 'FAIL %: expected error matching /%/ but got: %',
      p_label, p_pattern, SQLERRM;
  END;
  RAISE EXCEPTION 'FAIL %: expected error matching /%/ but statement succeeded',
    p_label, p_pattern;
END $$;

-- Assert a boolean condition, raising on false.
CREATE OR REPLACE FUNCTION pg_temp.expect_true(
  p_label  text,
  p_ok     boolean,
  p_detail text DEFAULT ''
) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok THEN
    RAISE NOTICE 'PASS % %', p_label, p_detail;
  ELSE
    RAISE EXCEPTION 'FAIL %: %', p_label, p_detail;
  END IF;
END $$;

-- ---------------------------------------------------------------- seed --
DELETE FROM void_requests;
DELETE FROM sales;
DELETE FROM pos_users;
DELETE FROM customers;

INSERT INTO customers (id, name)
VALUES ('11111111-1111-1111-1111-111111111111', 'H1 Test Shop');

INSERT INTO pos_users (id, customer_id, username, role, pw_salt, pw_hash)
VALUES
  ('owner1', '11111111-1111-1111-1111-111111111111', 'owner', 'OWNER', 's', 'h'),
  ('cash1',  '11111111-1111-1111-1111-111111111111', 'cash',  'CASHIER', 's', 'h');

CREATE TEMP TABLE h1_sales (label text PRIMARY KEY, id text);

-- helper: one COMPLETED sale per scenario label
CREATE OR REPLACE FUNCTION pg_temp.h1_sale(p_label text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE sid text := 'sale-' || p_label;
BEGIN
  INSERT INTO sales (id, customer_id, receipt_number, cashier_id, device_id,
    shift_id, payment_method, subtotal_minor_units, discount_minor_units,
    total_minor_units, amount_paid_minor_units, change_minor_units,
    status, created_at)
  VALUES (sid, '11111111-1111-1111-1111-111111111111',
    'R-' || p_label, 'cash1', 'dev1', 'shift1', 'CASH',
    1000, 0, 1000, 1000, 0, 'COMPLETED', now())
  ON CONFLICT (customer_id, id) DO NOTHING;
  RETURN sid;
END $$;

-- ================================================================ S1 ======
-- PENDING request + direct owner void => APPROVED, decided_by = voider.
SELECT pg_temp.h1_sale('s1') AS s1_sale \gset
INSERT INTO void_requests (id, customer_id, sale_id, requested_by, reason,
  status, created_at)
VALUES ('req-s1', '11111111-1111-1111-1111-111111111111', :'s1_sale',
  'cash1', 'customer changed mind', 'PENDING', now());

SELECT pos_void_sale('11111111-1111-1111-1111-111111111111', 'owner1',
  :'s1_sale', 'owner voided directly');

SELECT pg_temp.expect_true('S1 settle',
  (SELECT status FROM void_requests WHERE id='req-s1') = 'APPROVED'
  AND (SELECT decided_by FROM void_requests WHERE id='req-s1') = 'owner1'
  AND (SELECT decided_at IS NOT NULL FROM void_requests WHERE id='req-s1')
  AND (SELECT status FROM sales WHERE id=:'s1_sale') = 'VOIDED',
  'request APPROVED by owner1, sale VOIDED');

-- idempotent: replaying the void decision must not re-settle or duplicate
SELECT pg_temp.expect_error('S1 void replay',
  format('SELECT pos_void_sale(%L,%L,%L,%L)',
    '11111111-1111-1111-1111-111111111111', 'owner1', :'s1_sale', 'replay'),
  'already voided');

-- ================================================================ S2 ======
SELECT pg_temp.h1_sale('s2') AS s2_sale \gset
SELECT pos_void_sale('11111111-1111-1111-1111-111111111111', 'owner1',
  :'s2_sale', 'void first');

-- direct INSERT on the now-VOIDED sale must be refused by the trigger
SELECT pg_temp.expect_error('S2 post-void insert',
  format($f$INSERT INTO void_requests (id, customer_id, sale_id, requested_by, reason, status, created_at)
    VALUES ('req-s2','11111111-1111-1111-1111-111111111111',%L,'cash1','too late','PENDING',now())$f$,
    :'s2_sale'),
  'not voidable');

SELECT pg_temp.expect_true('S2 no leaked row',
  (SELECT count(*) FROM void_requests WHERE id='req-s2') = 0,
  'no void_request row exists for the voided sale');

-- ================================================================ S4 ======
-- A request naming a sale that does not exist must violate the FK.
SELECT pg_temp.expect_error('S4 missing sale FK',
  $f$INSERT INTO void_requests (id, customer_id, sale_id, requested_by, reason, status, created_at)
    VALUES ('req-s4','11111111-1111-1111-1111-111111111111','sale-does-not-exist','cash1','ghost','PENDING',now())$f$,
  'foreign key');

-- cross-tenant: same sale id shape under a DIFFERENT customer must also fail
INSERT INTO customers (id, name)
VALUES ('22222222-2222-2222-2222-222222222222', 'Other Shop');
SELECT pg_temp.h1_sale('s4x') AS s4x_sale \gset
SELECT pg_temp.expect_error('S4 cross-tenant FK',
  format($f$INSERT INTO void_requests (id, customer_id, sale_id, requested_by, reason, status, created_at)
    VALUES ('req-s4x','22222222-2222-2222-2222-222222222222',%L,'cash1','wrong tenant','PENDING',now())$f$,
    :'s4x_sale'),
  'foreign key');

-- ================================================================ S5 ======
-- A sale reaching VOIDED with voided_by NULL must NOT produce approvals.
SELECT pg_temp.h1_sale('s5') AS s5_sale \gset
INSERT INTO void_requests (id, customer_id, sale_id, requested_by, reason,
  status, created_at)
VALUES ('req-s5', '11111111-1111-1111-1111-111111111111', :'s5_sale',
  'cash1', 'orphaned decision', 'PENDING', now());

-- Simulate a legacy/corrupt void path that records no actor.
UPDATE sales SET status='VOIDED', voided_at=now(), voided_by=NULL
WHERE id=:'s5_sale';

SELECT pg_temp.expect_true('S5 unattributed void',
  (SELECT status FROM void_requests WHERE id='req-s5') = 'PENDING'
  AND (SELECT decided_by FROM void_requests WHERE id='req-s5') IS NULL,
  'request stays PENDING with no decided_by — never an ownerless approval');

-- ================================================================ S6 ======
-- 6a) pos_sync_apply path: a staged void_request for a VOIDED sale is
--     REJECTED, never inserted.
SELECT pg_temp.h1_sale('s6') AS s6_sale \gset
SELECT pos_void_sale('11111111-1111-1111-1111-111111111111', 'owner1',
  :'s6_sale', 'voided before sync arrived');

INSERT INTO sync_mirror (customer_id, entity_type, entity_id, operation,
  device_id, payload, apply_status)
VALUES ('11111111-1111-1111-1111-111111111111', 'void_request', 'req-s6',
  'UPSERT', 'dev1',
  jsonb_build_object('void_request', jsonb_build_object(
    'sale_id', :'s6_sale', 'requested_by', 'cash1',
    'reason', 'offline request', 'created_at', now())),
  'PENDING');

SELECT pos_sync_apply('11111111-1111-1111-1111-111111111111', 50);

SELECT pg_temp.expect_true('S6a sync_apply rejected',
  (SELECT apply_status FROM sync_mirror WHERE entity_id='req-s6') = 'REJECTED'
  AND (SELECT count(*) FROM void_requests WHERE id='req-s6') = 0,
  'mirror REJECTED, no void_request row leaked');

-- 6b) one PENDING request per sale (partial unique index)
SELECT pg_temp.h1_sale('s6b') AS s6b_sale \gset
INSERT INTO void_requests (id, customer_id, sale_id, requested_by, reason,
  status, created_at)
VALUES ('req-s6b-1', '11111111-1111-1111-1111-111111111111', :'s6b_sale',
  'cash1', 'first', 'PENDING', now());
SELECT pg_temp.expect_error('S6b duplicate pending',
  format($f$INSERT INTO void_requests (id, customer_id, sale_id, requested_by, reason, status, created_at)
    VALUES ('req-s6b-2','11111111-1111-1111-1111-111111111111',%L,'cash1','duplicate','PENDING',now())$f$,
    :'s6b_sale'),
  'void_requests_one_pending_per_sale');

-- 6c) privileged RPCs refuse non-owners
SELECT pg_temp.expect_error('S6c cashier void refused',
  format('SELECT pos_void_sale(%L,%L,%L,%L)',
    '11111111-1111-1111-1111-111111111111', 'cash1', :'s6b_sale',
    'cashier cannot void'),
  'owner authorization');
SELECT pg_temp.expect_error('S6c cashier approve refused',
  'SELECT pos_approve_void(''11111111-1111-1111-1111-111111111111'',''cash1'',''req-s6b-1'')',
  'owner authorization');

-- 6d) EXECUTE is not granted to anon/authenticated — asserted via the
--     catalog rather than SET ROLE, which cannot run inside a transaction.
SELECT pg_temp.expect_true('S6d no anon/auth EXECUTE',
  NOT has_function_privilege('anon',
      'public.pos_void_sale(uuid,text,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated',
      'public.pos_void_sale(uuid,text,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('anon',
      'public.pos_approve_void(uuid,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated',
      'public.pos_approve_void(uuid,text,text)', 'EXECUTE'),
  'pos_void_sale/pos_approve_void not executable by anon/authenticated');

-- ================================================================ final ====
SELECT 'ALL H1 INVARIANT CHECKS PASSED' AS result;
SELECT vr.id, vr.sale_id, vr.status, vr.decided_by, s.status AS sale_status
FROM void_requests vr JOIN sales s
  ON s.customer_id = vr.customer_id AND s.id = vr.sale_id
ORDER BY vr.id;
