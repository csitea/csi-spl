#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_db_maint, the nightly DB maintenance (workflow 47). Offline,
# psql and gcloud are stubs:
#   1. bad arguments are refused BEFORE gcloud or psql is called. CONTROL: the
#      stub log records a call
#   2. the window is 01:00-05:00 Europe/Helsinki: DRY_RUN=0 outside it is
#      refused unless MAINT_FORCE=1; MAINT_HEAVY=1 outside it is refused even
#      forced; DRY_RUN=1 runs at any hour; the edges 00/01/04/05
#   3. the estimate and the plan from a fixture snapshot: VACUUM on dead rows,
#      REINDEX on an estimated-bloated btree, FULL only HELD without
#      MAINT_HEAVY=1, a FULL replaces that table's other steps, an INVALID
#      index is a NOTE, a tiny or clean table gets no step
#   4. statements: exact quoting, odd names refused
#   5. steps: each its own psql, lock_timeout before the statement, a failed
#      step does not stop the next and makes the run non-zero; HELD and NOTE
#      never run
#   6. the whole action: DRY_RUN=1 writes a report with BEFORE and PLAN and
#      runs no step; DRY_RUN=0 (forced) writes BEFORE -> AFTER
#   7. facts.sql only reads, inside BEGIN READ ONLY ... ROLLBACK
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FN="$PROJ_ROOT/src/bash/run/spl-db-maint.func.sh"
SQL="$PROJ_ROOT/src/sql/db-maint/facts.sql"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# A raw facts.sql snapshot: messages (bloated heap, dead rows), deliveries
# (a bloated index), tiny (nothing to do), plus an INVALID index.
cat >"$T/raw" <<'EOF'
T|public|messages|20000|40000|40000|2010|60000|16465920|21282816|100|||2026-10-06T18:38:30Z|
T|public|deliveries|5000|10|10|100|5000|819200|3000000|100|2026-10-05T01:00:00Z||2026-10-05T01:00:00Z|
T|public|tiny|3|0|0|1|3|8192|16384|100||||
I|public|messages_pkey|messages|160|60000|1310720|t|btree|90|f|7
I|public|deliveries_state|deliveries|400|5000|3276800|t|btree|90|f|12
I|public|deliveries_lower|deliveries|50|5000|409600|t|btree|90|t|0
I|public|issues_x_ccnew|issues|10|0|81920|f|btree|90|f|0
TW|public|messages|2000|200
TW|public|deliveries|2000|120
TW|public|tiny|3|30
IW|public|messages_pkey|2000|8
IW|public|deliveries_state|2000|20
EOF

mkdir -p "$T/stub"
printf '#!/bin/sh\necho "gcloud $*" >>"$STUB_LOG"\nexit 1\n' >"$T/stub/gcloud"
# psql: a facts read (-f -) prints the fixture; a step (-c ...) is logged and
# fails when its statement names $FAIL_ON.
cat >"$T/stub/psql" <<'EOF'
#!/bin/bash
echo "psql $*" >>"$STUB_LOG"
for a in "$@"; do
  if [[ "$a" == "-f" ]]; then cat >>"$STUB_LOG.stdin"; cat "$RAW"; exit 0; fi
done
last="${*: -1}"
[[ -n "${FAIL_ON:-}" && "$last" == *"$FAIL_ON"* ]] && { echo "ERROR: canceling statement due to lock timeout" >&2; exit 1; }
exit 0
EOF
chmod +x "$T/stub/gcloud" "$T/stub/psql"

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" STUB_LOG="$T/calls.log" RAW="$T/raw" \
    PATH="$T/stub:$PATH" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_db_maint_hour() { echo "${HOUR:-14}"; }
    do_spl_cloud_cnf() { SPL_CNF=x SPL_DB_OWNER_USER=own SPL_OWNER_DSN_SECRET=owner-dsn SPL_PROJECT=p SPL_SQL_INSTANCE=i SPL_DB_NAME=db; }
    do_spl_cloud_provider() { echo none; }
    spl_read_owner_dsn() { echo "postgres://${OWNER_LOGIN:-own}:pw@/db?host=/cloudsql/p:r:i"; }
    spl_sql_proxy_start() { echo "proxy start" >>"$STUB_LOG"; SPL_PROXY_PORT=1; }
    spl_sql_proxy_stop() { echo "proxy stop" >>"$STUB_LOG"; }
    eval "$SNIPPET"'
}

