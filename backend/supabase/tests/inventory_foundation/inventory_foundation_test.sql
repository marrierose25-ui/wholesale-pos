-- Inventory foundation, on the REAL schema (migrations
-- 20261209000000_inventory_foundation + 20261210000000_inventory_sync_apply).
--
-- Runs against the replayed schema AFTER request3_financial_integrity in CI.
-- Never run against production.
--
--   I1  pos_create_inventory_product: product + opening stock + optional
--       image land atomically; an invalid image rolls ALL of it back
--   I2  store tenant isolation: a same-id store under another tenant is
--       refused loudly (REJECTED), never overwritten
--   I3  store_inventory upsert: duplicate pushes converge on one row;
--       newest-wins on updated_at both directions
--   I4  missing-parent deferral: store_inventory / product_image staged
--       before their parents stay PENDING with DEFERRED, then land once
--       the parents arrive — no data loss, no duplicates on retry
--   I5  tombstone behaviour: deleted_at propagates and a stale
--       non-deleted write can neither overwrite nor resurrect
--   I6  product_image persistence: bytes stored and retrievable,
--       invalid base64 REJECTED, tombstone clears bytes
--   I7  inventory-only product creation sync: product + stock + image land;
--       purchase price survives; updates still require 'pos'; an actor with
--       neither feature is rejected; older payloads default bought price to 0
--   I8  authorization: an actor without the 'inventory' feature is
--       REJECTED; anon/authenticated cannot execute the RPCs directly
--
-- psql -v ON_ERROR_STOP=1 -f inventory_foundation_test.sql

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
  p_grant text DEFAULT NULL, p_device text DEFAULT 'fp-inv1'
) RETURNS void LANGUAGE plpgsql AS $$
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
    payload = EXCLUDED.payload,
    actor_grant_hash = EXCLUDED.actor_grant_hash,
    device_id = EXCLUDED.device_id,
    apply_status = 'PENDING', apply_error = NULL, applied_at = NULL,
    received_at = now();
END $$;

-- ---------------------------------------------------------------------------
-- Fixture: two tenants. Tenant A exercises everything; tenant B only proves
-- isolation. Both get an OWNER (all features) and a CASHIER holding 'pos'
-- but NOT 'inventory'.
-- ---------------------------------------------------------------------------

DELETE FROM sync_mirror
WHERE customer_id IN ('11111111-1111-1111-1111-111111111111',
                      '22222222-2222-2222-2222-222222222222');
DELETE FROM product_images
WHERE customer_id IN ('11111111-1111-1111-1111-111111111111',
                      '22222222-2222-2222-2222-222222222222');
DELETE FROM store_inventory
WHERE customer_id IN ('11111111-1111-1111-1111-111111111111',
                      '22222222-2222-2222-2222-222222222222');
DELETE FROM stores
WHERE customer_id IN ('11111111-1111-1111-1111-111111111111',
                      '22222222-2222-2222-2222-222222222222');
DELETE FROM pos_products
WHERE customer_id IN ('11111111-1111-1111-1111-111111111111',
                      '22222222-2222-2222-2222-222222222222');
DELETE FROM pos_users
WHERE customer_id IN ('11111111-1111-1111-1111-111111111111',
                      '22222222-2222-2222-2222-222222222222');
DELETE FROM device_registrations
WHERE activation_code IN ('INV-CODE-AAAA-BBBB-CCCC-0001',
                          'INV-CODE-AAAA-BBBB-CCCC-0002');
DELETE FROM licenses
WHERE activation_code IN ('INV-CODE-AAAA-BBBB-CCCC-0001',
                          'INV-CODE-AAAA-BBBB-CCCC-0002');
DELETE FROM customers
WHERE id IN ('11111111-1111-1111-1111-111111111111',
             '22222222-2222-2222-2222-222222222222');

INSERT INTO customers (id, name) VALUES
  ('11111111-1111-1111-1111-111111111111', 'Inv Tenant A'),
  ('22222222-2222-2222-2222-222222222222', 'Inv Tenant B');
