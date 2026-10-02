#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_hub_member_list stays read-only and injection-proof, offline
#          (no cloud call).
#   1. the SQL: TENANT_ID must be a slug and MATCH a narrow token; a quote- or
#      space-carrying value is refused before any SQL is built. CONTROL: good
#      values yield the tenant filter and a lowercased MATCH on both queries.
#   2. the SQL only SELECTs (no INSERT/UPDATE/DELETE/ALTER/DROP) and reads no
#      credential table (native_credentials, human_keys)
#   3. with no key readable, it stops before gcloud (a stub log stays empty)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy psql

# --- 1. filter ---------------------------------------------------------------------
sql=$(SNIPPET=spl_hub_member_list_sql in_orc TENANT_ID=t1 2>&1)
[[ $(grep -c "tenant_id = 't1'" <<<"$sql") == 2 ]] && pass "TENANT_ID filters members and invites" || fail "tenant filter: $sql"
grep -q "LIKE" <<<"$sql" && fail "no MATCH yet a LIKE filter" || pass "no MATCH = no LIKE filter"
sql=$(SNIPPET=spl_hub_member_list_sql in_orc TENANT_ID=t1 MATCH=Veliko 2>&1)
[[ $(grep -o "LIKE '%veliko%'" <<<"$sql" | wc -l) == 3 ]] && pass "MATCH lowercased on email, name and invite email" \
  || fail "MATCH filter: $(grep LIKE <<<"$sql")"
for bad in "TENANT_ID=t1'--" "TENANT_ID=" "MATCH=a'b" "MATCH=a b" "MATCH=%" "MATCH=$(printf 'x%.0s' {1..65})"; do
  if SNIPPET=spl_hub_member_list_sql in_orc TENANT_ID=t1 "$bad" >"$T/o" 2>&1; then
    fail "refuses ${bad:0:20}: $(head -c 200 "$T/o")"
  else
    pass "refuses ${bad:0:20}"
  fi
done

# --- 2. read-only, no credential tables -------------------------------------------
sql=$(SNIPPET=spl_hub_member_list_sql in_orc TENANT_ID=t1 2>&1)
grep -qiE '\b(insert|update|delete|alter|drop|truncate|grant)\b' <<<"$sql" && fail "SQL writes: $sql" || pass "SQL only reads"
grep -qE 'native_credentials|human_keys|password' <<<"$sql" && fail "SQL touches a credential table" || pass "SQL reads no credential table"

# --- 3. no key: stops before gcloud --------------------------------------------------
: >"$T/calls.log"
if SNIPPET=do_spl_hub_member_list in_orc TENANT_ID=t1 SPL_SA_KEY="$T/nope.json" \
  do_spl_cloud_cnf=1 >"$T/o" 2>&1; then
  fail "no key: exit 0"
else
  grep -q gcloud "$T/calls.log" && fail "no key: gcloud was called" || pass "no key: refused before any gcloud call"
fi

echo
(( fails == 0 )) && echo "ALL HUB MEMBER LIST CHECKS PASSED" || echo "$fails CHECK(S) FAILED"
exit $(( fails > 0 ))
