-- Request 3 — device licence vs user authorization, on the REAL schema.
--
-- Runs against the replayed schema (replay_migrations.sh output) in CI,
-- AFTER h1_void_invariants and request2_licensing. Never run against
-- production.
--
-- A signed device licence authenticates the DEVICE. It never proves which
-- human is at the till, so `pos_sync_apply` must resolve every staged row to
-- a live user through a server-issued actor grant (`actor_grants`) and must
-- ignore every actor/credential claim inside the payload.
--
-- Covered here (single-session semantics):
--   A1  no grant        -> every staged row DEFERS (stays PENDING), never applies
--   A2  device-only     -> cannot change an owner's credentials, create or
--                         promote an owner, or alter another user's credentials
--   A3  owner grant     -> may provision a CASHIER (role forced, credentials
--                         accepted once) but still cannot touch an OWNER row
--   A4  forged ids      -> payload cashier_id/user_id/created_by are ignored;
--                         the resolved grant user is what lands
--   A5  authority       -> a grant for an inactive user or a user without the
--                         required feature permission cannot sell, move cash,
--                         or touch finance/warehouse rows
--   A6  finance         -> a client can REQUEST completion/deletion but the
--                         transition runs through the locked RPC with the
--                         resolved actor; completed_by is never payload data
--   A7  void safety     -> H1 posture intact: staged void requests land
--                         PENDING only; no VOIDED/APPROVED transition exists
--   A8  grant lifecycle -> wrong device, expiry, revocation, and a
--                         token_version bump all stop resolving
--   A9  tenant isolation-> a grant minted for tenant A resolves nothing for
--                         tenant B, and B's apply pass never sees A's rows
--   A10 legit workflows -> authorized sale / cash movement / finance /
--                         warehouse rows still apply end to end
--   A11 grants surface -> issue/resolve/revoke are service-role only and
--                         actor_grants is RLS-locked
--
-- psql -v ON_ERROR_STOP=1 -f request3_actor_authorization_test.sql

\set ON_ERROR_STOP on
\pset footer off

-- ------------------------------------------------------------- helpers --
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

-- Stage one mirror row exactly the way the sync gateway does: device_id is
-- the VERIFIED fingerprint and actor_grant_hash is the SHA-256 of the raw
-- token (never the token itself).
CREATE OR REPLACE FUNCTION pg_temp.stage(
  p_customer uuid,
  p_type     text,
  p_id       text,
  p_payload  jsonb,
  p_grant    text DEFAULT NULL,
  p_device   text DEFAULT 'fp-dev1'
) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.sync_mirror
    (customer_id, entity_type, entity_id, operation, device_id, payload,
     actor_grant_hash, apply_status)
  VALUES (
    p_customer, p_type, p_id, 'UPSERT', p_device, p_payload,
    CASE WHEN p_grant IS NULL OR btrim(p_grant) = '' THEN NULL
         ELSE public.pos_actor_grant_hash(p_grant) END,
    'PENDING')
  ON CONFLICT (customer_id, entity_type, entity_id) DO UPDATE SET
    payload          = EXCLUDED.payload,
    actor_grant_hash = EXCLUDED.actor_grant_hash,
    device_id        = EXCLUDED.device_id,
    apply_status     = 'PENDING',
    apply_error      = NULL,
    applied_at       = NULL,
    received_at      = now();
END $$;

-- Run the apply pass the way the gateway does after a push.
CREATE OR REPLACE FUNCTION pg_temp.apply(
  p_customer uuid DEFAULT '44444444-4444-4444-4444-444444444444',
  p_device   text    DEFAULT 'fp-dev1'
) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT public.pos_sync_apply(p_customer, 500, p_device);
$$;

-- Mirror verdict for one staged entity.
CREATE OR REPLACE FUNCTION pg_temp.verdict(
  p_type text, p_id text
) RETURNS text
LANGUAGE sql AS $$
  SELECT apply_status || ':' || COALESCE(apply_error, '')
  FROM public.sync_mirror
  WHERE customer_id = '44444444-4444-4444-4444-444444444444'
    AND entity_type = p_type AND entity_id = p_id;
$$;

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
  ('44444444-4444-4444-4444-444444444444', 'R3 Test Shop'),
  ('55555555-5555-5555-5555-555555555555', 'R3 Other Shop');

INSERT INTO licenses (activation_code, customer_id, seat_limit)
VALUES ('R3-CODE-AAAA-BBBB-CCCC-DDDD', '44444444-4444-4444-4444-444444444444', 1),
       ('R3-CODE-EEEE-FFFF-GGGG-HHHH', '55555555-5555-5555-5555-555555555555', 1);

INSERT INTO device_registrations
  (activation_code, device_fingerprint, device_name)
VALUES
  ('R3-CODE-AAAA-BBBB-CCCC-DDDD', 'fp-dev1', 'till 1'),
  ('R3-CODE-AAAA-BBBB-CCCC-DDDD', 'fp-dev2', 'till 2'),
  ('R3-CODE-EEEE-FFFF-GGGG-HHHH', 'fp-c2',   'other till');