# --- 1. bad arguments never reach the cloud ------------------------------------------
for kv in DRY_RUN=2 MAINT_HEAVY=yes MAINT_FORCE=2 MAINT_DEAD_MIN=0 MAINT_REINDEX_PCT=x "MAINT_DEAD_PCT=5;x" \
          MAINT_LOCK_TIMEOUT=forever MAINT_STATEMENT_TIMEOUT=1h ENV=tst; do
  : >"$T/calls.log"
  SNIPPET=do_spl_db_maint in_orc ENV=dev "$kv" >"$T/o" 2>&1 && fail "$kv: ran" || pass "$kv: refused"
  grep -q FATAL "$T/o" && pass "$kv: the refusal is FATAL" || fail "$kv: refusal text: $(cat "$T/o")"
  [[ ! -s "$T/calls.log" ]] && pass "$kv: no gcloud/psql call" || fail "$kv: called: $(cat "$T/calls.log")"
done
SNIPPET='gcloud probe' in_orc ENV=dev >/dev/null 2>&1
grep -q "gcloud probe" "$T/calls.log" && pass "CONTROL: the stub log records a call" || fail "CONTROL: stub log empty"

# --- 2. the window ---------------------------------------------------------------------
chk() { SNIPPET=spl_db_maint_check in_orc ENV=prd "$@" >"$T/o" 2>&1; }
chk HOUR=14 DRY_RUN=0 && fail "DRY_RUN=0 at 14 Helsinki ran" || pass "DRY_RUN=0 outside the window: refused"
grep -q "MAINT_FORCE=1" "$T/o" && pass "the refusal names MAINT_FORCE=1" || fail "window refusal text: $(cat "$T/o")"
chk HOUR=14 DRY_RUN=0 MAINT_FORCE=1 && pass "MAINT_FORCE=1 runs the light steps outside the window" || fail "MAINT_FORCE=1 refused: $(cat "$T/o")"
chk HOUR=14 DRY_RUN=0 MAINT_FORCE=1 MAINT_HEAVY=1 && fail "MAINT_HEAVY=1 forced outside the window ran" ||
  pass "MAINT_HEAVY=1 outside the window: refused even with MAINT_FORCE=1"
chk HOUR=14 DRY_RUN=1 MAINT_HEAVY=1 && pass "DRY_RUN=1 plans at any hour" || fail "DRY_RUN=1 refused at 14: $(cat "$T/o")"
for h in 01 02 04; do
  chk HOUR=$h DRY_RUN=0 MAINT_HEAVY=1 && pass "$h:xx Helsinki is inside the window" || fail "$h:xx refused: $(cat "$T/o")"
done
for h in 00 05 23; do
  chk HOUR=$h DRY_RUN=0 && fail "$h:xx Helsinki ran" || pass "$h:xx Helsinki is outside the window"
done
h=$(TZ=Europe/Helsinki date +%H)
grep -q 'TZ=Europe/Helsinki date +%H' "$FN" && [[ "$h" =~ ^[0-9]{2}$ ]] &&
  pass "the hour is read in Europe/Helsinki (DST by the tz database), two digits" || fail "hour source"

# --- 3. estimate and plan --------------------------------------------------------------
SNIPPET='_spl_db_maint_py estimate "$RAW"' in_orc ENV=dev >"$T/facts" 2>&1
grep -q '^T|public|messages|20000|40000|40000|16465920|21282816|[0-9.]*|' "$T/facts" && pass "estimate keeps the table numbers" ||
  fail "estimate T row: $(grep messages "$T/facts")"
b=$(awk -F'|' '$1=="T" && $3=="messages"{print $9}' "$T/facts")
[[ -n "$b" ]] && awk -v b="$b" 'BEGIN{exit !(b > 50 && b < 80)}' && pass "messages heap bloat estimated ($b%, 2/3 of rows deleted)" ||
  fail "messages heap bloat: '$b'"
