#!/usr/bin/env bash
# Request 3 P0 — first-owner bootstrap concurrency proof.
#
# Two REAL psql sessions race pos_setup_owner for the same tenant:
#   A) two DIFFERENT owner ids fired simultaneously — the advisory lock must
#      serialize them so exactly ONE owner row exists and the loser errors.
#   B) two IDENTICAL (id + credentials) calls fired simultaneously — both
#      must succeed idempotently and still leave exactly one owner.
#
# Usage: same PG* env as replay_migrations.sh. Exits non-zero on failure.
set -euo pipefail

PSQL="psql -v ON_ERROR_STOP=1 -q -tA"
CUST='88888888-8888-8888-8888-888888888888'
CUST2='99999999-9999-9999-9999-999999999999'

$PSQL <<SQL
INSERT INTO customers (id, name) VALUES ('$CUST','Boot Race A'),('$CUST2','Boot Race B')
ON CONFLICT (id) DO NOTHING;
DELETE FROM pos_users WHERE customer_id IN ('$CUST','$CUST2');
SQL

echo "== A: two different owner ids, true parallel race =="
( $PSQL -c "SELECT pg_sleep(0.2); SELECT pos_setup_owner('$CUST','own-race-a','boss-a','s','h');" ) &
P1=$!
( $PSQL -c "SELECT pg_sleep(0.2); SELECT pos_setup_owner('$CUST','own-race-b','boss-b','s','h');" ) &
P2=$!
RC1=0; RC2=0
wait $P1 || RC1=$?
wait $P2 || RC2=$?
# Exactly one may succeed; the loser must see 'Owner already exists.'
if [ $RC1 -eq 0 ] && [ $RC2 -eq 0 ]; then
  echo "FAIL A: both different-id bootstraps succeeded" >&2
  exit 1
fi
if [ $RC1 -ne 0 ] && [ $RC2 -ne 0 ]; then
  echo "FAIL A: both different-id bootstraps failed" >&2
  exit 1
fi
N=$($PSQL -c "SELECT count(*) FROM pos_users WHERE customer_id='$CUST' AND role='OWNER' AND deleted_at IS NULL")
if [ "$N" != "1" ]; then
  echo "FAIL A: expected 1 owner, got $N" >&2
  exit 1
fi
echo "PASS A: exactly one owner survived the race"

echo "== B: identical id+credentials, true parallel race =="
( $PSQL -c "SELECT pg_sleep(0.2); SELECT pos_setup_owner('$CUST2','own-same','boss','s','h');" ) &
P1=$!
( $PSQL -c "SELECT pg_sleep(0.2); SELECT pos_setup_owner('$CUST2','own-same','boss','s','h');" ) &
P2=$!
RC1=0; RC2=0
wait $P1 || RC1=$?
wait $P2 || RC2=$?
if [ $RC1 -ne 0 ] || [ $RC2 -ne 0 ]; then
  echo "FAIL B: identical bootstrap retry errored (rc $RC1/$RC2)" >&2
  exit 1
fi
N=$($PSQL -c "SELECT count(*) FROM pos_users WHERE customer_id='$CUST2' AND role='OWNER' AND deleted_at IS NULL")
if [ "$N" != "1" ]; then
  echo "FAIL B: expected 1 owner, got $N" >&2
  exit 1
fi
echo "PASS B: concurrent identical retries converge to one owner"

echo "== C: same id, DIFFERENT credentials loses even when serialized =="
set +e
$PSQL -c "SELECT pos_setup_owner('$CUST2','own-same','boss','s','h-EVIL');" 2>/tmp/r3_boot.err
RC=$?
set -e
if [ $RC -eq 0 ]; then
  echo "FAIL C: mismatched same-id bootstrap succeeded" >&2
  exit 1
fi
grep -qi "Owner already exists" /tmp/r3_boot.err || {
  echo "FAIL C: unexpected error: $(cat /tmp/r3_boot.err)" >&2
  exit 1
}
H=$($PSQL -c "SELECT pw_hash FROM pos_users WHERE customer_id='$CUST2' AND id='own-same'")
if [ "$H" != "h" ]; then
  echo "FAIL C: stored credential was overwritten" >&2
  exit 1
fi
echo "PASS C: credential mismatch refused, stored hash untouched"

echo "== Request-3 bootstrap concurrency: ALL PASSED =="
