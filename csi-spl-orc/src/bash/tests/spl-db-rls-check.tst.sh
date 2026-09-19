#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_db_rls_check (017 FR-SEC-013) decides from the catalog JSON,
#          offline (no cloud call):
#   1. a superuser or BYPASSRLS login is exit 3, whatever the tables say
#   2. EXPECT_RLS=1 with a table lacking FORCE (or no table) is exit 4
#   3. a bound role with every table forced is exit 0; without EXPECT_RLS a
#      bound role before 0014 is exit 0 too (the pre-apply check)
#   4. the SQL reads only the catalog + spool_schema_migrations, and runs in
#      the read-only transaction of spl_psql_ro
#   5. with no key readable it stops before gcloud. CONTROL: the stub log
#      records a call when one is made.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mkdir -p "$T/stub"
printf '#!/bin/sh\necho "gcloud $*" >>"$STUB_LOG"\nexit 1\n' >"$T/stub/gcloud"
chmod +x "$T/stub/gcloud"

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" STUB_LOG="$T/calls.log" \
    PATH="$T/stub:$PATH" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}

verdict() { # <json> <expect> -> prints "rc=<n> <log>"
  local out rc
  out=$(SNIPPET="spl_db_rls_verdict '$1' $2" in_orc 2>&1); rc=$?
  echo "rc=$rc $out"
}

ALL='{"t1":[true,true],"t2":[true,true]}'
# --- 1. bypassing role ---------------------------------------------------------------
o=$(verdict '{"role":"hub","superuser":true,"bypassrls":false,"migration_0014":true,"tables":'"$ALL"'}' 1)
[[ "$o" == "rc=3 FAIL"* ]] && pass "superuser login is exit 3" || fail "superuser: $o"
o=$(verdict '{"role":"hub","superuser":false,"bypassrls":true,"migration_0014":true,"tables":'"$ALL"'}' 0)
[[ "$o" == "rc=3 FAIL"* ]] && pass "BYPASSRLS login is exit 3" || fail "bypassrls: $o"
# --- 2. expected but not forced ---------------------------------------------------
o=$(verdict '{"role":"hub","superuser":false,"bypassrls":false,"migration_0014":false,"tables":{"t1":[true,true],"t2":[true,false]}}' 1)
[[ "$o" == "rc=4 FAIL"*"1/2"*"t2"* ]] && pass "EXPECT_RLS=1 with an unforced table is exit 4 and names it" || fail "unforced: $o"
o=$(verdict '{"role":"hub","superuser":false,"bypassrls":false,"migration_0014":false,"tables":null}' 1)
[[ "$o" == "rc=4 FAIL"* ]] && pass "EXPECT_RLS=1 with no tenant table is exit 4" || fail "no tables: $o"
# --- 3. bound -----------------------------------------------------------------------
o=$(verdict '{"role":"hub","superuser":false,"bypassrls":false,"migration_0014":true,"tables":'"$ALL"'}' 1)
[[ "$o" == "rc=0 OK"*"2/2"* ]] && pass "bound role, all forced: exit 0" || fail "bound: $o"
o=$(verdict '{"role":"hub","superuser":false,"bypassrls":false,"migration_0014":false,"tables":{"t1":[false,false]}}' 0)
[[ "$o" == "rc=0 OK"*"0/1"* ]] && pass "pre-0014 check without EXPECT_RLS: exit 0, reports 0/1" || fail "pre-apply: $o"
# --- 4. SQL -------------------------------------------------------------------------
sql=$(SNIPPET=spl_db_rls_sql in_orc 2>&1)
grep -qE '\b(messages|deliveries|pins|tenants|roster)\b' <<<"$sql" && fail "SQL reads a data table" || pass "SQL reads no data table"
grep -q "relforcerowsecurity" <<<"$sql" && grep -q "rolbypassrls" <<<"$sql" && pass "SQL reads force + bypassrls" || fail "SQL lacks the flags"
# --- 5. no key: no cloud call -------------------------------------------------------
: >"$T/calls.log"
SNIPPET=do_spl_db_rls_check in_orc SPL_SA_KEY="$T/nokey.json" >"$T/o" 2>&1 && fail "ran without a key" || pass "no key: refused"
[[ ! -s "$T/calls.log" ]] && pass "no key: no gcloud call" || fail "gcloud called: $(cat "$T/calls.log")"
SNIPPET='gcloud probe' in_orc >/dev/null 2>&1
grep -q "gcloud probe" "$T/calls.log" && pass "CONTROL: stub log records a call" || fail "CONTROL: stub log empty"

(( fails == 0 )) && echo "OK spl-db-rls-check: all checks passed" || { echo "FAIL spl-db-rls-check: $fails check(s)"; exit 1; }
