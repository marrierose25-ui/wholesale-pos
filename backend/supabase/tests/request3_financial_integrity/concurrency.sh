#!/usr/bin/env bash
# Request 3 P0 — cash-leg dedup concurrency proof, run as TWO real psql
# sessions against the replayed database.
#
#   W) two DIFFERENT WITHDRAWAL movement ids for the same finance collection
#      fired simultaneously: the (customer, source, type) unique index must
#      let exactly ONE reversal land; both callers get a safe outcome.
#   D) the same race for DEPOSIT legs on a collection whose deposit has not
#      landed yet: exactly one deposit survives.
#   The collection's OTHER leg (its deposit for W, unrelated rows) is
#   asserted untouched.
#
# Usage: same PG* env as replay_migrations.sh. Exits non-zero on failure.
set -euo pipefail

PSQL="psql -v ON_ERROR_STOP=1 -q -tA"
CUST='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
SHIFT=''

$PSQL <<SQL
INSERT INTO customers (id, name)
VALUES ('$CUST', 'R3 Cash Race Shop')
ON CONFLICT (id) DO NOTHING;
DELETE FROM actor_grants WHERE customer_id='$CUST';
DELETE FROM sync_mirror WHERE customer_id='$CUST';
DELETE FROM cash_movements WHERE customer_id='$CUST';
DELETE FROM pos_finance_entries WHERE customer_id='$CUST';
DELETE FROM pos_finance_categories WHERE customer_id='$CUST';
DELETE FROM shifts WHERE customer_id='$CUST';
DELETE FROM pos_users WHERE customer_id='$CUST';
INSERT INTO pos_users (id, customer_id, username, role, pw_salt, pw_hash, active, permissions)
VALUES ('race-cash', '$CUST', 'race-cash', 'CASHIER', 's', 'h', true,
        '["pos","register","finance"]'::jsonb);
INSERT INTO pos_finance_categories (id, customer_id, name, created_at)
VALUES ('cat-race', '$CUST', 'RaceCat', now());
-- fe-rw: completed CASH collection WITH its deposit already landed.
INSERT INTO pos_finance_entries (id, customer_id, category_id, source,
  amount_minor_units, description, status, entry_date, created_at,
  created_by, completed_at, completed_by, updated_at, payment_method)
VALUES ('fe-rw', '$CUST', 'cat-race', 'Till', 7000, 'race w', 'COMPLETED',
        now(), now(), 'race-cash', now(), 'race-cash', now(), 'CASH');
-- fe-rd: PENDING cash collection — its deposit has NOT landed yet, so two
-- concurrent device deposits genuinely race for the same leg.
INSERT INTO pos_finance_entries (id, customer_id, category_id, source,
  amount_minor_units, description, status, entry_date, created_at,
  created_by, updated_at, payment_method)
VALUES ('fe-rd', '$CUST', 'cat-race', 'Till', 8000, 'race d', 'PENDING',
        now(), now(), 'race-cash', now(), 'CASH');
SQL

SHIFT=$($PSQL -c "SELECT pos_ensure_shift('$CUST','race-cash','fp-race')")
$PSQL -c "INSERT INTO cash_movements (id, customer_id, shift_id, user_id, type, amount_minor_units, reason, created_at, source_finance_entry_id)
  VALUES ('dep-fe-rw', '$CUST', '$SHIFT', 'race-cash', 'DEPOSIT', 7000, 'Collected from RaceCat', now(), 'fe-rw')"

mv() { # $1=movement_id $2=type $3=amount $4=source
  $PSQL -c "SELECT pos_add_cash_movement('$CUST','race-cash','$SHIFT','$2',$3,'race leg',NULL,'$1','$4')"
}

echo "== W: two different WITHDRAWAL ids, same collection, true parallel race =="
mv mv-rw-a WITHDRAWAL 7000 fe-rw > /tmp/r3fin_w1.out 2>/tmp/r3fin_w1.err &
P1=$!
mv mv-rw-b WITHDRAWAL 7000 fe-rw > /tmp/r3fin_w2.out 2>/tmp/r3fin_w2.err &
P2=$!
RC1=0; RC2=0
wait $P1 || RC1=$?
wait $P2 || RC2=$?
if [ $RC1 -ne 0 ] || [ $RC2 -ne 0 ]; then
  echo "FAIL W: a withdrawal call errored (rc $RC1/$RC2)" >&2
  cat /tmp/r3fin_w1.err /tmp/r3fin_w2.err >&2
  exit 1
fi
N=$($PSQL -c "SELECT count(*) FROM cash_movements WHERE customer_id='$CUST' AND source_finance_entry_id='fe-rw' AND type='WITHDRAWAL'")
if [ "$N" != "1" ]; then
  echo "FAIL W: expected exactly 1 withdrawal, got $N" >&2
  exit 1
fi
# Both callers must have been answered with the SAME surviving movement id.
ID1=$(sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' /tmp/r3fin_w1.out | head -1)
ID2=$(sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' /tmp/r3fin_w2.out | head -1)
if [ "$ID1" != "$ID2" ]; then
  echo "FAIL W: callers disagree on the surviving movement ($ID1 vs $ID2)" >&2
  exit 1
fi
# The collection's deposit leg is untouched.
D=$($PSQL -c "SELECT count(*) FROM cash_movements WHERE customer_id='$CUST' AND source_finance_entry_id='fe-rw' AND type='DEPOSIT'")
if [ "$D" != "1" ]; then
  echo "FAIL W: deposit leg disturbed, count=$D" >&2
  exit 1
fi
echo "PASS W: one reversal survived; both callers converged on $ID1; deposit intact"

echo "== D: two different DEPOSIT ids, same pending collection, true parallel race =="
mv mv-rd-a DEPOSIT 8000 fe-rd > /tmp/r3fin_d1.out 2>/tmp/r3fin_d1.err &
P1=$!
mv mv-rd-b DEPOSIT 8000 fe-rd > /tmp/r3fin_d2.out 2>/tmp/r3fin_d2.err &
P2=$!
RC1=0; RC2=0
wait $P1 || RC1=$?
wait $P2 || RC2=$?
if [ $RC1 -ne 0 ] || [ $RC2 -ne 0 ]; then
  echo "FAIL D: a deposit call errored (rc $RC1/$RC2)" >&2
  cat /tmp/r3fin_d1.err /tmp/r3fin_d2.err >&2
  exit 1
fi
N=$($PSQL -c "SELECT count(*) FROM cash_movements WHERE customer_id='$CUST' AND source_finance_entry_id='fe-rd' AND type='DEPOSIT'")
if [ "$N" != "1" ]; then
  echo "FAIL D: expected exactly 1 deposit, got $N" >&2
  exit 1
fi
ID1=$(sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' /tmp/r3fin_d1.out | head -1)
ID2=$(sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' /tmp/r3fin_d2.out | head -1)
if [ "$ID1" != "$ID2" ]; then
  echo "FAIL D: callers disagree on the surviving deposit ($ID1 vs $ID2)" >&2
  exit 1
fi
echo "PASS D: one deposit survived; both callers converged on $ID1"

echo "== Request-3 cash-leg concurrency: ALL PASSED =="
