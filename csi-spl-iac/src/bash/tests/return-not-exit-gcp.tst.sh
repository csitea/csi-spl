#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: two sourced gcp actions RETURN on their error branch, never exit
# (refactor r6-03, round 3 row 13). ./run sources an action and calls it in its
# own shell: an `exit 1` inside the function kills that shell and skips the
# caller's error report. Each case sources the action in a subshell, drives the
# branch, then runs one more line in the same shell:
#   1. do_gcp_import_to_cloudsql, an unsupported dump format (.bak) -> rc 1,
#      and the caller's next line runs
#   2. do_gcp_export_dns_settings, a missing admin key file -> rc 1, and the
#      caller's next line runs
# Red control: put `exit 1` back on either branch -> its "next line runs"
# assertion fails (the subshell is gone before it prints).
# gcloud and psql are stubs on PATH. No network, no GCP, no key.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
IMPORT="$PROJ_ROOT/src/bash/run/gcp-import-to-cloudsql.func.sh"
DNS="$PROJ_ROOT/src/bash/run/gcp-export-dns-settings.func.sh"
RUN_SH="$PROJ_ROOT/src/bash/run/run.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fails=0

require_action "$IMPORT"
require_action "$DNS"
QUIT_ON=$(sed -n '/^quit_on(){/,/^}/p' "$RUN_SH")
[[ "$QUIT_ON" == *'rv=$?'* ]] && pass "run.sh's real quit_on is extracted" || { echo "FAIL: no quit_on in $RUN_SH"; exit 1; }

stub gcloud 'echo "$*" >>"$GC_CALLS"; exit 0'
stub psql 'cat >/dev/null 2>&1 || true; exit 0'

# the shared stubs of the run framework, then the action, in one bash -c
COMMON='do_log(){ echo "$*"; }; do_gcp_account(){ echo sa@p.iam.gserviceaccount.com; }
  do_gcp_log_identity(){ :; }; do_gcp_isolated_active_account(){ echo sa@p.iam.gserviceaccount.com; }
  do_resolve_oap(){ :; }; do_require_var(){ :; }; do_require_run_vars(){ :; }
  eval "$QUIT_ON"'

# --- 1. import: unsupported file format ---------------------------------------
mkdir -p "$T/app/o-a-cnf/o-a"
echo '{"env":{"rdb":{"cloud_sql_instance":"i","app_db":"d","pg-host":"h"}}}' >"$T/app/o-a-cnf/o-a/dev.env.json"
echo '{}' >"$T/key.json"
: >"$T/calls.log"
env PATH="$T/bin:$PATH" GC_CALLS="$T/calls.log" QUIT_ON="$QUIT_ON" COMMON="$COMMON" ACTION="$IMPORT" \
  ORG=o APP=a ENV=dev APP_PATH="$T/app" SERVICE_KEY_FILE="$T/key.json" GS_UTIL_URI=gs://b/dump.bak \
  bash -c 'eval "$COMMON"; source "$ACTION"
    do_gcp_import_to_cloudsql; rc=$?
    echo "NEXT-LINE-RAN rc=$rc"' >"$T/out.log" 2>&1
grep -q "Unsupported file format: gs://b/dump.bak" "$T/out.log" \
  && pass "import: the .bak dump reaches the unsupported-format branch" || fail "import branch: $(cat "$T/out.log")"
grep -qx "NEXT-LINE-RAN rc=1" "$T/out.log" \
  && pass "import: unsupported format -> rc 1 and the caller's next line runs" || fail "import next line: $(cat "$T/out.log")"

# --- 2. dns export: missing admin key file ------------------------------------
mkdir -p "$T/home"
: >"$T/calls.log"
env PATH="$T/bin:$PATH" GC_CALLS="$T/calls.log" QUIT_ON="$QUIT_ON" COMMON="$COMMON" ACTION="$DNS" \
  HOME="$T/home" ORG=o APP=a ENV=dev PROJ_PATH="$T" \
  bash -c 'eval "$COMMON"; source "$ACTION"
    do_gcp_export_dns_settings; rc=$?
    echo "NEXT-LINE-RAN rc=$rc"' >"$T/out.log" 2>&1
grep -q "FATAL Error: Admin key file not found at $T/home/.gcp/.o/key-o-a-dev.json" "$T/out.log" \
  && pass "dns: a missing key file reaches its FATAL branch" || fail "dns branch: $(cat "$T/out.log")"
grep -qx "NEXT-LINE-RAN rc=1" "$T/out.log" \
  && pass "dns: missing key file -> rc 1 and the caller's next line runs" || fail "dns next line: $(cat "$T/out.log")"
[[ ! -s "$T/calls.log" ]] \
  && pass "dns: no gcloud call after the missing key" || fail "dns calls: $(cat "$T/calls.log")"

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
