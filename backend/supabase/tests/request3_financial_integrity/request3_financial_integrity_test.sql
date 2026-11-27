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
--   H1  late old-format withdrawal after the server reversal exists:
--       converges on the linked movement, no second unlinked leg
--   H2  late withdrawal, same reason+amount, conflicting actor: deferred,
--       preserved, never inserted
--   H3  late withdrawal matching TWO linked reversals: ambiguous, no pick
--   H4  staged delete first, old-format movement in a LATER batch: still
--       exactly one reversal
--   I1  operator UNRELATED verdict unblocks a plausible-blocked delete;
--       verdict is per-(movement, collection) and fully audited
--   I2  the same verdict does NOT unblock a different collection
--   H5  reason drift: category renamed AFTER the device wrote its reversal
--       but BEFORE the cloud delete — late old-reason push must defer,
--       never insert a second withdrawal
--   H6  ambiguous reason drift: multiple plausible linked reversals with
--       the same amount — deferred, nothing attached or inserted
--   H7  actor conflict WITH reason drift: cannot be auto-deduplicated —
--       the movement records normally as its own unlinked row
--   J1  audited manual link: LEGACY_REVERSAL_LINKED with operator + ids;
--       identical retry is a no-op; conflicting link refused
--   J2  audited UNRELATED revocation: verdict removed, revocation audited,
--       original MARKED_UNRELATED event preserved
--   J3  amount mismatch refused: 5,000 withdrawal cannot link to a
--       7,000 collection — no link, no audit, both records untouched
--   J4  exact amount accepted through pos_link_legacy_reversal
--   J5  existing safety intact: idempotent retry, cross-collection link
--       refused, second reversal refused
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
DELETE FROM cash_movement_reconciliations
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

-- ================================================================ H1 ======
-- Test A — late old-format withdrawal. The collection is deleted through
-- the server path FIRST (server writes the linked reversal); the legacy
-- unlinked push arrives afterwards with a different movement id. It must
-- converge on the existing linked movement, not insert a second leg.
DO $$
BEGIN
  PERFORM pg_temp.mk_collection(
    'fe-h1', 6100, 'cat-h1', 'Bay', 'fin-cash', 'LateCat');
  PERFORM public.pos_delete_finance_entry(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash', 'fe-h1');
END $$;
SELECT pg_temp.expect_true('H1 late legacy withdrawal returns the linked reversal',
  (SELECT (public.pos_add_cash_movement(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash',
      (SELECT id FROM public.shifts
        WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
          AND status = 'OPEN' LIMIT 1),
      'WITHDRAWAL', 6100,
      'Reversal: deleted cash collection from LateCat (Bay)',
      NULL, 'leg-h1-late', NULL)->>'duplicate')::boolean)
  AND (SELECT public.pos_add_cash_movement(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash',
      (SELECT id FROM public.shifts
        WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
          AND status = 'OPEN' LIMIT 1),
      'WITHDRAWAL', 6100,
      'Reversal: deleted cash collection from LateCat (Bay)',
      NULL, 'leg-h1-late', NULL)->>'id')
    = (SELECT id FROM public.cash_movements
       WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
         AND source_finance_entry_id = 'fe-h1' AND type = 'WITHDRAWAL'),
  'second call is same-id idempotent; both resolve to the server leg');
SELECT pg_temp.expect_true('H1 exactly one withdrawal exists for the collection',
  (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND source_finance_entry_id = 'fe-h1' AND type = 'WITHDRAWAL') = 1
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'leg-h1-late') = 0
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND reason = 'Reversal: deleted cash collection from LateCat (Bay)'
      AND amount_minor_units = 6100) = 1,
  'no unlinked duplicate was written');