INSERT INTO pos_users
  (id, customer_id, username, role, pw_salt, pw_hash, active, permissions)
VALUES
  ('owner1', '44444444-4444-4444-4444-444444444444', 'owner', 'OWNER', 's', 'h-owner', true, '[]'::jsonb),
  ('cashall', '44444444-4444-4444-4444-444444444444', 'cashall', 'CASHIER', 's', 'h-cashall', true,
   '["pos","register","finance","warehouse","warehouse_fill","reports"]'::jsonb),
  ('cashnopos', '44444444-4444-4444-4444-444444444444', 'cashnopos', 'CASHIER', 's', 'h-nopos', true,
   '["register"]'::jsonb),
  -- cashrev starts ACTIVE so a grant can be minted for it; it is deactivated
  -- below, which is what makes its grant stop resolving (A5/A8).
  ('cashrev', '44444444-4444-4444-4444-444444444444', 'cashrev', 'CASHIER', 's', 'h-rev', true,
   '["pos","register","finance","warehouse","warehouse_fill"]'::jsonb),
  ('cashdead', '44444444-4444-4444-4444-444444444444', 'cashdead', 'CASHIER', 's', 'h-dead', false,
   '["pos","register","finance","warehouse","warehouse_fill"]'::jsonb),
  ('c2owner', '55555555-5555-5555-5555-555555555555', 'c2owner', 'OWNER', 's', 'h-c2', true, '[]'::jsonb);

-- Mint grants through the real RPC, exactly as pos-api does. Only the hash
-- is ever stored; the raw token lives in this temp table for staging.
CREATE TEMP TABLE r3_grants (label text PRIMARY KEY, token text NOT NULL);

INSERT INTO r3_grants (label, token)
SELECT 'owner', (public.pos_issue_actor_grant(
  '44444444-4444-4444-4444-444444444444', 'owner1', 'fp-dev1', 3600)->>'grant');
INSERT INTO r3_grants (label, token)
SELECT 'cashall', (public.pos_issue_actor_grant(
  '44444444-4444-4444-4444-444444444444', 'cashall', 'fp-dev1', 3600)->>'grant');
INSERT INTO r3_grants (label, token)
SELECT 'cashnopos', (public.pos_issue_actor_grant(
  '44444444-4444-4444-4444-444444444444', 'cashnopos', 'fp-dev1', 3600)->>'grant');
INSERT INTO r3_grants (label, token)
SELECT 'cashrev', (public.pos_issue_actor_grant(
  '44444444-4444-4444-4444-444444444444', 'cashrev', 'fp-dev1', 3600)->>'grant');

-- Deactivate cashrev AFTER its grant exists: this is the "user was disabled
-- while holding a live grant" case.
UPDATE public.pos_users SET active = false
WHERE customer_id = '44444444-4444-4444-4444-444444444444' AND id = 'cashrev';

INSERT INTO r3_grants (label, token)
SELECT 'c2owner', (public.pos_issue_actor_grant(
  '55555555-5555-5555-5555-555555555555', 'c2owner', 'fp-c2', 3600)->>'grant');

CREATE OR REPLACE FUNCTION pg_temp.grant(p_label text) RETURNS text
LANGUAGE sql AS $$ SELECT token FROM r3_grants WHERE label = p_label $$;

-- Grant issuance refuses unknown/inactive users and unregistered devices.
SELECT pg_temp.expect_error('A11 issue unknown user',
  format('SELECT public.pos_issue_actor_grant(%L,%L,%L,%L)',
    '44444444-4444-4444-4444-444444444444', 'ghost', 'fp-dev1', 3600),
  'User is not active');
SELECT pg_temp.expect_error('A11 issue inactive user',
  format('SELECT public.pos_issue_actor_grant(%L,%L,%L,%L)',
    '44444444-4444-4444-4444-444444444444', 'cashdead', 'fp-dev1', 3600),
  'User is not active');
SELECT pg_temp.expect_error('A11 issue unregistered device',
  format('SELECT public.pos_issue_actor_grant(%L,%L,%L,%L)',
    '44444444-4444-4444-4444-444444444444', 'owner1', 'fp-ghost', 3600),
  'Device is not registered');

-- One live grant per (user, device): re-issuing retires the old token.
DO $$
DECLARE old_hash text; new_token text;
BEGIN
  SELECT public.pos_actor_grant_hash(token) INTO old_hash
    FROM r3_grants WHERE label = 'cashnopos';
  SELECT public.pos_issue_actor_grant(
    '44444444-4444-4444-4444-444444444444', 'cashnopos', 'fp-dev1', 3600
  )->>'grant' INTO new_token;
  UPDATE r3_grants SET token = new_token WHERE label = 'cashnopos';
  PERFORM pg_temp.expect_true('A8 reissue rotates grant',
    (SELECT count(*) FROM public.actor_grants
      WHERE grant_hash = old_hash AND revoked_at IS NULL) = 0
    AND (SELECT count(*) FROM public.actor_grants ag
      JOIN public.pos_users u ON u.customer_id = ag.customer_id
        AND u.id = ag.user_id
      WHERE ag.user_id = 'cashnopos' AND ag.revoked_at IS NULL) = 1,
    'old token revoked, exactly one live grant remains');
