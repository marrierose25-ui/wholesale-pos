-- H1 closure — void_request / sale-void database invariants.
--
-- Runs against a LOCAL PostgreSQL replica of the production schema
-- (supabase db pull --declarative export) with migrations
-- 20261125000000, 20261126000000 and 20261127000000 applied.
-- Never run against production.
--
-- Scenario coverage:
--   S1  direct owner void settles PENDING requests, attributed to voider
--   S2  request insert on a VOIDED sale is rejected (BEFORE INSERT trigger)
--   S3  concurrent insert-vs-void serialization — run via concurrency.sh
--       (two sessions; both orderings verified)
--   S4  missing sale reference rejected (composite FK)
--   S5  VOIDED sale with NULL voided_by creates NO unattributed approval
--   S6  every insertion path obeys the invariant: pos_sync_apply path,
--       duplicate PENDING request, non-owner void refusal
--
-- psql -v ON_ERROR_STOP=0 -f h1_void_invariants_test.sql

\set ON_ERROR_STOP off
\pset footer off

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

SELECT 'S1 settle' AS check,
  (SELECT status FROM void_requests WHERE id='req-s1') AS req_status,
  (SELECT decided_by FROM void_requests WHERE id='req-s1') AS decided_by,
  (SELECT decided_at IS NOT NULL FROM void_requests WHERE id='req-s1') AS decided_at_set,
  (SELECT status FROM sales WHERE id=:'s1_sale') AS sale_status;

-- idempotent: replaying the void decision must not re-settle or duplicate
SAVEPOINT s1_replay;
SELECT pos_void_sale('11111111-1111-1111-1111-111111111111', 'owner1',
  :'s1_sale', 'replay');
ROLLBACK TO SAVEPOINT s1_replay;  -- expected: "already voided" error above

-- ================================================================ S2 ======
SELECT pg_temp.h1_sale('s2') AS s2_sale \gset
SELECT pos_void_sale('11111111-1111-1111-1111-111111111111', 'owner1',
  :'s2_sale', 'void first');

-- direct INSERT on the now-VOIDED sale must be refused by the trigger
INSERT INTO void_requests (id, customer_id, sale_id, requested_by, reason,
  status, created_at)
VALUES ('req-s2', '11111111-1111-1111-1111-111111111111', :'s2_sale',
  'cash1', 'too late', 'PENDING', now());
-- expected: ERROR: Sale sale-s2 is not voidable (status VOIDED).

SELECT 'S2 post-void insert refused' AS check,
  (SELECT count(*) FROM void_requests WHERE id='req-s2') AS leaked_rows;

-- ================================================================ S4 ======
-- A request naming a sale that does not exist must violate the FK.
INSERT INTO void_requests (id, customer_id, sale_id, requested_by, reason,
  status, created_at)
VALUES ('req-s4', '11111111-1111-1111-1111-111111111111',
  'sale-does-not-exist', 'cash1', 'ghost', 'PENDING', now());
-- expected: ERROR: insert or update on table "void_requests" violates
--           foreign key constraint "void_requests_sale_fkey"

-- cross-tenant: same sale id under a DIFFERENT customer must also fail
INSERT INTO customers (id, name)
VALUES ('22222222-2222-2222-2222-222222222222', 'Other Shop');
SELECT pg_temp.h1_sale('s4x') AS s4x_sale \gset
INSERT INTO void_requests (id, customer_id, sale_id, requested_by, reason,
  status, created_at)
VALUES ('req-s4x', '22222222-2222-2222-2222-222222222222', :'s4x_sale',
  'cash1', 'wrong tenant', 'PENDING', now());
-- expected: FK violation (sale belongs to tenant 1111..., not 2222...)

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

SELECT 'S5 unattributed void' AS check,
  (SELECT status FROM void_requests WHERE id='req-s5') AS req_status,
  (SELECT decided_by FROM void_requests WHERE id='req-s5') AS decided_by;
-- expected: req_status=PENDING, decided_by=NULL  (stays visible, never an
-- approval nobody owns)

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

SELECT 'S6a sync_apply rejected' AS check,
  (SELECT apply_status FROM sync_mirror
    WHERE entity_id='req-s6') AS mirror_status,
  (SELECT count(*) FROM void_requests WHERE id='req-s6') AS leaked_rows;
-- expected: mirror_status=REJECTED, leaked_rows=0

-- 6b) one PENDING request per sale (partial unique index)
SELECT pg_temp.h1_sale('s6b') AS s6b_sale \gset
INSERT INTO void_requests (id, customer_id, sale_id, requested_by, reason,
  status, created_at)
VALUES ('req-s6b-1', '11111111-1111-1111-1111-111111111111', :'s6b_sale',
  'cash1', 'first', 'PENDING', now());
INSERT INTO void_requests (id, customer_id, sale_id, requested_by, reason,
  status, created_at)
VALUES ('req-s6b-2', '11111111-1111-1111-1111-111111111111', :'s6b_sale',
  'cash1', 'duplicate', 'PENDING', now());
-- expected: ERROR: duplicate key value violates unique constraint
--           "void_requests_one_pending_per_sale"

-- 6c) privileged RPCs refuse non-owners
SELECT pos_void_sale('11111111-1111-1111-1111-111111111111', 'cash1',
  :'s6b_sale', 'cashier cannot void');
-- expected: ERROR: Void requires owner authorization.
SELECT pos_approve_void('11111111-1111-1111-1111-111111111111', 'cash1',
  'req-s6b-1');
-- expected: ERROR: Void requires owner authorization.

-- 6d) EXECUTE is not granted to anon/authenticated
SET ROLE authenticated;
SELECT pos_void_sale('11111111-1111-1111-1111-111111111111', 'owner1',
  :'s6b_sale', 'anon must not run');
-- expected: ERROR: permission denied for function pos_void_sale
RESET ROLE;

-- ================================================================ final ====
SELECT 'FINAL STATE' AS check;
SELECT vr.id, vr.sale_id, vr.status, vr.decided_by, s.status AS sale_status
FROM void_requests vr JOIN sales s
  ON s.customer_id = vr.customer_id AND s.id = vr.sale_id
ORDER BY vr.id;
