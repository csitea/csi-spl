#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_search_index_probe (spec 100 T001) proves S1r on dev inside
#   ONE transaction that always ends in ROLLBACK. Offline, psql stubbed:
#   1. ENV=prd is refused BEFORE cnf, gcloud or psql; so are a bad ENV and
#      bad knobs. CONTROL: the stub log records a call
#   2. the script: BEGIN once, ON_ERROR_STOP off + ON_ERROR_ROLLBACK on, the
#      P1 DDL steps, ROLLBACK the LAST SQL statement outside every \if, and
#      no COMMIT anywhere; the same with PROBE_WORD set and unset
#   3. the action end to end with stubbed helpers: psql gets that script on
#      stdin, never -1 / --single-transaction; the owner login is checked
#      before the proxy starts; a run whose output lacks the ROLLBACK marker
#      fails (and the script it was sent still ended in ROLLBACK)
#   4. the verdict lines read G1 / G2 / G3 / G6 / G7 from the markers
#   5. prd opt-in (gap T3): refused without PROBE_PRD_GO=1 or off a test
#      workspace, before any call; with it, two psql sessions, each a READ
#      ONLY transaction ending in ROLLBACK, the SQL sent holding no DDL or
#      write; G1 runs as the runtime login on its own DSN, never SET ROLE;
#      the guard refuses the dev DDL script (CONTROL); dev still sends
#      BEGIN + the DDL + its fallbacks
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FN="$PROJ_ROOT/src/bash/run/spl-search-index-probe.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mkdir -p "$T/stub"
for b in gcloud psql; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
  chmod +x "$T/stub/$b"
done
# The psql the end-to-end path reaches: logs argv, keeps the script it was fed
# (stdin, or -c), and prints PSQL_OUT.
cat >"$T/stub/psql-fake" <<'EOF_STUB'
#!/bin/bash
echo "psql $*" >>"$STUB_LOG"
if [[ " $* " == *" -f - "* ]]; then cat >>"$SQL_IN"; fi
printf '%b\n' "${PSQL_OUT:-}"
exit "${PSQL_RC:-0}"
EOF_STUB
chmod +x "$T/stub/psql-fake"

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" STUB_LOG="$T/calls.log" \
    SQL_IN="$T/sql.in" PATH="$T/stub:$PATH" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}

# STUBS: the cloud seams, so the action runs to psql offline.
STUBS='
do_spl_cloud_cnf() { echo "cnf" >>"$STUB_LOG"; SPL_DB_USER=spool_rt; SPL_DB_OWNER_USER=spool_owner; SPL_OWNER_DSN_SECRET=owner-dsn; SPL_DSN_SECRET=rt-dsn; SPL_CNF=x; }
do_spl_cloud_provider() { echo none; }
spl_read_owner_dsn() { echo "postgres://${OWNER_LOGIN:-spool_owner}:pw@/db?host=/cloudsql/p:r:i"; }
spl_read_dsn() { echo "postgres://${RT_LOGIN:-spool_rt}:pw@/db?host=/cloudsql/p:r:i"; }
spl_sql_proxy_start() { echo "proxy start" >>"$STUB_LOG"; SPL_PROXY_PORT=1; }
spl_sql_proxy_stop() { echo "proxy stop" >>"$STUB_LOG"; }
spl_local_dsn() { echo "postgres://x@127.0.0.1:1/db"; }
spl_pg_env() { shift; [[ "$1" == psql ]] && shift; psql-fake "$@"; }
'

# last_sql <file> -> the last SQL line: not blank, not a psql meta-command.
last_sql() { grep -vE '^\s*($|\\)' "$1" | tail -1; }
# rollback_depth <file> -> the \if depth at the ROLLBACK line.
rollback_depth() { awk '/^\s*\\if /{d++} /^\s*\\endif/{d--} /^ROLLBACK;$/{print d; exit}' "$1"; }

# --- 1. refusals before any call ----------------------------------------------------
: >"$T/calls.log"
SNIPPET=do_spl_search_index_probe in_orc ENV=prd >"$T/o" 2>&1 && fail "ENV=prd ran" || pass "ENV=prd refused"
grep -q "ENV=prd is refused" "$T/o" && pass "the prd refusal says so" || fail "prd refusal text: $(cat "$T/o")"
[[ ! -s "$T/calls.log" ]] && pass "prd refusal: no cnf/gcloud/psql call" || fail "prd refusal called: $(cat "$T/calls.log")"
SNIPPET="$STUBS do_spl_search_index_probe" in_orc ENV=prd PSQL_OUT='@@rolled_back' >"$T/o" 2>&1 &&
  fail "ENV=prd ran with every seam stubbed" || pass "ENV=prd refused with every seam stubbed"
