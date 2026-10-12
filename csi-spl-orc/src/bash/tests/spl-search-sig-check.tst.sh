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
#   6. perf round 5 P5-05: an equal fingerprint (Postgres major:md5 of
#      spool_search_sig) skips the full compare; SPL_SEARCH_SIG_FULL=1 and a
#      malformed record never skip, and a malformed record never reaches SQL
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

FP=16:0123456789abcdef0123456789abcdef
run() { # <psql out> <psql rc> [VAR=value]... -> prints "rc=<n> <output>"
  local out rc po="$1" pr="$2"
  shift 2
  : >"$T/calls.log"
  out=$(SNIPPET="$CLOUD"$'\n'do_spl_search_sig_check in_orc PSQL_OUT="$po" PSQL_RC="$pr" "$@" 2>&1); rc=$?
  echo "rc=$rc $out"
}

# --- 1. the verdict -------------------------------------------------------------------
o=$(run "fp $FP"$'\n'0 0)
[[ "$o" == "rc=0 "*"mismatched=0 fp=$FP"*"OK "* ]] && pass "count 0: exit 0, mismatched=0, OK" || fail "count 0: $o"
[[ "$o" == *"NOTE"*"SPL_SEARCH_SIG_PASSED_ON_RECORDED='$FP'"* ]] && pass "count 0 on an unrecorded fingerprint: NOTE names the value to record" || fail "no NOTE: $o"
grep -q "^proxy-stop" "$T/calls.log" && pass "count 0: proxy stopped" || fail "count 0: proxy not stopped"
o=$(run "fp $FP"$'\n'0 0 SPL_SEARCH_SIG_PASSED_ON="$FP" SPL_SEARCH_SIG_FULL=1)
[[ "$o" == "rc=0 "*"mismatched=0"* && "$o" != *NOTE* ]] && pass "count 0 on the recorded fingerprint: no NOTE" || fail "NOTE on recorded: $o"
o=$(run "fp $FP"$'\n'1 0)
[[ "$o" == "rc=1 "*"mismatched=1"*"FAIL 1 message(s)"* ]] && pass "count 1: exit 1, mismatched=1, FAIL" || fail "count 1: $o"
o=$(run "fp $FP"$'\n'37 0)
[[ "$o" == "rc=1 "*"mismatched=37"* ]] && pass "count 37: exit 1" || fail "count 37: $o"
# --- 2. errors are never a pass -----------------------------------------------------------
o=$(run 'ERROR:  function spool_search_sig(tsvector) does not exist' 3)
[[ "$o" == "rc=1 "*"FATAL"* && "$o" != *mismatched* ]] && pass "psql error: exit 1, FATAL" || fail "psql error: $o"
grep -q "^proxy-stop" "$T/calls.log" && pass "psql error: proxy stopped" || fail "psql error: proxy not stopped"
o=$(run '' 0)
[[ "$o" == "rc=1 "*"FATAL"* ]] && pass "empty output: exit 1, FATAL" || fail "empty output: $o"
o=$(run 'zero' 0)
[[ "$o" == "rc=1 "*"FATAL"* ]] && pass "non-count output: exit 1, FATAL" || fail "non-count: $o"
o=$(run 0 0)
[[ "$o" == "rc=1 "*"FATAL"*"no fingerprint"* ]] && pass "a bare count with no fingerprint: exit 1, FATAL" || fail "bare count: $o"
o=$(run "fp $FP"$'\n'zero 0)
[[ "$o" == "rc=1 "*"FATAL"*"no count"* ]] && pass "fingerprint without a count: exit 1, FATAL" || fail "fp no count: $o"
o=$(run 'skipped 16:nothex' 0)
[[ "$o" == "rc=1 "*"FATAL"* && "$o" != *mismatched* ]] && pass "a malformed skip line: exit 1, never a pass" || fail "bad skip: $o"
# --- 3. the SQL ---------------------------------------------------------------------------
run "fp $FP"$'\n'0 0 >/dev/null
sql=$(cat "$T/calls.log.sql")
want='SELECT count(*) FROM messages WHERE search_sig IS NOT NULL AND search_sig <> spool_search_sig(search_tsv);'
grep -qxF "$want" <<<"$sql" && pass "SQL is the spec 5.2 invariant query" || fail "SQL: $sql"
[[ "$(head -1 <<<"$sql")" == "BEGIN READ ONLY;" && "$(tail -1 <<<"$sql")" == "ROLLBACK;" ]] &&
  pass "SQL runs in BEGIN READ ONLY ... ROLLBACK" || fail "transaction: $sql"
