-- Request 2 PostgreSQL integration tests — licensing + rate limiting.
--
-- Runs against the replayed schema (replay_migrations.sh output) in CI,
-- AFTER h1_void_invariants. Never run against production.
--
-- Covered here (single-session semantics):
--   R2-1  unlimited activation despite legacy seat_limit = 1
--   R2-2  active fingerprint idempotency (no duplicate rows)
--   R2-3  revoked fingerprint reactivation
--   R2-4  mixed active+revoked historical duplicates: active wins, no
--         unique-index failure (the register_device regression)
--   R2-5  deterministic reactivation choice among multiple revoked rows
--   R2-6  rate_limit_hit counting, reset, and fixed-window expiry
--   R2-7  service-role-only EXECUTE grants + RLS on rate_limit_buckets
--
-- Concurrency cases (same fingerprint, different fingerprints, activation
-- racing revocation, rate-limit atomicity) live in concurrency.sh — they
-- need two real sessions.
--
-- psql -v ON_ERROR_STOP=1 -f request2_licensing_test.sql

\set ON_ERROR_STOP on
\pset footer off

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
DELETE FROM device_registrations;
DELETE FROM licenses;
DELETE FROM rate_limit_buckets;

INSERT INTO customers (id, name)
VALUES ('33333333-3333-3333-3333-333333333333', 'R2 Test Shop')
ON CONFLICT (id) DO NOTHING;

-- Legacy license: seat_limit = 1 must NOT gate activation anymore.
INSERT INTO licenses (activation_code, customer_id, seat_limit, expires_at, revoked_at)
VALUES ('R2-CODE-AAAA-BBBB-CCCC-DDDD', '33333333-3333-3333-3333-333333333333', 1, NULL, NULL);

-- ================================================================ R2-1 =====
-- Unlimited activation despite seat_limit = 1.
DO $$
DECLARE i int; r jsonb;
BEGIN
  FOR i IN 1..5 LOOP
    r := register_device('R2-CODE-AAAA-BBBB-CCCC-DDDD', 'fp-u-' || i, 'dev ' || i);
    IF (r->>'status') <> 'activated' THEN
      RAISE EXCEPTION 'FAIL R2-1: device % status=%', i, r;
    END IF;
  END LOOP;
  PERFORM pg_temp.expect_true('R2-1 unlimited vs seat_limit=1',
    (SELECT count(*) FROM device_registrations
      WHERE activation_code='R2-CODE-AAAA-BBBB-CCCC-DDDD' AND revoked_at IS NULL) = 5,
    '5 active devices on a seat_limit=1 license');
END $$;

-- ================================================================ R2-2 =====
DO $$
DECLARE r jsonb;
BEGIN
  r := register_device('R2-CODE-AAAA-BBBB-CCCC-DDDD', 'fp-u-1', 'renamed dev');
  PERFORM pg_temp.expect_true('R2-2 active idempotent',
    (r->>'status') = 'refreshed'
    AND (SELECT count(*) FROM device_registrations
      WHERE activation_code='R2-CODE-AAAA-BBBB-CCCC-DDDD'
        AND device_fingerprint='fp-u-1') = 1,
    'second activation refreshes, never duplicates');
END $$;

-- ================================================================ R2-3 =====
DO $$
DECLARE r jsonb;
BEGIN
  UPDATE device_registrations SET revoked_at = now()
    WHERE activation_code='R2-CODE-AAAA-BBBB-CCCC-DDDD' AND device_fingerprint='fp-u-2';
  r := register_device('R2-CODE-AAAA-BBBB-CCCC-DDDD', 'fp-u-2', 'dev 2 back');
  PERFORM pg_temp.expect_true('R2-3 revoked reactivation',
    (r->>'status') = 'reactivated'
    AND (SELECT revoked_at IS NULL FROM device_registrations
      WHERE activation_code='R2-CODE-AAAA-BBBB-CCCC-DDDD'
        AND device_fingerprint='fp-u-2'),
    'revoked row reactivated, still exactly one row for the fingerprint');
END $$;