-- ================================================================ H2 ======
-- Test B — late withdrawal, same reason and amount, CONFLICTING actor.
-- It must not attach and must not insert: deferred with the durable marker.
DO $$
BEGIN
  PERFORM pg_temp.mk_collection(
    'fe-h2', 6200, 'cat-h2', 'Dock', 'fin-cash', 'ActorLate');
  PERFORM public.pos_delete_finance_entry(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash', 'fe-h2');
END $$;
SELECT pg_temp.expect_error('H2 conflicting actor defers the late movement',
  'SELECT public.pos_add_cash_movement(''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'',''fin-cash2'','
  '(SELECT id FROM public.shifts WHERE customer_id = ''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'' AND status = ''OPEN'' LIMIT 1),'||
  '''WITHDRAWAL'', 6200, ''Reversal: deleted cash collection from ActorLate (Dock)'', NULL, ''leg-h2-late'', NULL)',
  'LEGACY_REVERSAL_AMBIGUOUS');
SELECT pg_temp.expect_true('H2 conflicting-actor movement preserved, nothing inserted',
  (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND reason = 'Reversal: deleted cash collection from ActorLate (Dock)'
      AND amount_minor_units = 6200) = 1
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'leg-h2-late') = 0,
  'only the server reversal stands; the doubtful push left no row');

-- ================================================================ H3 ======
-- Test C — late withdrawal matching TWO linked reversals (same generated
-- reason + amount on two collections). Ambiguity must not be resolved by
-- arrival order.
DO $$
BEGIN
  PERFORM pg_temp.mk_collection(
    'fe-h3a', 6400, 'cat-h3', 'Route', 'fin-cash', 'PairLate');
  PERFORM pg_temp.mk_collection(
    'fe-h3b', 6400, 'cat-h3', 'Route', 'fin-cash', 'PairLate');
  PERFORM public.pos_delete_finance_entry(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash', 'fe-h3a');
  PERFORM public.pos_delete_finance_entry(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash', 'fe-h3b');
END $$;
SELECT pg_temp.expect_error('H3 doubly-linked match is ambiguous',
  'SELECT public.pos_add_cash_movement(''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'',''fin-cash'','
  '(SELECT id FROM public.shifts WHERE customer_id = ''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'' AND status = ''OPEN'' LIMIT 1),'||
  '''WITHDRAWAL'', 6400, ''Reversal: deleted cash collection from PairLate (Route)'', NULL, ''leg-h3-late'', NULL)',
  'LEGACY_REVERSAL_AMBIGUOUS');
SELECT pg_temp.expect_true('H3 both reversals preserved, nothing added',
  (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND reason = 'Reversal: deleted cash collection from PairLate (Route)'
      AND amount_minor_units = 6400
      AND source_finance_entry_id IN ('fe-h3a','fe-h3b')) = 2
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'leg-h3-late') = 0,
  'one reversal per collection stands; the ambiguous push wrote nothing');

-- ================================================================ H4 ======
-- Test D — separate push batches. The staged DELETED entry applies first
-- and earns its server reversal; the old-format movement arrives in a
-- LATER sync_apply call and must still dedup to it.
SELECT pg_temp.stage(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'finance_category', 'cat-h4',
  jsonb_build_object('finance_category', jsonb_build_object(
    'name', 'StagedLate', 'created_at', now(), 'updated_at', now())),
  pg_temp.fgrant('cash'));
SELECT pg_temp.stage(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'finance_entry', 'fe-h4',
  jsonb_build_object('finance_entry', jsonb_build_object(
    'category_id', 'cat-h4', 'source', 'Pier',
    'amount_minor_units', 6600, 'description', 'late batch delete',
    'status', 'DELETED', 'payment_method', 'CASH',
    'created_by', 'fin-cash', 'completed_by', 'fin-cash',
    'deleted_by', 'fin-cash',
    'entry_date', now(), 'created_at', now(), 'updated_at', now())),
  pg_temp.fgrant('cash'),
  jsonb_build_object('fin-cash', pg_temp.fhash('cash')));