INSERT INTO licenses (activation_code, customer_id, seat_limit) VALUES
  ('INV-CODE-AAAA-BBBB-CCCC-0001', '11111111-1111-1111-1111-111111111111', 2),
  ('INV-CODE-AAAA-BBBB-CCCC-0002', '22222222-2222-2222-2222-222222222222', 2);
INSERT INTO device_registrations
  (activation_code, device_fingerprint, device_name) VALUES
  ('INV-CODE-AAAA-BBBB-CCCC-0001', 'fp-inv1', 'till inv-a'),
  ('INV-CODE-AAAA-BBBB-CCCC-0002', 'fp-inv2', 'till inv-b');

INSERT INTO pos_users
  (id, customer_id, username, role, pw_salt, pw_hash, active, permissions) VALUES
  ('inv-owner-a', '11111111-1111-1111-1111-111111111111', 'inv-owner-a',
   'OWNER', 's', 'h', true, '[]'::jsonb),
  ('inv-cash-a', '11111111-1111-1111-1111-111111111111', 'inv-cash-a',
   'CASHIER', 's', 'h', true, '["pos","inventory"]'::jsonb),
  ('inv-nofeat-a', '11111111-1111-1111-1111-111111111111', 'inv-nofeat-a',
   'CASHIER', 's', 'h', true, '["pos"]'::jsonb),
  ('inv-stock-a', '11111111-1111-1111-1111-111111111111', 'inv-stock-a',
   'CASHIER', 's', 'h', true, '["inventory"]'::jsonb),
  ('inv-none-a', '11111111-1111-1111-1111-111111111111', 'inv-none-a',
   'CASHIER', 's', 'h', true, '[]'::jsonb),
  ('inv-owner-b', '22222222-2222-2222-2222-222222222222', 'inv-owner-b',
   'OWNER', 's', 'h', true, '[]'::jsonb);

CREATE TEMP TABLE inv_grants (label text PRIMARY KEY, token text NOT NULL);
INSERT INTO inv_grants (label, token) VALUES
  ('owner-a', (public.pos_issue_actor_grant(
    '11111111-1111-1111-1111-111111111111', 'inv-owner-a', 'fp-inv1', 3600)->>'grant')),
  ('cash-a', (public.pos_issue_actor_grant(
    '11111111-1111-1111-1111-111111111111', 'inv-cash-a', 'fp-inv1', 3600)->>'grant')),
  ('nofeat-a', (public.pos_issue_actor_grant(
    '11111111-1111-1111-1111-111111111111', 'inv-nofeat-a', 'fp-inv1', 3600)->>'grant')),
  ('stock-a', (public.pos_issue_actor_grant(
    '11111111-1111-1111-1111-111111111111', 'inv-stock-a', 'fp-inv1', 3600)->>'grant')),
  ('none-a', (public.pos_issue_actor_grant(
    '11111111-1111-1111-1111-111111111111', 'inv-none-a', 'fp-inv1', 3600)->>'grant')),
  ('owner-b', (public.pos_issue_actor_grant(
    '22222222-2222-2222-2222-222222222222', 'inv-owner-b', 'fp-inv2', 3600)->>'grant'));

CREATE OR REPLACE FUNCTION pg_temp.igrant(p_label text) RETURNS text
LANGUAGE sql AS $$ SELECT token FROM inv_grants WHERE label = p_label $$;

-- A store parent row the way sync would leave it (direct insert for setup).
INSERT INTO public.stores
  (id, customer_id, name, created_at, updated_at)
VALUES
  ('st-a1', '11111111-1111-1111-1111-111111111111', 'Main Store', now(), now()),
  ('st-b1', '22222222-2222-2222-2222-222222222222', 'Beta Store', now(), now());
INSERT INTO public.pos_products
  (id, customer_id, name, code, unit, selling_price_minor_units,
   bought_price_minor_units, is_active, created_at, updated_at)