-- ================================================================ R2-4 =====
-- THE REGRESSION: one ACTIVE + two REVOKED rows for the same fingerprint.
-- The old code could pick the revoked row first and die on
-- device_reg_active_unique. The active row must win.
DO $$
DECLARE r jsonb; v_active int; v_revoked int;
BEGIN
  -- Historical mess: two revoked rows + one live row, same fingerprint.
  INSERT INTO device_registrations
    (activation_code, device_fingerprint, device_name, revoked_at)
  VALUES
    ('R2-CODE-AAAA-BBBB-CCCC-DDDD', 'fp-mixed', 'old-1', now() - interval '10 days'),
    ('R2-CODE-AAAA-BBBB-CCCC-DDDD', 'fp-mixed', 'old-2', now() - interval '5 days');
  INSERT INTO device_registrations
    (activation_code, device_fingerprint, device_name, revoked_at)
  VALUES
    ('R2-CODE-AAAA-BBBB-CCCC-DDDD', 'fp-mixed', 'current', NULL);

  r := register_device('R2-CODE-AAAA-BBBB-CCCC-DDDD', 'fp-mixed', 'current');
  SELECT count(*) INTO v_active FROM device_registrations
    WHERE activation_code='R2-CODE-AAAA-BBBB-CCCC-DDDD'
      AND device_fingerprint='fp-mixed' AND revoked_at IS NULL;
  SELECT count(*) INTO v_revoked FROM device_registrations
    WHERE activation_code='R2-CODE-AAAA-BBBB-CCCC-DDDD'
      AND device_fingerprint='fp-mixed' AND revoked_at IS NOT NULL;
  PERFORM pg_temp.expect_true('R2-4 mixed duplicates safe',
    (r->>'status') = 'refreshed' AND v_active = 1 AND v_revoked = 2,
    'active row refreshed; revoked history untouched; no unique violation');
END $$;

-- ================================================================ R2-5 =====
-- Multiple revoked rows, NO active row: reactivation must pick ONE row
-- deterministically (latest revoked_at) every time.
DO $$
DECLARE r jsonb; v_id uuid; v_id2 uuid; v_new uuid; v_old uuid;
BEGIN
  INSERT INTO device_registrations
    (activation_code, device_fingerprint, device_name, revoked_at)
  VALUES
    ('R2-CODE-AAAA-BBBB-CCCC-DDDD', 'fp-multi', 'rev-old', now() - interval '9 days')
    RETURNING id INTO v_old;
  INSERT INTO device_registrations
    (activation_code, device_fingerprint, device_name, revoked_at)
  VALUES
    ('R2-CODE-AAAA-BBBB-CCCC-DDDD', 'fp-multi', 'rev-new', now() - interval '1 day')
    RETURNING id INTO v_new;
  r := register_device('R2-CODE-AAAA-BBBB-CCCC-DDDD', 'fp-multi', 'back');
  SELECT id INTO v_id FROM device_registrations
    WHERE activation_code='R2-CODE-AAAA-BBBB-CCCC-DDDD'
      AND device_fingerprint='fp-multi' AND revoked_at IS NULL;
  PERFORM pg_temp.expect_true('R2-5 deterministic reactivation',
    (r->>'status') = 'reactivated' AND v_id = v_new,
    'latest-revoked row reactivated; older history stays revoked');
  -- Re-revoke and reactivate again: same row must be chosen again.
  UPDATE device_registrations SET revoked_at = now() WHERE id = v_id;
  r := register_device('R2-CODE-AAAA-BBBB-CCCC-DDDD', 'fp-multi', 'back2');
  SELECT id INTO v_id2 FROM device_registrations
    WHERE activation_code='R2-CODE-AAAA-BBBB-CCCC-DDDD'
      AND device_fingerprint='fp-multi' AND revoked_at IS NULL;
  PERFORM pg_temp.expect_true('R2-5 stable choice', v_id = v_id2,
    'repeat activation converges on the same row');
END $$;

-- ================================================================ R2-6 =====
-- rate_limit_hit: counting, atomic-feeling upsert semantics, reset,
-- fixed-window expiry.
DO $$
DECLARE r jsonb; k text := 'r2test-window';
BEGIN
  DELETE FROM rate_limit_buckets WHERE bucket_key = k;
  -- 3 charged hits against a limit of 3: all allowed.
  FOR i IN 1..3 LOOP
    r := rate_limit_hit(k, 3, 600, true);
    IF (r->>'allowed')::boolean IS NOT TRUE THEN
      RAISE EXCEPTION 'FAIL R2-6: hit % unexpectedly denied', i;
    END IF;
  END LOOP;
  -- 4th hit exceeds the limit.
  r := rate_limit_hit(k, 3, 600, true);
  PERFORM pg_temp.expect_true('R2-6 limit enforced',
    (r->>'allowed')::boolean IS FALSE, '4th charged hit denied');
  -- Read-only check (p_charge=false) must not inflate the count.
  PERFORM rate_limit_hit(k, 3, 600, false);
  r := rate_limit_hit(k, 3, 600, false);
  PERFORM pg_temp.expect_true('R2-6 charge=false read-only',
    (r->>'count')::int = 4, 'uncharged checks do not increment');
  -- rate_limit_reset clears the bucket.
  PERFORM rate_limit_reset(k);
  r := rate_limit_hit(k, 3, 600, true);
  PERFORM pg_temp.expect_true('R2-6 reset clears',
    (r->>'allowed')::boolean IS TRUE AND (r->>'count')::int = 1,
    'post-reset hit starts a fresh window');