SELECT public.pos_sync_apply('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 600, 'fp-fin1');
SELECT pg_temp.expect_true('H4 server reversal exists after first batch',
  (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND source_finance_entry_id = 'fe-h4' AND type = 'WITHDRAWAL') = 1,
  'delete applied with its own linked reversal');
-- Second, separate batch: the old-format unlinked push.
SELECT pg_temp.stage(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'cash_movement', 'cm-h4-late',
  jsonb_build_object('cash_movement', jsonb_build_object(
    'type', 'WITHDRAWAL', 'amount_minor_units', 6600,
    'reason', 'Reversal: deleted cash collection from StagedLate (Pier)',
    'user_id', 'fin-cash')),
  pg_temp.fgrant('cash'));
SELECT public.pos_sync_apply('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 601, 'fp-fin1');
SELECT pg_temp.expect_true('H4 late staged movement dedups across batches',
  (SELECT apply_status FROM public.sync_mirror
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND entity_type = 'cash_movement' AND entity_id = 'cm-h4-late') = 'APPLIED'
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND source_finance_entry_id = 'fe-h4' AND type = 'WITHDRAWAL') = 1
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND reason = 'Reversal: deleted cash collection from StagedLate (Pier)'
      AND amount_minor_units = 6600) = 1,
  'exactly one reversal stands across both push batches');

-- ================================================================ I1 ======
-- Operator resolution. fe-i1 has a plausible unlinked reversal (same
-- amount, reversal-shaped reason, DIFFERENT actor) that blocks the delete.
-- An explicit UNRELATED verdict for THIS collection unblocks it — the
-- movement row itself is never touched.
DO $$
BEGIN
  PERFORM pg_temp.mk_collection(
    'fe-i1', 7500, 'cat-i1', 'Floor', 'fin-cash', 'OpsCat');
  PERFORM pg_temp.mk_legacy_reversal(
    'leg-i1', 7500, 'OpsCat', 'Floor', 'fin-cash2',
    (SELECT id FROM public.shifts
      WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND status = 'OPEN' LIMIT 1));
END $$;
SELECT pg_temp.expect_error('I1 plausible reversal blocks the delete first',
  'SELECT public.pos_delete_finance_entry(''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'',''fin-cash'',''fe-i1'')',
  'LEGACY_REVERSAL_AMBIGUOUS');
SELECT public.pos_mark_movement_unrelated(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'leg-i1', 'fe-i1',
  'fin-owner', 'belongs to a different till''s collection');
SELECT pg_temp.expect_true('I1 UNRELATED verdict is recorded and audited',
  (SELECT resolution FROM public.cash_movement_reconciliations
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND movement_id = 'leg-i1' AND finance_entry_id = 'fe-i1')
      = 'UNRELATED'
  AND (SELECT resolved_by FROM public.cash_movement_reconciliations
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND movement_id = 'leg-i1' AND finance_entry_id = 'fe-i1')
      = 'fin-owner'
  AND (SELECT count(*) FROM public.pos_audit_logs
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND action = 'LEGACY_REVERSAL_MARKED_UNRELATED') >= 1,
  'durable verdict + audit row, movement untouched');
SELECT public.pos_delete_finance_entry(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash', 'fe-i1');
SELECT pg_temp.expect_true('I1 delete proceeds after explicit resolution',
  (SELECT status FROM public.pos_finance_entries
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'fe-i1') = 'DELETED'
  AND (SELECT source_finance_entry_id FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'leg-i1') IS NULL
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND source_finance_entry_id = 'fe-i1' AND type = 'WITHDRAWAL') = 1,
  'server wrote its own reversal; leg-i1 preserved unlinked for review');

-- ================================================================ I2 ======
-- The verdict is scoped to (movement, collection): the SAME movement still
-- blocks a DIFFERENT collection that generates the same plausible match.
DO $$
BEGIN
  PERFORM pg_temp.mk_collection(
    'fe-i2', 7500, 'cat-i1', 'Floor', 'fin-cash', 'OpsCat');
END $$;
SELECT pg_temp.expect_error('I2 verdict for fe-i1 does not unblock fe-i2',
  'SELECT public.pos_delete_finance_entry(''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'',''fin-cash'',''fe-i2'')',
  'LEGACY_REVERSAL_AMBIGUOUS');
