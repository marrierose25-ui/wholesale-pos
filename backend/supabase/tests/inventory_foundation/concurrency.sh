#!/usr/bin/env bash
# Inventory integrity concurrency proof — real psql sessions against the
# replayed database. Neither ordering may leave a deleted store with live
# inventory.
#
#   A/B) API-level races: pos_create_inventory_product vs pos_delete_store.
#   C/D) THE sync race: one session applies a store_inventory upsert through
#        pos_sync_apply while the other applies a store tombstone through
#        pos_sync_apply — the exact branches that had the lock-order defect.
#        pos_sync_apply only processes rows whose mirror device_id matches
#        its fingerprint argument, so each session sees only its own staged
#        entity.
#
# Usage: same PG* env as replay_migrations.sh. Exits non-zero on failure.
set -euo pipefail

PSQL="psql -v ON_ERROR_STOP=1 -q -tA"
CUST='cccccccc-cccc-cccc-cccc-cccccccccccc'

$PSQL <<SQL
INSERT INTO customers (id, name)
VALUES ('$CUST', 'Inv Race Shop')
ON CONFLICT (id) DO NOTHING;
DELETE FROM product_images WHERE customer_id='$CUST';
DELETE FROM store_inventory WHERE customer_id='$CUST';
DELETE FROM stores WHERE customer_id='$CUST';
DELETE FROM pos_products WHERE customer_id='$CUST';
DELETE FROM sync_mirror WHERE customer_id='$CUST';
DELETE FROM pos_users WHERE customer_id='$CUST';
DELETE FROM device_registrations WHERE activation_code='RC-CODE-AAAA-BBBB-CCCC-0004';
DELETE FROM licenses WHERE activation_code='RC-CODE-AAAA-BBBB-CCCC-0004';
INSERT INTO licenses (activation_code, customer_id, seat_limit)
VALUES ('RC-CODE-AAAA-BBBB-CCCC-0004', '$CUST', 1);
INSERT INTO device_registrations (activation_code, device_fingerprint, device_name)
VALUES ('RC-CODE-AAAA-BBBB-CCCC-0004', 'fp-rc', 'till rc'),
       ('RC-CODE-AAAA-BBBB-CCCC-0004', 'fp-race-a', 'till race-a'),
       ('RC-CODE-AAAA-BBBB-CCCC-0004', 'fp-race-b', 'till race-b');
INSERT INTO pos_users (id, customer_id, username, role, pw_salt, pw_hash, active, permissions)
VALUES ('rc-owner', '$CUST', 'rc-owner', 'OWNER', 's', 'h', true, '[]'::jsonb);
INSERT INTO stores (id, customer_id, name, created_at, updated_at)
VALUES ('st-rc-a', '$CUST', 'Race Store A', now(), now()),
       ('st-rc-b', '$CUST', 'Race Store B', now(), now()),
       ('st-sync-a', '$CUST', 'Sync Race A', now(), now()),
       ('st-sync-b', '$CUST', 'Sync Race B', now(), now());
INSERT INTO pos_products
  (id, customer_id, name, code, unit, selling_price_minor_units,
   bought_price_minor_units, is_active, created_at, updated_at)
VALUES
  ('p-rc-a', '$CUST', 'Race Prod A', 'RCA', 'Pc', 1000, 500, 1, now(), now()),
  ('p-rc-b', '$CUST', 'Race Prod B', 'RCB', 'Pc', 1000, 500, 1, now(), now()),
  ('p-sync-a', '$CUST', 'Sync Prod A', 'SPA', 'Pc', 1000, 500, 1, now(), now()),
  ('p-sync-b', '$CUST', 'Sync Prod B', 'SPB', 'Pc', 1000, 500, 1, now(), now());
SQL

mkproduct() { # $1=store_id $2=out_file
  $PSQL -c "SELECT pos_create_inventory_product('$CUST','rc-owner',
    jsonb_build_object('id','p-x-$RANDOM','name','Race Prod','unit','Pc',
      'selling_price_minor_units',1000,'bought_price_minor_units',500),
    '$1', 1000, 100)" > "$2" 2>&1
}

echo "== A: stock creation locks store first; delete waits then refuses =="
$PSQL > /tmp/rc_a_stock.out 2>/tmp/rc_a_stock.err <<'SQL' &
BEGIN;
SELECT pos_create_inventory_product(
  'cccccccc-cccc-cccc-cccc-cccccccccccc','rc-owner',
  jsonb_build_object('id','p-rc-a2','name','Race Prod A2','unit','Pc',
    'selling_price_minor_units',1000,'bought_price_minor_units',500),
  'st-rc-a', 1000, 100);
SELECT pg_sleep(3);
COMMIT;
SQL
P_STOCK=$!
sleep 1
$PSQL -c "SELECT pos_delete_store('$CUST','st-rc-a')" > /tmp/rc_a_del.out 2>&1 &
P_DEL=$!
RC_STOCK=0; RC_DEL=0
wait $P_STOCK || RC_STOCK=$?
wait $P_DEL || RC_DEL=$?
if [ $RC_STOCK -ne 0 ]; then
  echo "FAIL A: stock creation errored" >&2; cat /tmp/rc_a_stock.err >&2; exit 1
