#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_db_compact rewrites ONE allow-listed table, guarded. Offline:
#   1. an unknown TABLE, a bad DRY_RUN or a bad timeout is refused BEFORE
#      gcloud or psql is called. CONTROL: the stub log records a call
#   2. ENV=prd DRY_RUN=0 is refused without ALLOW_PRD=1 (and allowed with it
#      as far as the check goes); ENV=prd DRY_RUN=1 passes the check
#   3. the VACUUM runs as its own psql -c (never inside a transaction), after
#      SET lock_timeout, and only on the DRY_RUN=0 path; the owner login is
#      checked against cnf before the proxy starts
#   4. the size SQL names the table and reads sizes only
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FN="$PROJ_ROOT/src/bash/run/spl-db-compact.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mkdir -p "$T/stub"
for b in gcloud psql; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
  chmod +x "$T/stub/$b"
done

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" STUB_LOG="$T/calls.log" \
    PATH="$T/stub:$PATH" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}

# --- 1. bad arguments never reach the cloud ----------------------------------------
for kv in TABLE=humans TABLE="messages;drop" DRY_RUN=2 COMPACT_LOCK_TIMEOUT=forever COMPACT_STATEMENT_TIMEOUT=1h; do
  : >"$T/calls.log"
  SNIPPET=do_spl_db_compact in_orc ENV=dev "$kv" >"$T/o" 2>&1 && fail "$kv: ran" || pass "$kv: refused"
  grep -q FATAL "$T/o" && pass "$kv: the refusal is FATAL" || fail "$kv: refusal text: $(cat "$T/o")"
  [[ ! -s "$T/calls.log" ]] && pass "$kv: no gcloud/psql call" || fail "$kv: called: $(cat "$T/calls.log")"
done
SNIPPET='gcloud probe' in_orc ENV=dev >/dev/null 2>&1
grep -q "gcloud probe" "$T/calls.log" && pass "CONTROL: the stub log records a call" || fail "CONTROL: stub log empty"

# --- 2. the prd guard -----------------------------------------------------------------
: >"$T/calls.log"
SNIPPET=do_spl_db_compact in_orc ENV=prd DRY_RUN=0 >"$T/o" 2>&1 && fail "prd DRY_RUN=0 ran without ALLOW_PRD" ||
  pass "prd DRY_RUN=0 without ALLOW_PRD: refused"
grep -q "ALLOW_PRD=1" "$T/o" && pass "the refusal names ALLOW_PRD=1" || fail "prd refusal text: $(cat "$T/o")"
[[ ! -s "$T/calls.log" ]] && pass "prd refusal: no gcloud/psql call" || fail "prd refusal called: $(cat "$T/calls.log")"
SNIPPET='spl_db_compact_check messages 0 1 5s 10min' in_orc ENV=prd >/dev/null 2>&1 &&
  pass "prd DRY_RUN=0 with ALLOW_PRD=1 passes the check" || fail "ALLOW_PRD=1 still refused"
SNIPPET='spl_db_compact_check messages 1 0 5s 10min' in_orc ENV=prd >/dev/null 2>&1 &&
  pass "prd DRY_RUN=1 passes the check (it only reads sizes)" || fail "prd dry run refused"
SNIPPET='spl_db_compact_check messages 1 0 5s 10min' in_orc ENV=tst >/dev/null 2>&1 &&
  fail "ENV=tst accepted" || pass "ENV other than dev/prd refused"

# --- 3. the rewrite itself ---------------------------------------------------------------
grep -q -- '-c "VACUUM (FULL, ANALYZE) $table"' "$FN" && pass "VACUUM FULL runs as its own psql -c" || fail "no standalone VACUUM -c"
grep -qiE 'BEGIN|START TRANSACTION' "$FN" && fail "a transaction block around VACUUM" || pass "no transaction block"
lt=$(grep -n -- "-c \"SET lock_timeout" "$FN" | head -1 | cut -d: -f1); vf=$(grep -n -- '-c "VACUUM (FULL, ANALYZE) \$table"' "$FN" | head -1 | cut -d: -f1)
[[ -n "$lt" && -n "$vf" ]] && (( lt < vf )) && pass "lock_timeout is set before the VACUUM" || fail "lock_timeout order ($lt, $vf)"
dry=$(grep -n 'if \[\[ "$dry" == 1 \]\]' "$FN" | cut -d: -f1)
[[ -n "$dry" ]] && (( dry < vf )) && pass "the VACUUM sits behind the DRY_RUN branch" || fail "DRY_RUN branch order"
own=$(grep -n 'not the owner' "$FN" | cut -d: -f1); px=$(grep -n 'spl_sql_proxy_start' "$FN" | head -1 | cut -d: -f1)
(( own < px )) && pass "the owner login is checked before the proxy starts" || fail "owner check order"

# --- 4. the size SQL ----------------------------------------------------------------------
s=$(SNIPPET='spl_db_compact_size_sql deliveries' in_orc ENV=dev 2>&1)
grep -q "pg_total_relation_size('deliveries'::regclass)" <<<"$s" && ! grep -qiE '^\s*(VACUUM|DELETE|UPDATE|ALTER)' <<<"$s" &&
  pass "the size SQL reads the named table's sizes only" || fail "size SQL: $s"

(( fails == 0 )) && echo "OK spl-db-compact: all checks passed" || { echo "FAIL spl-db-compact: $fails check(s)"; exit 1; }