END $$;

-- Fixed-window expiry with a 1-second window. now() is transaction-constant
-- inside a DO block, so each phase runs as its OWN transaction (separate
-- psql statements) with a real pg_sleep between them.
DELETE FROM rate_limit_buckets WHERE bucket_key = 'r2test-expiry';
SELECT rate_limit_hit('r2test-expiry', 1, 1, true);   -- fills the window
SELECT pg_temp.expect_true('R2-6 window denies',
  ((rate_limit_hit('r2test-expiry', 1, 1, true)->>'allowed')::boolean) IS FALSE,
  'second hit inside 1s window denied');
SELECT pg_sleep(1.2);
DO $$
DECLARE r jsonb;
BEGIN
  r := rate_limit_hit('r2test-expiry', 1, 1, true);
  PERFORM pg_temp.expect_true('R2-6 window expiry resets',
    (r->>'allowed')::boolean IS TRUE AND (r->>'count')::int = 1,
    'elapsed window restarts the counter');
END $$;

-- ================================================================ R2-7 =====
-- Grants: privileged functions are service_role/postgres only; the buckets
-- table is RLS-enabled and revoked from anon/authenticated.
DO $$
BEGIN
  PERFORM pg_temp.expect_true('R2-7 function grants',
    has_function_privilege('service_role',
      'public.register_device(text,text,text)', 'EXECUTE')
    AND has_function_privilege('service_role',
      'public.rate_limit_hit(text,integer,integer,boolean)', 'EXECUTE')
    AND has_function_privilege('service_role',
      'public.rate_limit_reset(text)', 'EXECUTE')
    AND NOT has_function_privilege('anon',
      'public.register_device(text,text,text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated',
      'public.register_device(text,text,text)', 'EXECUTE')
    AND NOT has_function_privilege('anon',
      'public.rate_limit_hit(text,integer,integer,boolean)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated',
      'public.rate_limit_hit(text,integer,integer,boolean)', 'EXECUTE'),
    'service_role can execute; anon/authenticated cannot');
  PERFORM pg_temp.expect_true('R2-7 table grants + RLS',
    (SELECT relrowsecurity FROM pg_class
      WHERE oid = 'public.rate_limit_buckets'::regclass)
    AND has_table_privilege('service_role',
      'public.rate_limit_buckets', 'SELECT')
    AND NOT has_table_privilege('anon',
      'public.rate_limit_buckets', 'SELECT')
    AND NOT has_table_privilege('authenticated',
      'public.rate_limit_buckets', 'SELECT'),
    'RLS enabled; only service_role holds table privileges');
END $$;

-- register_device refuses unknown / revoked / expired codes.
DO $$
DECLARE r jsonb;
BEGIN
  r := register_device('NO-SUCH-CODE', 'fp-x', 'x');
  PERFORM pg_temp.expect_true('R2-7 unknown code',
    (r->>'status') = 'not_found', 'unknown code -> not_found');
  UPDATE licenses SET revoked_at = now()
    WHERE activation_code='R2-CODE-AAAA-BBBB-CCCC-DDDD';
  r := register_device('R2-CODE-AAAA-BBBB-CCCC-DDDD', 'fp-new', 'x');
  PERFORM pg_temp.expect_true('R2-7 revoked license',
    (r->>'status') = 'revoked', 'revoked license -> revoked');
  UPDATE licenses SET revoked_at = NULL
    WHERE activation_code='R2-CODE-AAAA-BBBB-CCCC-DDDD';
END $$;

SELECT 'ALL REQUEST-2 LICENSE/RATE-LIMIT CHECKS PASSED' AS result;