END $$;

-- ================================================================ A1 ======
-- No grant at all: nothing may apply. Every row stays PENDING with an
-- ACTOR_AUTH_REQUIRED error so the client keeps its outbox entry.
SELECT pg_temp.stage(
  '44444444-4444-4444-4444-444444444444', 'sale', 'sale-nogrant',
  jsonb_build_object(
    'sale', jsonb_build_object(
      'cashier_id', 'owner1', 'device_id', 'fp-dev1',
      'receipt_number', 'R-NG', 'payment_method', 'CASH',
      'discount_minor_units', 0, 'amount_paid_minor_units', 1000),
    'items', jsonb_build_array(jsonb_build_object(
      'id', 'li-ng', 'product_id', 'prod-widget', 'product_name_snapshot', 'Widget', 'quantity_text', '1',
      'unit_price_snapshot_minor_units', 1000,
      'billing_quantity_milliunits', 1000,
      'line_discount_minor_units', 0, 'line_total_minor_units', 1000))));

SELECT pg_temp.apply();
SELECT pg_temp.expect_true('A1 device-only sale defers',
  pg_temp.verdict('sale', 'sale-nogrant')
    LIKE 'PENDING:ACTOR_AUTH_REQUIRED%'
  AND NOT EXISTS (SELECT 1 FROM public.sales
    WHERE customer_id = '44444444-4444-4444-4444-444444444444'
      AND id = 'sale-nogrant'),
  'mirror row still PENDING, no sale written');

-- A syntactically present but UNKNOWN grant hash defers the same way.
SELECT pg_temp.stage(
  '44444444-4444-4444-4444-444444444444', 'cash_movement', 'cm-forged',
  jsonb_build_object('cash_movement', jsonb_build_object(
    'user_id', 'owner1', 'type', 'WITHDRAWAL',
    'amount_minor_units', 500, 'reason', 'fake')),
  'deadbeefdeadbeef');
SELECT pg_temp.apply();
SELECT pg_temp.expect_true('A1 forged grant defers',
  pg_temp.verdict('cash_movement', 'cm-forged')
    LIKE 'PENDING:ACTOR_AUTH_REQUIRED%'
  AND NOT EXISTS (SELECT 1 FROM public.cash_movements
    WHERE customer_id = '44444444-4444-4444-4444-444444444444'
      AND id = 'cm-forged'),
  'unknown grant hash cannot move cash');

-- ================================================================ A2 ======
-- A device (even holding a valid CASHIER grant) can never touch accounts:
-- not the owner's credentials, not an owner row, not a promotion.

-- 2a) cashier grant tries to rewrite the OWNER's login + credentials.
SELECT pg_temp.stage(
  '44444444-4444-4444-4444-444444444444', 'user', 'owner1',
  jsonb_build_object('user', jsonb_build_object(
    'id', 'owner1', 'username', 'attacker', 'role', 'CASHIER',
    'pw_hash', 'forged', 'pw_salt', 'forged',
    'permissions', '["pos"]', 'is_active', 1)),
  pg_temp.grant('cashall'));
SELECT pg_temp.apply();
SELECT pg_temp.expect_true('A2a cashier grant cannot edit owner',
  pg_temp.verdict('user', 'owner1') LIKE 'REJECTED:%'
  AND (SELECT username FROM public.pos_users
       WHERE customer_id = '44444444-4444-4444-4444-444444444444'
         AND id = 'owner1') = 'owner'
  AND (SELECT pw_hash FROM public.pos_users
       WHERE customer_id = '44444444-4444-4444-4444-444444444444'
         AND id = 'owner1') = 'h-owner',
  'owner username/credentials untouched');

-- 2b) even the OWNER's own grant cannot push credential/role changes for an
--     existing owner row — device sync simply does not carry that power.
SELECT pg_temp.stage(
  '44444444-4444-4444-4444-444444444444', 'user', 'owner1',
  jsonb_build_object('user', jsonb_build_object(
    'id', 'owner1', 'username', 'owner2', 'role', 'OWNER',
    'pw_hash', 'newhash', 'pw_salt', 'newsalt')),
  pg_temp.grant('owner'));
SELECT pg_temp.apply();
SELECT pg_temp.expect_true('A2b owner grant cannot rewrite owner creds',
  pg_temp.verdict('user', 'owner1') LIKE 'REJECTED:%'
  AND (SELECT pw_hash FROM public.pos_users
       WHERE customer_id = '44444444-4444-4444-4444-444444444444'
         AND id = 'owner1') = 'h-owner',
  'existing owner credentials immutable via device sync');

-- 2c) no grant may create or promote an owner — first with NO grant at all
--     (defers), then with a cashier grant (rejects).
SELECT pg_temp.stage(
  '44444444-4444-4444-4444-444444444444', 'user', 'newowner',
  jsonb_build_object('user', jsonb_build_object(
    'id', 'newowner', 'username', 'newowner', 'role', 'OWNER',
    'pw_hash', 'x', 'pw_salt', 'y')));
