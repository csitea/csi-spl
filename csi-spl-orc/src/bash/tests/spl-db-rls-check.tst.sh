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
#   7. (spec 100 T5) on real Postgres, as a runtime login: the SECURITY
#      DEFINER functions it can EXECUTE being exactly
#      {spool_search_candidates} is not liftable (exit 0, liftable=0); a
#      second definer it can EXECUTE is `liftable` (exit 5, names it), so is
#      a spool_search_candidates in another schema. CONTROL: a definer
#      revoked from PUBLIC and a plain (INVOKER) function add no path.
#   8. (spec 119 T-C1, rdb 0168) the personal tables count as forced tables:
#      one without FORCE is exit 4 and named personal.<t>; owning one is a
#      lift path. On real Postgres personal.due_receipts and
#      personal.delete_my_receipts are allow-listed by exact name (exit 0).
#      CONTROL: a third definer in personal, and a due_receipts in another
#      schema, are each exit 5 and named.
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
# --- 8. personal tables (spec 119 T-C1) -------------------------------------------------
o=$(verdict '{"role":"hub","superuser":false,"bypassrls":false,"migration_0014":true,"tables":'"$ALL"',"personal_tables":{"personal.profile":[true,true],"personal.settings":[true,false]}}' 1)
[[ "$o" == "rc=4 FAIL"*"3/4"*"personal.settings"* ]] && pass "8. EXPECT_RLS=1 with a personal table lacking FORCE is exit 4 and names it" || fail "8. personal unforced: $o"
o=$(verdict '{"role":"hub","superuser":false,"bypassrls":false,"migration_0014":true,"liftable":[],"tables":'"$ALL"',"personal_tables":{"personal.profile":[true,true]}}' 1 1)
[[ "$o" == "rc=0 OK"*"3/3"* ]] && pass "8. CONTROL: every tenant and personal table forced: exit 0, counts both" || fail "8. personal forced: $o"
o=$(verdict '{"role":"hub","superuser":false,"bypassrls":false,"migration_0014":true,"tables":{},"personal_tables":{"personal.profile":[true,true]}}' 1)
[[ "$o" == "rc=4 FAIL"* ]] && pass "8. personal tables alone do not stand in for the tenant tables (exit 4)" || fail "8. no tenant tables: $o"
sql8=$(SNIPPET=spl_db_rls_sql in_orc 2>&1)
grep -q "'personal_tables'" <<<"$sql8" && grep -q "owner of personal." <<<"$sql8" && pass "8. SQL reads the personal tables and their owners" || fail "8. SQL lacks personal"
grep -q "p.proname IN ('due_receipts', 'delete_my_receipts')" <<<"$sql8" && pass "8. SQL allow-lists the two realm definers by exact name" || fail "8. SQL lacks the realm allow-list"

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

# --- 7. definers on real Postgres (spec 100 T5) ---------------------------------------
IMG="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if command -v docker >/dev/null && docker image inspect "$IMG" >/dev/null 2>&1 && command -v psql >/dev/null; then
  PG_CTR="spl-rls-check-tst-$$"
  trap 'docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"' EXIT
  docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=su -e POSTGRES_PASSWORD=su -e POSTGRES_DB=spool \
    -p 127.0.0.1::5432 "$IMG" >/dev/null
  PORT=$(docker port "$PG_CTR" 5432 | sed -n 1p | sed 's/.*://')
  for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U su -d spool -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
  sleep 1
  su_sql() { docker exec -i "$PG_CTR" psql -q -v ON_ERROR_STOP=1 -U su -d spool >/dev/null; }
  su_sql <<'EOF'
CREATE ROLE own LOGIN PASSWORD 'own';
CREATE ROLE rt LOGIN PASSWORD 'rt' NOBYPASSRLS;
CREATE ROLE spool_search_reader NOLOGIN NOBYPASSRLS;
ALTER SCHEMA public OWNER TO own;
GRANT CREATE ON DATABASE spool TO own;
SET ROLE own;
CREATE TABLE spool_schema_migrations (filename text PRIMARY KEY);
CREATE TABLE messages (tenant_id text NOT NULL, msg_id text);
ALTER TABLE messages ENABLE ROW LEVEL SECURITY; ALTER TABLE messages FORCE ROW LEVEL SECURITY;
GRANT SELECT ON messages TO rt, spool_search_reader;
GRANT SELECT ON spool_schema_migrations TO rt;
GRANT CREATE ON SCHEMA public TO spool_search_reader;
SET ROLE spool_search_reader;
CREATE FUNCTION public.spool_search_candidates(q text, cap int) RETURNS SETOF text
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
  AS $$ SELECT msg_id FROM public.messages WHERE tenant_id = current_setting('app.tenant_id', true) LIMIT cap + 1 $$;