SELECT public.pos_mark_movement_unrelated(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'leg-i1', 'fe-i2',
  'fin-owner', 'confirmed unrelated to this collection too');
SELECT public.pos_delete_finance_entry(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash', 'fe-i2');
SELECT pg_temp.expect_true('I2 per-collection resolution converges',
  (SELECT status FROM public.pos_finance_entries
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'fe-i2') = 'DELETED'
  AND (SELECT source_finance_entry_id FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'leg-i1') IS NULL,
  'each collection needed its own verdict; leg-i1 still untouched');

-- ================================================================ H5 ======
-- Reason drift. The device wrote its reversal against 'DriftOld'; the
-- category was renamed to 'DriftNew' before the cloud delete, so the
-- server reversal carries the NEW reason. The late old-reason push must
-- NOT insert a second withdrawal — it defers for operator review.
DO $$
BEGIN
  PERFORM pg_temp.mk_collection(
    'fe-j1', 8100, 'cat-j1', 'Pier', 'fin-cash', 'DriftOld');
  UPDATE public.pos_finance_categories SET name = 'DriftNew'
  WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND id = 'cat-j1';
  PERFORM public.pos_delete_finance_entry(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash', 'fe-j1');
END $$;
SELECT pg_temp.expect_error('H5 drifted late reversal defers, not duplicates',
  'SELECT public.pos_add_cash_movement(''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'',''fin-cash'','
  '(SELECT id FROM public.shifts WHERE customer_id = ''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'' AND status = ''OPEN'' LIMIT 1),'||
  '''WITHDRAWAL'', 8100, ''Reversal: deleted cash collection from DriftOld (Pier)'', NULL, ''leg-j1-late'', NULL)',
  'LEGACY_REVERSAL_AMBIGUOUS');
SELECT pg_temp.expect_true('H5 no second withdrawal was written',
  (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND source_finance_entry_id = 'fe-j1' AND type = 'WITHDRAWAL') = 1
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'leg-j1-late') = 0
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND amount_minor_units = 8100
      AND btrim(reason) LIKE 'Reversal: deleted cash collection from%') = 1,
  'only the server reversal stands; drifted push preserved nowhere as money');

-- ================================================================ H6 ======
-- Ambiguous reason drift: TWO linked reversals share the amount and the
-- reversal-shaped prefix. The incoming movement cannot be attributed —
-- defer, attach nothing, insert nothing.
DO $$
BEGIN
  PERFORM pg_temp.mk_collection(
    'fe-j2a', 8200, 'cat-j2a', 'A1', 'fin-cash', 'MultiCat');
  PERFORM pg_temp.mk_collection(
    'fe-j2b', 8200, 'cat-j2b', 'B2', 'fin-cash', 'MultiCat');
  PERFORM public.pos_delete_finance_entry(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash', 'fe-j2a');
  PERFORM public.pos_delete_finance_entry(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash', 'fe-j2b');
END $$;
SELECT pg_temp.expect_error('H6 ambiguous drift defers the movement',
  'SELECT public.pos_add_cash_movement(''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'',''fin-cash'','
  '(SELECT id FROM public.shifts WHERE customer_id = ''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'' AND status = ''OPEN'' LIMIT 1),'||
  '''WITHDRAWAL'', 8200, ''Reversal: deleted cash collection from DriftedName (Nowhere)'', NULL, ''leg-j2-late'', NULL)',
  'LEGACY_REVERSAL_AMBIGUOUS');
SELECT pg_temp.expect_true('H6 both reversals intact, nothing inserted',
  (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND source_finance_entry_id IN ('fe-j2a','fe-j2b')
      AND type = 'WITHDRAWAL') = 2
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'leg-j2-late') = 0,
  'no arrival-order pick; payload stays recoverable in sync_mirror');

