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

(( fails == 0 )) && echo "OK spl-db-restore-drill: all checks passed" || { echo "FAIL spl-db-restore-drill: $fails check(s)"; exit 1; }