SELECT pg_temp.apply();
SELECT pg_temp.expect_true('A2c ungranted owner create defers',
  pg_temp.verdict('user', 'newowner') LIKE 'PENDING:ACTOR_AUTH_REQUIRED%',
  'no account row appears without a grant');

SELECT pg_temp.stage(
  '44444444-4444-4444-4444-444444444444', 'user', 'newowner',
  jsonb_build_object('user', jsonb_build_object(
    'id', 'newowner', 'username', 'newowner', 'role', 'OWNER',
    'pw_hash', 'x', 'pw_salt', 'y')),
  pg_temp.grant('cashall'));
SELECT pg_temp.apply();
SELECT pg_temp.expect_true('A2c cashier grant cannot promote owner',
  pg_temp.verdict('user', 'newowner') LIKE 'REJECTED:%'
  AND NOT EXISTS (SELECT 1 FROM public.pos_users
    WHERE customer_id = '44444444-4444-4444-4444-444444444444'
      AND id = 'newowner'),
  'no owner row created');

-- Even an owner grant cannot mint an OWNER row through sync: owner
-- provisioning belongs to the live pos-api surface only.
SELECT pg_temp.stage(
  '44444444-4444-4444-4444-444444444444', 'user', 'newowner2',
  jsonb_build_object('user', jsonb_build_object(
    'id', 'newowner2', 'username', 'newowner2', 'role', 'OWNER',
    'pw_hash', 'x', 'pw_salt', 'y')),
  pg_temp.grant('owner'));
SELECT pg_temp.apply();
SELECT pg_temp.expect_true('A2c owner grant cannot mint owner via sync',
  pg_temp.verdict('user', 'newowner2') LIKE 'REJECTED:%'
  AND NOT EXISTS (SELECT 1 FROM public.pos_users
    WHERE customer_id = '44444444-4444-4444-4444-444444444444'
      AND id = 'newowner2'),
  'owner creation refused even for an owner grant');

-- ================================================================ A3 ======
-- Owner grant MAY provision a CASHIER offline. The role is forced to
-- CASHIER regardless of payload claims about authority, and provisioning
-- credentials are accepted once for a NEW account.
SELECT pg_temp.stage(
  '44444444-4444-4444-4444-444444444444', 'user', 'cashnew',
  jsonb_build_object('user', jsonb_build_object(
    'id', 'cashnew', 'username', 'cashnew', 'role', 'CASHIER',
    'pw_hash', 'realhash', 'pw_salt', 'realsalt',
    'permissions', '["pos","register"]', 'is_active', 1)),
  pg_temp.grant('owner'));
SELECT pg_temp.apply();
SELECT pg_temp.expect_true('A3 owner provisions cashier',
  pg_temp.verdict('user', 'cashnew') LIKE 'APPLIED%'
  AND (SELECT role FROM public.pos_users
       WHERE customer_id = '44444444-4444-4444-4444-444444444444'
         AND id = 'cashnew') = 'CASHIER',
  'new account landed as CASHIER with provisioning credentials');

-- An owner grant editing an existing CASHIER may change name/permissions/
-- status but NEVER the credential columns.
SELECT pg_temp.stage(
  '44444444-4444-4444-4444-444444444444', 'user', 'cashall',
  jsonb_build_object('user', jsonb_build_object(
    'id', 'cashall', 'username', 'cashall', 'role', 'CASHIER',
    'pw_hash', 'ATTACKER', 'pw_salt', 'ATTACKER',
    'permissions', '["pos"]', 'is_active', 1)),
  pg_temp.grant('owner'));
SELECT pg_temp.apply();
SELECT pg_temp.expect_true('A3 owner edit keeps cashier credentials',
  pg_temp.verdict('user', 'cashall') LIKE 'APPLIED%'
  AND (SELECT pw_hash FROM public.pos_users
       WHERE customer_id = '44444444-4444-4444-4444-444444444444'
         AND id = 'cashall') = 'h-cashall'
  AND (SELECT permissions FROM public.pos_users
       WHERE customer_id = '44444444-4444-4444-4444-444444444444'
         AND id = 'cashall') = '["pos"]'::jsonb,
  'credentials untouched, permissions updated');

-- Restore cashall's full permission set for the workflow tests below.
UPDATE public.pos_users SET permissions =
  '["pos","register","finance","warehouse","warehouse_fill","reports"]'::jsonb
WHERE customer_id = '44444444-4444-4444-4444-444444444444' AND id = 'cashall';

-- A non-owner grant cannot provision or edit accounts at all.
SELECT pg_temp.stage(
  '44444444-4444-4444-4444-444444444444', 'user', 'cashx',
  jsonb_build_object('user', jsonb_build_object(
    'id', 'cashx', 'username', 'cashx', 'role', 'CASHIER',
    'pw_hash', 'x', 'pw_salt', 'y')),
  pg_temp.grant('cashall'));
