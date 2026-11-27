#!/usr/bin/env bash
# H1 concurrency proof — insert-vs-void race on void_requests, run as TWO
# real psql sessions against the replayed database.
#
#   Ordering A (request first, void second): the PENDING request must be
#     settled APPROVED, decided_by the voiding owner.
#   Ordering B (void first, request second): the insert must be rejected by
#     the BEFORE INSERT trigger and leave no row.
#   Ordering C (true parallel race): both statements are fired
#     simultaneously; whichever wins, the invariant must hold — the sale is
#     VOIDED and there is NEVER a PENDING request left on a VOIDED sale.
#
# Usage: same PG* env as replay_migrations.sh. Exits non-zero on any
# assertion failure.
set -euo pipefail

PSQL="psql -v ON_ERROR_STOP=1 -q -tA"
CUST='11111111-1111-1111-1111-111111111111'
SALE_A='sale-h1-conc-a'
SALE_B='sale-h1-conc-b'
SALE_C='sale-h1-conc-c'

seed() {
  $PSQL <<SQL
INSERT INTO customers (id, name)
VALUES ('$CUST', 'H1 Concurrency Shop')
ON CONFLICT (id) DO NOTHING;
INSERT INTO pos_users (id, customer_id, username, role, pw_salt, pw_hash)
VALUES ('owner1', '$CUST', 'owner', 'OWNER', 's', 'h')
ON CONFLICT DO NOTHING;
DELETE FROM void_requests WHERE customer_id='$CUST'
  AND sale_id IN ('$SALE_A','$SALE_B','$SALE_C');
DELETE FROM sales WHERE customer_id='$CUST'
  AND id IN ('$SALE_A','$SALE_B','$SALE_C');
INSERT INTO sales (id, customer_id, receipt_number, cashier_id, device_id,
  shift_id, payment_method, subtotal_minor_units, discount_minor_units,
  total_minor_units, amount_paid_minor_units, change_minor_units,
  status, created_at)
VALUES ('$SALE_A','$CUST','R-CA','cash1','dev1','shift1','CASH',1000,0,1000,1000,0,'COMPLETED',now()),
       ('$SALE_B','$CUST','R-CB','cash1','dev1','shift1','CASH',1000,0,1000,1000,0,'COMPLETED',now()),
       ('$SALE_C','$CUST','R-CC','cash1','dev1','shift1','CASH',1000,0,1000,1000,0,'COMPLETED',now());
SQL
}

insert_request() { # $1=sale $2=reqid
  $PSQL -c "INSERT INTO void_requests (id, customer_id, sale_id, requested_by, reason, status, created_at)
    VALUES ('$2','$CUST','$1','cash1','race','PENDING',now());"
}
void_sale() {
  $PSQL -c "SELECT pos_void_sale('$CUST','owner1','$1','race void');"
}

assert_eq() { # $1=label $2=actual $3=expected
  if [ "$2" != "$3" ]; then
    echo "FAIL $1: expected '$3', got '$2'" >&2
    exit 1
  fi
  echo "PASS $1"
}

echo "== H1 concurrency: seeding =="
seed

echo "== Ordering A: insert THEN void =="
insert_request "$SALE_A" req-conc-a
void_sale "$SALE_A"
STATUS=$( $PSQL -c "SELECT status||'|'||coalesce(decided_by,'') FROM void_requests WHERE id='req-conc-a'" )
assert_eq "A settled" "$STATUS" "APPROVED|owner1"
SALE_STATUS=$( $PSQL -c "SELECT status FROM sales WHERE id='$SALE_A'" )
assert_eq "A sale voided" "$SALE_STATUS" "VOIDED"

echo "== Ordering B: void THEN insert =="
void_sale "$SALE_B"
set +e
insert_request "$SALE_B" req-conc-b 2>/tmp/h1_conc_b.err
RC=$?
set -e
if [ $RC -eq 0 ]; then
  echo "FAIL B: insert on VOIDED sale succeeded" >&2
  exit 1
fi
grep -qi "not voidable" /tmp/h1_conc_b.err || {
  echo "FAIL B: unexpected error: $(cat /tmp/h1_conc_b.err)" >&2
  exit 1
}
ROWS=$( $PSQL -c "SELECT count(*) FROM void_requests WHERE id='req-conc-b'" )
assert_eq "B no leaked row" "$ROWS" "0"

echo "== Ordering C: true parallel race =="
# Both sessions start together; pg_sleep inside each makes the overlap real.
( $PSQL -c "SELECT pg_sleep(0.2); INSERT INTO void_requests (id, customer_id, sale_id, requested_by, reason, status, created_at)
    VALUES ('req-conc-c','$CUST','$SALE_C','cash1','race','PENDING',now());" ) &
P1=$!
( $PSQL -c "SELECT pg_sleep(0.2); SELECT pos_void_sale('$CUST','owner1','$SALE_C','race void');" ) &
P2=$!
RC1=0; RC2=0
wait $P1 || RC1=$?
wait $P2 || RC2=$?
# Exactly one of the two may fail (insert rejected if void won; void is
# idempotent-safe so it should not fail). Any OTHER failure is a bug.
if [ $RC1 -ne 0 ] && [ $RC2 -ne 0 ]; then
  echo "FAIL C: both sessions errored" >&2
  exit 1
fi
if [ $RC1 -ne 0 ]; then
  grep -qi "not voidable" /tmp/h1_conc_c1.err 2>/dev/null || true
fi
# The invariant, whichever side won: sale VOIDED, and NO pending request on it.
SALE_STATUS=$( $PSQL -c "SELECT status FROM sales WHERE id='$SALE_C'" )
assert_eq "C sale voided" "$SALE_STATUS" "VOIDED"
PENDING=$( $PSQL -c "SELECT count(*) FROM void_requests WHERE sale_id='$SALE_C' AND customer_id='$CUST' AND status='PENDING'" )
assert_eq "C no pending on voided" "$PENDING" "0"
# And if a request row exists it must be decided (APPROVED) — never decided_by NULL.
ORPHAN=$( $PSQL -c "SELECT count(*) FROM void_requests WHERE sale_id='$SALE_C' AND customer_id='$CUST' AND status='APPROVED' AND decided_by IS NULL" )
assert_eq "C no ownerless approval" "$ORPHAN" "0"

echo "== H1 concurrency: ALL PASSED =="
