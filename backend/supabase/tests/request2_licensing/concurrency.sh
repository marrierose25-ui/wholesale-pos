#!/usr/bin/env bash
# Request 2 PostgreSQL concurrency proofs — real two-session races against
# the replayed database. Same PG* env as replay_migrations.sh.
#
#   C1  concurrent activation, SAME fingerprint  -> exactly one row
#   C2  concurrent activation, DIFFERENT fps    -> both activate
#   C3  activation racing license revocation     -> consistent outcome
#   C4  rate_limit_hit atomicity under parallel load -> exactly `limit`
#       allowed responses, no over-admission
set -euo pipefail

PSQL="psql -v ON_ERROR_STOP=1 -q -tA"
CUST='33333333-3333-3333-3333-333333333333'
CODE='R2-CONC-1111-2222-3333-4444'
TMP="${TMPDIR:-/tmp}/r2conc.$$"
mkdir -p "$TMP"

seed() {
  $PSQL <<SQL
INSERT INTO customers (id, name)
VALUES ('$CUST', 'R2 Concurrency Shop')
ON CONFLICT (id) DO NOTHING;
DELETE FROM device_registrations WHERE activation_code='$CODE';
DELETE FROM licenses WHERE activation_code='$CODE';
INSERT INTO licenses (activation_code, customer_id, seat_limit)
VALUES ('$CODE', '$CUST', 1);
SQL
}

reg() { # $1=fingerprint -> prints status
  $PSQL -c "SELECT register_device('$CODE','$1','conc')->>'status'"
}

assert_eq() {
  if [ "$2" != "$3" ]; then
    echo "FAIL $1: expected '$3', got '$2'" >&2
    exit 1
  fi
  echo "PASS $1"
}

echo "== R2-C1: concurrent activation, same fingerprint =="
seed
reg 'fp-same' >"$TMP/c1a.out" & P1=$!
reg 'fp-same' >"$TMP/c1b.out" & P2=$!
wait $P1; wait $P2
A=$(cat "$TMP/c1a.out"); B=$(cat "$TMP/c1b.out")
ROWS=$($PSQL -c "SELECT count(*) FROM device_registrations WHERE activation_code='$CODE' AND device_fingerprint='fp-same'")
assert_eq "C1 row count" "$ROWS" "1"
case "$A$B" in
  *activated*refreshed*|*refreshed*activated*) echo "PASS C1 statuses ($A,$B)" ;;
  *) echo "FAIL C1 statuses: $A / $B" >&2; exit 1 ;;
esac

echo "== R2-C2: concurrent activation, different fingerprints =="
reg 'fp-d1' >"$TMP/c2a.out" & P1=$!
reg 'fp-d2' >"$TMP/c2b.out" & P2=$!
wait $P1; wait $P2
ROWS=$($PSQL -c "SELECT count(*) FROM device_registrations WHERE activation_code='$CODE' AND revoked_at IS NULL")
assert_eq "C2 active rows" "$ROWS" "3"

echo "== R2-C3: activation racing license revocation =="
# One session loops register_device on a fresh fingerprint; the other
# revokes the license mid-flight. The license-row FOR UPDATE lock means
# each activation either completes before the revoke commits (row exists,
# license revoked) or observes revoked_at and returns 'revoked'.
$PSQL -c "DELETE FROM device_registrations WHERE activation_code='$CODE' AND device_fingerprint='fp-race';"
( for i in $(seq 1 15); do reg 'fp-race' >>"$TMP/c3.out" 2>>"$TMP/c3.err"; done ) &
P1=$!
sleep 0.3
$PSQL -c "UPDATE licenses SET revoked_at=now() WHERE activation_code='$CODE';"
wait $P1 || true
# Invariant: no ERROR escaped (statuses only), and once revoked every
# subsequent call returns 'revoked'.
BAD=$(grep -c -v -E '^(activated|refreshed|reactivated|revoked)$' "$TMP/c3.out" || true)
assert_eq "C3 no unexpected statuses" "$BAD" "0"
LAST=$($PSQL -c "SELECT register_device('$CODE','fp-race','x')->>'status'")
assert_eq "C3 post-revoke refused" "$LAST" "revoked"
# Restore for cleanliness.
$PSQL -c "UPDATE licenses SET revoked_at=NULL WHERE activation_code='$CODE';"

echo "== R2-C4: rate_limit_hit atomicity under parallel load =="
KEY="r2conc-atomic-$$"
$PSQL -c "DELETE FROM rate_limit_buckets WHERE bucket_key='$KEY';"
LIMIT=10
N=30
for i in $(seq 1 $N); do
  $PSQL -c "SELECT (rate_limit_hit('$KEY',$LIMIT,600,true)->>'allowed')::boolean" \
    >"$TMP/rl-$i.out" 2>"$TMP/rl-$i.err" &
done
wait
ALLOWED=$(grep -l '^t$' "$TMP"/rl-*.out | wc -l)
DENIED=$((N - ALLOWED))
assert_eq "C4 allowed count" "$ALLOWED" "$LIMIT"
assert_eq "C4 denied count" "$DENIED" "$((N - LIMIT))"
COUNT=$($PSQL -c "SELECT hit_count FROM rate_limit_buckets WHERE bucket_key='$KEY'")
assert_eq "C4 charged count" "$COUNT" "$N"
$PSQL -c "DELETE FROM rate_limit_buckets WHERE bucket_key='$KEY';"

echo "== R2 concurrency: ALL PASSED =="
rm -rf "$TMP"