[[ ! -s "$T/calls.log" ]] && pass "prd, seams stubbed: still no call" || fail "prd, seams stubbed, called: $(cat "$T/calls.log")"
for kv in ENV=tst ENV= TENANT_ID="t1';drop" PROBE_WORD="two words" PROBE_WORD="x'y" PROBE_N=5 PROBE_N=500 \
  PROBE_CAP=0 PROBE_BODY_CHARS=100 PROBE_LOCK_TIMEOUT=forever PROBE_STATEMENT_TIMEOUT=1h; do
  : >"$T/calls.log"
  env_kv=("$kv"); [[ "$kv" == ENV=* ]] || env_kv=(ENV=dev "$kv")
  SNIPPET=do_spl_search_index_probe in_orc "${env_kv[@]}" >"$T/o" 2>&1 && fail "$kv: ran" || pass "$kv: refused"
  grep -q FATAL "$T/o" && [[ ! -s "$T/calls.log" ]] && pass "$kv: FATAL, no call" || fail "$kv: $(cat "$T/o") / $(cat "$T/calls.log")"
done
SNIPPET='gcloud probe' in_orc ENV=dev >/dev/null 2>&1
grep -q "gcloud probe" "$T/calls.log" && pass "CONTROL: the stub log records a call" || fail "CONTROL: stub log empty"
SNIPPET=spl_search_index_probe_check in_orc ENV=dev >/dev/null 2>&1 && pass "ENV=dev with defaults passes the check" ||
  fail "ENV=dev defaults refused"

# --- 2. the script --------------------------------------------------------------------
for w in "" rareword; do
  SNIPPET="spl_search_index_probe_sql t1 spool_rt '$w'" in_orc ENV=dev >"$T/s" 2>&1
  tag="PROBE_WORD='${w}'"
  [[ "$(last_sql "$T/s")" == "ROLLBACK;" ]] && pass "$tag: ROLLBACK is the last SQL statement" || fail "$tag: last SQL: $(last_sql "$T/s")"
  [[ "$(grep -c '^ROLLBACK;$' "$T/s")" == 1 && "$(rollback_depth "$T/s")" == 0 ]] &&
    pass "$tag: one ROLLBACK, outside every \\if (every branch reaches it)" || fail "$tag: ROLLBACK count/depth"
  awk '/^\s*\\if /{d++} /^\s*\\endif/{d--} END{exit d != 0}' "$T/s" && pass "$tag: \\if / \\endif balance" || fail "$tag: unbalanced \\if"
  ! grep -qiE '^\s*(COMMIT\b|END\s*;|END\s+(TRANSACTION|WORK)\b|\\set AUTOCOMMIT)' "$T/s" && pass "$tag: no COMMIT / END / AUTOCOMMIT" || fail "$tag: a commit path"
  [[ "$(grep -c '^BEGIN;$' "$T/s")" == 1 ]] && (( $(grep -n '^BEGIN;$' "$T/s" | cut -d: -f1) < $(grep -n 'CREATE ROLE' "$T/s" | cut -d: -f1) )) &&
    pass "$tag: one BEGIN, before the DDL" || fail "$tag: BEGIN"
  grep -qx '\\set ON_ERROR_STOP 0' "$T/s" && grep -qx '\\set ON_ERROR_ROLLBACK on' "$T/s" &&
    pass "$tag: a failed step rolls back to its savepoint and the script goes on" || fail "$tag: error handling vars"
  for ddl in 'CREATE ROLE spool_search_reader NOLOGIN NOBYPASSRLS' 'CREATE EXTENSION IF NOT EXISTS btree_gin' \
    'CREATE INDEX messages_search ON public.messages USING gin (tenant_id, search_tsv)' \
    'LANGUAGE sql STABLE SECURITY DEFINER ROWS 200' 'SET search_path = pg_catalog, public, pg_temp' \
    'OWNER TO spool_search_reader' 'CREATE POLICY search_reader_all ON public.messages FOR SELECT TO spool_search_reader USING (true)' \
    'SET LOCAL ROLE spool_rt' 'EXPLAIN (ANALYZE, BUFFERS) SELECT msg_id FROM public.spool_search_candidates('; do
    grep -qF "$ddl" "$T/s" || fail "$tag: missing: $ddl"
  done
  pass "$tag: the P1 DDL steps and the runtime EXPLAIN are there"
  ! grep -q 'CONCURRENTLY' "$T/s" && pass "$tag: plain CREATE INDEX (CONCURRENTLY cannot run in a transaction)" || fail "$tag: CONCURRENTLY"
  (( $(grep -n 'CREATE POLICY' "$T/s" | cut -d: -f1) > $(grep -n 'ins_index' "$T/s" | tail -1 | cut -d: -f1) )) &&
    pass "$tag: the ACCESS EXCLUSIVE policy step comes after the timed inserts" || fail "$tag: policy order"
