#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_check_sql_portable (spec 076 T006).
#   1. a clean standard-SQL fixture passes (exit 0, hits=0)
#   2. a planted vendor construct fails and names file:line
#   3. the same tokens inside comments are not hits
#   4. a missing directory refuses (exit 2); it does not pass
#   5. a directory with no .sql refuses (exit 2)
#   6. the default dirs are the real migration trees, and both must exist
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

do_log() { printf '%s\n' "$*"; }
# shellcheck source=../run/check-sql-portable.func.sh
. "$PROJ_ROOT/src/bash/run/check-sql-portable.func.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# run_scan <tree> [dirs]
# Unset SQL_PORTABLE_DIRS when no second argument is given, so the default
# migration dirs are what the action scans.
run_scan() {
  rc=0
  if [[ $# -ge 2 ]]; then
    out="$(SQL_PORTABLE_TREE="$1" SQL_PORTABLE_DIRS="$2" do_check_sql_portable 2>&1)" || rc=$?
  else
    out="$(SQL_PORTABLE_TREE="$1" do_check_sql_portable 2>&1)" || rc=$?
  fi
}

mkdir -p "$T/mig"
cat >"$T/mig/0001_clean.sql" <<'SQL'
-- standard PostgreSQL, including a contrib extension that ships with it
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE TABLE messages (
    id bigint PRIMARY KEY,
    body text NOT NULL
);
CREATE INDEX messages_body ON messages USING gin (to_tsvector('simple', body));
SQL

# 1. clean
run_scan "$T" mig
{ [[ "$rc" -eq 0 ]] \
  && grep -qx 'SQL_PORTABLE n=1 hits=0' <<<"$out" \
  && grep -qx 'SQL_PORTABLE_LIMIT a deny list only catches the tokens it names; it cannot prove absence' <<<"$out" \
  && grep -Fq 'SQL_PORTABLE_DENY cloudsql* google_* alloydb* rds_* rdsadmin* aws_* aurora_*' <<<"$out" \
  && ! grep -E ':[0-9]+:' <<<"$out" >/dev/null; } \
  && pass "1. a clean fixture passes" || fail "1. a clean fixture passes" "rc=$rc $out"

# 2. one planted file, one clean sibling. Each deny-list alternative has a line.
cat >"$T/mig/0100_vendor.sql" <<'SQL'
GRANT cloudsqlsuperuser TO app_user;
CREATE EXTENSION IF NOT EXISTS google_ml_integration;
CREATE EXTENSION aws_s3;
GRANT rds_superuser TO app_user;
SELECT aurora_version();
CREATE EXTENSION alloydb_scann;
SET cloudsql.logical_decoding = on;
GRANT CLOUDSQLADMIN TO app_user;
SELECT 'cloudsqliamuser';
GRANT rdsadmin TO app_user;
CREATE FUNCTION f() RETURNS text LANGUAGE sql AS $$
SELECT '-- cloudsqlreplica';
$$;
SQL
run_scan "$T" mig
ok2=1
expect=(
  "mig/0100_vendor.sql:1: cloudsqlsuperuser"
  "mig/0100_vendor.sql:2: google_ml_integration"
  "mig/0100_vendor.sql:3: aws_s3"
  "mig/0100_vendor.sql:4: rds_superuser"
  "mig/0100_vendor.sql:5: aurora_version"
  "mig/0100_vendor.sql:6: alloydb_scann"
  "mig/0100_vendor.sql:7: cloudsql"
  "mig/0100_vendor.sql:8: cloudsqladmin"
  "mig/0100_vendor.sql:9: cloudsqliamuser"
  "mig/0100_vendor.sql:10: rdsadmin"
  "mig/0100_vendor.sql:12: cloudsqlreplica"
)
for line in "${expect[@]}"; do
  grep -Fxq "$line" <<<"$out" || ok2=0
done
{ [[ "$ok2" -eq 1 && "$rc" -eq 1 ]] \
  && grep -qx 'SQL_PORTABLE n=2 hits=11' <<<"$out" \
  && ! grep -F 'mig/0001_clean.sql:' <<<"$out" >/dev/null; } \
  && pass "2. a planted vendor construct fails with file:line" || fail "2. a planted vendor construct fails with file:line" "rc=$rc $out"

# 3. comments are not constructs: line comment, block comment, function-body comment
cat >"$T/mig/0002_comment.sql" <<'SQL'
-- (cloudsqlsuperuser owns the database). pg_trgm is NOT added.
/* google_ml_integration
   aws_s3
*/
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE FUNCTION g() RETURNS void LANGUAGE sql AS $$
-- cloudsqlobservability is named only in this comment
SELECT 1;
$$;
SQL
rm -f "$T/mig/0100_vendor.sql"
run_scan "$T" mig
{ [[ "$rc" -eq 0 ]] && grep -qx 'SQL_PORTABLE n=2 hits=0' <<<"$out"; } \
  && pass "3. a comment that names a vendor role is not a hit" || fail "3. a comment that names a vendor role is not a hit" "rc=$rc $out"

# 4. missing dir
run_scan "$T" "mig no-such-dir"
{ [[ "$rc" -eq 2 ]] && grep -q 'missing dir no-such-dir' <<<"$out" && grep -q 'proved nothing' <<<"$out"; } \
  && pass "4. a missing directory refuses" || fail "4. a missing directory refuses" "rc=$rc $out"

# 5. no sql
mkdir -p "$T/empty"
run_scan "$T" empty
{ [[ "$rc" -eq 2 ]] && grep -q 'no .sql' <<<"$out"; } \
  && pass "5. a directory with no .sql refuses" || fail "5. a directory with no .sql refuses" "rc=$rc $out"

# 6. default dirs are the two real migration trees
D="$T/repo"
mkdir -p "$D/csi-spl-rdb/src/sql/postgres/spool-hub" \
         "$D/csi-spl-rdb/src/sql/postgres/spool-hub-roles"
echo 'CREATE TABLE t (id int);' >"$D/csi-spl-rdb/src/sql/postgres/spool-hub/0001_ok.sql"
echo 'CREATE ROLE app_runtime;' >"$D/csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-role.sql"
run_scan "$D"
{ [[ "$rc" -eq 0 ]] && grep -qx 'SQL_PORTABLE n=2 hits=0' <<<"$out"; } \
  && pass "6. the default dirs are the two migration trees" || fail "6. the default dirs are the two migration trees" "rc=$rc $out"
rm -rf "$D/csi-spl-rdb/src/sql/postgres/spool-hub-roles"
run_scan "$D"
{ [[ "$rc" -eq 2 ]] && grep -q 'missing dir csi-spl-rdb/src/sql/postgres/spool-hub-roles' <<<"$out"; } \
  && pass "6b. a missing default dir refuses" || fail "6b. a missing default dir refuses" "rc=$rc $out"

echo "=== $((7 - fails))/7 assertions passed"
[[ "$fails" -eq 0 ]]