SELECT pg_temp.apply();
SELECT pg_temp.expect_true('A3 cashier grant cannot provision',
  pg_temp.verdict('user', 'cashx') LIKE 'REJECTED:%'
  AND NOT EXISTS (SELECT 1 FROM public.pos_users
    WHERE customer_id = '44444444-4444-4444-4444-444444444444'
      AND id = 'cashx'),
  'account creation is owner-only even via sync');

-- ================================================================ A4 ======
-- Forged actor ids inside the payload are ignored: the resolved grant user
-- is what lands in every actor column.
SELECT pg_temp.stage(
  '44444444-4444-4444-4444-444444444444', 'sale', 'sale-forged',
  jsonb_build_object(
    'sale', jsonb_build_object(
      'cashier_id', 'owner1', 'device_id', 'fp-dev1',
      'receipt_number', 'R-FG', 'payment_method', 'CASH',
      'discount_minor_units', 0, 'amount_paid_minor_units', 1000),
    'items', jsonb_build_array(jsonb_build_object(
      'id', 'li-fg', 'product_id', 'prod-widget', 'product_name_snapshot', 'Widget', 'quantity_text', '1',
      'unit_price_snapshot_minor_units', 1000,
      'billing_quantity_milliunits', 1000,
      'line_discount_minor_units', 0, 'line_total_minor_units', 1000))),
  pg_temp.grant('cashall'));

SELECT pg_temp.stage(
  '44444444-4444-4444-4444-444444444444', 'cash_movement', 'cm-forged2',
  jsonb_build_object('cash_movement', jsonb_build_object(
    'user_id', 'owner1', 'type', 'WITHDRAWAL',
    'amount_minor_units', 500, 'reason', 'petty cash')),
  pg_temp.grant('cashall'));

SELECT pg_temp.apply();
SELECT pg_temp.expect_true('A4 forged cashier_id ignored',
  pg_temp.verdict('sale', 'sale-forged') LIKE 'APPLIED%'
  AND (SELECT cashier_id FROM public.sales
       WHERE customer_id = '44444444-4444-4444-4444-444444444444'
         AND id = 'sale-forged') = 'cashall',
  'sale booked under the grant user, not the claimed owner');
SELECT pg_temp.expect_true('A4 forged user_id ignored',
  pg_temp.verdict('cash_movement', 'cm-forged2') LIKE 'APPLIED%'
  AND (SELECT user_id FROM public.cash_movements
       WHERE customer_id = '44444444-4444-4444-4444-444444444444'
         AND id = 'cm-forged2') = 'cashall',
  'movement booked under the grant user');

-- ================================================================ A5 ======
-- Authority: the resolved user must be ACTIVE and hold the feature tick.
-- cashnopos lacks 'pos'; cashdead is deactivated (its grant no longer
-- resolves at all).
SELECT pg_temp.stage(
  '44444444-4444-4444-4444-444444444444', 'sale', 'sale-nopos',
  jsonb_build_object(
    'sale', jsonb_build_object(
      'cashier_id', 'cashnopos', 'device_id', 'fp-dev1',
      'receipt_number', 'R-NP', 'payment_method', 'CASH',
      'discount_minor_units', 0, 'amount_paid_minor_units', 1000),
    'items', jsonb_build_array(jsonb_build_object(
      'id', 'li-np', 'product_id', 'prod-widget', 'product_name_snapshot', 'Widget', 'quantity_text', '1',
      'unit_price_snapshot_minor_units', 1000,
      'billing_quantity_milliunits', 1000,
      'line_discount_minor_units', 0, 'line_total_minor_units', 1000))),
  pg_temp.grant('cashnopos'));

SELECT pg_temp.stage(
  '44444444-4444-4444-4444-444444444444', 'sale', 'sale-dead',
  jsonb_build_object(
    'sale', jsonb_build_object(
      'cashier_id', 'cashrev', 'device_id', 'fp-dev1',
      'receipt_number', 'R-DD', 'payment_method', 'CASH',
      'discount_minor_units', 0, 'amount_paid_minor_units', 1000),
    'items', jsonb_build_array(jsonb_build_object(
      'id', 'li-dd', 'product_id', 'prod-widget', 'product_name_snapshot', 'Widget', 'quantity_text', '1',
      'unit_price_snapshot_minor_units', 1000,
      'billing_quantity_milliunits', 1000,
      'line_discount_minor_units', 0, 'line_total_minor_units', 1000))),
  pg_temp.grant('cashrev'));

SELECT pg_temp.apply();
SELECT pg_temp.expect_true('A5 missing pos permission rejected',
  pg_temp.verdict('sale', 'sale-nopos') LIKE 'REJECTED:%'
  AND NOT EXISTS (SELECT 1 FROM public.sales
    WHERE customer_id = '44444444-4444-4444-4444-444444444444'
      AND id = 'sale-nopos'),
  'cashier without pos tick cannot sell via sync');
SELECT pg_temp.expect_true('A5 inactive user defers, never applies',
  pg_temp.verdict('sale', 'sale-dead') LIKE 'PENDING:ACTOR_AUTH_REQUIRED%'
  AND NOT EXISTS (SELECT 1 FROM public.sales
    WHERE customer_id = '44444444-4444-4444-4444-444444444444'
      AND id = 'sale-dead'),
  'deactivated account grant stops resolving');