REVOKE ALL ON FUNCTION public.spool_search_candidates(text, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.spool_search_candidates(text, int) TO rt;
SET ROLE own;
CREATE FUNCTION public.plain_invoker() RETURNS int LANGUAGE sql AS 'SELECT 1';
CREATE FUNCTION public.definer_revoked() RETURNS int LANGUAGE sql SECURITY DEFINER AS 'SELECT 1';
REVOKE ALL ON FUNCTION public.definer_revoked() FROM PUBLIC;
EOF
  RTDSN="postgres://rt:rt@127.0.0.1:$PORT/spool"
  live() { # -> "rc=<verdict rc> <catalog json> <verdict log>" for the runtime login, EXPECT_NOT_LIFTABLE=1
    local out
    out=$(SNIPPET='j=$(spl_psql_ro "$RTDSN" "$(spl_db_rls_sql)") || { echo "psql: $j"; exit 9; }; echo "$j"; spl_db_rls_verdict "$j" 1 1' in_orc RTDSN="$RTDSN" 2>&1)
    echo "rc=$? $out"
  }
  o=$(live)
  [[ "$o" == "rc=0 "*'"liftable" : []'*"liftable=0"* ]] && pass "7. definers = exactly {spool_search_candidates}: not liftable, liftable=0" || fail "7. allow-listed only: $o"
  [[ "$o" == "rc=0 "* && "$o" != *plain_invoker* && "$o" != *definer_revoked* ]] && pass "7. CONTROL: an INVOKER function and a definer revoked from PUBLIC add no path" || fail "7. control: $o"
  su_sql <<<"SET ROLE own; CREATE FUNCTION public.second_definer() RETURNS int LANGUAGE sql SECURITY DEFINER AS 'SELECT 1';"
  o=$(live)
  [[ "$o" == "rc=5 "*"FAIL"*"SECURITY DEFINER public.second_definer (runs as own)"* ]] && pass "7. a second definer the runtime can EXECUTE: liftable, exit 5, named" || fail "7. second definer: $o"
  su_sql <<<"SET ROLE own; DROP FUNCTION public.second_definer(); CREATE SCHEMA other; CREATE FUNCTION other.spool_search_candidates() RETURNS int LANGUAGE sql SECURITY DEFINER AS 'SELECT 1'; GRANT USAGE ON SCHEMA other TO rt;"
  o=$(live)
  [[ "$o" == "rc=5 "*"other.spool_search_candidates"* ]] && pass "7. the allow-list is schema-exact: other.spool_search_candidates is liftable" || fail "7. other schema: $o"
  # 8. spec 119 (rdb 0168): the two realm definers, each owned by a NOLOGIN role, EXECUTE granted to the runtime
  su_sql <<'EOF'
DROP FUNCTION other.spool_search_candidates();
CREATE ROLE spool_realm_sweeper NOLOGIN NOBYPASSRLS;
CREATE ROLE spool_realm_eraser NOLOGIN NOBYPASSRLS;
CREATE SCHEMA personal AUTHORIZATION own;
GRANT USAGE, CREATE ON SCHEMA personal TO spool_realm_sweeper, spool_realm_eraser;
GRANT USAGE ON SCHEMA personal TO rt;
SET ROLE own;
CREATE TABLE personal.receipt_due (person_id text NOT NULL, workspace_id text NOT NULL);
ALTER TABLE personal.receipt_due ENABLE ROW LEVEL SECURITY;
ALTER TABLE personal.receipt_due FORCE ROW LEVEL SECURITY;
SET ROLE spool_realm_sweeper;
CREATE FUNCTION personal.due_receipts(now timestamptz) RETURNS TABLE (person_id text, workspace_id text)
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS 'SELECT NULL::text, NULL::text WHERE false';
REVOKE ALL ON FUNCTION personal.due_receipts(timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION personal.due_receipts(timestamptz) TO rt;
SET ROLE spool_realm_eraser;
CREATE FUNCTION personal.delete_my_receipts(workspace_id text) RETURNS int
  LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS 'SELECT 0';
REVOKE ALL ON FUNCTION personal.delete_my_receipts(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION personal.delete_my_receipts(text) TO rt;
EOF
  o=$(live)
  [[ "$o" == "rc=0 "*'"personal.receipt_due" : [true, true]'*"liftable=0"* ]] && pass "8. the two realm definers are allow-listed and personal.receipt_due counts as forced: exit 0" || fail "8. realm allow-list: $o"
  su_sql <<<"SET ROLE spool_realm_eraser; CREATE FUNCTION personal.delete_all_receipts() RETURNS int LANGUAGE sql SECURITY DEFINER AS 'SELECT 0';"
  o=$(live)
  [[ "$o" == "rc=5 "*"FAIL"*"SECURITY DEFINER personal.delete_all_receipts (runs as spool_realm_eraser)"* ]] && pass "8. CONTROL: an unlisted definer in personal is liftable, exit 5, named" || fail "8. unlisted personal definer: $o"
  su_sql <<<"DROP FUNCTION personal.delete_all_receipts(); SET ROLE own; CREATE FUNCTION other.due_receipts() RETURNS int LANGUAGE sql SECURITY DEFINER AS 'SELECT 1';"
  o=$(live)
  [[ "$o" == "rc=5 "*"other.due_receipts"* ]] && pass "8. CONTROL: the realm allow-list is schema-exact: other.due_receipts is liftable" || fail "8. other.due_receipts: $o"
  su_sql <<<"DROP FUNCTION other.due_receipts(); ALTER TABLE personal.receipt_due OWNER TO rt;"
  o=$(live)
  [[ "$o" == "rc=5 "*"owner of personal.receipt_due"* ]] && pass "8. owning a personal table is a lift path, exit 5, named" || fail "8. personal owner: $o"
else
  echo "SKIP: 7. no cached $IMG image or no psql: real-Postgres leg not run"
fi

(( fails == 0 )) && echo "OK spl-db-rls-check: all checks passed" || { echo "FAIL spl-db-rls-check: $fails check(s)"; exit 1; }