[[ "$(awk -F'|' '$1=="T" && $3=="tiny"{print $9}' "$T/facts")" == "" ]] && pass "a table under 8 pages is not estimated" || fail "tiny estimated"
[[ "$(awk -F'|' '$1=="I" && $3=="deliveries_lower"{print $6}' "$T/facts")" == "" ]] && pass "an expression index is not estimated" ||
  fail "expression index estimated"
plan() { SNIPPET='_spl_db_maint_py plan <(_spl_db_maint_py estimate "$RAW")' in_orc ENV=dev "$@" 2>&1; }
p=$(plan)
grep -q '^VACUUM|public|messages|dead 40000 rows' <<<"$p" && pass "plan: VACUUM messages for its dead rows" || fail "plan VACUUM: $p"
grep -q '^REINDEX|public|deliveries_state|' <<<"$p" && pass "plan: REINDEX the bloated btree" || fail "plan REINDEX: $p"
grep -q '^HELD|public|messages|' <<<"$p" && ! grep -q '^FULL|' <<<"$p" && pass "plan: FULL is HELD without MAINT_HEAVY=1" || fail "plan HELD: $p"
grep -q '^NOTE|public|issues_x_ccnew|INVALID' <<<"$p" && pass "plan: an INVALID index is a NOTE" || fail "plan NOTE: $p"
grep -qE '\|tiny\||messages_pkey|deliveries\|' <<<"$(grep -E '^(VACUUM|REINDEX)' <<<"$p")" && fail "plan touches a clean table/index: $p" ||
  pass "plan: no step for a clean table or index"
p=$(plan MAINT_HEAVY=1)
grep -q '^FULL|public|messages|' <<<"$p" && pass "plan: MAINT_HEAVY=1 makes it a FULL" || fail "plan heavy: $p"
grep -q '^VACUUM|public|messages|' <<<"$p" && fail "plan: VACUUM messages beside its FULL" || pass "plan: the FULL replaces that table's VACUUM"
p=$(plan MAINT_DEAD_MIN=50000 MAINT_REINDEX_PCT=99)
grep -qE '^(VACUUM|REINDEX)' <<<"$p" && fail "thresholds ignored: $p" || pass "plan: the MAINT_* thresholds are honoured"

# --- 4. statements -----------------------------------------------------------------------
s=$(SNIPPET='spl_db_maint_stmt VACUUM public messages; echo; spl_db_maint_stmt REINDEX public m_pkey; echo; spl_db_maint_stmt FULL public messages' in_orc ENV=dev)
[[ "$s" == $'VACUUM (ANALYZE) "public"."messages"\nREINDEX INDEX CONCURRENTLY "public"."m_pkey"\nVACUUM (FULL, ANALYZE) "public"."messages"' ]] &&
  pass "statements are exact and quoted" || fail "statements: $s"
for n in 'Messages' 'm"; drop table x; --' 'a b'; do
  SNIPPET="spl_db_maint_stmt VACUUM public '$n'" in_orc ENV=dev >/dev/null 2>&1 && fail "name '$n' accepted" || pass "name '$n' refused"
done
SNIPPET='spl_db_maint_stmt DROP public messages' in_orc ENV=dev >/dev/null 2>&1 && fail "kind DROP accepted" || pass "an unknown kind is refused"

# --- 5. steps ---------------------------------------------------------------------------------
printf 'VACUUM|public|messages|r\nREINDEX|public|deliveries_state|r\nHELD|public|messages|r\nNOTE|public|x_ccnew|r\nVACUUM|public|deliveries|r\n' >"$T/plan"
: >"$T/calls.log"
SNIPPET='spl_db_maint_steps "postgres://own:pw@127.0.0.1:1/db" "'"$T/plan"'"' in_orc ENV=dev FAIL_ON=deliveries_state >"$T/o" 2>&1 &&
  fail "a failed step returned 0" || pass "a failed step makes the steps non-zero"
[[ "$(grep -c '^psql' "$T/calls.log")" == 3 ]] && pass "3 runnable steps, 3 psql calls (HELD and NOTE never run)" || fail "calls: $(cat "$T/calls.log")"
grep -q 'VACUUM (ANALYZE) "public"."deliveries"' "$T/calls.log" && pass "the step after the failed one still ran" || fail "stopped after a failure"
grep -q '^FAILED.*deliveries_state.*lock timeout' "$T/o" && grep -q 'steps run n=3, failed n=1' "$T/o" &&
  pass "the report names the failed step and n" || fail "steps output: $(cat "$T/o")"