VALUES
  ('p-a1', '11111111-1111-1111-1111-111111111111', 'Berbere', 'B-1', 'Kg',
   12000, 8000, 1, now(), now());

-- ===========================================================================
-- I1  Atomic product + opening stock + image
-- ===========================================================================

DO $$
DECLARE v_res jsonb; v_pid text;
BEGIN
  v_res := public.pos_create_inventory_product(
    '11111111-1111-1111-1111-111111111111', 'inv-owner-a',
    jsonb_build_object(
      'id', 'p-atomic-1', 'name', 'Shiro Powder', 'code', 'SP-1',
      'unit', 'Kg', 'selling_price_minor_units', 15000,
      'bought_price_minor_units', 9000,
      'image_data', 'aGVsbG8='),
    'st-a1', 5000, 1000);
  v_pid := v_res->>'product_id';
  PERFORM pg_temp.expect_true('I1 product row exists', EXISTS (
    SELECT 1 FROM public.pos_products
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND id = v_pid AND name = 'Shiro Powder'));
  PERFORM pg_temp.expect_true('I1 opening stock row exists', EXISTS (
    SELECT 1 FROM public.store_inventory
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND product_id = v_pid AND store_id = 'st-a1'
      AND on_hand_milliunits = 5000 AND reorder_milliunits = 1000));
  PERFORM pg_temp.expect_true('I1 image row exists with bytes', EXISTS (
    SELECT 1 FROM public.product_images
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND product_id = v_pid AND image_data = 'aGVsbG8='));
END $$;

-- Invalid image must roll the product and stock back with it.
DO $$
DECLARE v_pid text := 'p-atomic-bad';
BEGIN
  PERFORM pg_temp.expect_error(
    'I1b invalid image rejected atomically',
    format(
      'SELECT public.pos_create_inventory_product(%L, %L, %L::jsonb, %L, %s, %s)',
      '11111111-1111-1111-1111-111111111111', 'inv-owner-a',
      jsonb_build_object(
        'id', v_pid, 'name', 'Bad Image Product', 'unit', 'Kg',
        'selling_price_minor_units', 100, 'image_data', '!!!not-b64!!!')::text,
      'st-a1', 0, 0),
    'valid base64');
  PERFORM pg_temp.expect_true('I1b no orphan product', NOT EXISTS (
    SELECT 1 FROM public.pos_products
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND id = v_pid));
  PERFORM pg_temp.expect_true('I1b no orphan stock', NOT EXISTS (
    SELECT 1 FROM public.store_inventory
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND product_id = v_pid));
  PERFORM pg_temp.expect_true('I1b no orphan image', NOT EXISTS (
    SELECT 1 FROM public.product_images
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND product_id = v_pid));
END $$;

-- ===========================================================================
-- I2  Store tenant isolation
-- ===========================================================================

-- Tenant B already owns a store with id 'st-shared'. Tenant A pushing the
-- same id must be REJECTED, never overwrite.
INSERT INTO public.stores
  (id, customer_id, name, created_at, updated_at)
VALUES ('st-shared', '22222222-2222-2222-2222-222222222222',
        'Beta Shared', now(), now());

SELECT pg_temp.stage(
  '11111111-1111-1111-1111-111111111111', 'store', 'st-shared',
  jsonb_build_object('store', jsonb_build_object(
    'name', 'Mall Branch', 'created_at', now(), 'updated_at', now())),
  pg_temp.igrant('owner-a'));
SELECT public.pos_sync_apply('11111111-1111-1111-1111-111111111111', 500, 'fp-inv1');

DO $$
BEGIN
  PERFORM pg_temp.expect_true('I2 cross-tenant store rejected', EXISTS (
    SELECT 1 FROM public.sync_mirror
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND entity_type = 'store' AND entity_id = 'st-shared'
      AND apply_status = 'REJECTED'
      AND apply_error LIKE '%another tenant%'));
  PERFORM pg_temp.expect_true('I2 tenant B store untouched', EXISTS (
    SELECT 1 FROM public.stores
    WHERE id = 'st-shared'
      AND customer_id = '22222222-2222-2222-2222-222222222222'
      AND name = 'Beta Shared'));