-- ================================================================ H7 ======
-- Actor conflict WITH reason drift: a different actor''s same-amount
-- reversal-shaped withdrawal is NOT plausible evidence — it records as its
-- own unlinked movement, never auto-deduplicated onto the linked reversal.
DO $$
BEGIN
  PERFORM pg_temp.mk_collection(
    'fe-j3', 8300, 'cat-j3', 'Zed', 'fin-cash', 'ActorDrift');
  PERFORM public.pos_delete_finance_entry(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash', 'fe-j3');
END $$;
SELECT pg_temp.expect_true('H7 conflicting-actor drift records as its own row',
  (SELECT (public.pos_add_cash_movement(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'fin-cash2',
      (SELECT id FROM public.shifts
        WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
          AND status = 'OPEN' LIMIT 1),
      'WITHDRAWAL', 8300,
      'Reversal: deleted cash collection from OldActorName (OldSource)',
      NULL, 'leg-j3-late', NULL)->>'id') = 'leg-j3-late')
  AND (SELECT source_finance_entry_id FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'leg-j3-late') IS NULL
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND source_finance_entry_id = 'fe-j3' AND type = 'WITHDRAWAL') = 1,
  'different actor = different money; recorded unlinked, not deduped');

-- ================================================================ J1 ======
-- Audited manual link. fe-j4 is a live COMPLETED CASH collection with an
-- unlinked legacy reversal leg-j4. pos_link_legacy_reversal performs the
-- link atomically and writes LEGACY_REVERSAL_LINKED with the operator.
DO $$
BEGIN
  PERFORM pg_temp.mk_collection(
    'fe-j4', 8400, 'cat-j4', 'Harbor', 'fin-cash', 'LinkCat');
  PERFORM pg_temp.mk_legacy_reversal(
    'leg-j4', 8400, 'LinkCat', 'Harbor', 'fin-cash',
    (SELECT id FROM public.shifts
      WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND status = 'OPEN' LIMIT 1));
END $$;
SELECT public.pos_link_legacy_reversal(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'leg-j4', 'fe-j4',
  'fin-owner', 'verified against physical till roll');
SELECT pg_temp.expect_true('J1 manual link applied and audited',
  (SELECT source_finance_entry_id FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'leg-j4') = 'fe-j4'
  AND (SELECT count(*) FROM public.pos_audit_logs
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND action = 'LEGACY_REVERSAL_LINKED'
      AND user_id = 'fin-owner'
      AND details LIKE '%leg-j4%'
      AND details LIKE '%fe-j4%') = 1,
  'link + exactly one audit row naming operator and both ids');
-- Identical retry: safe no-op, no misleading second audit.
SELECT public.pos_link_legacy_reversal(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'leg-j4', 'fe-j4',
  'fin-owner', 'retry after lost response');
SELECT pg_temp.expect_true('J1 identical retry adds no second audit',
  (SELECT count(*) FROM public.pos_audit_logs
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND action = 'LEGACY_REVERSAL_LINKED'
      AND details LIKE '%leg-j4%') = 1
  AND (SELECT source_finance_entry_id FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'leg-j4') = 'fe-j4',
  'idempotent: same link, no duplicate transition');
-- Conflicting link refused: fe-j5 already has a reversal leg.
DO $$
BEGIN
  PERFORM pg_temp.mk_collection(
    'fe-j5', 8500, 'cat-j5', 'Quay', 'fin-cash', 'ConflictCat');
  PERFORM pg_temp.mk_legacy_reversal(
    'leg-j5', 8500, 'ConflictCat', 'Quay', 'fin-cash',
    (SELECT id FROM public.shifts
      WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND status = 'OPEN' LIMIT 1));
  -- Pretend a reversal already exists for fe-j5.
  UPDATE public.cash_movements SET source_finance_entry_id = 'fe-j5'
  WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND id = 'leg-j5';
END $$;
SELECT pg_temp.expect_error('J1 missing movement refused',
  'SELECT public.pos_link_legacy_reversal(''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'',''leg-ghost'',''fe-j5'',''fin-owner'',''x'')',
  'Movement not found');
