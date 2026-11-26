-- Request 3 financial integrity, on the REAL schema (migration
-- 20261204000000_request3_financial_integrity).
--
-- Runs against the replayed schema AFTER request3_acceptance in CI.
-- Never run against production.
--
--   F1  atomic leg dedup: two different movement ids for the same
--       (collection, leg) converge on ONE row — the loser gets the existing
--       movement back, never a financial failure; unrelated legs still land
--   F2  legacy reversal, already-landed: an unlinked pre-20261204 reversal
--       whose exact generated reason + amount identify ONE collection is
--       LINKED by the delete path instead of a second withdrawal
--   F3  legacy reversal ambiguity: two matching unlinked reversals refuse
--       the delete (LEGACY_REVERSAL_AMBIGUOUS), change nothing, and resolve
--       cleanly once an operator links the correct movement
--   F4  legacy reversal through the staged sync path: an unlinked reversal
--       and its DELETED finance payload arrive together; apply links the
--       movement and deletes the collection with no second withdrawal
--   F5  staged ambiguity: two matching staged reversals leave the finance
--       entry PENDING with LEGACY_REVERSAL_AMBIGUOUS (payload preserved),
--       then converge after the operator links the right movement
--   F6  new-format dedup through sync: two staged WITHDRAWALs and one
--       staged DEPOSIT for the same collection each land exactly once
--   G1  bidirectional uniqueness: one unlinked reversal matching TWO
--       collections is claimed by NEITHER — both deletes defer
--   G4  category rename: exact reason no longer matches, but a plausible
--       unlinked reversal blocks the server fallback — delete deferred,
--       no duplicate drawer movement (direct RPC + staged path)
--   G5  reason/source mismatch: a reversal-shaped unlinked withdrawal of
--       the same amount is still "possible old reversal" evidence — the
--       delete defers instead of writing a second reversal
--   G6  actor mismatch: exact reason + amount but wrong actor — no
--       automatic association, delete deferred
--   G7  genuinely missing reversal: exactly one server-written leg
--       (covered by the fe-f7 assertion in F6)
--   G8-G10 exact-unique match, multi-withdrawal ambiguity and new-format
--       dedup remain covered by F2/F3/F5/F6 above
--
-- psql -v ON_ERROR_STOP=1 -f request3_financial_integrity_test.sql

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
  p_device text DEFAULT 'fp-fin1'
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

