#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_db_restore_drill (SPL-2310), offline: docker, gcloud and the
# spool migrate are stubs, the migrations dir is a fixture.
#   1. ENV=prd (and no ENV) is refused before any cloud call
#   2. an EMPTY dump (0 bytes) is exit 5, a CORRUPT one (not gzip) exit 4,
#      and neither starts a container
#   3. the schema ledger: an applied file whose sha256 changed is exit 8, an
#      empty ledger is exit 8, a file still pending after the migrate is
#      exit 8; a row naming no repo file (a rename) is a WARN, not a failure.
#      CONTROL: a ledger that matches the repo passes
#   4. the migrate: `spool migrate` runs against the restored container's
#      bridge address with the repo migrations dir; its failure is exit 9
#   5. sanity: a core table missing or empty is exit 5 (CONTROL: rows pass)
#   6. CONTROL end to end: a good dump passes and prints the timing line
#   7. a schema mismatch end to end fails the drill
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# the fixture rdb tree: two migration files
mkdir -p "$T/mig"
printf 'CREATE TABLE tenants (id int);\n' >"$T/mig/0001_tenants.sql"
printf 'CREATE TABLE messages (id int);\n' >"$T/mig/0002_messages.sql"
sha() { sha256sum "$T/mig/$1" | cut -d' ' -f1; }
GOOD="0001_tenants.sql $(sha 0001_tenants.sql)
0002_messages.sql $(sha 0002_messages.sql)"
ONE="0001_tenants.sql $(sha 0001_tenants.sql)"

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" STUB_LOG="$T/calls.log" ENV="${ENV_-dev}" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}

# docker: exec answers the ledger from $STUB_LEDGER before the migrate and
# from $STUB_LEDGER_AFTER once the migrate stub has run; inspect gives an ip
DOCKER='docker(){ echo "docker $*" >>"$STUB_LOG"; case "$1" in
    inspect) echo 172.17.0.7 ;;
    exec) if [[ -f "$STUB_LOG.migrated" ]]; then printf "%s\n" "${STUB_LEDGER_AFTER-$STUB_LEDGER}"; else printf "%s\n" "$STUB_LEDGER"; fi ;;
  esac; };'
cat >"$T/spool" <<'STUB'
#!/bin/sh
echo "spool $*" >>"$STUB_LOG"
touch "$STUB_LOG.migrated"
[ "${STUB_MIGRATE_RC:-0}" = 0 ] || { echo "spool: apply 0002_messages.sql: boom" >&2; exit 1; }
echo "skipped 0001_tenants.sql (already applied)"
echo "applied 0002_messages.sql"
STUB
chmod +x "$T/spool"
CHECK_ENV=(SPL_RESTORE_DRILL_BIN="$T/spool" SPL_RESTORE_DRILL_MIGDIR="$T/mig" SPL_RESTORE_DRILL_STATE="$T/st")
reset() { rm -f "$T/calls.log" "$T/calls.log.migrated" "$T"/st.*; : >"$T/calls.log"; }

# --- 1. dev only ------------------------------------------------------------------
for e in prd ""; do
  reset
  o=$(ENV_="$e" SNIPPET="$DOCKER do_spl_db_restore_drill" in_orc 2>&1) && fail "ENV=$e was accepted: $o" ||
    { grep -q 'dev only' <<<"$o" && [[ ! -s "$T/calls.log" ]] && pass "ENV=${e:-<unset>} is refused before any call" ||
      fail "ENV=$e refusal: $o"; }
done

# --- 2. empty and corrupt dumps ---------------------------------------------------
reset
: >"$T/empty.sql.gz"
o=$(SNIPPET="$DOCKER spl_db_restore_drill_file $T/empty.sql.gz $T/spool $T/mig" in_orc 2>&1); rc=$?
(( rc == 5 )) && grep -q 'empty' <<<"$o" && ! grep -q '^docker run' "$T/calls.log" &&
  pass "an empty dump is exit 5 and starts no container" || fail "empty dump: rc=$rc $o"