-- Real conflict: fe-j5 has linked leg-j5; try linking another unlinked
-- withdrawal leg-j5c to it.
INSERT INTO public.cash_movements (id, customer_id, shift_id, user_id, type,
  amount_minor_units, reason, created_at, source_finance_entry_id)
SELECT 'leg-j5c', customer_id, shift_id, 'fin-cash', 'WITHDRAWAL', 8500,
  'Reversal: deleted cash collection from ConflictCat (Quay)', now(), NULL
FROM public.cash_movements
WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND id = 'leg-j5';
SELECT pg_temp.expect_error('J1 conflicting link refused (entry has reversal)',
  'SELECT public.pos_link_legacy_reversal(''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'',''leg-j5c'',''fe-j5'',''fin-owner'',''attempt'')',
  'already has a reversal leg');
SELECT pg_temp.expect_true('J1 refused link changed nothing',
  (SELECT source_finance_entry_id FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'leg-j5c') IS NULL
  AND (SELECT source_finance_entry_id FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'leg-j5') = 'fe-j5',
  'both movements keep their original association state');

-- ================================================================ J2 ======
-- Audited UNRELATED revocation: verdict removed, revocation audited, and
-- the original MARKED_UNRELATED audit event is preserved.
DO $$
BEGIN
  PERFORM pg_temp.mk_collection(
    'fe-j6', 8600, 'cat-j6', 'Marsh', 'fin-cash', 'RevokeCat');
  PERFORM pg_temp.mk_legacy_reversal(
    'leg-j6', 8600, 'RevokeCat', 'Marsh', 'fin-cash2',
    (SELECT id FROM public.shifts
      WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND status = 'OPEN' LIMIT 1));
END $$;
SELECT public.pos_mark_movement_unrelated(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'leg-j6', 'fe-j6',
  'fin-owner', 'initial unrelated verdict');
SELECT public.pos_revoke_unrelated_verdict(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'leg-j6', 'fe-j6',
  'fin-owner', 'verdict was mistaken');
SELECT pg_temp.expect_true('J2 revocation audited, original preserved',
  (SELECT count(*) FROM public.cash_movement_reconciliations
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND movement_id = 'leg-j6' AND finance_entry_id = 'fe-j6') = 0
  AND (SELECT count(*) FROM public.pos_audit_logs
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND action = 'LEGACY_REVERSAL_MARKED_UNRELATED'
      AND details LIKE '%leg-j6%') = 1
  AND (SELECT count(*) FROM public.pos_audit_logs
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND action = 'LEGACY_REVERSAL_UNRELATED_REVOKED'
      AND user_id = 'fin-owner'
      AND details LIKE '%leg-j6%') = 1,
  'verdict gone, both audit events intact, movement untouched');
SELECT pg_temp.expect_error('J2 revoking a non-existent verdict fails',
  'SELECT public.pos_revoke_unrelated_verdict(''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'',''leg-j6'',''fe-j6'',''fin-owner'',''again'')',
  'No UNRELATED verdict exists');

-- ================================================================ J3 ======
-- Amount integrity: a 5,000 withdrawal must NOT link to a 7,000 collection.
DO $$
BEGIN
  PERFORM pg_temp.mk_collection(
    'fe-j7', 7000, 'cat-j7', 'Cliff', 'fin-cash', 'AmountCat');
  PERFORM pg_temp.mk_legacy_reversal(
    'leg-j7', 5000, 'AmountCat', 'Cliff', 'fin-cash',
    (SELECT id FROM public.shifts
      WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND status = 'OPEN' LIMIT 1));
END $$;
SELECT pg_temp.expect_error('J3 amount mismatch refused',
  'SELECT public.pos_link_legacy_reversal(''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'',''leg-j7'',''fe-j7'',''fin-owner'',''wrong amount'')',
  'Amount mismatch');