END $$;

-- ===========================================================================
-- I3  store_inventory upsert: convergence + newest-wins
-- ===========================================================================

SELECT pg_temp.stage(
  '11111111-1111-1111-1111-111111111111', 'store_inventory', 'si-1',
  jsonb_build_object('store_inventory', jsonb_build_object(
    'store_id', 'st-a1', 'product_id', 'p-a1',
    'on_hand_milliunits', 8000, 'reorder_milliunits', 2000,
    'created_at', '2026-01-01T00:00:00Z', 'updated_at', '2026-01-02T00:00:00Z')),
  pg_temp.igrant('owner-a'));
SELECT public.pos_sync_apply('11111111-1111-1111-1111-111111111111', 500, 'fp-inv1');
-- Identical re-push must converge, not duplicate.
SELECT pg_temp.stage(
  '11111111-1111-1111-1111-111111111111', 'store_inventory', 'si-1',
  jsonb_build_object('store_inventory', jsonb_build_object(
    'store_id', 'st-a1', 'product_id', 'p-a1',
    'on_hand_milliunits', 8000, 'reorder_milliunits', 2000,
    'created_at', '2026-01-01T00:00:00Z', 'updated_at', '2026-01-02T00:00:00Z')),
  pg_temp.igrant('owner-a'));
SELECT public.pos_sync_apply('11111111-1111-1111-1111-111111111111', 500, 'fp-inv1');

DO $$
BEGIN
  PERFORM pg_temp.expect_true('I3 duplicate upsert converges', (
    SELECT count(*) FROM public.store_inventory
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND id = 'si-1') = 1);
END $$;

-- Older updated_at must NOT overwrite.
SELECT pg_temp.stage(
  '11111111-1111-1111-1111-111111111111', 'store_inventory', 'si-1',
  jsonb_build_object('store_inventory', jsonb_build_object(
    'store_id', 'st-a1', 'product_id', 'p-a1',
    'on_hand_milliunits', 999999, 'reorder_milliunits', 1,
    'updated_at', '2026-01-01T12:00:00Z')),
  pg_temp.igrant('owner-a'));
SELECT public.pos_sync_apply('11111111-1111-1111-1111-111111111111', 500, 'fp-inv1');
DO $$
BEGIN
  PERFORM pg_temp.expect_true('I3 older update cannot overwrite', EXISTS (
    SELECT 1 FROM public.store_inventory
    WHERE id = 'si-1' AND customer_id = '11111111-1111-1111-1111-111111111111'
      AND on_hand_milliunits = 8000));
END $$;

-- Newer updated_at DOES overwrite.
SELECT pg_temp.stage(
  '11111111-1111-1111-1111-111111111111', 'store_inventory', 'si-1',
  jsonb_build_object('store_inventory', jsonb_build_object(
    'store_id', 'st-a1', 'product_id', 'p-a1',
    'on_hand_milliunits', 7000, 'reorder_milliunits', 1500,
    'updated_at', '2026-01-03T00:00:00Z')),
  pg_temp.igrant('owner-a'));
SELECT public.pos_sync_apply('11111111-1111-1111-1111-111111111111', 500, 'fp-inv1');
DO $$
BEGIN
  PERFORM pg_temp.expect_true('I3 newer update wins', EXISTS (
    SELECT 1 FROM public.store_inventory
    WHERE id = 'si-1' AND on_hand_milliunits = 7000
      AND reorder_milliunits = 1500));
END $$;

-- ===========================================================================
-- I4  Missing-parent deferral, then landing
-- ===========================================================================

