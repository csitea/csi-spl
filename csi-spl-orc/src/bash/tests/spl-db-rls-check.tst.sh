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
#   6. (FR-SEC-014) EXPECT_NOT_LIFTABLE=1 with a liftable login is exit 5;
#      without it the OK line reports the liftable count and 0021
#   5. with no key readable it stops before gcloud. CONTROL: the stub log
#      records a call when one is made.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

mkdir -p "$T/stub"
printf '#!/bin/sh\necho "gcloud $*" >>"$STUB_LOG"\nexit 1\n' >"$T/stub/gcloud"
chmod +x "$T/stub/gcloud"

verdict() { # <json> <expect> [<expect_not_liftable>] -> prints "rc=<n> <log>"
  local out rc
  out=$(SNIPPET="spl_db_rls_verdict '$1' $2 ${3:-0}" in_orc 2>&1); rc=$?
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
# --- 6. liftable (FR-SEC-014) ---------------------------------------------------------
LIFT='{"role":"hub","superuser":false,"bypassrls":false,"migration_0014":true,"migration_0021_fail_closed":true,"liftable":["owns or can SET ROLE to the owner of messages"],"tables":'"$ALL"'}'
o=$(verdict "$LIFT" 1 1)
[[ "$o" == "rc=5 FAIL"*"owner of messages"* ]] && pass "EXPECT_NOT_LIFTABLE=1 with an owner login is exit 5 and names the path" || fail "liftable: $o"
o=$(verdict "$LIFT" 1 0)
[[ "$o" == "rc=0 OK"*"0021 fail-closed applied=True"*"liftable=1"* ]] && pass "without EXPECT_NOT_LIFTABLE: exit 0, reports 0021 and liftable=1" || fail "liftable report: $o"
o=$(verdict '{"role":"hub","superuser":false,"bypassrls":false,"migration_0014":true,"liftable":[],"tables":'"$ALL"'}' 1 1)
[[ "$o" == "rc=0 OK"*"liftable=0"* ]] && pass "CONTROL: a non-owner login passes EXPECT_NOT_LIFTABLE=1" || fail "not liftable: $o"
# --- 4. SQL -------------------------------------------------------------------------
sql=$(SNIPPET=spl_db_rls_sql in_orc 2>&1)
grep -qE '\b(messages|deliveries|pins|tenants|roster)\b' <<<"$sql" && fail "SQL reads a data table" || pass "SQL reads no data table"
grep -q "relforcerowsecurity" <<<"$sql" && grep -q "rolbypassrls" <<<"$sql" && pass "SQL reads force + bypassrls" || fail "SQL lacks the flags"
grep -q "relowner" <<<"$sql" && grep -q "0021_rls_fail_closed.sql" <<<"$sql" && pass "SQL reads table owners + 0021" || fail "SQL lacks owner / 0021"
# --- 5. no key: no cloud call -------------------------------------------------------
: >"$T/calls.log"
SNIPPET=do_spl_db_rls_check in_orc SPL_SA_KEY="$T/nokey.json" >"$T/o" 2>&1 && fail "ran without a key" || pass "no key: refused"
[[ ! -s "$T/calls.log" ]] && pass "no key: no gcloud call" || fail "gcloud called: $(cat "$T/calls.log")"
SNIPPET='gcloud probe' in_orc >/dev/null 2>&1
grep -q "gcloud probe" "$T/calls.log" && pass "CONTROL: stub log records a call" || fail "CONTROL: stub log empty"

(( fails == 0 )) && echo "OK spl-db-rls-check: all checks passed" || { echo "FAIL spl-db-rls-check: $fails check(s)"; exit 1; }