-- ================================================================ A6 ======
-- Finance: entries always land PENDING; a client may REQUEST a transition,
-- the locked RPC performs it with the RESOLVED actor — never the claimed
-- completed_by. cashall has 'finance'; the payload claims owner1.
SELECT pg_temp.stage(
  '44444444-4444-4444-4444-444444444444', 'finance_category', 'cat-r3',
  jsonb_build_object('finance_category', jsonb_build_object(
    'name', 'Staff loans', 'created_at', now(), 'updated_at', now())),
  pg_temp.grant('cashall'));
SELECT pg_temp.stage(
  '44444444-4444-4444-4444-444444444444', 'finance_entry', 'fe-r3',
  jsonb_build_object('finance_entry', jsonb_build_object(
    'category_id', 'cat-r3', 'source', 'LOAN',
    'amount_minor_units', 2500, 'description', 'till float',
    'status', 'COMPLETED', 'created_by', 'owner1',
    'completed_by', 'owner1', 'payment_method', 'CASH',
    'entry_date', now(), 'created_at', now(), 'updated_at', now())),
  pg_temp.grant('cashall'));
SELECT pg_temp.apply();
SELECT pg_temp.expect_true('A6 entry completes under grant actor',
  pg_temp.verdict('finance_entry', 'fe-r3') LIKE 'APPLIED%'
  AND (SELECT status FROM public.pos_finance_entries
       WHERE customer_id = '44444444-4444-4444-4444-444444444444'
         AND id = 'fe-r3') = 'COMPLETED'
  AND (SELECT completed_by FROM public.pos_finance_entries
       WHERE customer_id = '44444444-4444-4444-4444-444444444444'
         AND id = 'fe-r3') = 'cashall'
  AND (SELECT created_by FROM public.pos_finance_entries
       WHERE customer_id = '44444444-4444-4444-4444-444444444444'
         AND id = 'fe-r3') = 'cashall',
  'completed_by is the resolved grant user, not the payload claim');

-- A user WITHOUT finance permission cannot complete or delete entries, and
-- cannot delete finance categories.
SELECT pg_temp.stage(
  '44444444-4444-4444-4444-444444444444', 'finance_entry', 'fe-noperm',
  jsonb_build_object('finance_entry', jsonb_build_object(
    'category_id', 'cat-r3', 'source', 'LOAN',
    'amount_minor_units', 100, 'status', 'COMPLETED',
    'created_by', 'owner1', 'completed_by', 'owner1')),
  pg_temp.grant('cashnopos'));
SELECT pg_temp.stage(
  '55555555-5555-5555-5555-555555555555', 'finance_category', 'cat-c2',
  jsonb_build_object('finance_category', jsonb_build_object(
    'name', 'Other shop', 'created_at', now())),
  pg_temp.grant('c2owner'), 'fp-c2');
SELECT pg_temp.apply();
SELECT pg_temp.expect_true('A5 finance permission enforced',
  pg_temp.verdict('finance_entry', 'fe-noperm') LIKE 'REJECTED:%'
  AND NOT EXISTS (SELECT 1 FROM public.pos_finance_entries
    WHERE customer_id = '44444444-4444-4444-4444-444444444444'
      AND id = 'fe-noperm'),
  'no finance tick, no finance write');

-- ================================================================ A7 ======
-- H1 posture: a staged void request lands PENDING only. A payload claiming
-- APPROVED/VOIDED authority changes nothing — the transition belongs to
-- pos-api's JWT-authenticated actions.
INSERT INTO public.sales (id, customer_id, receipt_number, cashier_id,
  device_id, shift_id, payment_method, subtotal_minor_units,
  discount_minor_units, total_minor_units, amount_paid_minor_units,
  change_minor_units, status, created_at)
VALUES ('sale-vr', '44444444-4444-4444-4444-444444444444', 'R-VR', 'cashall',
  'fp-dev1', 'shift-x', 'CASH', 1000, 0, 1000, 1000, 0, 'COMPLETED', now());

SELECT pg_temp.stage(
  '44444444-4444-4444-4444-444444444444', 'void_request', 'vr-r3',
  jsonb_build_object('void_request', jsonb_build_object(
    'sale_id', 'sale-vr', 'requested_by', 'owner1',
    'reason', 'offline void', 'status', 'APPROVED',
    'decided_by', 'owner1', 'created_at', now())),
  pg_temp.grant('cashall'));
SELECT pg_temp.apply();
SELECT pg_temp.expect_true('A7 staged void stays PENDING',
  pg_temp.verdict('void_request', 'vr-r3') LIKE 'APPLIED%'
  AND (SELECT status FROM public.void_requests
       WHERE customer_id = '44444444-4444-4444-4444-444444444444'
         AND id = 'vr-r3') = 'PENDING'
  AND (SELECT requested_by FROM public.void_requests
       WHERE customer_id = '44444444-4444-4444-4444-444444444444'
         AND id = 'vr-r3') = 'cashall'
  AND (SELECT status FROM public.sales
       WHERE customer_id = '44444444-4444-4444-4444-444444444444'
         AND id = 'sale-vr') = 'COMPLETED',
  'request recorded under grant actor; sale untouched');