-- store_inventory whose store does not exist yet.
SELECT pg_temp.stage(
  '11111111-1111-1111-1111-111111111111', 'store_inventory', 'si-defer',
  jsonb_build_object('store_inventory', jsonb_build_object(
    'store_id', 'st-late', 'product_id', 'p-a1',
    'on_hand_milliunits', 100, 'reorder_milliunits', 10,
    'updated_at', '2026-01-01T00:00:00Z')),
  pg_temp.igrant('owner-a'));
-- product_image whose product does not exist yet.
SELECT pg_temp.stage(
  '11111111-1111-1111-1111-111111111111', 'product_image', 'p-late',
  jsonb_build_object('product_image', jsonb_build_object(
    'product_id', 'p-late', 'image_data', 'aGVsbG8=',
    'updated_at', '2026-01-01T00:00:00Z')),
  pg_temp.igrant('owner-a'));
SELECT public.pos_sync_apply('11111111-1111-1111-1111-111111111111', 500, 'fp-inv1');

DO $$
BEGIN
  PERFORM pg_temp.expect_true('I4 store_inventory deferred', EXISTS (
    SELECT 1 FROM public.sync_mirror
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND entity_type = 'store_inventory' AND entity_id = 'si-defer'
      AND apply_status = 'PENDING'
      AND apply_error LIKE 'DEFERRED: store%'));
  PERFORM pg_temp.expect_true('I4 product_image deferred', EXISTS (
    SELECT 1 FROM public.sync_mirror
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND entity_type = 'product_image' AND entity_id = 'p-late'
      AND apply_status = 'PENDING'
      AND apply_error LIKE 'DEFERRED: product%'));
  PERFORM pg_temp.expect_true('I4 nothing written', NOT EXISTS (
    SELECT 1 FROM public.store_inventory WHERE id = 'si-defer'));
END $$;

-- Parents arrive; the next pass must land both without duplicates.
INSERT INTO public.stores
  (id, customer_id, name, created_at, updated_at)
VALUES ('st-late', '11111111-1111-1111-1111-111111111111', 'Late Store',
        now(), now());
INSERT INTO public.pos_products
  (id, customer_id, name, code, unit, selling_price_minor_units,
   bought_price_minor_units, is_active, created_at, updated_at)
VALUES ('p-late', '11111111-1111-1111-1111-111111111111', 'Late Prod', 'LP-1',
        'Pc', 500, 300, 1, now(), now());
SELECT public.pos_sync_apply('11111111-1111-1111-1111-111111111111', 500, 'fp-inv1');
SELECT public.pos_sync_apply('11111111-1111-1111-1111-111111111111', 500, 'fp-inv1');

DO $$
BEGIN
  PERFORM pg_temp.expect_true('I4 deferred inventory landed once', (
    SELECT count(*) FROM public.store_inventory
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND id = 'si-defer') = 1);
  PERFORM pg_temp.expect_true('I4 deferred image landed once', (
    SELECT count(*) FROM public.product_images
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND product_id = 'p-late') = 1);
END $$;

-- ===========================================================================
-- I5  Tombstones: propagate and never resurrect
-- ===========================================================================

-- Tombstone the store_inventory row (UPSERT carrying deleted_at).
SELECT pg_temp.stage(
  '11111111-1111-1111-1111-111111111111', 'store_inventory', 'si-1',
  jsonb_build_object('store_inventory', jsonb_build_object(
    'store_id', 'st-a1', 'product_id', 'p-a1',
    'on_hand_milliunits', 7000, 'reorder_milliunits', 1500,
    'updated_at', '2026-01-05T00:00:00Z',
    'deleted_at', '2026-01-05T00:00:00Z')),
  pg_temp.igrant('owner-a'));
SELECT public.pos_sync_apply('11111111-1111-1111-1111-111111111111', 500, 'fp-inv1');
-- A stale pending write with an OLDER updated_at and no deleted_at.
SELECT pg_temp.stage(
  '11111111-1111-1111-1111-111111111111', 'store_inventory', 'si-1',
  jsonb_build_object('store_inventory', jsonb_build_object(
    'store_id', 'st-a1', 'product_id', 'p-a1',
    'on_hand_milliunits', 1, 'reorder_milliunits', 1,
    'updated_at', '2026-01-04T00:00:00Z')),
  pg_temp.igrant('owner-a'));
