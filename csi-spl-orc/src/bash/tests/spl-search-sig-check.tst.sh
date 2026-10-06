#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_search_sig_check (spec 100 T010, the rdb 0135 invariant of
#          section 5.2) decides from psql's count, offline (stubbed psql, no
#          cloud call):
#   1. psql prints 0 -> exit 0 and "mismatched=0"; prints 1 -> exit 1, FAIL
#   2. a psql error or a non-count output is exit 1 (FATAL), never a pass
#   3. the SQL is the spec 5.2 query, bounded by statement_timeout, inside the
#      read-only transaction of spl_psql_ro, which ends in ROLLBACK
#   4. the proxy is stopped on every path
#   5. with no account to pin it stops before psql. CONTROL: the stub log
#      records a call when one is made
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# psql stub: logs the call and its stdin, prints $PSQL_OUT, exits $PSQL_RC.
mkdir -p "$T/stub"
printf '#!/bin/sh\necho "psql $*" >>"$STUB_LOG"\ncat >"$STUB_LOG.sql"\nprintf "%%s\\n" "$PSQL_OUT"\nexit "${PSQL_RC:-0}"\n' >"$T/stub/psql"
chmod +x "$T/stub/psql"

# The cloud half is stubbed: the identity is pinned, $dsn is a local login,
# and the proxy stop leaves a mark. do_spl_cloud_cnf re-sources the live
# account check, so the stub of it is set again after the real cnf load.
CLOUD='eval "$(declare -f do_spl_cloud_cnf | sed 1s/do_spl_cloud_cnf/_real_cloud_cnf/)"
do_spl_cloud_cnf() { _real_cloud_cnf || return 1; do_gcp_require_live_account() { return 0; }; }
do_gcp_pin_account() { GCP_ACCOUNT=sa@example.iam.gserviceaccount.com; }
spl_db_runtime_local() { dsn=postgres://u:p@127.0.0.1:5999/db; }
spl_sql_proxy_stop() { echo proxy-stop >>"$STUB_LOG"; }'

run() { # <psql out> <psql rc> -> prints "rc=<n> <output>"
  local out rc
  : >"$T/calls.log"
  out=$(SNIPPET="$CLOUD"$'\n'do_spl_search_sig_check in_orc PSQL_OUT="$1" PSQL_RC="$2" 2>&1); rc=$?
  echo "rc=$rc $out"
}

# --- 1. the verdict -------------------------------------------------------------------
o=$(run 0 0)
[[ "$o" == "rc=0 "*"mismatched=0"*"OK "* ]] && pass "count 0: exit 0, mismatched=0, OK" || fail "count 0: $o"
grep -q "^proxy-stop" "$T/calls.log" && pass "count 0: proxy stopped" || fail "count 0: proxy not stopped"
o=$(run 1 0)
[[ "$o" == "rc=1 "*"mismatched=1"*"FAIL 1 message(s)"* ]] && pass "count 1: exit 1, mismatched=1, FAIL" || fail "count 1: $o"
o=$(run 37 0)
[[ "$o" == "rc=1 "*"mismatched=37"* ]] && pass "count 37: exit 1" || fail "count 37: $o"
# --- 2. errors are never a pass -----------------------------------------------------------
o=$(run 'ERROR:  function spool_search_sig(tsvector) does not exist' 3)
[[ "$o" == "rc=1 "*"FATAL"* && "$o" != *mismatched* ]] && pass "psql error: exit 1, FATAL" || fail "psql error: $o"
grep -q "^proxy-stop" "$T/calls.log" && pass "psql error: proxy stopped" || fail "psql error: proxy not stopped"
o=$(run '' 0)
[[ "$o" == "rc=1 "*"FATAL"* ]] && pass "empty output: exit 1, FATAL" || fail "empty output: $o"
o=$(run 'zero' 0)
[[ "$o" == "rc=1 "*"FATAL"* ]] && pass "non-count output: exit 1, FATAL" || fail "non-count: $o"
# --- 3. the SQL ---------------------------------------------------------------------------
run 0 0 >/dev/null
sql=$(cat "$T/calls.log.sql")
want='SELECT count(*) FROM messages WHERE search_sig IS NOT NULL AND search_sig <> spool_search_sig(search_tsv);'
grep -qxF "$want" <<<"$sql" && pass "SQL is the spec 5.2 invariant query" || fail "SQL: $sql"
[[ "$(head -1 <<<"$sql")" == "BEGIN READ ONLY;" && "$(tail -1 <<<"$sql")" == "ROLLBACK;" ]] &&
  pass "SQL runs in BEGIN READ ONLY ... ROLLBACK" || fail "transaction: $sql"
grep -q "SET LOCAL statement_timeout" <<<"$sql" && pass "SQL is bounded by statement_timeout" || fail "no timeout: $sql"
grep -qiE '\b(insert|update|delete|alter|create|drop|truncate|grant)\b' <<<"$sql" && fail "SQL writes: $sql" || pass "SQL writes nothing"
grep -q "p@" "$T/calls.log" && fail "the password reached psql argv" || pass "the password stays out of psql argv"
# --- 5. no account: no psql -----------------------------------------------------------------
: >"$T/calls.log"
SNIPPET='do_gcp_pin_account() { return 1; }
do_spl_search_sig_check' in_orc PSQL_OUT=0 >"$T/o" 2>&1 && fail "ran without an account" || pass "no account: refused"
[[ ! -s "$T/calls.log" ]] && pass "no account: no psql call" || fail "psql called: $(cat "$T/calls.log")"
SNIPPET='psql probe </dev/null' in_orc PSQL_OUT=0 >/dev/null 2>&1
grep -q "psql probe" "$T/calls.log" && pass "CONTROL: stub log records a call" || fail "CONTROL: stub log empty"

(( fails == 0 )) && echo "OK spl-search-sig-check: all checks passed" || { echo "FAIL spl-search-sig-check: $fails check(s)"; exit 1; }