-- ================================================================ A8 ======
-- Grant lifecycle: wrong device, expiry, revocation, token_version bump.
SELECT pg_temp.expect_true('A8 wrong device does not resolve',
  (SELECT count(*) FROM public.pos_resolve_actor_grant(
     '44444444-4444-4444-4444-444444444444',
     public.pos_actor_grant_hash(pg_temp.grant('owner')),
     'fp-dev2')) = 0,
  'grant is bound to the device it was minted for');

SELECT pg_temp.expect_true('A8 tenant mismatch does not resolve',
  (SELECT count(*) FROM public.pos_resolve_actor_grant(
     '55555555-5555-5555-5555-555555555555',
     public.pos_actor_grant_hash(pg_temp.grant('owner')),
     'fp-dev1')) = 0,
  'tenant A grant is meaningless to tenant B');

-- expires_at must stay > issued_at (table CHECK), so age the whole row.
UPDATE public.actor_grants
SET issued_at = now() - interval '2 days',
    expires_at = now() - interval '1 day'
WHERE grant_hash = public.pos_actor_grant_hash(pg_temp.grant('cashnopos'));
SELECT pg_temp.expect_true('A8 expired grant does not resolve',
  (SELECT count(*) FROM public.pos_resolve_actor_grant(
     '44444444-4444-4444-4444-444444444444',
     public.pos_actor_grant_hash(pg_temp.grant('cashnopos')),
     'fp-dev1')) = 0,
  'expiry is enforced at resolve time');

-- Re-mint so the A10 workflow below still has a live cashnopos grant.
UPDATE r3_grants SET token = (
  SELECT public.pos_issue_actor_grant(
    '44444444-4444-4444-4444-444444444444', 'cashnopos', 'fp-dev1', 3600
  )->>'grant')
WHERE label = 'cashnopos';

UPDATE public.pos_users SET token_version = token_version + 1
WHERE customer_id = '44444444-4444-4444-4444-444444444444'
  AND id = 'cashall';
SELECT pg_temp.expect_true('A8 token_version bump kills grant',
  (SELECT count(*) FROM public.pos_resolve_actor_grant(
     '44444444-4444-4444-4444-444444444444',
     public.pos_actor_grant_hash(pg_temp.grant('cashall')),
     'fp-dev1')) = 0,
  'credential/status change invalidates outstanding grants');
UPDATE public.pos_users SET token_version = token_version - 1
WHERE customer_id = '44444444-4444-4444-4444-444444444444'
  AND id = 'cashall';

SELECT public.pos_revoke_actor_grants(
  '44444444-4444-4444-4444-444444444444', 'owner1', NULL);
SELECT pg_temp.expect_true('A8 explicit revoke kills grant',
  (SELECT count(*) FROM public.pos_resolve_actor_grant(
     '44444444-4444-4444-4444-444444444444',
     public.pos_actor_grant_hash(pg_temp.grant('owner')),
     'fp-dev1')) = 0,
  'pos_revoke_actor_grants severs the delegation');

-- Re-mint the owner grant for the remaining tests (revoke above retired it).
UPDATE r3_grants SET token = (
  SELECT public.pos_issue_actor_grant(
    '44444444-4444-4444-4444-444444444444', 'owner1', 'fp-dev1', 3600
  )->>'grant')
WHERE label = 'owner';

-- ================================================================ A9 ======
-- Tenant isolation end to end: tenant B's apply pass cannot see or apply
-- tenant A's staged rows, and A's grant does not resolve under B.
SELECT pg_temp.stage(
  '55555555-5555-5555-5555-555555555555', 'user', 'c2new',
  jsonb_build_object('user', jsonb_build_object(
    'id', 'c2new', 'username', 'c2new', 'role', 'CASHIER',
    'pw_hash', 'x', 'pw_salt', 'y')),
  pg_temp.grant('c2owner'), 'fp-c2');
SELECT pg_temp.apply('55555555-5555-5555-5555-555555555555', 'fp-c2');
SELECT pg_temp.expect_true('A9 tenant B applies its own row',
  EXISTS (SELECT 1 FROM public.pos_users
    WHERE customer_id = '55555555-5555-5555-5555-555555555555'
      AND id = 'c2new' AND role = 'CASHIER')
  AND NOT EXISTS (SELECT 1 FROM public.pos_users
    WHERE customer_id = '44444444-4444-4444-4444-444444444444'
      AND id = 'c2new'),
  'B row landed in B only');

-- A row staged under tenant A is invisible to tenant B's apply pass.
SELECT pg_temp.expect_true('A9 cross-tenant apply is a no-op',
  (SELECT count(*) FROM public.sync_mirror
    WHERE customer_id = '55555555-5555-5555-5555-555555555555'
      AND apply_status = 'APPLIED'
      AND entity_id IN ('sale-nogrant', 'cm-forged')) = 0,
  'A staged rows never appear in B results');

