#!/usr/bin/env bash
# Inventory integrity concurrency proof — TWO real psql sessions against the
# replayed database. Neither ordering may leave a deleted store with live
# inventory.
#
#   A) the stock writer locks the store row first (pos_create_inventory_product
#      takes FOR UPDATE on the live store). pos_delete_store must WAIT on that
#      lock, then refuse once the stock commits.
#   B) pos_delete_store locks the store row first and tombstones inside an
#      open transaction. pos_create_inventory_product must WAIT, then observe
#      deleted_at IS NOT NULL after the delete commits and refuse.
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
DELETE FROM pos_users WHERE customer_id='$CUST';
DELETE FROM device_registrations WHERE activation_code='RC-CODE-AAAA-BBBB-CCCC-0004';
DELETE FROM licenses WHERE activation_code='RC-CODE-AAAA-BBBB-CCCC-0004';
INSERT INTO licenses (activation_code, customer_id, seat_limit)
VALUES ('RC-CODE-AAAA-BBBB-CCCC-0004', '$CUST', 1);
INSERT INTO device_registrations (activation_code, device_fingerprint, device_name)
VALUES ('RC-CODE-AAAA-BBBB-CCCC-0004', 'fp-rc', 'till rc');
INSERT INTO pos_users (id, customer_id, username, role, pw_salt, pw_hash, active, permissions)
VALUES ('rc-owner', '$CUST', 'rc-owner', 'OWNER', 's', 'h', true, '[]'::jsonb);
INSERT INTO stores (id, customer_id, name, created_at, updated_at)
VALUES ('st-rc-a', '$CUST', 'Race Store A', now(), now()),
       ('st-rc-b', '$CUST', 'Race Store B', now(), now());
SQL

mkproduct() { # $1=store_id $2=pid $3=out_file
  $PSQL -c "SELECT pos_create_inventory_product('$CUST','rc-owner',
    jsonb_build_object('id','$3','name','Race Prod $3','unit','Pc',
      'selling_price_minor_units',1000,'bought_price_minor_units',500),
    '$1', 1000, 100)" > "$2" 2>&1
}

delstore() { # $1=store_id $2=out_file — inside BEGIN..COMMIT held open by caller
  $PSQL -c "SELECT pos_delete_store('$CUST','$1')" > "$2" 2>&1
}

echo "== A: stock creation locks store first; delete waits then refuses =="
# Session A: create product+stock inside a transaction, hold the store lock.
$PSQL > /tmp/rc_a_stock.out 2>/tmp/rc_a_stock.err <<'SQL' &
BEGIN;
SELECT pos_create_inventory_product(
  'cccccccc-cccc-cccc-cccc-cccccccccccc','rc-owner',
  jsonb_build_object('id','p-rc-a','name','Race Prod A','unit','Pc',
    'selling_price_minor_units',1000,'bought_price_minor_units',500),
  'st-rc-a', 1000, 100);
SELECT pg_sleep(3);
COMMIT;
SQL
P_STOCK=$!
sleep 1
# Session B: delete must block on the store lock, then see the new stock.
delstore st-rc-a /tmp/rc_a_del.out &
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
if [ "$S" != "1" ]; then
  echo "FAIL A: store was deleted anyway (deleted_at set)" >&2; exit 1
fi
I=$($PSQL -c "SELECT count(*) FROM store_inventory WHERE store_id='st-rc-a' AND deleted_at IS NULL")
if [ "$I" != "1" ]; then
  echo "FAIL A: committed stock missing, count=$I" >&2; exit 1
fi
echo "PASS A: delete waited on the store lock, then refused; store+stock intact"

echo "== B: store deletion locks first; stock creation waits then refuses =="
# Session A: delete inside an open transaction — holds the store lock.
$PSQL > /tmp/rc_b_del.out 2>/tmp/rc_b_del.err <<'SQL' &
BEGIN;
SELECT pos_delete_store('cccccccc-cccc-cccc-cccc-cccccccccccc','st-rc-b');
SELECT pg_sleep(3);
COMMIT;
SQL
P_DEL=$!
sleep 1
# Session B: product create must block on FOR UPDATE, then see the tombstone.
mkproduct st-rc-b /tmp/rc_b_stock.out p-rc-b &
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
if [ "$S" != "1" ]; then
  echo "FAIL B: store tombstone missing" >&2; exit 1
fi
I=$($PSQL -c "SELECT count(*) FROM store_inventory WHERE store_id='st-rc-b' AND deleted_at IS NULL")
if [ "$I" != "0" ]; then
  echo "FAIL B: live inventory exists on deleted store, count=$I" >&2; exit 1
fi
echo "PASS B: create waited on the store lock, then refused; no live stock on deleted store"

echo "inventory_concurrency_test: ALL PASSED"