SELECT public.pos_sync_apply('11111111-1111-1111-1111-111111111111', 500, 'fp-inv1');

DO $$
BEGIN
  PERFORM pg_temp.expect_true('I5 tombstone propagated', EXISTS (
    SELECT 1 FROM public.store_inventory
    WHERE id = 'si-1' AND deleted_at IS NOT NULL));
  PERFORM pg_temp.expect_true('I5 stale write did not resurrect', EXISTS (
    SELECT 1 FROM public.store_inventory
    WHERE id = 'si-1' AND deleted_at IS NOT NULL
      AND on_hand_milliunits = 7000));
END $$;

-- ===========================================================================
-- I6  Product image persistence, validation, tombstone
-- ===========================================================================

SELECT pg_temp.stage(
  '11111111-1111-1111-1111-111111111111', 'product_image', 'p-a1',
  jsonb_build_object('product_image', jsonb_build_object(
    'product_id', 'p-a1', 'image_data', 'aGVsbG8gd29ybGQ=',
    'updated_at', '2026-01-02T00:00:00Z')),
  pg_temp.igrant('owner-a'));
SELECT public.pos_sync_apply('11111111-1111-1111-1111-111111111111', 500, 'fp-inv1');

DO $$
BEGIN
  PERFORM pg_temp.expect_true('I6 image bytes persisted', EXISTS (
    SELECT 1 FROM public.product_images
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND product_id = 'p-a1' AND image_data = 'aGVsbG8gd29ybGQ='
      AND deleted_at IS NULL));
END $$;

-- Invalid base64 must be REJECTED permanently.
SELECT pg_temp.stage(
  '11111111-1111-1111-1111-111111111111', 'product_image', 'p-badimg',
  jsonb_build_object('product_image', jsonb_build_object(
    'product_id', 'p-a1', 'image_data', '!!!bad!!!',
    'updated_at', '2026-01-06T00:00:00Z')),
  pg_temp.igrant('owner-a'));
SELECT public.pos_sync_apply('11111111-1111-1111-1111-111111111111', 500, 'fp-inv1');
DO $$
BEGIN
  PERFORM pg_temp.expect_true('I6 invalid image rejected', EXISTS (
    SELECT 1 FROM public.sync_mirror
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND entity_type = 'product_image' AND entity_id = 'p-badimg'
      AND apply_status = 'REJECTED'
      AND apply_error LIKE '%valid base64%'));
END $$;

-- Tombstone the image; bytes clear, deleted_at sticks.
SELECT pg_temp.stage(
  '11111111-1111-1111-1111-111111111111', 'product_image', 'p-a1',
  jsonb_build_object('product_image', jsonb_build_object(
    'product_id', 'p-a1',
    'updated_at', '2026-01-07T00:00:00Z',
    'deleted_at', '2026-01-07T00:00:00Z')),
  pg_temp.igrant('owner-a'));
SELECT public.pos_sync_apply('11111111-1111-1111-1111-111111111111', 500, 'fp-inv1');
DO $$
BEGIN
  PERFORM pg_temp.expect_true('I6 image tombstone sticks', EXISTS (
    SELECT 1 FROM public.product_images
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND product_id = 'p-a1' AND deleted_at IS NOT NULL));
END $$;

-- ===========================================================================
-- I7  Inventory-only product creation sync + purchase price
-- ===========================================================================

-- A cashier with 'inventory' but no 'pos' can land the wizard's three sync
-- entities: product, opening stock and optional image.
SELECT pg_temp.stage(
  '11111111-1111-1111-1111-111111111111', 'product', 'p-stock-create',
  jsonb_build_object('product', jsonb_build_object(
    'id', 'p-stock-create', 'name', 'Inventory Created', 'code', '',
    'category', NULL, 'unit', 'Pc',
    'selling_price_minor_units', 9999,
    'bought_price_minor_units', 4321,
    'is_active', 1,
    'created_at', '2026-01-01T00:00:00Z',
    'updated_at', '2026-01-02T00:00:00Z')),
  pg_temp.igrant('stock-a'));