done
grep -q "\\\\set w 'rareword'" "$T/s" && pass "PROBE_WORD is used as given" || fail "PROBE_WORD not set"
! grep -vE '^\s*#' "$FN" | grep -E -- '(^|\s)(-1|--single-transaction)(\s|$)' >/dev/null && pass "psql is never run with -1 / --single-transaction" || fail "a single-transaction psql"

# --- 3. end to end, stubbed ------------------------------------------------------------
OK_OUT='@@step ext ok\n@@step index ok\n@@build_ms 812 index_bytes=1000\n@@rolled_back'
: >"$T/calls.log"; rm -f "$T/sql.in"
SNIPPET="$STUBS do_spl_search_index_probe" in_orc ENV=dev PSQL_OUT="$OK_OUT" >"$T/o" 2>&1 &&
  pass "dev run with a stubbed psql succeeds" || fail "dev run: $(cat "$T/o")"
[[ -s "$T/sql.in" && "$(last_sql "$T/sql.in")" == "ROLLBACK;" ]] && pass "psql was fed the script, ROLLBACK last" ||
  fail "psql stdin: $(tail -3 "$T/sql.in" 2>/dev/null)"
grep -q 'SET LOCAL ROLE spool_rt' "$T/sql.in" && pass "the runtime login comes from cnf hub.db_user" || fail "runtime role"
grep -q 'G2 build: 812 ms' "$T/o" && pass "the verdict is printed" || fail "verdict: $(cat "$T/o")"
[[ "$(grep -c '^psql ' "$T/calls.log")" == 2 ]] && grep -q 'proxy stop' "$T/calls.log" &&
  pass "the probe session, then a separate read session; the proxy is stopped" || fail "calls: $(cat "$T/calls.log")"

: >"$T/calls.log"; rm -f "$T/sql.in"
SNIPPET="$STUBS do_spl_search_index_probe" in_orc ENV=dev PSQL_RC=2 PSQL_OUT='psql: error: connection lost' >"$T/o" 2>&1 &&
  fail "a run that never reached its ROLLBACK passed" || pass "a run without the ROLLBACK marker fails"
grep -q 'did not reach its ROLLBACK' "$T/o" && pass "it says so" || fail "lost-connection text: $(cat "$T/o")"
[[ "$(last_sql "$T/sql.in")" == "ROLLBACK;" ]] && pass "the script it was sent still ended in ROLLBACK" || fail "failed path script"

: >"$T/calls.log"
SNIPPET="$STUBS do_spl_search_index_probe" in_orc ENV=dev OWNER_LOGIN=spool_rt PSQL_OUT="$OK_OUT" >"$T/o" 2>&1 &&
  fail "a non-owner DSN ran" || pass "a DSN that is not the owner login is refused"
! grep -qE 'proxy start|^psql' "$T/calls.log" && pass "refused before the proxy or psql" || fail "non-owner called: $(cat "$T/calls.log")"

# --- 4. the verdict ----------------------------------------------------------------------
V='@@step ext ok\n@@step index ok\n@@build_ms 1234 index_bytes=99\n@@step owner error must be able to SET ROLE "spool_search_reader"
@@step owner_self_grant ok\n@@step owner_after_grant ok\n@@ins noindex n=20 p50_ms=1.00 p95_ms=2.00 max_ms=3
@@ins index n=20 p50_ms=1.50 p95_ms=2.75 max_ms=4\n@@step rt_self_grant ok\n@@step g1_call ok
@@idx_scan messages_search before=0 after=1\n@@plan reader begin\n  ->  Bitmap Index Scan on messages_search\n@@plan reader end'
v=$(printf '%b\n' "$V" | SNIPPET=spl_search_index_probe_verdict in_orc ENV=dev 2>&1)
grep -qx 'G6 btree_gin: ok' <<<"$v" && pass "G6 ok" || fail "G6: $v"
grep -q 'G7 OWNER TO spool_search_reader: ok only after GRANT spool_search_reader TO the owner WITH SET TRUE$' <<<"$v" &&
  pass "G7 names the self-grant it needed" || fail "G7: $v"
