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

echo "== C: two deletes competing for ONE shared legacy reversal =="
# fe-c1 and fe-c2 generate the IDENTICAL reversal reason (same category,
# source, amount, actor) — leg-c1 fits both, so bidirectional uniqueness
# must refuse BOTH deletes instead of letting arrival order pick a winner.
$PSQL <<SQL
INSERT INTO pos_finance_categories (id, customer_id, name, created_at)
VALUES ('cat-race-c', '$CUST', 'SharedCat', now())
ON CONFLICT (customer_id, id) DO NOTHING;
INSERT INTO pos_finance_entries (id, customer_id, category_id, source,
  amount_minor_units, description, status, entry_date, created_at,
  created_by, completed_at, completed_by, updated_at, payment_method)
VALUES ('fe-c1', '$CUST', 'cat-race-c', 'Route', 9000, 'race c1', 'COMPLETED',
        now(), now(), 'race-cash', now(), 'race-cash', now(), 'CASH'),
       ('fe-c2', '$CUST', 'cat-race-c', 'Route', 9000, 'race c2', 'COMPLETED',
        now(), now(), 'race-cash', now(), 'race-cash', now(), 'CASH');
INSERT INTO cash_movements (id, customer_id, shift_id, user_id, type,
  amount_minor_units, reason, created_at, source_finance_entry_id)
VALUES ('dep-fe-c1', '$CUST', '$SHIFT', 'race-cash', 'DEPOSIT', 9000,
        'Collected from SharedCat', now(), 'fe-c1'),
       ('dep-fe-c2', '$CUST', '$SHIFT', 'race-cash', 'DEPOSIT', 9000,
        'Collected from SharedCat', now(), 'fe-c2'),
       ('leg-c1', '$CUST', '$SHIFT', 'race-cash', 'WITHDRAWAL', 9000,
        'Reversal: deleted cash collection from SharedCat (Route)', now(), NULL);
SQL
( $PSQL -c "SELECT pos_delete_finance_entry('$CUST','race-cash','fe-c1')" ) \
  > /tmp/r3fin_c1.out 2>/tmp/r3fin_c1.err &
P1=$!
( $PSQL -c "SELECT pos_delete_finance_entry('$CUST','race-cash','fe-c2')" ) \
  > /tmp/r3fin_c2.out 2>/tmp/r3fin_c2.err &
P2=$!
RC1=0; RC2=0
wait $P1 || RC1=$?
wait $P2 || RC2=$?
if [ $RC1 -eq 0 ] || [ $RC2 -eq 0 ]; then
  echo "FAIL C: a shared-reversal delete succeeded — order picked a winner" >&2
  cat /tmp/r3fin_c1.out /tmp/r3fin_c2.out >&2
  exit 1
fi
grep -q "LEGACY_REVERSAL_AMBIGUOUS" /tmp/r3fin_c1.err || {
  echo "FAIL C: fe-c1 failed for the wrong reason: $(cat /tmp/r3fin_c1.err)" >&2; exit 1; }
grep -q "LEGACY_REVERSAL_AMBIGUOUS" /tmp/r3fin_c2.err || {
  echo "FAIL C: fe-c2 failed for the wrong reason: $(cat /tmp/r3fin_c2.err)" >&2; exit 1; }
N=$($PSQL -c "SELECT count(*) FROM pos_finance_entries WHERE customer_id='$CUST' AND id IN ('fe-c1','fe-c2') AND status='DELETED'")
if [ "$N" != "0" ]; then
  echo "FAIL C: $N shared-reversal entries were deleted" >&2
  exit 1
fi
L=$($PSQL -c "SELECT count(*) FROM cash_movements WHERE customer_id='$CUST' AND id='leg-c1' AND source_finance_entry_id IS NULL")
W=$($PSQL -c "SELECT count(*) FROM cash_movements WHERE customer_id='$CUST' AND source_finance_entry_id IN ('fe-c1','fe-c2') AND type='WITHDRAWAL'")
if [ "$L" != "1" ] || [ "$W" != "0" ]; then
  echo "FAIL C: movement state corrupted (unlinked=$L withdrawals=$W)" >&2
  exit 1