grep -q "^psql -X -q -v ON_ERROR_STOP=1 -c SET lock_timeout = '5s' -c SET statement_timeout = '30min' -c VACUUM" "$T/calls.log" &&
  pass "lock and statement timeouts come before the statement, one psql per step" || fail "step argv: $(head -1 "$T/calls.log")"
grep -qE '^psql .*(BEGIN|-1 )' "$T/calls.log" && fail "a step runs in a transaction block" || pass "no transaction block around a step"

# --- 6. the whole action ----------------------------------------------------------------------
: >"$T/calls.log"
SNIPPET=do_spl_db_maint in_orc ENV=dev MAINT_REPORT_DIR="$T/rep" >"$T/o" 2>&1 && pass "DRY_RUN=1 exits 0" || fail "dry run: $(tail -5 "$T/o")"
r=$(find "$T/rep" -name "db-maint-dev-*.txt" 2>/dev/null | sed -n 1p)
[[ -n "$r" ]] && grep -q -- '--- BEFORE' "$r" && grep -q -- '--- PLAN (n=2 steps' "$r" && grep -q 'DRY_RUN=1: nothing was run' "$r" &&
  pass "the dry-run report has BEFORE and the PLAN with n" || fail "dry report: $(sed -n 1,20p "$r" 2>/dev/null)"
grep -q 'tables n=3 (rows; MB' "$r" && pass "the report states n and units" || fail "n/units missing"
[[ "$(grep -c '^psql' "$T/calls.log")" == 1 ]] && grep -q 'proxy stop' "$T/calls.log" &&
  pass "dry run: one read, no step, the proxy is stopped" || fail "dry run calls: $(cat "$T/calls.log")"
: >"$T/calls.log"
SNIPPET=do_spl_db_maint in_orc ENV=dev DRY_RUN=0 MAINT_FORCE=1 MAINT_REPORT_DIR="$T/rep2" >"$T/o" 2>&1 && pass "forced DRY_RUN=0 exits 0" || fail "forced run: $(tail -5 "$T/o")"
r=$(find "$T/rep2" -name "db-maint-dev-*.txt" 2>/dev/null | sed -n 1p)
grep -q -- '--- BEFORE -> AFTER' "$r" && grep -q 'SUM n=3 tables' "$r" && grep -q 'steps run n=2, failed n=0' "$r" &&
  pass "the run report has steps and BEFORE -> AFTER with n" || fail "run report: $(cat "$r" 2>/dev/null | tail -20)"
grep -q "^report=$r" "$T/o" && pass "the report path is printed" || fail "no report= line"
: >"$T/calls.log"
SNIPPET=do_spl_db_maint in_orc ENV=dev DRY_RUN=0 MAINT_FORCE=1 FAIL_ON=messages MAINT_REPORT_DIR="$T/rep3" >"$T/o" 2>&1 &&
  fail "a failed step exited 0" || pass "a failed step makes the action exit non-zero"
SNIPPET=do_spl_db_maint in_orc ENV=dev OWNER_LOGIN=spool_hub_rt >"$T/o" 2>&1 && fail "a non-owner DSN ran" ||
  { grep -q "not the owner" "$T/o" && pass "a DSN that is not the owner's is refused" || fail "owner check: $(cat "$T/o")"; }

# --- 7. facts.sql reads only -------------------------------------------------------------------
grep -viE '^\s*--' "$SQL" | grep -iE '\b(INSERT|UPDATE|DELETE|ALTER|DROP|CREATE|TRUNCATE|VACUUM|REINDEX|GRANT)\b' >/dev/null &&
  fail "facts.sql has a write verb" || pass "facts.sql has no write verb"
grep -q 'BEGIN READ ONLY' "$FN" && grep -q 'ROLLBACK' "$FN" && grep -q "default_transaction_read_only=on" "$FN" &&
  pass "the snapshot runs read-only and rolls back" || fail "snapshot transaction"

(( fails == 0 )) && echo "OK spl-db-maint: all checks passed" || { echo "FAIL spl-db-maint: $fails check(s)"; exit 1; }