grep -q "SET LOCAL statement_timeout" <<<"$sql" && pass "SQL is bounded by statement_timeout" || fail "no timeout: $sql"
grep -qiE '\b(insert|update|delete|alter|create|drop|truncate|grant)\b' <<<"$sql" && fail "SQL writes: $sql" || pass "SQL writes nothing"
grep -q "p@" "$T/calls.log" && fail "the password reached psql argv" || pass "the password stays out of psql argv"
# --- 6. the fingerprint gate (P5-05) --------------------------------------------------------
o=$(run "skipped $FP" 0 SPL_SEARCH_SIG_PASSED_ON="$FP")
[[ "$o" == "rc=0 "*"mismatched=skipped fp=$FP"*"OK "*"skipped"* ]] && pass "equal fingerprint: exit 0, mismatched=skipped" || fail "skip: $o"
grep -q "^proxy-stop" "$T/calls.log" && pass "skip: proxy stopped" || fail "skip: proxy not stopped"
sql=$(cat "$T/calls.log.sql")
grep -qF "server_version_num" <<<"$sql" && grep -qF "pg_get_functiondef('spool_search_sig(tsvector)'::regprocedure)" <<<"$sql" &&
  pass "fingerprint = server major + spool_search_sig definition" || fail "fingerprint SQL: $sql"
grep -qF "(:'sig_fp' = '$FP')" <<<"$sql" && pass "the record reaches the compare" || fail "record not compared: $sql"
grep -qxF '\if :sig_same' <<<"$sql" && pass "the count sits behind \\if :sig_same" || fail "no \\if gate: $sql"
run "fp $FP"$'\n'0 0 SPL_SEARCH_SIG_PASSED_ON="$FP" SPL_SEARCH_SIG_FULL=1 >/dev/null
grep -qF "(:'sig_fp' = 'none')" "$T/calls.log.sql" && pass "SPL_SEARCH_SIG_FULL=1: never skips" || fail "FULL=1: $(cat "$T/calls.log.sql")"
run "fp $FP"$'\n'0 0 SPL_SEARCH_SIG_PASSED_ON="16:x'; DROP TABLE messages; --" >/dev/null
grep -qF "(:'sig_fp' = 'none')" "$T/calls.log.sql" && ! grep -q DROP "$T/calls.log.sql" &&
  pass "a malformed record never skips and never reaches the SQL" || fail "malformed record: $(cat "$T/calls.log.sql")"
grep -qE "^SPL_SEARCH_SIG_PASSED_ON_RECORDED='([0-9]+:[0-9a-f]{32})?'$" "$TEST_DIR/../run/spl-search-sig-check.func.sh" &&
  pass "the recorded fingerprint is empty or of the fingerprint's form" || fail "recorded fingerprint malformed"
# --- 5. no account: no psql -----------------------------------------------------------------
: >"$T/calls.log"
SNIPPET='do_gcp_pin_account() { return 1; }
do_spl_search_sig_check' in_orc PSQL_OUT=0 >"$T/o" 2>&1 && fail "ran without an account" || pass "no account: refused"
[[ ! -s "$T/calls.log" ]] && pass "no account: no psql call" || fail "psql called: $(cat "$T/calls.log")"
SNIPPET='psql probe </dev/null' in_orc PSQL_OUT=0 >/dev/null 2>&1
grep -q "psql probe" "$T/calls.log" && pass "CONTROL: stub log records a call" || fail "CONTROL: stub log empty"

(( fails == 0 )) && echo "OK spl-search-sig-check: all checks passed" || { echo "FAIL spl-search-sig-check: $fails check(s)"; exit 1; }
