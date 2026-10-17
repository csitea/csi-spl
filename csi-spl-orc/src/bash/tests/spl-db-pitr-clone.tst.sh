#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_db_pitr_clone, offline (stubbed gcloud and psql):
#   1. a statement that is not ONE plain SELECT (insert, WITH, a psql \d, a
#      second statement after ';') is refused before any gcloud call, even
#      with DRY_RUN=0; so is a PITR_AT that is not a UTC timestamp
#   2. DRY_RUN=1 is the default: it prints the plan and calls no gcloud at all
#   3. CONTROL: DRY_RUN=0 with a SQL_FILE of two SELECTs makes ONE clone at
#      PITR_AT, reads both through one proxy pointed at the CLONE, each in a
#      READ ONLY transaction, then deletes the clone
#   4. the clone is deleted on every error path: a failed read, a clone call
#      that failed after the instance appeared, and a TERM mid-read
#      (the clone runs --async and the action waits on its operation)
#   5. a clone that cannot be deleted fails the run (rc 6) and names the command
#   6. every gcloud call in the action carries --account
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
ACTION="$PROJ_ROOT/src/bash/run/spl-db-pitr-clone.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mkdir -p "$T/stub"
# gcloud: the clone exists while $T/clone holds its name
cat >"$T/stub/gcloud" <<'STUB'
#!/bin/bash
echo "gcloud $*" >>"$STUB_LOG"
case "$*" in
  *"print-access-token"*) head -c 1024 /dev/zero | tr '\0' 'x'; echo; exit 0 ;;
  "sql instances clone "*)
    echo "$5" >"$STUB_DIR/clone"; echo "https://example.invalid/operations/op-1"; exit 0 ;;
  "sql operations wait "*)
    exit "${STUB_CLONE_RC:-0}" ;;
  "sql instances list "*)
    [[ -s "$STUB_DIR/clone" ]] && cat "$STUB_DIR/clone"; exit 0 ;;
  "sql instances delete "*)
    [[ "${STUB_DELETE_RC:-0}" == 0 ]] || exit 1
    rm -f "$STUB_DIR/clone"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
cat >"$T/stub/psql" <<'STUB'
#!/bin/bash
echo "psql $*" >>"$STUB_LOG"
[[ "${STUB_PSQL:-ok}" == term ]] && { kill -TERM "$PPID"; sleep 1; }
[[ "${STUB_PSQL:-ok}" == ok ]] || exit 3
printf 'n\n1\n'
STUB
chmod +x "$T/stub/gcloud" "$T/stub/psql"

PIN='do_gcp_pin_account(){ export GCP_ACCOUNT=tester@example.com; };'
# the proxy is the cloud: record where it points, hand the reader a DSN
PROXY='spl_via_proxy(){ echo "proxy conn=$SPL_SQL_CONN" >>"$STUB_LOG"; SPL_PROXY_DSN=postgres://u:p@127.0.0.1:1/db "$@"; };'

in_orc() {
  rm -f "$T/clone"; : >"$T/calls.log"
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" STUB_LOG="$T/calls.log" STUB_DIR="$T" \
    PATH="$T/stub:$PATH" PIN="$PIN" PROXY="$PROXY" ENV=dev PITR_AT="${PITR_AT_-2026-10-17T01:59:00Z}" SPL_PITR_DELETE_TRIES=2 SPL_PITR_DELETE_WAIT=0 \
    "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    mkdir -p "$SPL_STATE_DIR"
    eval "$PIN $PROXY do_spl_db_pitr_clone"'
}

# --- 1. only ONE plain SELECT, only a UTC PITR_AT --------------------------------
for q in "insert into fleet_tokens values (1)" "with x as (delete from t returning *) select * from x" \
         '\d fleet_tokens' "select 1; delete from t" "update t set a = 1"; do
  o=$(in_orc DRY_RUN=0 SQL="$q" 2>&1) && fail "accepted: $q" || pass "refused: ${q:0:30}"
  grep -q "gcloud sql" "$T/calls.log" && fail "a refused statement still called gcloud: $q" || :
done
printf 'select 1;\ndelete from t;\n' >"$T/bad.sql"
o=$(in_orc DRY_RUN=0 SQL_FILE="$T/bad.sql" 2>&1) && fail "a SQL_FILE with a DELETE was accepted" ||
  pass "a SQL_FILE holding one non-SELECT is refused whole"
grep -q "gcloud sql" "$T/calls.log" && fail "the refused file still called gcloud" || pass "no gcloud call for a refused statement"
o=$(PITR_AT_='2026-10-17 01:59' in_orc SQL="select 1" 2>&1) && fail "bad PITR_AT accepted" || pass "a PITR_AT that is not YYYY-MM-DDTHH:MM:SSZ is refused"

# --- 2. DRY_RUN=1 is the default ----------------------------------------------------
o=$(in_orc SQL="select count(*) from fleet_tokens" 2>&1); rc=$?
(( rc == 0 )) && grep -qE 'clone=.*-pitr-[0-9]{14} pitr_at=2026-10-17T01:59:00Z statements=1' <<<"$o" &&
  pass "the default run prints the plan" || fail "dry run rc=$rc: $o"