grep -q 'G1 runtime call: ok (SET ROLE to the runtime needed a self-grant: ok), messages_search scanned by the call: yes, in the reader plan: yes' <<<"$v" &&
  pass "G1 reads the call, the scan counter and the reader plan" || fail "G1: $v"
grep -qx 'G2 build: 1234 ms, index_bytes=99' <<<"$v" && pass "G2 build ms" || fail "G2: $v"
grep -q 'G3 insert p95: no index 2.00 ms, with index 2.75 ms, delta 0.75 ms' <<<"$v" && pass "G3 p95 delta" || fail "G3: $v"
v=$(printf '%b\n' '@@step ext error permission denied\n@@step owner ok\n@@step index error lock timeout\n@@idx_scan messages_search before=none after=none' |
  SNIPPET=spl_search_index_probe_verdict in_orc ENV=dev 2>&1)
grep -qx 'G6 btree_gin: FAILED' <<<"$v" && grep -qx 'G7 OWNER TO spool_search_reader: ok (direct)' <<<"$v" &&
  grep -qx 'G2 build: FAILED' <<<"$v" && grep -q 'G1 runtime call: FAILED.*scanned by the call: NO' <<<"$v" &&
  pass "failed steps read FAILED, a direct OWNER TO reads direct" || fail "failure verdict: $v"

# --- 5. prd opt-in: read-only, no DDL ----------------------------------------------------
for go in "" 0 yes; do
  : >"$T/calls.log"
  SNIPPET="$STUBS do_spl_search_index_probe" in_orc ENV=prd PROBE_PRD_GO="$go" PSQL_OUT='@@rolled_back' >"$T/o" 2>&1 &&
    fail "prd PROBE_PRD_GO='$go' ran" || pass "prd PROBE_PRD_GO='$go' refused"
  grep -q 'refused without PROBE_PRD_GO=1' "$T/o" && [[ ! -s "$T/calls.log" ]] &&
    pass "prd PROBE_PRD_GO='$go': says so, no call" || fail "prd PROBE_PRD_GO='$go': $(cat "$T/o") / $(cat "$T/calls.log")"
done
for t in t1 acme; do
  : >"$T/calls.log"
  SNIPPET="$STUBS do_spl_search_index_probe" in_orc ENV=prd PROBE_PRD_GO=1 TENANT_ID=$t >"$T/o" 2>&1 &&
    fail "prd TENANT_ID=$t ran" || pass "prd TENANT_ID=$t refused (not a test workspace)"
  [[ ! -s "$T/calls.log" ]] && pass "prd TENANT_ID=$t: no call" || fail "prd TENANT_ID=$t called: $(cat "$T/calls.log")"
done
RO_OUT='@@step ext ok\n@@step index ok\n@@step fn ok\n@@step owner ok\n@@step fn_grant ok\n@@step g1_call ok
@@idx_scan messages_search before=0 after=1\n@@plan reader begin\n  ->  Bitmap Index Scan on messages_search\n@@plan reader end\n@@rolled_back'
: >"$T/calls.log"; rm -f "$T/sql.in"
SNIPPET="$STUBS do_spl_search_index_probe" in_orc ENV=prd PROBE_PRD_GO=1 PSQL_OUT="$RO_OUT" >"$T/o" 2>&1 &&
  pass "prd PROBE_PRD_GO=1 with a stubbed psql succeeds" || fail "prd opt-in run: $(cat "$T/o")"
[[ -s "$T/sql.in" ]] && pass "prd: psql was fed a script" || fail "prd: no script sent"
[[ "$(grep -c '^BEGIN TRANSACTION READ ONLY;$' "$T/sql.in")" == 2 && "$(grep -c '^ROLLBACK;$' "$T/sql.in")" == 2 ]] &&
  ! grep -q '^BEGIN;$' "$T/sql.in" && pass "prd: two BEGIN TRANSACTION READ ONLY ... ROLLBACK, no plain BEGIN" || fail "prd: BEGIN"