reset
printf 'this is not gzip\n' >"$T/bad.sql.gz"
o=$(SNIPPET="$DOCKER spl_db_restore_drill_file $T/bad.sql.gz $T/spool $T/mig" in_orc 2>&1); rc=$?
(( rc == 4 )) && grep -q 'not gzip' <<<"$o" && ! grep -q '^docker run' "$T/calls.log" &&
  pass "a corrupt dump is exit 4 and starts no container" || fail "corrupt dump: rc=$rc $o"

# --- 3. the schema ledger ---------------------------------------------------------
o=$(SNIPPET='spl_db_restore_drill_ledger "$L" "'"$T/mig"'" before' in_orc L="$GOOD" 2>&1); rc=$?
(( rc == 0 )) && grep -q 'head=0002_messages.sql repo_head=0002_messages.sql applied=2 pending=0' <<<"$o" &&
  pass "CONTROL: a ledger that matches the repo passes and names the head" || fail "good ledger: rc=$rc $o"
o=$(SNIPPET='spl_db_restore_drill_ledger "$L" "'"$T/mig"'" before' in_orc L="0001_tenants.sql deadbeef" 2>&1); rc=$?
(( rc == 8 )) && grep -q 'changed since: 0001_tenants.sql' <<<"$o" &&
  pass "an applied file whose sha256 changed is a schema mismatch (exit 8)" || fail "changed sha: rc=$rc $o"
o=$(SNIPPET='spl_db_restore_drill_ledger "" "'"$T/mig"'" before' in_orc 2>&1); rc=$?
(( rc == 8 )) && pass "an empty ledger is exit 8" || fail "empty ledger: rc=$rc $o"
o=$(SNIPPET='spl_db_restore_drill_ledger "$L" "'"$T/mig"'" before' in_orc L="$ONE" 2>&1); rc=$?
(( rc == 0 )) && grep -q 'pending=1' <<<"$o" && pass "a file pending BEFORE the migrate is reported, not failed" ||
  fail "pending before: rc=$rc $o"
o=$(SNIPPET='spl_db_restore_drill_ledger "$L" "'"$T/mig"'" after' in_orc L="$ONE" 2>&1); rc=$?
(( rc == 8 )) && grep -q 'still not applied: 0002_messages.sql' <<<"$o" &&
  pass "a file still pending AFTER the migrate is exit 8" || fail "pending after: rc=$rc $o"