fi
if [ $RC_DEL -eq 0 ]; then
  echo "FAIL A: delete succeeded despite committed stock" >&2; exit 1
fi
grep -q "still has inventory" /tmp/rc_a_del.out || {
  echo "FAIL A: delete failed for the wrong reason" >&2
  cat /tmp/rc_a_del.out >&2; exit 1; }
S=$($PSQL -c "SELECT count(*) FROM stores WHERE id='st-rc-a' AND deleted_at IS NULL")
[ "$S" = "1" ] || { echo "FAIL A: store was deleted anyway" >&2; exit 1; }
I=$($PSQL -c "SELECT count(*) FROM store_inventory WHERE store_id='st-rc-a' AND deleted_at IS NULL")
[ "$I" = "1" ] || { echo "FAIL A: committed stock missing, count=$I" >&2; exit 1; }
echo "PASS A: delete waited on the store lock, then refused; store+stock intact"

echo "== B: store deletion locks first; stock creation waits then refuses =="
$PSQL > /tmp/rc_b_del.out 2>/tmp/rc_b_del.err <<'SQL' &
BEGIN;
SELECT pos_delete_store('cccccccc-cccc-cccc-cccc-cccccccccccc','st-rc-b');
SELECT pg_sleep(3);
COMMIT;
SQL
P_DEL=$!
sleep 1
mkproduct st-rc-b /tmp/rc_b_stock.out &
P_STOCK=$!
RC_DEL=0; RC_STOCK=0
wait $P_DEL || RC_DEL=$?
wait $P_STOCK || RC_STOCK=$?
if [ $RC_DEL -ne 0 ]; then
  echo "FAIL B: delete errored" >&2; cat /tmp/rc_b_del.err >&2; exit 1
fi
if [ $RC_STOCK -eq 0 ]; then
  echo "FAIL B: stock creation succeeded on a deleted store" >&2
  cat /tmp/rc_b_stock.out >&2; exit 1
fi
grep -qi "does not exist" /tmp/rc_b_stock.out || {
  echo "FAIL B: create failed for the wrong reason" >&2
  cat /tmp/rc_b_stock.out >&2; exit 1; }
S=$($PSQL -c "SELECT count(*) FROM stores WHERE id='st-rc-b' AND deleted_at IS NOT NULL")
[ "$S" = "1" ] || { echo "FAIL B: store tombstone missing" >&2; exit 1; }
I=$($PSQL -c "SELECT count(*) FROM store_inventory WHERE store_id='st-rc-b' AND deleted_at IS NULL")
[ "$I" = "0" ] || { echo "FAIL B: live inventory on deleted store" >&2; exit 1; }
echo "PASS B: create waited on the store lock, then refused; no live stock on deleted store"

# ---------------------------------------------------------------------------
# C/D — the actual sync race: pos_sync_apply's store_inventory branch vs its
# store tombstone branch. pos_sync_apply scans ALL pending mirror rows for
# the customer (foreign-device rows are deferred, not skipped) and locks
# every fetched row FOR UPDATE until commit — so the second entity is staged
# MID-RACE, after the first session's cursor has already fetched. Each apply
# then genuinely races on the store row lock inside its own branch.
# ---------------------------------------------------------------------------

GR=$($PSQL -c "SELECT (public.pos_issue_actor_grant('$CUST','rc-owner','fp-rc',3600)->>'grant')")

stage() { # $1=entity_type $2=entity_id $3=payload_json
  $PSQL -c "INSERT INTO public.sync_mirror
    (customer_id, entity_type, entity_id, operation, device_id, payload,
     actor_grant_hash, apply_status)
  VALUES ('$CUST', '$1', '$2', 'UPSERT', 'fp-rc', '$3'::jsonb,
          public.pos_actor_grant_hash('$GR'), 'PENDING')"
}

si_payload() { # $1=store_id $2=product_id
  printf '{"store_inventory":{"store_id":"%s","product_id":"%s","on_hand_milliunits":5000,"reorder_milliunits":100,"created_at":"2027-01-01T00:00:00Z","updated_at":"2027-01-01T00:00:00Z","deleted_at":null}}' "$1" "$2"
}
tomb_payload() { # $1=store name (entity_id is the store id)
  printf '{"store":{"name":"%s","created_at":"2027-01-01T00:00:00Z","updated_at":"2027-01-02T00:00:00Z","deleted_at":"2027-01-02T00:00:00Z"}}' "$1"
}