! grep -q 'SET LOCAL ROLE spool_rt' "$T/sql.in" && pass "prd: never SET ROLE to the runtime login" || fail "prd: SET ROLE spool_rt"
W='^\s*(CREATE|ALTER|DROP|GRANT|REVOKE|INSERT|UPDATE|DELETE|TRUNCATE|COPY|COMMIT|END|DO|VACUUM|REINDEX|LOCK|\\set AUTOCOMMIT)\b'
! grep -qiE "$W" "$T/sql.in" && pass "prd: no DDL, write, DO block or COMMIT in the SQL sent" ||
  fail "prd: a write in the SQL sent: $(grep -iE "$W" "$T/sql.in")"
! grep -qiE '\b(CREATE|GRANT|INSERT|ALTER|POLICY)\b' "$T/sql.in" && pass "prd: not even inside a line: CREATE / GRANT / INSERT / ALTER / POLICY" ||
  fail "prd: $(grep -iE '\b(CREATE|GRANT|INSERT|ALTER|POLICY)\b' "$T/sql.in")"
[[ "$(last_sql "$T/sql.in")" == "ROLLBACK;" && "$(rollback_depth "$T/sql.in")" == 0 ]] &&
  pass "prd: ROLLBACK the last SQL statement, outside every \\if" || fail "prd: last SQL: $(last_sql "$T/sql.in")"
grep -qF 'EXPLAIN (ANALYZE, BUFFERS) SELECT msg_id FROM public.spool_search_candidates(' "$T/sql.in" && grep -q "current_user = 'spool_rt'" "$T/sql.in" &&
  pass "prd: the runtime login EXPLAINs the call (G1)" || fail "prd: no G1 EXPLAIN"
grep -q "set_config('app.tenant_id', 'e2e', true)" "$T/sql.in" && pass "prd: the default workspace is e2e" || fail "prd: tenant"
[[ "$(grep -c '^psql .* -f -' "$T/calls.log")" == 2 && "$(grep -c '^psql ' "$T/calls.log")" == 2 ]] && grep -q 'proxy stop' "$T/calls.log" &&
  pass "prd: two psql sessions fed on stdin, proxy stopped" || fail "prd calls: $(cat "$T/calls.log")"
grep -qx 'G1 runtime call: ok, messages_search scanned by the call: yes, in the reader plan: yes' "$T/o" &&
  grep -q '^mode: read-only' "$T/o" && grep -qx 'G6 btree_gin: ok' "$T/o" && pass "prd: the read-only verdict is printed" ||
  fail "prd verdict: $(cat "$T/o")"
: >"$T/calls.log"
SNIPPET="$STUBS do_spl_search_index_probe" in_orc ENV=prd PROBE_PRD_GO=1 RT_LOGIN=spool_owner PSQL_OUT="$RO_OUT" >"$T/o" 2>&1 &&
  fail "prd: a runtime DSN that is not the runtime login ran" || pass "prd: a runtime DSN that is not the runtime login is refused"
! grep -qE 'proxy start|^psql' "$T/calls.log" && pass "prd: refused before the proxy or psql" || fail "prd non-runtime called: $(cat "$T/calls.log")"
v=$(printf '%b\n' '@@step ext ok\n@@step index error missing\n@@step fn error missing\n@@step g1_call error x' |
  SNIPPET=spl_search_index_probe_ro_verdict in_orc ENV=prd 2>&1)
grep -qx 'index messages_search: MISSING, fn spool_search_candidates: MISSING' <<<"$v" && grep -q '^G1 runtime call: FAILED' <<<"$v" &&
  pass "prd: a missing object reads MISSING" || fail "prd missing verdict: $v"
SNIPPET='spl_search_index_probe_sql t1 spool_rt | spl_search_index_probe_ro_guard' in_orc ENV=dev >"$T/o" 2>&1 &&
  fail "CONTROL: the guard let the dev DDL script through" || pass "CONTROL: the guard refuses the dev DDL script"
grep -q 'CREATE INDEX messages_search' "$T/o" && pass "CONTROL: the refusal names the DDL line" || fail "CONTROL text: $(cat "$T/o")"
SNIPPET="spl_search_index_probe_sql t1 spool_rt" in_orc ENV=dev >"$T/s" 2>&1
grep -q '^BEGIN;$' "$T/s" && ! grep -q 'READ ONLY' "$T/s" && grep -q 'GRANT spool_rt TO CURRENT_USER' "$T/s" &&
  pass "dev unchanged: plain BEGIN, the DDL and the SET ROLE self-grant fallback" || fail "dev script changed"

(( fails == 0 )) && echo "OK spl-search-index-probe: all checks passed" || { echo "FAIL spl-search-index-probe: $fails check(s)"; exit 1; }