fi
echo "PASS C: both deletes refused; movement preserved unlinked; no reversal written"

echo "== D: movement claimed by another transaction before the link UPDATE =="
# fe-d1 has exactly one matching legacy reversal leg-d1. Transaction A
# claims leg-d1 for 'fe-other' and holds the row lock; delete(fe-d1) must
# lose the UPDATE race, re-read the real association, recompute, and write
# its OWN server reversal — never adopt a movement that belongs elsewhere.
$PSQL <<SQL
INSERT INTO pos_finance_categories (id, customer_id, name, created_at)
VALUES ('cat-race-d', '$CUST', 'SoloCat', now())
ON CONFLICT (customer_id, id) DO NOTHING;
INSERT INTO pos_finance_entries (id, customer_id, category_id, source,
  amount_minor_units, description, status, entry_date, created_at,
  created_by, completed_at, completed_by, updated_at, payment_method)
VALUES ('fe-d1', '$CUST', 'cat-race-d', 'Alone', 9500, 'race d1', 'COMPLETED',
        now(), now(), 'race-cash', now(), 'race-cash', now(), 'CASH');
INSERT INTO cash_movements (id, customer_id, shift_id, user_id, type,
  amount_minor_units, reason, created_at, source_finance_entry_id)
VALUES ('dep-fe-d1', '$CUST', '$SHIFT', 'race-cash', 'DEPOSIT', 9500,
        'Collected from SoloCat', now(), 'fe-d1'),
       ('leg-d1', '$CUST', '$SHIFT', 'race-cash', 'WITHDRAWAL', 9500,
        'Reversal: deleted cash collection from SoloCat (Alone)', now(), NULL);
SQL
# Session A: claim leg-d1 inside an open transaction, hold ~4s.
( printf 'BEGIN;\nUPDATE cash_movements SET source_finance_entry_id='"'"'fe-other'"'"' WHERE customer_id='"'"'%s'"'"' AND id='"'"'leg-d1'"'"';\nSELECT pg_sleep(4);\nCOMMIT;\n' "$CUST" \
  | $PSQL > /tmp/r3fin_dA.out 2>/tmp/r3fin_dA.err ) &
PA=$!
sleep 1
# Session B: delete fe-d1 while A holds the movement lock.
( $PSQL -c "SELECT pos_delete_finance_entry('$CUST','race-cash','fe-d1')" ) \
  > /tmp/r3fin_dB.out 2>/tmp/r3fin_dB.err &
PB=$!
RCB=0
wait $PB || RCB=$?
wait $PA || true
if [ $RCB -ne 0 ]; then
  echo "FAIL D: delete errored instead of recovering: $(cat /tmp/r3fin_dB.err)" >&2
  exit 1
fi
ST=$($PSQL -c "SELECT status FROM pos_finance_entries WHERE customer_id='$CUST' AND id='fe-d1'")
SRC=$($PSQL -c "SELECT source_finance_entry_id FROM cash_movements WHERE customer_id='$CUST' AND id='leg-d1'")
OWN=$($PSQL -c "SELECT count(*) FROM cash_movements WHERE customer_id='$CUST' AND source_finance_entry_id='fe-d1' AND type='WITHDRAWAL' AND id <> 'leg-d1'")
if [ "$ST" != "DELETED" ] || [ "$SRC" != "fe-other" ] || [ "$OWN" != "1" ]; then
  echo "FAIL D: status=$ST leg-d1.source=$SRC own-reversals=$OWN" >&2
  exit 1
fi
echo "PASS D: lost claim race recovered — fe-d1 deleted with its own reversal, leg-d1 stayed with fe-other"

echo "== Request-3 financial-integrity concurrency: ALL PASSED =="