o=$(SNIPPET='spl_db_restore_drill_ledger "$L" "'"$T/mig"'" before' in_orc L="$GOOD
0000_renamed_away.sql abc" 2>&1); rc=$?
(( rc == 0 )) && grep -q 'WARN .*name no repo file.*0000_renamed_away.sql' <<<"$o" &&
  pass "a ledger row naming no repo file (a rename) is a WARN, not a failure" || fail "renamed row: rc=$rc $o"

# --- 4. the migrate hook ----------------------------------------------------------
reset
o=$(SNIPPET="$DOCKER spl_db_restore_drill_check con1" in_orc "${CHECK_ENV[@]}" STUB_LEDGER="$ONE" STUB_LEDGER_AFTER="$GOOD" 2>&1); rc=$?
(( rc == 0 )) && grep -qx "spool migrate --db postgres://postgres:restorecheck@172.17.0.7:5432/restorecheck?sslmode=disable --sql-dir $T/mig" "$T/calls.log" &&
  grep -q 'migrate: 1 applied, 1 already there' <<<"$o" &&
  pass "CONTROL: spool migrate runs on the container's bridge address with the repo dir, then the head matches" ||
  fail "migrate hook: rc=$rc $o $(cat "$T/calls.log")"
reset
o=$(SNIPPET="$DOCKER spl_db_restore_drill_check con1" in_orc "${CHECK_ENV[@]}" STUB_LEDGER="$ONE" STUB_MIGRATE_RC=1 2>&1); rc=$?
(( rc == 9 )) && grep -q 'FAIL.*boom' <<<"$o" && pass "a failed migrate is exit 9 and shows its error" ||
  fail "failed migrate: rc=$rc $o"
reset
o=$(SNIPPET="$DOCKER spl_db_restore_drill_check con1" in_orc "${CHECK_ENV[@]}" STUB_LEDGER="0001_tenants.sql deadbeef" 2>&1); rc=$?
(( rc == 8 )) && ! grep -q '^spool' "$T/calls.log" && pass "a schema mismatch stops before the migrate" ||
  fail "mismatch before migrate: rc=$rc $o"

# --- 5. sanity --------------------------------------------------------------------
printf 'messages 4\ntenants 2\nother 0\n' >"$T/ok.counts"
printf 'messages 0\ntenants 2\n' >"$T/empty.counts"
printf 'tenants 2\n' >"$T/missing.counts"
o=$(SNIPPET="spl_db_restore_drill_sanity $T/ok.counts" in_orc 2>&1) &&
  grep -q '3 table(s), 6 row(s)' <<<"$o" && pass "CONTROL: core tables with rows pass" || fail "sanity ok: $o"
o=$(SNIPPET="spl_db_restore_drill_sanity $T/empty.counts" in_orc 2>&1); rc=$?
(( rc == 5 )) && grep -q 'messages holds no row' <<<"$o" && pass "an empty core table is exit 5" || fail "sanity empty: rc=$rc $o"
o=$(SNIPPET="spl_db_restore_drill_sanity $T/missing.counts" in_orc 2>&1); rc=$?
(( rc == 5 )) && grep -q 'messages is missing' <<<"$o" && pass "a missing core table is exit 5" || fail "sanity missing: rc=$rc $o"

# --- 6/7. end to end on a dump (the container is the restore_counts stub) ---------
COUNTS='spl_db_backup_restore_counts(){ echo "counts $1" >>"$STUB_LOG"; printf "messages 4\ntenants 2\n"; "$SPL_RESTORE_CHECK" con1 >&2; };'
printf 'SELECT 1;\n' | gzip >"$T/good.sql.gz"
reset
o=$(SNIPPET="$DOCKER $COUNTS spl_db_restore_drill_file $T/good.sql.gz $T/spool $T/mig" in_orc STUB_LEDGER="$ONE" STUB_LEDGER_AFTER="$GOOD" 2>&1); rc=$?
(( rc == 0 )) && grep -Eq '^restore_drill env=dev rc=0 download_s=- restore_s=[0-9]+ migrate_s=[0-9]+ total_s=[0-9]+$' <<<"$o" &&
  pass "CONTROL: a good dump passes end to end and prints the timing line" || fail "good e2e: rc=$rc $o"
printf 'SELECT 1;\n' | gzip >"$T/good.sql.gz"
reset
o=$(SNIPPET="$DOCKER $COUNTS spl_db_restore_drill_file $T/good.sql.gz $T/spool $T/mig" in_orc STUB_LEDGER="0002_messages.sql 00ff" 2>&1); rc=$?
(( rc == 8 )) && grep -q '^restore_drill env=dev rc=8 ' <<<"$o" && pass "a schema mismatch fails the drill end to end (exit 8)" ||
  fail "mismatch e2e: rc=$rc $o"


# --- 8. the group roles, read from the migration files (SPL-3173) -----------------
mkdir -p "$T/rmig" "$T/rbad"
cat >"$T/rmig/0001_a.sql" <<'SQL'
-- CREATE ROLE in_a_comment LOGIN is not read
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'spool_one') THEN
    CREATE ROLE spool_one NOLOGIN NOBYPASSRLS;
  END IF;