SELECT pg_temp.stage(
  '11111111-1111-1111-1111-111111111111', 'store_inventory', 'si-stock-create',
  jsonb_build_object('store_inventory', jsonb_build_object(
    'id', 'si-stock-create', 'store_id', 'st-a1', 'product_id', 'p-stock-create',
    'on_hand_milliunits', 123, 'reorder_milliunits', 4,
    'created_at', '2026-01-01T00:00:00Z',
    'updated_at', '2026-01-02T00:00:00Z')),
  pg_temp.igrant('stock-a'));
SELECT pg_temp.stage(
  '11111111-1111-1111-1111-111111111111', 'product_image', 'p-stock-create',
  jsonb_build_object('product_image', jsonb_build_object(
    'product_id', 'p-stock-create', 'image_data', 'aGVsbG8=',
    'created_at', '2026-01-01T00:00:00Z',
    'updated_at', '2026-01-02T00:00:00Z')),
  pg_temp.igrant('stock-a'));
SELECT public.pos_sync_apply('11111111-1111-1111-1111-111111111111', 500, 'fp-inv1');
DO $$
BEGIN
  PERFORM pg_temp.expect_true('I7 inventory-only product applied', EXISTS (
    SELECT 1 FROM public.pos_products
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND id = 'p-stock-create' AND name = 'Inventory Created'));
  PERFORM pg_temp.expect_true('I7 purchase price survived sync', EXISTS (
    SELECT 1 FROM public.pos_products
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND id = 'p-stock-create' AND bought_price_minor_units = 4321));
  PERFORM pg_temp.expect_true('I7 opening stock applied', EXISTS (
    SELECT 1 FROM public.store_inventory
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND id = 'si-stock-create' AND product_id = 'p-stock-create'
      AND on_hand_milliunits = 123 AND reorder_milliunits = 4));
  PERFORM pg_temp.expect_true('I7 product image applied', EXISTS (
    SELECT 1 FROM public.product_images
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND product_id = 'p-stock-create' AND image_data = 'aGVsbG8='));
END $$;

-- The same inventory-only actor cannot update an existing product: that is
-- catalogue editing and still requires 'pos'.
SELECT pg_temp.stage(
  '11111111-1111-1111-1111-111111111111', 'product', 'p-a1',
  jsonb_build_object('product', jsonb_build_object(
    'id', 'p-a1', 'name', 'Berbere Renamed', 'code', 'B-1', 'unit', 'Kg',
    'selling_price_minor_units', 13000, 'bought_price_minor_units', 8100,
    'is_active', 1,
    'created_at', '2026-01-01T00:00:00Z',
    'updated_at', '2030-01-01T00:00:00Z')),
  pg_temp.igrant('stock-a'));
SELECT public.pos_sync_apply('11111111-1111-1111-1111-111111111111', 500, 'fp-inv1');
DO $$
BEGIN
  PERFORM pg_temp.expect_true('I7 inventory-only product update rejected', EXISTS (
    SELECT 1 FROM public.sync_mirror
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND entity_type = 'product' AND entity_id = 'p-a1'
      AND apply_status = 'REJECTED'
      AND apply_error LIKE '%pos permission required%'));
  PERFORM pg_temp.expect_true('I7 existing product untouched', EXISTS (
    SELECT 1 FROM public.pos_products
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND id = 'p-a1' AND name = 'Berbere'
      AND selling_price_minor_units = 12000));
END $$;

