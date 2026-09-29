#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_db_restore, offline (no cloud call):
#   1. the target guard: an unknown target, a throwaway name that is not
#      spool_restore_*, and prd's own database without ALLOW_PRD_RESTORE=1
#      are refused. CONTROL: the same prd call WITH the flag passes the guard
#   2. DRY_RUN defaults to 1: the plan resolves the newest dump and its age
#      (the RPO) and creates, imports and drops nothing
#   3. a BACKUP_URI outside the env's 045 bucket is refused
#   4. CONTROL: DRY_RUN=0 TARGET=database:<x> creates the throwaway database,
#      imports AS THE SCHEMA OWNER (the default import user cannot run the
#      dump's ALTER DEFAULT PRIVILEGES FOR ROLE <owner>) and drops it again
#   5. TARGET=env refuses a database that already holds tables, before any
#      import: a restore never merges into live data
#   6. every gcloud call is pinned with --account
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
ACTION="$PROJ_ROOT/src/bash/run/spl-db-restore.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mkdir -p "$T/stub"
for b in docker psql; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
  chmod +x "$T/stub/$b"
done
cat >"$T/stub/gcloud" <<'STUB'
#!/bin/sh
echo "gcloud $*" >>"$STUB_LOG"
case "$*" in
  *"print-access-token"*) head -c 1024 /dev/zero | tr '\0' 'x'; echo; exit 0 ;;
  *"storage ls"*)         echo "gs://$STUB_BUCKET/$ENV/spool-20260101T000000Z.sql.gz"
                          echo "gs://$STUB_BUCKET/$ENV/spool-20260102T000000Z.sql.gz"; exit 0 ;;
  *"objects describe"*)   echo "2026-01-02T00:00:00+00:00"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$T/stub/gcloud"

PIN='do_gcp_pin_account(){ export GCP_ACCOUNT=tester@example.com; };'
# the proxy is the cloud; here it answers the two reads the action makes
PROXY='spl_via_proxy(){ case "$1" in _spl_db_restore_table_count) echo "${STUB_TABLES:-0}" ;; *) printf "messages 5\ntenants 2\n" ;; esac; };'

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" STUB_LOG="$T/calls.log" \
    STUB_BUCKET="csi-spl-${ENV_:-dev}-db-backups" STUB_TABLES="${STUB_TABLES:-0}" \
    PATH="$T/stub:$PATH" ENV="${ENV_:-dev}" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}

# --- 1. the target guard --------------------------------------------------------
for t in bogus database:spool database:prod_copy 'database:spool_restore_X'; do
  o=$(SNIPPET="$PIN do_spl_db_restore" in_orc TARGET="$t" 2>&1) && fail "TARGET=$t was accepted: $o" ||
    pass "TARGET=$t is refused"
done
o=$(ENV_=prd SNIPPET="$PIN do_spl_db_restore" in_orc TARGET=env SPL_STATE_DIR="$T/state-prd" 2>&1) &&
  fail "prd TARGET=env without the flag was accepted: $o" || pass "prd TARGET=env without ALLOW_PRD_RESTORE=1 is refused"
grep -q 'ALLOW_PRD_RESTORE=1' <<<"$o" && pass "the refusal names the flag" || fail "refusal text: $o"
o=$(ENV_=prd SNIPPET="$PIN do_spl_db_restore" in_orc TARGET=env ALLOW_PRD_RESTORE=1 SPL_STATE_DIR="$T/state-prd" 2>&1) &&
  pass "CONTROL: prd TARGET=env WITH the flag passes the guard (dry run)" || fail "CONTROL prd with flag: $o"

# --- 2. DRY_RUN is the default ----------------------------------------------------
: >"$T/calls.log"
o=$(SNIPPET="$PIN do_spl_db_restore" in_orc 2>&1); rc=$?
(( rc == 0 )) && pass "the default run succeeds as a plan" || fail "dry run rc=$rc: $o"
grep -q 'uri=gs://csi-spl-dev-db-backups/dev/spool-20260102T000000Z.sql.gz target=local rpo_s=[0-9]' <<<"$o" &&
  pass "latest = the newest object, and the plan prints its age (RPO)" || fail "plan line: $o"
grep -qE 'sql import|databases (create|delete)|storage cp' "$T/calls.log" &&
  fail "DRY_RUN=1 touched something: $(cat "$T/calls.log")" || pass "DRY_RUN=1: no create, import, drop or download"

# --- 3. a foreign uri is refused ----------------------------------------------------
o=$(SNIPPET="$PIN do_spl_db_restore" in_orc BACKUP_URI=gs://someone-else/x.sql.gz 2>&1) &&
  fail "a foreign BACKUP_URI was accepted: $o" || pass "a BACKUP_URI outside the 045 bucket is refused"

# --- 4. CONTROL: the throwaway database round trip ---------------------------------
: >"$T/calls.log"
o=$(SNIPPET="$PIN $PROXY do_spl_db_restore" in_orc DRY_RUN=0 TARGET=database:spool_restore_t 2>&1); rc=$?
(( rc == 0 )) && pass "CONTROL: DRY_RUN=0 into a throwaway database succeeds" || fail "round trip rc=$rc: $o"
grep -q 'databases create spool_restore_t' "$T/calls.log" && pass "it creates the throwaway database" ||
  fail "no create: $(cat "$T/calls.log")"
grep -q 'sql import sql .*--database=spool_restore_t --user=spool_hub ' "$T/calls.log" &&
  pass "it imports into it AS THE SCHEMA OWNER" || fail "import line: $(grep import "$T/calls.log")"
grep -q 'databases delete spool_restore_t' "$T/calls.log" && pass "it drops the throwaway afterwards" ||
  fail "no drop: $(cat "$T/calls.log")"
grep -q 'rto_s=[0-9]' <<<"$o" && pass "the run prints its RTO" || fail "no rto: $o"
: >"$T/calls.log"
SNIPPET="$PIN $PROXY do_spl_db_restore" in_orc DRY_RUN=0 TARGET=database:spool_restore_t KEEP=1 >/dev/null 2>&1
grep -q 'databases delete' "$T/calls.log" && fail "KEEP=1 still dropped it" || pass "KEEP=1 keeps the throwaway"

# --- 5. TARGET=env never merges into a populated database -----------------------------
: >"$T/calls.log"
o=$(STUB_TABLES=36 SNIPPET="$PIN $PROXY do_spl_db_restore" in_orc DRY_RUN=0 TARGET=env 2>&1) &&
  fail "a populated env database was restored into: $o" || pass "TARGET=env with 36 tables present is refused"
grep -q 'sql import' "$T/calls.log" && fail "it imported anyway" || pass "the refusal comes before any import"
: >"$T/calls.log"
STUB_TABLES=0 SNIPPET="$PIN $PROXY do_spl_db_restore" in_orc DRY_RUN=0 TARGET=env >/dev/null 2>&1
grep -q 'sql import sql .*--database=spool ' "$T/calls.log" &&
  pass "CONTROL: an EMPTY env database is imported into" || fail "CONTROL empty env: $(cat "$T/calls.log")"

# --- 6. every gcloud call carries --account -------------------------------------------
bad=$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$ACTION" |
      grep -E '(^|[^_[:alnum:]])gcloud[[:space:]]' |
      grep -vE '^[[:space:]]*#' | grep -v 'do_require_bin' | grep -v -- '--account')
[[ -z "$bad" ]] && pass "every gcloud invocation in the action carries --account" || fail "unpinned gcloud: $bad"

(( fails == 0 )) && echo "OK spl-db-restore: all checks passed" || { echo "FAIL spl-db-restore: $fails check(s)"; exit 1; }