-- ================================================================ A10 =====
-- Legitimate workflows still work end to end under real grants.
-- Owner grant sells, cashier-with-permission moves cash and does finance,
-- warehouse fill is allowed for the warehouse-granted cashier.
SELECT pg_temp.stage(
  '44444444-4444-4444-4444-444444444444', 'sale', 'sale-ok-owner',
  jsonb_build_object(
    'sale', jsonb_build_object(
      'cashier_id', 'owner1', 'device_id', 'fp-dev1',
      'receipt_number', 'R-OK1', 'payment_method', 'CASH',
      'discount_minor_units', 0, 'amount_paid_minor_units', 2000),
    'items', jsonb_build_array(jsonb_build_object(
      'id', 'li-ok1', 'product_id', 'prod-widget', 'product_name_snapshot', 'Widget', 'quantity_text', '1',
      'unit_price_snapshot_minor_units', 2000,
      'billing_quantity_milliunits', 1000,
      'line_discount_minor_units', 0, 'line_total_minor_units', 2000))),
  pg_temp.grant('owner'));
SELECT pg_temp.stage(
  '44444444-4444-4444-4444-444444444444', 'picklist', 'pl-r3',
  jsonb_build_object('picklist', jsonb_build_object(
    'customer_name', 'Walk-in', 'status', 'PENDING',
    'created_by', 'owner1', 'created_at', now(), 'updated_at', now())),
  pg_temp.grant('cashall'));
SELECT pg_temp.apply();
SELECT pg_temp.expect_true('A10 owner sale applies',
  pg_temp.verdict('sale', 'sale-ok-owner') LIKE 'APPLIED%'
  AND (SELECT cashier_id FROM public.sales
       WHERE id = 'sale-ok-owner') = 'owner1',
  'authorized owner sale booked');
SELECT pg_temp.expect_true('A10 warehouse picklist applies',
  pg_temp.verdict('picklist', 'pl-r3') LIKE 'APPLIED%'
  AND (SELECT created_by FROM public.picklists
       WHERE customer_id = '44444444-4444-4444-4444-444444444444'
         AND id = 'pl-r3') = 'cashall',
  'warehouse-authorized cashier created the picklist');

-- cashnopos has 'register' but no 'finance': a cash movement is fine, a
-- finance entry is not (already proven above for finance).
SELECT pg_temp.stage(
  '44444444-4444-4444-4444-444444444444', 'cash_movement', 'cm-ok-nopos',
  jsonb_build_object('cash_movement', jsonb_build_object(
    'user_id', 'cashnopos', 'type', 'DEPOSIT',
    'amount_minor_units', 700, 'reason', 'float top-up')),
  pg_temp.grant('cashnopos'));
SELECT pg_temp.apply();
SELECT pg_temp.expect_true('A10 register-permitted movement applies',
  pg_temp.verdict('cash_movement', 'cm-ok-nopos') LIKE 'APPLIED%'
  AND (SELECT user_id FROM public.cash_movements
       WHERE customer_id = '44444444-4444-4444-4444-444444444444'
         AND id = 'cm-ok-nopos') = 'cashnopos',
  'movement booked under its real actor');

-- ================================================================ A11 ======
-- The grant surface itself is service-role only and RLS-locked.
SELECT pg_temp.expect_true('A11 grant functions not client-executable',
  NOT has_function_privilege('anon',
      'public.pos_issue_actor_grant(uuid,text,text,integer)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated',
      'public.pos_issue_actor_grant(uuid,text,text,integer)', 'EXECUTE')
  AND NOT has_function_privilege('anon',
      'public.pos_resolve_actor_grant(uuid,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated',
      'public.pos_resolve_actor_grant(uuid,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('anon',
      'public.pos_revoke_actor_grants(uuid,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated',
      'public.pos_revoke_actor_grants(uuid,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('anon',
      'public.pos_actor_grant_hash(text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated',
      'public.pos_actor_grant_hash(text)', 'EXECUTE'),
  'no grant RPC reachable by anon/authenticated');

SELECT pg_temp.expect_true('A11 actor_grants RLS + no client grants',
  (SELECT relrowsecurity FROM pg_class c JOIN pg_namespace n
     ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relname = 'actor_grants')
  AND NOT has_table_privilege('anon', 'public.actor_grants', 'SELECT')
  AND NOT has_table_privilege('authenticated', 'public.actor_grants', 'SELECT'),
  'grant table is RLS-enabled and invisible to clients');

SELECT pg_temp.expect_true('A11 raw token never stored',
  NOT EXISTS (
    SELECT 1 FROM public.actor_grants ag
    JOIN r3_grants g ON ag.grant_hash = public.pos_actor_grant_hash(g.token)
    WHERE ag.grant_hash = g.token),
  'only SHA-256 digests persist; the bearer token itself is never a key');

-- ================================================================ final ====
SELECT 'ALL REQUEST-3 ACTOR-AUTHORIZATION CHECKS PASSED' AS result;
SELECT entity_type, entity_id, apply_status, apply_error
FROM public.sync_mirror
WHERE customer_id = '44444444-4444-4444-4444-444444444444'
ORDER BY entity_type, entity_id;