[[ ! -s "$T/calls.log" ]] && pass "DRY_RUN=1 calls no gcloud and no psql" || fail "DRY_RUN=1 called: $(cat "$T/calls.log")"

# --- 3. CONTROL: one clone, two reads, deleted --------------------------------------
printf -- '-- per box\nselect 1 as n;\n\nselect 2\n  as n;\n' >"$T/ok.sql"
o=$(in_orc DRY_RUN=0 SQL_FILE="$T/ok.sql" 2>&1); rc=$?
(( rc == 0 )) && pass "CONTROL: DRY_RUN=0 succeeds" || fail "rc=$rc: $o"
[[ "$(grep -c 'sql instances clone ' "$T/calls.log")" == 1 ]] && pass "exactly ONE clone for two statements" ||
  fail "clone calls: $(grep clone "$T/calls.log")"
grep -q 'sql instances clone [a-z0-9-]* [a-z0-9-]*-pitr-[0-9]\{14\} --point-in-time=2026-10-17T01:59:00Z ' "$T/calls.log" &&
  pass "the clone is taken at PITR_AT under a -pitr-<stamp> name" || fail "clone line: $(grep clone "$T/calls.log")"
grep -q 'sql instances clone .* --async ' "$T/calls.log" && grep -q '^gcloud sql operations wait op-1 --timeout=3600 ' "$T/calls.log" &&
  pass "it clones --async and waits on the operation (gcloud's own wait gives up at ~10 min)" ||
  fail "no async wait: $(grep -E 'clone|wait' "$T/calls.log")"
clone=$(awk '/sql instances clone /{print $6}' "$T/calls.log")
grep -qx "proxy conn=[a-z0-9-]*:[a-z0-9-]*:$clone" "$T/calls.log" && pass "the proxy points at the CLONE, not the live instance" ||
  fail "proxy line: $(grep proxy "$T/calls.log")"
[[ "$(grep -c '^psql .*BEGIN TRANSACTION READ ONLY' "$T/calls.log")" == 2 ]] && grep -q "rls_scope = 'operator'" "$T/calls.log" &&
  pass "each statement runs in a READ ONLY transaction, operator scope" || fail "psql: $(grep psql "$T/calls.log")"
grep -q -- '-- stmt 2' <<<"$o" && pass "the output is split per statement" || fail "output: $o"
grep -q "sql instances delete $clone " "$T/calls.log" && [[ ! -s "$T/clone" ]] && pass "the clone is deleted after the reads" ||
  fail "no delete: $(cat "$T/calls.log")"

# --- 4. the clone is deleted on every error path ------------------------------------
o=$(in_orc DRY_RUN=0 SQL="select 1" STUB_PSQL=fail 2>&1); rc=$?
(( rc != 0 )) && grep -q 'sql instances delete ' "$T/calls.log" && [[ ! -s "$T/clone" ]] &&
  pass "a failed read: the run fails AND the clone is deleted" || fail "failed read rc=$rc: $(cat "$T/calls.log")"
o=$(in_orc DRY_RUN=0 SQL="select 1" STUB_CLONE_RC=1 2>&1); rc=$?
(( rc != 0 )) && grep -q 'sql instances delete ' "$T/calls.log" && [[ ! -s "$T/clone" ]] &&
  pass "a clone operation that failed after the instance appeared: deleted" || fail "clone error rc=$rc: $(cat "$T/calls.log")"
! grep -q '^psql' "$T/calls.log" && pass "a failed clone reads nothing" || fail "read after a failed clone"
o=$(in_orc DRY_RUN=0 SQL="select 1" STUB_PSQL=term 2>&1); rc=$?
(( rc == 130 )) && grep -q 'sql instances delete ' "$T/calls.log" && [[ ! -s "$T/clone" ]] &&
  pass "a TERM mid-read: rc 130 and the clone is deleted" || fail "TERM rc=$rc: $(cat "$T/calls.log")"

# --- 5. an undeletable clone fails the run --------------------------------------------
o=$(in_orc DRY_RUN=0 SQL="select 1" STUB_DELETE_RC=1 2>&1); rc=$?
(( rc == 6 )) && grep -q 'could not delete .* - delete it now: gcloud sql instances delete ' <<<"$o" &&
  pass "an undeletable clone: rc 6 and the exact delete command" || fail "undeletable rc=$rc: $o"
[[ "$(grep -c 'sql instances delete ' "$T/calls.log")" == 2 ]] && pass "it retried SPL_PITR_DELETE_TRIES times" ||
  fail "delete tries: $(grep -c 'sql instances delete ' "$T/calls.log")"

# --- 6. every gcloud call carries --account -------------------------------------------
bad=$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$ACTION" |
      grep -E '(^|[^_[:alnum:]])gcloud[[:space:]]' |
      grep -vE '^[[:space:]]*#' | grep -v 'do_require_bin' | grep -v -- '--account')
[[ -z "$bad" ]] && pass "every gcloud invocation in the action carries --account" || fail "unpinned gcloud: $bad"

echo "fails=$fails"
(( fails == 0 ))