SELECT pg_temp.expect_true('J3 nothing changed, no audit written',
  (SELECT source_finance_entry_id FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'leg-j7') IS NULL
  AND (SELECT status FROM public.pos_finance_entries
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'fe-j7') = 'COMPLETED'
  AND (SELECT count(*) FROM public.pos_audit_logs
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND action = 'LEGACY_REVERSAL_LINKED'
      AND details LIKE '%leg-j7%') = 0,
  'movement unlinked, entry untouched, zero link audits');

-- ================================================================ J4 ======
-- Exact amount accepted: 7,000 withdrawal links to the 7,000 collection.
DO $$
BEGIN
  PERFORM pg_temp.mk_legacy_reversal(
    'leg-j8', 7000, 'AmountCat', 'Cliff', 'fin-cash',
    (SELECT id FROM public.shifts
      WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND status = 'OPEN' LIMIT 1));
END $$;
SELECT public.pos_link_legacy_reversal(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'leg-j8', 'fe-j7',
  'fin-owner', 'amounts verified equal');
SELECT pg_temp.expect_true('J4 exact-amount link applied and audited',
  (SELECT source_finance_entry_id FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'leg-j8') = 'fe-j7'
  AND (SELECT count(*) FROM public.pos_audit_logs
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND action = 'LEGACY_REVERSAL_LINKED'
      AND details LIKE '%leg-j8%'
      AND details LIKE '%fe-j7%') = 1,
  'link + audit recorded for the matching amounts');

-- ================================================================ J5 ======
-- Existing safety intact on the new code path.
-- (a) identical retry on the J4 link is a no-op;
SELECT public.pos_link_legacy_reversal(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'leg-j8', 'fe-j7',
  'fin-owner', 'idempotent retry');
SELECT pg_temp.expect_true('J5a identical retry stays a single transition',
  (SELECT count(*) FROM public.pos_audit_logs
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND action = 'LEGACY_REVERSAL_LINKED'
      AND details LIKE '%leg-j8%') = 1
  AND (SELECT source_finance_entry_id FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'leg-j8') = 'fe-j7',
  'retry linked to same collection: no new audit, link unchanged');
-- (b) a movement already linked elsewhere cannot be re-linked;
DO $$
BEGIN
  PERFORM pg_temp.mk_collection(
    'fe-j9', 7200, 'cat-j9', 'Mere', 'fin-cash', 'OtherCat');
  PERFORM pg_temp.mk_legacy_reversal(
    'leg-j9', 7200, 'OtherCat', 'Mere', 'fin-cash',
    (SELECT id FROM public.shifts
      WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND status = 'OPEN' LIMIT 1));
  UPDATE public.cash_movements SET source_finance_entry_id = 'fe-j9'
  WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND id = 'leg-j9';
END $$;
SELECT pg_temp.expect_error('J5b cross-collection relink refused',
  'SELECT public.pos_link_legacy_reversal(''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'',''leg-j9'',''fe-j7'',''fin-owner'',''attempt'')',
  'already linked to a different collection');
-- (c) an entry that already has a reversal cannot acquire another;
DO $$
BEGIN
  PERFORM pg_temp.mk_legacy_reversal(
    'leg-j10', 7000, 'AmountCat', 'Cliff', 'fin-cash',
    (SELECT id FROM public.shifts
      WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND status = 'OPEN' LIMIT 1));
END $$;
SELECT pg_temp.expect_error('J5c second reversal refused',
  'SELECT public.pos_link_legacy_reversal(''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'',''leg-j10'',''fe-j7'',''fin-owner'',''attempt'')',
  'already has a reversal leg');
SELECT pg_temp.expect_true('J5 refused attempts changed nothing',
  (SELECT source_finance_entry_id FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'leg-j9') = 'fe-j9'
  AND (SELECT source_finance_entry_id FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND id = 'leg-j10') IS NULL
  AND (SELECT count(*) FROM public.cash_movements
    WHERE customer_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND source_finance_entry_id = 'fe-j7' AND type = 'WITHDRAWAL') = 1,
  'each record kept its original state; fe-j7 still has exactly one leg');

SELECT 'request3_financial_integrity: ALL PASSED' AS result;