echo "== C: sync_apply — inventory applies first, tombstone waits then defers =="
# Only the inventory row is pending when session A scans.
stage store_inventory si-race-c "$(si_payload st-sync-a p-sync-a)"
$PSQL > /tmp/rc_c_si.out 2>/tmp/rc_c_si.err <<'SQL' &
BEGIN;
SELECT public.pos_sync_apply('cccccccc-cccc-cccc-cccc-cccccccccccc', 500, 'fp-rc');
SELECT pg_sleep(3);
COMMIT;
SQL
P_SI=$!
sleep 1
# Stage the tombstone mid-race: session B's apply fetches only this row and
# must WAIT on the store lock session A holds, then see live inventory.
stage store st-sync-a "$(tomb_payload 'Sync Race A')"
$PSQL > /tmp/rc_c_st.out 2>/tmp/rc_c_st.err <<'SQL' &
BEGIN;
SELECT public.pos_sync_apply('cccccccc-cccc-cccc-cccc-cccccccccccc', 500, 'fp-rc');
COMMIT;
SQL
P_ST=$!
RC_SI=0; RC_ST=0
wait $P_SI || RC_SI=$?
wait $P_ST || RC_ST=$?
[ $RC_SI -eq 0 ] || { echo "FAIL C: inventory apply errored" >&2; cat /tmp/rc_c_si.err >&2; exit 1; }
[ $RC_ST -eq 0 ] || { echo "FAIL C: tombstone apply errored" >&2; cat /tmp/rc_c_st.err >&2; exit 1; }
S=$($PSQL -c "SELECT count(*) FROM stores WHERE id='st-sync-a' AND deleted_at IS NULL")
[ "$S" = "1" ] || { echo "FAIL C: store deleted despite live inventory" >&2; exit 1; }
I=$($PSQL -c "SELECT count(*) FROM store_inventory WHERE store_id='st-sync-a' AND deleted_at IS NULL")
[ "$I" = "1" ] || { echo "FAIL C: committed inventory missing, count=$I" >&2; exit 1; }
M=$($PSQL -c "SELECT count(*) FROM sync_mirror WHERE customer_id='$CUST' AND entity_type='store' AND entity_id='st-sync-a' AND apply_status='PENDING' AND apply_error LIKE 'DEFERRED:%'")
[ "$M" = "1" ] || { echo "FAIL C: tombstone not deferred, mirror state wrong" >&2
  $PSQL -c "SELECT apply_status, apply_error FROM sync_mirror WHERE entity_id='st-sync-a'" >&2
  exit 1; }
echo "PASS C: tombstone waited on the store lock, then deferred; store+stock intact"

echo "== D: sync_apply — tombstone applies first, inventory waits then defers =="
# Only the tombstone is pending when session A scans.
stage store st-sync-b "$(tomb_payload 'Sync Race B')"
$PSQL > /tmp/rc_d_st.out 2>/tmp/rc_d_st.err <<'SQL' &
BEGIN;
SELECT public.pos_sync_apply('cccccccc-cccc-cccc-cccc-cccccccccccc', 500, 'fp-rc');
SELECT pg_sleep(3);
COMMIT;
SQL
P_ST=$!
sleep 1
# Stage the inventory row mid-race: session B must WAIT on the store lock,
# then observe deleted_at IS NULL no longer matches and defer.
stage store_inventory si-race-d "$(si_payload st-sync-b p-sync-b)"
$PSQL > /tmp/rc_d_si.out 2>/tmp/rc_d_si.err <<'SQL' &
BEGIN;
SELECT public.pos_sync_apply('cccccccc-cccc-cccc-cccc-cccccccccccc', 500, 'fp-rc');
COMMIT;
SQL
P_SI=$!
RC_ST=0; RC_SI=0
wait $P_ST || RC_ST=$?
wait $P_SI || RC_SI=$?
[ $RC_ST -eq 0 ] || { echo "FAIL D: tombstone apply errored" >&2; cat /tmp/rc_d_st.err >&2; exit 1; }
[ $RC_SI -eq 0 ] || { echo "FAIL D: inventory apply errored" >&2; cat /tmp/rc_d_si.err >&2; exit 1; }
S=$($PSQL -c "SELECT count(*) FROM stores WHERE id='st-sync-b' AND deleted_at IS NOT NULL")
[ "$S" = "1" ] || { echo "FAIL D: store tombstone missing" >&2; exit 1; }
I=$($PSQL -c "SELECT count(*) FROM store_inventory WHERE store_id='st-sync-b' AND deleted_at IS NULL")
[ "$I" = "0" ] || { echo "FAIL D: live inventory on deleted store, count=$I" >&2; exit 1; }
M=$($PSQL -c "SELECT count(*) FROM sync_mirror WHERE customer_id='$CUST' AND entity_type='store_inventory' AND entity_id='si-race-d' AND apply_status='PENDING' AND apply_error LIKE 'DEFERRED:%'")
[ "$M" = "1" ] || { echo "FAIL D: inventory not deferred, mirror state wrong" >&2
  $PSQL -c "SELECT apply_status, apply_error FROM sync_mirror WHERE entity_id='si-race-d'" >&2
  exit 1; }
echo "PASS D: inventory waited on the store lock, then deferred; deleted store has no live stock"

echo "inventory_concurrency_test: ALL PASSED"
