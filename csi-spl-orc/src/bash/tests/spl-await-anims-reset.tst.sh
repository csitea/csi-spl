#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_await_anims_reset (SPL-3836) with psql and every cloud call
#          stubbed.
#   1. a bad DRY_RUN is refused before any cloud call
#   2. DRY_RUN=1 (default): READ ONLY, the per-workspace counts, no UPDATE
#   3. DRY_RUN=0: one transaction, operator scope, the key removed from every
#      membership that has it, in every workspace (no tenant filter)
#   4. a failed psql is a FATAL, nothing reported as reset
#   5. CONTROL: a malformed row is refused, not summed
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# spl_pg_env logs its stdin (the SQL) and answers with $PG_OUT; PG_RC=1 fails it.
STUBS='do_spl_cloud_cnf() { SPL_CNF=/dev/null; }
do_gcp_pin_account() { echo "REACHED-CLOUD"; GCP_ACCOUNT=sa@example.com; }
do_gcp_require_live_account() { :; }
spl_via_proxy() { SPL_PROXY_DSN=x "$@"; }
spl_pg_env() { shift; { echo "PSQL $*"; cat; } >>"$SQL_LOG"; printf "%s\n" "$PG_OUT"; return "${PG_RC:-0}"; }'
run() { # [VAR=value]...
  : >"$T/sql.log"
  SNIPPET="$STUBS; do_spl_await_anims_reset" in_orc SQL_LOG="$T/sql.log" "$@" 2>&1
}
ROWS=$'t1|3|4|5\nt7|0|1|2\nt9|0|0|1'

# 1 --------------------------------------------------------------------------
out="$(run DRY_RUN=yes)"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'DRY_RUN must be 0 or 1' <<<"$out" && ! grep -q REACHED-CLOUD <<<"$out" \
  && pass "1. DRY_RUN=yes is refused before any cloud call" || fail "1. rc=$rc $out"

# 2 --------------------------------------------------------------------------
out="$(run PG_OUT="$ROWS")"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'INFO dev workspace t1: members=5 picked=3 keyed=4' <<<"$out" \
  && grep -q 'INFO dev workspace t7: members=2 picked=0 keyed=1' <<<"$out" \
  && grep -q 'OK DRY_RUN dev workspaces=3 members=8 picked=3 would_reset=5; nothing written' <<<"$out" \
  && pass "2. the default is a dry run that counts per workspace" || fail "2. dry: rc=$rc $out"
grep -q 'BEGIN TRANSACTION READ ONLY' "$T/sql.log" && grep -q '^ROLLBACK;' "$T/sql.log" && ! grep -q 'UPDATE' "$T/sql.log" \
  && grep -q "SET LOCAL app.rls_scope = 'operator'" "$T/sql.log" \
  && pass "2. ...read only, operator scope, no UPDATE" || fail "2. dry SQL: $(cat "$T/sql.log")"

# 3 --------------------------------------------------------------------------
out="$(run DRY_RUN=0 PG_OUT="$ROWS")"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'OK dev reset workspaces=3 members=8 picked=3 reset=5' <<<"$out" \
  && pass "3. DRY_RUN=0 resets and reports per workspace" || fail "3. run: rc=$rc $out"
[[ "$(grep -c '^BEGIN;' "$T/sql.log")" == 1 && "$(grep -c '^COMMIT;' "$T/sql.log")" == 1 ]] \
  && grep -q "SET LOCAL app.rls_scope = 'operator'" "$T/sql.log" && grep -q "SET LOCAL lock_timeout = '5s'" "$T/sql.log" \
  && grep -qx "UPDATE tenant_memberships SET settings = settings - 'await_anims' WHERE settings ? 'await_anims';" "$T/sql.log" \
  && ! grep -qi 'tenant_id *=' "$T/sql.log" \
  && pass "3. ...one transaction, operator scope, every workspace, only the await_anims key" || fail "3. SQL: $(cat "$T/sql.log")"

# 4 --------------------------------------------------------------------------
out="$(run DRY_RUN=0 PG_OUT='ERROR: lock timeout' PG_RC=1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL the reset on dev failed, nothing written' <<<"$out" && ! grep -q 'OK dev reset' <<<"$out" \
  && pass "4. a failed psql is FATAL, nothing reported as reset" || fail "4. rc=$rc $out"

# 5 --------------------------------------------------------------------------
out="$(run PG_OUT=$'t1|3|4|5\nERROR: relation does not exist')"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL unexpected row' <<<"$out" && ! grep -q 'OK DRY_RUN' <<<"$out" \
  && pass "5. CONTROL: a malformed row is refused, not summed" || fail "5. rc=$rc $out"

echo "---"; (( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