-- Seed a completed CASH collection the way the cloud stores it after the
-- finance lifecycle replay: entry COMPLETED plus its linked DEPOSIT leg.
CREATE OR REPLACE FUNCTION pg_temp.mk_collection(
  p_id text, p_amount bigint, p_cat text, p_source text,
  p_by text, p_reason_cat text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_cat text := COALESCE(p_reason_cat, p_cat);
BEGIN
  INSERT INTO public.pos_finance_categories (id, customer_id, name, created_at)
  VALUES (p_cat, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_cat, now())
  ON CONFLICT (customer_id, id) DO NOTHING;
  INSERT INTO public.pos_finance_entries (
    id, customer_id, category_id, source, amount_minor_units, description,
    status, entry_date, created_at, created_by, completed_at, completed_by,
    updated_at, payment_method)
  VALUES (
    p_id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', p_cat, p_source, p_amount,
    'fixture', 'COMPLETED', now(), now(), p_by, now(), p_by, now(), 'CASH');
  INSERT INTO public.cash_movements (
    id, customer_id, shift_id, user_id, type, amount_minor_units, reason,
    created_at, source_finance_entry_id)
  VALUES (
    'dep-' || p_id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    (SELECT id FROM public.shifts
      WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND status = 'OPEN' LIMIT 1),
    p_by, 'DEPOSIT', p_amount,
    'Collected from ' || v_cat, now(), p_id);
END $$;

-- Legacy (pre-20261204) reversal: WITHDRAWAL with NO source link and the
-- exact generated reason the old client wrote.
CREATE OR REPLACE FUNCTION pg_temp.mk_legacy_reversal(
  p_id text, p_amount bigint, p_cat text, p_source text,
  p_user text, p_shift text
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.cash_movements (
    id, customer_id, shift_id, user_id, type, amount_minor_units, reason,
    created_at, source_finance_entry_id)
  VALUES (
    p_id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', p_shift, p_user,
    'WITHDRAWAL', p_amount,
    'Reversal: deleted cash collection from ' || p_cat || ' (' || p_source || ')',
    now(), NULL);
END $$;

-- ---------------------------------------------------------------- seed --
-- Scoped to this suite's tenant: earlier suites' rows stay untouched.
DELETE FROM actor_grants
WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
DELETE FROM sync_mirror
WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
DELETE FROM void_requests
WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
DELETE FROM cash_movements
WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
DELETE FROM sale_items
WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
DELETE FROM sales
WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
DELETE FROM shifts
WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
DELETE FROM pos_finance_entries
WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
DELETE FROM pos_finance_categories
WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
DELETE FROM pos_audit_logs
WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
DELETE FROM pos_users
WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
DELETE FROM device_registrations
WHERE activation_code = 'FIN-CODE-AAAA-BBBB-CCCC-DDDD';
DELETE FROM licenses
WHERE activation_code = 'FIN-CODE-AAAA-BBBB-CCCC-DDDD';
DELETE FROM customers
WHERE id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

INSERT INTO customers (id, name)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'R3 Finite Shop');
INSERT INTO licenses (activation_code, customer_id, seat_limit)
VALUES ('FIN-CODE-AAAA-BBBB-CCCC-DDDD',
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 1);
INSERT INTO device_registrations
  (activation_code, device_fingerprint, device_name)
VALUES ('FIN-CODE-AAAA-BBBB-CCCC-DDDD', 'fp-fin1', 'till fin');

INSERT INTO pos_users
  (id, customer_id, username, role, pw_salt, pw_hash, active, permissions)
VALUES
  ('fin-owner', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-owner', 'OWNER',
   's', 'h-o', true, '[]'::jsonb),
  ('fin-cash', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash', 'CASHIER',
   's', 'h-c', true, '["pos","register","finance"]'::jsonb),
  ('fin-cash2', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash2', 'CASHIER',
   's', 'h-c2', true, '["pos","register","finance"]'::jsonb);

CREATE TEMP TABLE fin_grants (label text PRIMARY KEY, token text NOT NULL);
INSERT INTO fin_grants (label, token) VALUES
  ('owner', (public.pos_issue_actor_grant(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-owner', 'fp-fin1', 3600)->>'grant')),
  ('cash', (public.pos_issue_actor_grant(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash', 'fp-fin1', 3600)->>'grant'));

CREATE OR REPLACE FUNCTION pg_temp.fgrant(p_label text) RETURNS text
LANGUAGE sql AS $$ SELECT token FROM fin_grants WHERE label = p_label $$;
CREATE OR REPLACE FUNCTION pg_temp.fhash(p_label text) RETURNS text
LANGUAGE sql AS $$
  SELECT public.pos_actor_grant_hash(token) FROM fin_grants WHERE label = p_label
$$;

DO $$
DECLARE v_shift text;
BEGIN
  v_shift := public.pos_ensure_shift(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash', 'fp-fin1');
  PERFORM pg_temp.mk_collection(
    'fe-f1', 5000, 'cat-f1', 'Till', 'fin-cash');
  PERFORM pg_temp.mk_collection(
    'fe-f2', 6000, 'cat-f2', 'Bank', 'fin-cash');
  PERFORM pg_temp.mk_collection(
    'fe-f6', 8000, 'cat-f6', 'Route', 'fin-cash');
  -- Deposit but NO reversal anywhere: the missing-leg fallback case.
  PERFORM pg_temp.mk_collection(
    'fe-f7', 9000, 'cat-f7', 'Safe', 'fin-cash');
END $$;

-- ================================================================ F1 ======
-- Atomic leg dedup through the checked RPC: same (collection, leg), two
-- different movement ids — exactly one row survives and the loser is handed
-- the existing movement, not an error.
DO $$
DECLARE
  v_shift text;
  v_first jsonb;
  v_second jsonb;
BEGIN
  SELECT id INTO v_shift FROM public.shifts
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND status = 'OPEN' LIMIT 1;

  v_first := public.pos_add_cash_movement(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash', v_shift,
    'WITHDRAWAL', 5000, 'device reversal a', NULL, 'mv-w-1', 'fe-f1');
  v_second := public.pos_add_cash_movement(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash', v_shift,
    'WITHDRAWAL', 5000, 'device reversal b', NULL, 'mv-w-2', 'fe-f1');

  PERFORM pg_temp.expect_true('F1 concurrent-leg withdrawals converge',
    (v_first->>'id') = 'mv-w-1'
    AND (v_second->>'id') = 'mv-w-1'
    AND (v_second->>'duplicate')::boolean
    AND (SELECT count(*) FROM public.cash_movements
      WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND source_finance_entry_id = 'fe-f1' AND type = 'WITHDRAWAL') = 1,
    'second id got the existing movement back, one WITHDRAWAL row');

  -- Same for the DEPOSIT leg: the device-pushed deposit must converge on
  -- the leg the completion RPC already wrote.
  v_first := public.pos_add_cash_movement(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash', v_shift,
    'DEPOSIT', 5000, 'device deposit a', NULL, 'mv-d-1', 'fe-f1');
  v_second := public.pos_add_cash_movement(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash', v_shift,
    'DEPOSIT', 5000, 'device deposit b', NULL, 'mv-d-2', 'fe-f1');

  PERFORM pg_temp.expect_true('F1 concurrent-leg deposits converge',
    (v_first->>'id') = 'dep-fe-f1'
    AND (v_second->>'id') = 'dep-fe-f1'
    AND (SELECT count(*) FROM public.cash_movements
      WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND source_finance_entry_id = 'fe-f1' AND type = 'DEPOSIT') = 1,
    'both deposits resolved to the existing leg');

  -- Legitimate unrelated movements are untouched: an unlinked withdrawal
  -- and a withdrawal on a DIFFERENT collection both insert.
  v_first := public.pos_add_cash_movement(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash', v_shift,
    'WITHDRAWAL', 500, 'petty cash', NULL, 'mv-u-1', NULL);
  v_second := public.pos_add_cash_movement(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash', v_shift,
    'WITHDRAWAL', 6000, 'reversal b-collection', NULL, 'mv-w-3', 'fe-f2');
  PERFORM pg_temp.expect_true('F1 unrelated movements still land',
    (v_first->>'id') = 'mv-u-1' AND (v_first->>'duplicate') IS NULL
    AND (v_second->>'id') = 'mv-w-3'
    AND (SELECT count(*) FROM public.cash_movements
      WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND source_finance_entry_id = 'fe-f2' AND type = 'WITHDRAWAL') = 1,
    'unlinked and other-collection legs are independent');
END $$;

-- ================================================================ F2 ======
-- Legacy unlinked reversal, already in cash_movements: the delete path must
-- LINK it (exact generated reason + amount) instead of writing a second one.
DO $$
DECLARE v_shift text;
BEGIN
  SELECT id INTO v_shift FROM public.shifts
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND status = 'OPEN' LIMIT 1;
  PERFORM pg_temp.mk_collection(
    'fe-leg1', 3000, 'cat-leg1', 'Counter', 'fin-cash', 'LegacyCat');
  PERFORM pg_temp.mk_legacy_reversal(
    'leg-w1', 3000, 'LegacyCat', 'Counter', 'fin-cash', v_shift);
END $$;
SELECT public.pos_delete_finance_entry(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash', 'fe-leg1');
SELECT pg_temp.expect_true('F2 unique legacy reversal linked not duplicated',
  (SELECT status FROM public.pos_finance_entries
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'fe-leg1') = 'DELETED'
  AND (SELECT deleted_by FROM public.pos_finance_entries
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'fe-leg1') = 'fin-cash'
  AND (SELECT source_finance_entry_id FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'leg-w1') = 'fe-leg1'
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND source_finance_entry_id = 'fe-leg1' AND type = 'WITHDRAWAL') = 1,
  'existing unlinked reversal adopted; no second withdrawal written');
SELECT pg_temp.expect_true('F2 legacy link audited',
  EXISTS (SELECT 1 FROM public.pos_audit_logs
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND action = 'LEGACY_REVERSAL_LINKED'
      AND details LIKE '%leg-w1%' AND details LIKE '%fe-leg1%'),
  'LEGACY_REVERSAL_LINKED audit row recorded');

-- ================================================================ F3 ======
-- Two matching unlinked reversals: ambiguous — the delete must refuse,
-- change nothing, and only proceed once an operator links the right one.
DO $$
DECLARE v_shift text;
BEGIN
  SELECT id INTO v_shift FROM public.shifts
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND status = 'OPEN' LIMIT 1;
  PERFORM pg_temp.mk_collection(
    'fe-leg2', 4000, 'cat-leg2', 'Van', 'fin-cash', 'AmbigCat');
  PERFORM pg_temp.mk_legacy_reversal(
    'leg-w2a', 4000, 'AmbigCat', 'Van', 'fin-cash', v_shift);
  PERFORM pg_temp.mk_legacy_reversal(
    'leg-w2b', 4000, 'AmbigCat', 'Van', 'fin-cash', v_shift);
END $$;
SELECT pg_temp.expect_error('F3 ambiguous legacy reversals refuse delete',
  'SELECT public.pos_delete_finance_entry(''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'',''fin-cash'',''fe-leg2'')',
  'LEGACY_REVERSAL_AMBIGUOUS');
SELECT pg_temp.expect_true('F3 refusal changed nothing',
  (SELECT status FROM public.pos_finance_entries
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'fe-leg2') = 'COMPLETED'
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND source_finance_entry_id = 'fe-leg2'
      AND type = 'WITHDRAWAL') = 0
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id IN ('leg-w2a','leg-w2b')
      AND source_finance_entry_id IS NULL) = 2,
  'entry still COMPLETED, both reversals still unlinked, no new leg');
-- Operator resolution: link the correct movement, retry the delete.
UPDATE public.cash_movements SET source_finance_entry_id = 'fe-leg2'
WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND id = 'leg-w2a';
SELECT public.pos_delete_finance_entry(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash', 'fe-leg2');
SELECT pg_temp.expect_true('F3 resolved ambiguity deletes cleanly',
  (SELECT status FROM public.pos_finance_entries
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'fe-leg2') = 'DELETED'
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND source_finance_entry_id = 'fe-leg2' AND type = 'WITHDRAWAL') = 1,
  'exactly the operator-linked reversal stands for the collection');

-- ================================================================ F4 ======
-- Staged path: the unlinked legacy reversal AND the DELETED finance payload
-- arrive in one sync batch. Apply must link the movement and delete the
-- collection without writing a second reversal.
SELECT pg_temp.stage(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'finance_category', 'cat-leg3',
  jsonb_build_object('finance_category', jsonb_build_object(
    'name', 'StagedCat', 'created_at', now(), 'updated_at', now())),
  pg_temp.fgrant('cash'));
SELECT pg_temp.stage(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'cash_movement', 'cm-leg3',
  jsonb_build_object('cash_movement', jsonb_build_object(
    'type', 'WITHDRAWAL', 'amount_minor_units', 5000,
    'reason', 'Reversal: deleted cash collection from StagedCat (Route)',
    'user_id', 'fin-cash')),
  pg_temp.fgrant('cash'));
SELECT pg_temp.stage(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'finance_entry', 'fe-leg3',
  jsonb_build_object('finance_entry', jsonb_build_object(
    'category_id', 'cat-leg3', 'source', 'Route',
    'amount_minor_units', 5000, 'description', 'staged legacy lifecycle',
    'status', 'DELETED', 'payment_method', 'CASH',
    'created_by', 'fin-cash', 'completed_by', 'fin-cash',
    'deleted_by', 'fin-cash',
    'entry_date', now(), 'created_at', now(), 'updated_at', now())),
  pg_temp.fgrant('cash'),
  jsonb_build_object('fin-cash', pg_temp.fhash('cash')));
SELECT public.pos_sync_apply('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 500, 'fp-fin1');
SELECT pg_temp.expect_true('F4 staged legacy reversal reconciled',
  (SELECT status FROM public.pos_finance_entries
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'fe-leg3') = 'DELETED'
  AND (SELECT source_finance_entry_id FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'cm-leg3') = 'fe-leg3'
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND source_finance_entry_id = 'fe-leg3' AND type = 'WITHDRAWAL') = 1
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND source_finance_entry_id = 'fe-leg3' AND type = 'DEPOSIT') = 1,
  'staged unlinked reversal linked; one deposit + one reversal total');
SELECT pg_temp.expect_true('F4 staged rows all applied',
  (SELECT count(*) FROM public.sync_mirror
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND entity_id IN ('cat-leg3','cm-leg3','fe-leg3')
      AND apply_status = 'APPLIED') = 3,
  'category, movement and entry all reached APPLIED');

-- ================================================================ F5 ======
-- Staged ambiguity: two matching unlinked reversals + a DELETED payload.
-- The entry must stay PENDING with a durable marker — never guessed, never
-- acknowledged — until an operator links the correct movement.
SELECT pg_temp.stage(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'finance_category', 'cat-leg4',
  jsonb_build_object('finance_category', jsonb_build_object(
    'name', 'AmbigCat2', 'created_at', now(), 'updated_at', now())),
  pg_temp.fgrant('cash'));
SELECT pg_temp.stage(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'cash_movement', 'cm-leg4a',
  jsonb_build_object('cash_movement', jsonb_build_object(
    'type', 'WITHDRAWAL', 'amount_minor_units', 6000,
    'reason', 'Reversal: deleted cash collection from AmbigCat2 (Route2)',
    'user_id', 'fin-cash')),
  pg_temp.fgrant('cash'));
SELECT pg_temp.stage(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'cash_movement', 'cm-leg4b',
  jsonb_build_object('cash_movement', jsonb_build_object(
    'type', 'WITHDRAWAL', 'amount_minor_units', 6000,
    'reason', 'Reversal: deleted cash collection from AmbigCat2 (Route2)',
    'user_id', 'fin-cash')),
  pg_temp.fgrant('cash'));
SELECT pg_temp.stage(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'finance_entry', 'fe-leg4',
  jsonb_build_object('finance_entry', jsonb_build_object(
    'category_id', 'cat-leg4', 'source', 'Route2',
    'amount_minor_units', 6000, 'description', 'staged ambiguous',
    'status', 'DELETED', 'payment_method', 'CASH',
    'created_by', 'fin-cash', 'completed_by', 'fin-cash',
    'deleted_by', 'fin-cash',
    'entry_date', now(), 'created_at', now(), 'updated_at', now())),
  pg_temp.fgrant('cash'),
  jsonb_build_object('fin-cash', pg_temp.fhash('cash')));
SELECT public.pos_sync_apply('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 500, 'fp-fin1');
SELECT pg_temp.expect_true('F5 ambiguous staged delete deferred not guessed',
  (SELECT apply_status FROM public.sync_mirror
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND entity_type = 'finance_entry' AND entity_id = 'fe-leg4') = 'PENDING'
  AND (SELECT apply_error FROM public.sync_mirror
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND entity_type = 'finance_entry' AND entity_id = 'fe-leg4')
    LIKE 'LEGACY_REVERSAL_AMBIGUOUS%'
  AND (SELECT status FROM public.pos_finance_entries
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'fe-leg4') = 'COMPLETED'
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND source_finance_entry_id = 'fe-leg4'
      AND type = 'WITHDRAWAL') = 0,
  'entry PENDING with durable marker; no leg guessed or duplicated');
SELECT pg_temp.expect_true('F5 reversal payloads preserved applied',
  (SELECT count(*) FROM public.sync_mirror
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND entity_id IN ('cm-leg4a','cm-leg4b')
      AND apply_status = 'APPLIED') = 2,
  'the two real movements applied; only the delete deferred');
-- Operator links the correct movement; the next apply converges.
UPDATE public.cash_movements SET source_finance_entry_id = 'fe-leg4'
WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND id = 'cm-leg4a';
SELECT public.pos_sync_apply('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 500, 'fp-fin1');
SELECT pg_temp.expect_true('F5 deferred delete converges after resolution',
  (SELECT apply_status FROM public.sync_mirror
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND entity_type = 'finance_entry' AND entity_id = 'fe-leg4') = 'APPLIED'
  AND (SELECT status FROM public.pos_finance_entries
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'fe-leg4') = 'DELETED'
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND source_finance_entry_id = 'fe-leg4' AND type = 'WITHDRAWAL') = 1,
  'linked reversal satisfies the delete; exactly one reversal stands');

-- ================================================================ F6 ======
-- New-format reversals keep deduplicating through the staged path: two
-- staged WITHDRAWALs (different entity ids, same leg) and one staged
-- DEPOSIT land exactly once each.
SELECT pg_temp.stage(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'cash_movement', 'cm-n1',
  jsonb_build_object('cash_movement', jsonb_build_object(
    'type', 'WITHDRAWAL', 'amount_minor_units', 8000,
    'reason', 'reversal one', 'user_id', 'fin-cash',
    'source_finance_entry_id', 'fe-f6')),
  pg_temp.fgrant('cash'));
SELECT pg_temp.stage(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'cash_movement', 'cm-n2',
  jsonb_build_object('cash_movement', jsonb_build_object(
    'type', 'WITHDRAWAL', 'amount_minor_units', 8000,
    'reason', 'reversal two', 'user_id', 'fin-cash',
    'source_finance_entry_id', 'fe-f6')),
  pg_temp.fgrant('cash'));
SELECT pg_temp.stage(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'cash_movement', 'cm-n3',
  jsonb_build_object('cash_movement', jsonb_build_object(
    'type', 'DEPOSIT', 'amount_minor_units', 8000,
    'reason', 'deposit retry', 'user_id', 'fin-cash',
    'source_finance_entry_id', 'fe-f6')),
  pg_temp.fgrant('cash'));
SELECT public.pos_sync_apply('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 500, 'fp-fin1');
SELECT pg_temp.expect_true('F6 new-format legs dedup through sync',
  (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND source_finance_entry_id = 'fe-f6' AND type = 'WITHDRAWAL') = 1
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND source_finance_entry_id = 'fe-f6' AND type = 'DEPOSIT') = 1
  AND (SELECT count(*) FROM public.sync_mirror
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND entity_id IN ('cm-n1','cm-n2','cm-n3')
      AND apply_status = 'APPLIED') = 3,
  'one withdrawal + one deposit despite three staged pushes');

-- Missing reversal sanity: a completed CASH collection with a deposit but
-- NO reversal anywhere gets exactly one server-written reversal on delete —
-- the uncertain case never silently produces zero or two legs.
SELECT public.pos_delete_finance_entry(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash', 'fe-f7');
SELECT pg_temp.expect_true('F6 missing reversal produces exactly one leg',
  (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND source_finance_entry_id = 'fe-f7' AND type = 'WITHDRAWAL') = 1
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND source_finance_entry_id = 'fe-f7' AND type = 'DEPOSIT') = 1,
  'server fallback wrote the single reversal for fe-f7');

-- ================================================================ G1 ======
-- Bidirectional uniqueness: ONE unlinked reversal whose reason+amount fit
-- TWO different collections (same category name, source and amount). It
-- must be claimed by NEITHER — processing order cannot pick a winner.
DO $$
BEGIN
  -- Same category id/name, same source, same amount: both entries generate
  -- the identical reversal reason, so leg-g1 fits both of them.
  PERFORM pg_temp.mk_collection(
    'fe-g1', 5000, 'cat-g', 'Route', 'fin-cash', 'SharedCat');
  PERFORM pg_temp.mk_collection(
    'fe-g2', 5000, 'cat-g', 'Route', 'fin-cash', 'SharedCat');
  PERFORM pg_temp.mk_legacy_reversal(
    'leg-g1', 5000, 'SharedCat', 'Route', 'fin-cash',
    (SELECT id FROM public.shifts
      WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND status = 'OPEN' LIMIT 1));
END $$;
SELECT pg_temp.expect_error('G1 shared reversal cannot be claimed by fe-g1',
  'SELECT public.pos_delete_finance_entry(''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'',''fin-cash'',''fe-g1'')',
  'LEGACY_REVERSAL_AMBIGUOUS');
SELECT pg_temp.expect_error('G1 shared reversal cannot be claimed by fe-g2',
  'SELECT public.pos_delete_finance_entry(''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'',''fin-cash'',''fe-g2'')',
  'LEGACY_REVERSAL_AMBIGUOUS');
SELECT pg_temp.expect_true('G1 neither collection claimed the movement',
  (SELECT count(*) FROM public.pos_finance_entries
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id IN ('fe-g1','fe-g2') AND status = 'COMPLETED') = 2
  AND (SELECT source_finance_entry_id FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'leg-g1') IS NULL
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND source_finance_entry_id IN ('fe-g1','fe-g2')
      AND type = 'WITHDRAWAL') = 0,
  'both entries still COMPLETED, movement unlinked, no reversal written');

-- ================================================================ G4 ======
-- Category rename while a device is offline: the stored reversal reason
-- still names the OLD category, so exact matching finds nothing — but the
-- plausible-reversal check must stop the server fallback from writing a
-- second drawer movement.
DO $$
BEGIN
  PERFORM pg_temp.mk_collection(
    'fe-g4', 7000, 'cat-g4', 'Shop', 'fin-cash', 'OldCatName');
  UPDATE public.pos_finance_categories SET name = 'NewCatName'
  WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND id = 'cat-g4';
  PERFORM pg_temp.mk_legacy_reversal(
    'leg-g4', 7000, 'OldCatName', 'Shop', 'fin-cash',
    (SELECT id FROM public.shifts
      WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND status = 'OPEN' LIMIT 1));
END $$;
SELECT pg_temp.expect_error('G4 renamed category defers instead of duplicating',
  'SELECT public.pos_delete_finance_entry(''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'',''fin-cash'',''fe-g4'')',
  'LEGACY_REVERSAL_AMBIGUOUS');
SELECT pg_temp.expect_true('G4 no server reversal was written',
  (SELECT status FROM public.pos_finance_entries
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'fe-g4') = 'COMPLETED'
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND source_finance_entry_id = 'fe-g4' AND type = 'WITHDRAWAL') = 0
  AND (SELECT source_finance_entry_id FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'leg-g4') IS NULL,
  'entry preserved, old reversal preserved unlinked, zero new legs');
-- Same scenario through the staged offline path: the delete must stay
-- PENDING with the durable marker, payload intact.
SELECT pg_temp.stage(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'finance_category', 'cat-g6',
  jsonb_build_object('finance_category', jsonb_build_object(
    'name', 'RenamedNow', 'created_at', now(), 'updated_at', now())),
  pg_temp.fgrant('cash'));
SELECT pg_temp.stage(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'cash_movement', 'cm-g6',
  jsonb_build_object('cash_movement', jsonb_build_object(
    'type', 'WITHDRAWAL', 'amount_minor_units', 4500,
    'reason', 'Reversal: deleted cash collection from RenamedBefore (Yard)',
    'user_id', 'fin-cash')),
  pg_temp.fgrant('cash'));
SELECT pg_temp.stage(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'finance_entry', 'fe-g6',
  jsonb_build_object('finance_entry', jsonb_build_object(
    'category_id', 'cat-g6', 'source', 'Yard',
    'amount_minor_units', 4500, 'description', 'renamed category staged',
    'status', 'DELETED', 'payment_method', 'CASH',
    'created_by', 'fin-cash', 'completed_by', 'fin-cash',
    'deleted_by', 'fin-cash',
    'entry_date', now(), 'created_at', now(), 'updated_at', now())),
  pg_temp.fgrant('cash'),
  jsonb_build_object('fin-cash', pg_temp.fhash('cash')));
SELECT public.pos_sync_apply('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 500, 'fp-fin1');
SELECT pg_temp.expect_true('G4 staged rename stays PENDING with marker',
  (SELECT apply_status FROM public.sync_mirror
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND entity_type = 'finance_entry' AND entity_id = 'fe-g6') = 'PENDING'
  AND (SELECT apply_error FROM public.sync_mirror
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND entity_type = 'finance_entry' AND entity_id = 'fe-g6')
    LIKE 'LEGACY_REVERSAL_AMBIGUOUS%'
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND source_finance_entry_id = 'fe-g6' AND type = 'WITHDRAWAL') = 0,
  'staged delete deferred; no duplicate server withdrawal');

-- ================================================================ G5 ======
-- Reason/source mismatch: an unlinked reversal-shaped withdrawal of the
-- same amount exists but names a DIFFERENT collection. It is still possible
-- old-reversal evidence — the delete must defer, not write a second leg.
DO $$
BEGIN
  PERFORM pg_temp.mk_collection(
    'fe-g5', 5500, 'cat-g5', 'Dock', 'fin-cash', 'RealCat');
  PERFORM pg_temp.mk_legacy_reversal(
    'leg-g5', 5500, 'WrongCat', 'Elsewhere', 'fin-cash',
    (SELECT id FROM public.shifts
      WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND status = 'OPEN' LIMIT 1));
END $$;
SELECT pg_temp.expect_error('G5 mismatched reason defers the delete',
  'SELECT public.pos_delete_finance_entry(''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'',''fin-cash'',''fe-g5'')',
  'LEGACY_REVERSAL_AMBIGUOUS');
SELECT pg_temp.expect_true('G5 plausible movement preserved, no new leg',
  (SELECT status FROM public.pos_finance_entries
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'fe-g5') = 'COMPLETED'
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND source_finance_entry_id = 'fe-g5' AND type = 'WITHDRAWAL') = 0
  AND (SELECT source_finance_entry_id FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'leg-g5') IS NULL,
  'possible old reversal kept for operator review; nothing duplicated');

-- ================================================================ G6 ======
-- Actor mismatch: reason and amount match EXACTLY but the movement belongs
-- to a different user. No automatic association — the delete defers.
DO $$
BEGIN
  PERFORM pg_temp.mk_collection(
    'fe-g7', 6500, 'cat-g7', 'Bay', 'fin-cash', 'ActorCat');
  PERFORM pg_temp.mk_legacy_reversal(
    'leg-g7', 6500, 'ActorCat', 'Bay', 'fin-cash2',
    (SELECT id FROM public.shifts
      WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND status = 'OPEN' LIMIT 1));
END $$;
SELECT pg_temp.expect_error('G6 actor mismatch defers the delete',
  'SELECT public.pos_delete_finance_entry(''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'',''fin-cash'',''fe-g7'')',
  'LEGACY_REVERSAL_AMBIGUOUS');
SELECT pg_temp.expect_true('G6 wrong-actor movement never auto-linked',
  (SELECT status FROM public.pos_finance_entries
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'fe-g7') = 'COMPLETED'
  AND (SELECT source_finance_entry_id FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'leg-g7') IS NULL
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND source_finance_entry_id = 'fe-g7' AND type = 'WITHDRAWAL') = 0,
  'mismatched actor is not evidence; nothing was guessed or written');

SELECT 'request3_financial_integrity: ALL PASSED' AS result;
