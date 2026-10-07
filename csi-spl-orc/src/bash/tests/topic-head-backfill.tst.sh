#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_topic_head_backfill (spec 099 T006) with psql and every cloud
#          call stubbed. The real-Postgres run is topic-head-pg.tst.sh.
#   1. the guards: a bad DRY_RUN / REBUILD / TOPIC_HEAD_CHUNK is refused
#      before any cloud call
#   2. DRY_RUN=1 (default) reads in a READ ONLY transaction and never calls
#      topic_head_backfill
#   3. the chunk loop: one psql per chunk, the cursor fed forward, and it
#      STOPS on the empty chunk; chunks and topics are summed
#   4. each chunk is its own transaction, operator scope, lock_timeout 5s
#   5. a failed chunk is retried from the SAME cursor; 3 failures stop it
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# spl_pg_env answers the n-th psql call with line n of $PG_SEQ; a line
# starting FAIL exits 1 (a lock timeout).
STUBS='do_spl_cloud_cnf() { SPL_CNF=/dev/null; }
do_gcp_pin_account() { echo "REACHED-CLOUD"; GCP_ACCOUNT=sa@example.com; }
do_gcp_require_live_account() { :; }
spl_via_proxy() { echo "PROXY $1" >>"$STUB_LOG"; SPL_PROXY_DSN=x "$@"; }
spl_pg_env() { shift; local n line; n=$(( $(cat "$PG_N" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$PG_N"
  { echo "PSQL#$n $*"; cat; } >>"$SQL_LOG"; line="$(sed -n "${n}p" "$PG_SEQ")"
  [[ "$line" == FAIL* ]] && { echo "$line"; return 1; }; printf "%s\n" "$line"; }'
run() { # [VAR=value]...
  rm -f "$T/n"; : >"$T/sql.log"; : >"$T/calls.log"
  SNIPPET="$STUBS; do_spl_topic_head_backfill" in_orc SQL_LOG="$T/sql.log" PG_N="$T/n" PG_SEQ="$T/seq" \
    SPL_TH_RETRY_SLEEP=0 "$@" 2>&1
}
calls() { cat "$T/n" 2>/dev/null || echo 0; }
A=aaaaaaaa-0000-4000-8000-000000000001; B=bbbbbbbb-0000-4000-8000-000000000002

# 1 --------------------------------------------------------------------------
for g in "DRY_RUN=yes|DRY_RUN must be 0 or 1" "REBUILD=some|REBUILD must be 'all'" \
         "TOPIC_HEAD_CHUNK=0|TOPIC_HEAD_CHUNK must be 1..1000" "TOPIC_HEAD_CHUNK=1001|TOPIC_HEAD_CHUNK must be 1..1000"; do
  out="$(run "${g%%|*}")"; rc=$?
  [[ $rc -ne 0 ]] && grep -q "${g#*|}" <<<"$out" && ! grep -q REACHED-CLOUD <<<"$out" \
    && pass "1. ${g%%|*} is refused before any cloud call" || fail "1. ${g%%|*}: rc=$rc $out"
done

# 2 --------------------------------------------------------------------------
printf 'topics=7 heads=3 tenants=2 marked=0\n' >"$T/seq"
out="$(run)"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'DRY_RUN dev would pass topics=7 heads=3 tenants=2 marked=0 rebuild_all=false' <<<"$out" \
  && pass "2. the default is a dry run that counts" || fail "2. dry: rc=$rc $out"
grep -q 'BEGIN TRANSACTION READ ONLY' "$T/sql.log" && ! grep -q 'topic_head_backfill(' "$T/sql.log" \
  && pass "2. ...read only, topic_head_backfill never called" || fail "2. dry SQL: $(cat "$T/sql.log")"

# 3 --------------------------------------------------------------------------
printf '100 t1/%s\n42 t2/%s\n0 \n999 never/read\n' "$A" "$B" >"$T/seq"
out="$(run DRY_RUN=0 REBUILD=all)"; rc=$?
[[ $rc -eq 0 && "$(calls)" == 3 ]] && grep -q 'backfill done: chunks=3 topics=142 rebuild_all=true' <<<"$out" \
  && pass "3. the loop stops on the empty chunk (3 calls, 142 topics)" || fail "3. loop: rc=$rc calls=$(calls) $out"
grep -q "PSQL#1 .*-v after= " "$T/sql.log" && grep -q "PSQL#2 .*-v after=t1/$A " "$T/sql.log" \
  && grep -q "PSQL#3 .*-v after=t2/$B " "$T/sql.log" && pass "3. ...each call starts at the cursor the one before returned" \
  || fail "3. cursors: $(grep PSQL "$T/sql.log")"
grep -q -- '-v chunk=100 -v all=true' "$T/sql.log" && pass "3. chunk 100 and REBUILD=all reach the SQL" || fail "3. args: $(grep PSQL "$T/sql.log")"
printf '0 \n' >"$T/seq"
out="$(run DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(calls)" == 1 ]] && grep -q 'chunks=1 topics=0 rebuild_all=false' <<<"$out" \
  && pass "3. CONTROL: an empty first chunk is one call" || fail "3. empty: rc=$rc calls=$(calls) $out"

# 4 --------------------------------------------------------------------------
[[ "$(grep -c '^BEGIN;' "$T/sql.log")" == 1 && "$(grep -c '^COMMIT;' "$T/sql.log")" == 1 ]] \
  && grep -q "SET LOCAL app.rls_scope = 'operator'" "$T/sql.log" && grep -q "SET LOCAL lock_timeout = '5s'" "$T/sql.log" \
  && grep -q "topic_head_backfill(:chunk, :'all'::boolean, :'after')" "$T/sql.log" \
  && pass "4. one transaction per chunk: operator scope, lock_timeout 5s" || fail "4. tx: $(cat "$T/sql.log")"

# 5 --------------------------------------------------------------------------
printf 'FAIL lock timeout\n100 t1/%s\n0 \n' "$A" >"$T/seq"
out="$(run DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(calls)" == 3 ]] && grep -q 'WARN chunk 1 .* (try 1), retrying' <<<"$out" \
  && [[ "$(grep -c 'PSQL#[12] .*-v after= ' "$T/sql.log")" == 2 ]] \
  && pass "5. a failed chunk is retried from the same cursor" || fail "5. retry: rc=$rc $out $(grep PSQL "$T/sql.log")"
printf 'FAIL a\nFAIL b\nFAIL c\n0 \n' >"$T/seq"
out="$(run DRY_RUN=0)"; rc=$?
[[ $rc -ne 0 && "$(calls)" == 3 ]] && grep -q 'FATAL chunk 1 .* failed 3 times' <<<"$out" \
  && pass "5. three failures stop the loop" || fail "5. give up: rc=$rc calls=$(calls) $out"

echo "---"; (( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
