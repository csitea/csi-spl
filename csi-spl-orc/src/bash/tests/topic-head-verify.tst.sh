#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_topic_head_verify (spec 099 T006) with psql and every cloud
#          call stubbed. The real-Postgres run is topic-head-pg.tst.sh.
#   1. 0 mismatches: exit 0, the summary line logged OK
#   2. ONE mismatch: exit 1, the mismatch line printed
#   3. the read is READ ONLY, operator scope, topic_head_diff per tenant
#   4. an output without the summary line, or a failed psql, is exit 1
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

STUBS='do_spl_cloud_cnf() { SPL_CNF=/dev/null; }
do_gcp_pin_account() { GCP_ACCOUNT=sa@example.com; }
do_gcp_require_live_account() { :; }
spl_via_proxy() { echo "PROXY $1" >>"$STUB_LOG"; SPL_PROXY_DSN=x "$@"; }
spl_pg_env() { shift; { echo "PSQL $*"; cat; } >>"$SQL_LOG"; printf "%b" "$PG_OUT"; return "${PG_RC:-0}"; }'
run() { # [VAR=value]...
  : >"$T/sql.log"
  SNIPPET="$STUBS; do_spl_topic_head_verify" in_orc SQL_LOG="$T/sql.log" "$@" 2>&1
}

# 1 --------------------------------------------------------------------------
out="$(run PG_OUT='topics=1621 tenants=3 marked=3 mismatches=0\n')"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'OK dev topic heads: topics=1621 tenants=3 marked=3 mismatches=0' <<<"$out" \
  && pass "1. 0 mismatches exits 0" || fail "1. rc=$rc $out"

# 2 --------------------------------------------------------------------------
out="$(run PG_OUT='topics=1621 tenants=3 marked=3 mismatches=1\nt1 aaaaaaaa-0000-4000-8000-000000000001 head\n')"; rc=$?
[[ $rc -eq 1 ]] && grep -q 'FAIL dev topic heads: .*mismatches=1' <<<"$out" \
  && grep -q '^t1 aaaaaaaa-0000-4000-8000-000000000001 head$' <<<"$out" \
  && pass "2. ONE mismatch exits 1 and names the topic" || fail "2. rc=$rc $out"

# 3 --------------------------------------------------------------------------
grep -q 'BEGIN TRANSACTION READ ONLY' "$T/sql.log" && grep -q "SET LOCAL app.rls_scope = 'operator'" "$T/sql.log" \
  && grep -q 'LATERAL topic_head_diff(t.tenant_id)' "$T/sql.log" && grep -q '^ROLLBACK;' "$T/sql.log" \
  && ! grep -qE '^(COMMIT|INSERT|UPDATE|DELETE)' "$T/sql.log" \
  && pass "3. read only, operator scope, the diff of every tenant" || fail "3. SQL: $(cat "$T/sql.log")"
out="$(run PG_OUT='topics=1 tenants=1 marked=1 mismatches=0\n' TOPIC_HEAD_SHOW=5)"
grep -q -- '-v show=5' "$T/sql.log" && pass "3. TOPIC_HEAD_SHOW caps the list" || fail "3. show: $(grep PSQL "$T/sql.log")"
out="$(run TOPIC_HEAD_SHOW=x)"; [[ $? -ne 0 ]] && grep -q 'TOPIC_HEAD_SHOW must be' <<<"$out" \
  && pass "3. a bad TOPIC_HEAD_SHOW is refused" || fail "3. show guard: $out"

# 4 --------------------------------------------------------------------------
out="$(run PG_OUT='nothing useful\n')"; rc=$?
[[ $rc -eq 1 ]] && grep -q 'FATAL unexpected verify output' <<<"$out" && pass "4. no summary line is exit 1" || fail "4. rc=$rc $out"
out="$(run PG_OUT='ERROR: function topic_head_diff(text) does not exist\n' PG_RC=3)"; rc=$?
[[ $rc -eq 1 ]] && grep -q 'FATAL the verify read on dev failed' <<<"$out" && pass "4. a failed psql is exit 1" || fail "4. rc=$rc $out"

echo "---"; (( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