-- An actor with neither 'pos' nor 'inventory' cannot create product master
-- data through sync either.
SELECT pg_temp.stage(
  '11111111-1111-1111-1111-111111111111', 'product', 'p-denied-none',
  jsonb_build_object('product', jsonb_build_object(
    'id', 'p-denied-none', 'name', 'Denied Product', 'unit', 'Pc',
    'selling_price_minor_units', 100, 'bought_price_minor_units', 50,
    'is_active', 1, 'updated_at', '2026-01-01T00:00:00Z')),
  pg_temp.igrant('none-a'));
SELECT public.pos_sync_apply('11111111-1111-1111-1111-111111111111', 500, 'fp-inv1');
DO $$
BEGIN
  PERFORM pg_temp.expect_true('I7 no-feature product rejected', EXISTS (
    SELECT 1 FROM public.sync_mirror
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND entity_type = 'product' AND entity_id = 'p-denied-none'
      AND apply_status = 'REJECTED'));
  PERFORM pg_temp.expect_true('I7 denied product not written', NOT EXISTS (
    SELECT 1 FROM public.pos_products
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND id = 'p-denied-none'));
END $$;

-- An older product payload without bought_price_minor_units still applies and
-- defaults the cost to zero instead of failing the cast.
SELECT pg_temp.stage(
  '11111111-1111-1111-1111-111111111111', 'product', 'p-old-payload',
  jsonb_build_object('product', jsonb_build_object(
    'id', 'p-old-payload', 'name', 'Old Payload Product', 'unit', 'Pc',
    'selling_price_minor_units', 700, 'is_active', 1,
    'updated_at', '2026-01-01T00:00:00Z')),
  pg_temp.igrant('owner-a'));
SELECT public.pos_sync_apply('11111111-1111-1111-1111-111111111111', 500, 'fp-inv1');
DO $$
BEGIN
  PERFORM pg_temp.expect_true('I7 older payload defaults bought price', EXISTS (
    SELECT 1 FROM public.pos_products
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND id = 'p-old-payload' AND bought_price_minor_units = 0));
END $$;

-- ===========================================================================
-- I8  Authorization
-- ===========================================================================

-- Cashier WITHOUT the inventory feature cannot push a store.
SELECT pg_temp.stage(
  '11111111-1111-1111-1111-111111111111', 'store', 'st-denied',
  jsonb_build_object('store', jsonb_build_object(
    'name', 'Denied Store', 'updated_at', now())),
  pg_temp.igrant('nofeat-a'));
SELECT public.pos_sync_apply('11111111-1111-1111-1111-111111111111', 500, 'fp-inv1');
DO $$
BEGIN
  PERFORM pg_temp.expect_true('I8 no-feature actor rejected', EXISTS (
    SELECT 1 FROM public.sync_mirror
    WHERE customer_id = '11111111-1111-1111-1111-111111111111'
      AND entity_type = 'store' AND entity_id = 'st-denied'
      AND apply_status = 'REJECTED'
      AND apply_error LIKE '%inventory permission required%'));
  PERFORM pg_temp.expect_true('I8 denied store not written', NOT EXISTS (
    SELECT 1 FROM public.stores WHERE id = 'st-denied'));
END $$;

-- Direct RPC surface: anon/authenticated must not execute either function.
DO $$
BEGIN
  PERFORM pg_temp.expect_true('I8 anon cannot execute create RPC', NOT
    has_function_privilege('anon',
      'public.pos_create_inventory_product(uuid,text,jsonb,text,bigint,bigint)',
      'EXECUTE'));
  PERFORM pg_temp.expect_true('I8 authenticated cannot execute create RPC', NOT
    has_function_privilege('authenticated',
      'public.pos_create_inventory_product(uuid,text,jsonb,text,bigint,bigint)',
      'EXECUTE'));
  PERFORM pg_temp.expect_true('I8 anon cannot execute sync apply', NOT
    has_function_privilege('anon',
      'public.pos_sync_apply(uuid,integer,text)', 'EXECUTE'));
END $$;

-- ===========================================================================
-- Done
-- ===========================================================================
SELECT 'inventory_foundation_test: ALL PASSED' AS result;
