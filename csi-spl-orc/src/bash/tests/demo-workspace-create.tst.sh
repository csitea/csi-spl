#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_demo_workspace_create (spec 077 T023/T024). The cloud is
#          stubbed: the read (spl_demo_workspace_exists) and the create
#          (do_spl_tenant_create) are shell functions that record their calls.
#   1. ENV must be dev or prd; the id comes from cnf env.demo.workspace
#   2. a workspace that exists: exit 0, created false, NO create call (idempotent)
#   3. missing + DRY_RUN=1 (default): no create call
#   4. missing + DRY_RUN=0: one create, TENANT_HOST=0, the key goes to the
#      0600 file and never to stdout
#   5. the read-then-create path is do_spl_tenant_create TODAY; the SWITCH to
#      the 074 operator API (POST /v1/operator/workspaces as the env SA) is due
#      when 074 T007 lands. This test fails if the action stops naming it.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-demo-workspace-create.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
printf 'env:\n  demo:\n    workspace: demo\n' >"$T/cnf.yaml"

# run <exists yes|no> [VAR=val ...]: the action with the cloud stubbed
run() {
  local exists="$1"; shift
  : >"$T/calls"
  env FUNC="$FUNC" T="$T" EXISTS="$exists" HOME="$T/home" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "${FUNC%/src/bash/run/*}/lib/bash/funcs/spl-cloud-cnf.func.sh"
    do_require_bin() { return 0; }
    do_spl_cloud_cnf() { SPL_CNF="$T/cnf.yaml"; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.com; }
    do_gcp_require_live_account() { return 0; }
    source "$FUNC"
    spl_demo_workspace_exists() { echo "read $1" >>"$T/calls"; echo "$EXISTS"; }
    do_spl_tenant_create() {
      echo "create $TENANT_ID host=$TENANT_HOST dry=$DRY_RUN" >>"$T/calls"
      echo "{\"tenant\":\"$TENANT_ID\",\"root_private_key\":\"SECRETKEY\"}"
    }
    do_spl_demo_workspace_create' >"$T/o" 2>"$T/e"
}

run no ENV=lde; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "1. ENV=lde refused before any read" || fail "1. rc=$rc $(cat "$T/calls")"

run yes ENV=dev DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'read demo' "$T/calls" && ! grep -q '^create' "$T/calls" &&
  grep -q '"created":false' "$T/o" &&
  pass "2. exists: read cnf id demo, no create, created false" || fail "2. rc=$rc $(cat "$T/calls" "$T/o")"

run no ENV=prd; rc=$?
[[ $rc -eq 0 ]] && ! grep -q '^create' "$T/calls" && grep -q '"dry_run":true' "$T/o" &&
  pass "3. missing + DRY_RUN default: no create" || fail "3. rc=$rc $(cat "$T/calls" "$T/o")"

run no ENV=dev DRY_RUN=0; rc=$?
f="$T/home/.spool-hub/tenants/dev-demo.json"
[[ $rc -eq 0 ]] && grep -qx 'create demo host=0 dry=0' "$T/calls" && grep -q '"created":true' "$T/o" &&
  pass "4. missing + DRY_RUN=0: one create, no tenant host" || fail "4. rc=$rc $(cat "$T/calls" "$T/o" "$T/e")"
[[ -f "$f" && "$(stat -c %a "$f")" == 600 ]] && grep -q SECRETKEY "$f" &&
  ! grep -q SECRETKEY "$T/o" "$T/e" &&
  pass "4. the key is in a 0600 file, never on stdout or the log" || fail "4. key file $(ls -l "$f" 2>&1)"
run no ENV=dev DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^create' "$T/calls" && grep -q SECRETKEY "$f" &&
  pass "4. a saved key file is never overwritten" || fail "4. overwrite rc=$rc $(cat "$T/calls")"

grep -q '074 T007' "$FUNC" && grep -q 'POST /v1/operator/workspaces' "$FUNC" &&
  grep -q 'do_spl_tenant_create' "$FUNC" &&
  pass "5. the action names its switch to the 074 operator API (074 T007)" ||
  fail "5. the switch note to the operator API is gone from $FUNC"

(( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