END $$;
SQL
cat >"$T/rmig/0002_b.sql" <<'SQL'
DO $$ DECLARE r text; BEGIN
  FOREACH r IN ARRAY ARRAY['spool_two', 'spool_three'] LOOP
    EXECUTE format('CREATE ROLE %I NOLOGIN NOBYPASSRLS', r);
  END LOOP;
END $$;
CREATE ROLE spool_four NOLOGIN;
SQL
printf 'CREATE ROLE spool_login LOGIN;\n' >"$T/rbad/0001_x.sql"
o=$(SNIPPET="spl_db_restore_drill_group_roles $T/rmig" in_orc 2>&1); rc=$?
(( rc == 0 )) && [[ "$o" == "spool_four NOLOGIN
spool_one NOLOGIN NOBYPASSRLS
spool_three NOLOGIN NOBYPASSRLS
spool_two NOLOGIN NOBYPASSRLS" ]] &&
  pass "CONTROL: the group roles are read from the migrations: literal, the ARRAY a %I loops over, comments skipped" ||
  fail "group roles: rc=$rc [$o]"
o=$(SNIPPET="spl_db_restore_drill_group_roles $T/rbad" in_orc 2>&1); rc=$?
(( rc == 1 )) && grep -q '^UNREADABLE 0001_x.sql: CREATE ROLE spool_login LOGIN' <<<"$o" &&
  pass "a CREATE ROLE form the reader does not know is exit 1, never a role silently skipped" || fail "unreadable form: rc=$rc [$o]"
o=$(SNIPPET="spl_db_restore_drill_group_roles $APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" in_orc 2>&1); rc=$?
(( rc == 0 )) && grep -qx 'spool_channel_scoped NOLOGIN NOBYPASSRLS' <<<"$o" && grep -qx 'spool_search_reader NOLOGIN NOBYPASSRLS' <<<"$o" &&
  grep -qx 'spool_realm_eraser NOLOGIN NOBYPASSRLS' <<<"$o" && grep -qx 'spool_public_export NOLOGIN' <<<"$o" &&
  pass "the repo's migrations read clean and name spool_channel_scoped (rdb 0197), among $(wc -l <<<"$o")" ||
  fail "repo group roles: rc=$rc [$o]"

# --- 9. the roles hook runs before the restore ------------------------------------
printf 'SELECT 1;\n' | gzip >"$T/good.sql.gz"
reset
PREPC='spl_db_backup_restore_counts(){ echo "prep=${SPL_RESTORE_PREP:-}" >>"$STUB_LOG"; return 1; };'
SNIPPET="$DOCKER $PREPC spl_db_restore_drill_file $T/good.sql.gz $T/spool $T/mig" in_orc >/dev/null 2>&1
grep -qx 'prep=spl_db_restore_drill_roles' "$T/calls.log" &&
  pass "the drill hands the restore its roles hook (SPL_RESTORE_PREP)" || fail "prep wiring: $(cat "$T/calls.log")"
reset
RDOCK='docker(){ echo "docker $*" >>"$STUB_LOG"; [[ "$1" == exec ]] && cat >>"$STUB_LOG"; return 0; };'
o=$(SNIPPET="$RDOCK spl_db_restore_drill_roles con1" in_orc SPL_RESTORE_DRILL_MIGDIR="$T/rmig" 2>&1); rc=$?
(( rc == 0 )) && grep -q '4 group role(s) before the restore: spool_four,spool_one,spool_three,spool_two' <<<"$o" &&
  grep -qF "SELECT format('CREATE ROLE %I NOLOGIN NOBYPASSRLS', 'spool_two') WHERE NOT EXISTS" "$T/calls.log" &&
  grep -q '^docker exec -i con1 psql .*ON_ERROR_STOP=1' "$T/calls.log" &&
  pass "the roles hook creates each role idempotently in the container" || fail "roles hook: rc=$rc $o $(cat "$T/calls.log")"
reset
o=$(SNIPPET="$RDOCK spl_db_restore_drill_roles con1" in_orc SPL_RESTORE_DRILL_MIGDIR="$T/rbad" 2>&1); rc=$?
(( rc == 1 )) && grep -q 'FAIL dev roles: 0001_x.sql' <<<"$o" && ! grep -q '^docker' "$T/calls.log" &&
  pass "an unreadable role form fails the hook before any container call" || fail "roles hook bad: rc=$rc $o"

# --- 10. on real Postgres: a dump that grants to a role, a pending migration ------
# that names it (wf 49 run 40067941157, rdb 0197 + 0219). Red on the code
# before SPL-3173: `role "spool_x" does not exist`, exit 9.
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1 || ! command -v psql >/dev/null; then
  echo "SKIP: no cached $PG_IMAGE image or no psql; the real-Postgres part is not run"
else
  mkdir -p "$T/pmig"
  cat >"$T/pmig/0001_base.sql" <<'SQL'
CREATE TABLE tenants (id int);
CREATE TABLE messages (id int);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'spool_x') THEN
    CREATE ROLE spool_x NOLOGIN NOBYPASSRLS;
  END IF;
END $$;
GRANT SELECT ON messages TO spool_x;
SQL
  printf 'CREATE POLICY x_scope ON messages AS RESTRICTIVE TO spool_x USING (true);\n' >"$T/pmig/0002_names_x.sql"
  # the dump: 0001 applied, its GRANT to spool_x, and no role (a dump has none)
  { printf 'CREATE TABLE spool_schema_migrations (filename text PRIMARY KEY, sha256 text);\n'
    printf "INSERT INTO spool_schema_migrations VALUES ('0001_base.sql', '%s');\n" "$(sha256sum "$T/pmig/0001_base.sql" | cut -d' ' -f1)"
    printf 'CREATE TABLE tenants (id int);\nCREATE TABLE messages (id int);\n'
    printf 'INSERT INTO tenants VALUES (1);\nINSERT INTO messages VALUES (1), (2);\n'
    printf 'GRANT SELECT ON messages TO spool_x;\n'
  } | gzip >"$T/pg.sql.gz"
  # the migrate: each repo file the ledger lacks, applied with ON_ERROR_STOP
  cat >"$T/pgspool" <<'STUB'
#!/usr/bin/env bash
db="$3" dir="$5"
for f in "$dir"/*.sql; do
  b="$(basename "$f")"
  [[ -n "$(psql "$db" -XAtc "SELECT 1 FROM spool_schema_migrations WHERE filename = '$b'")" ]] && { echo "skipped $b"; continue; }
  psql "$db" -X -q -v ON_ERROR_STOP=1 -1 -f "$f" || { echo "spool: apply $b: failed" >&2; exit 1; }
  psql "$db" -XAtqc "INSERT INTO spool_schema_migrations VALUES ('$b', '$(sha256sum "$f" | cut -d' ' -f1)')"
  echo "applied $b"
done
STUB
  chmod +x "$T/pgspool"
  o=$(SNIPPET="spl_db_restore_drill_file $T/pg.sql.gz $T/pgspool $T/pmig" in_orc SPL_RESTORE_IMAGE="$PG_IMAGE" 2>&1); rc=$?
  (( rc == 0 )) && grep -q 'roles: 1 group role(s) before the restore: spool_x' <<<"$o" &&
    grep -q 'migrate: 1 applied, 1 already there' <<<"$o" && ! grep -q 'does not exist' "$T/pg.restore.log" &&
    pass "real Postgres: the dump's GRANT to spool_x restores and the pending migration naming it applies" ||
    fail "real Postgres: rc=$rc $o $(cat "$T/pg.restore.log" "$T/pg.sql.drill.migrate.log" 2>/dev/null)"
fi

(( fails == 0 )) && echo "OK spl-db-restore-drill: all checks passed" || { echo "FAIL spl-db-restore-drill: $fails check(s)"; exit 1; }
