#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-5126 do_spl_issue_origin_link, with the hub call stubbed (the
# hub side is internal/hub/issue_discussion_origin_test.go):
#   1. DRY_RUN (the default) calls nothing and names no origin
#   2. a missing or bad required var fails fast, before any call
#   3. DRY_RUN=0 POSTs as the SA; the output names no origin
#   4. a refusal fails the action and names no origin
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

run() {
  : >"$T/calls"
  env PROJ_PATH="$PROJ_ROOT" CALLS="$T/calls" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_CNF=/dev/null SPL_PROJECT=csi-spl-$ENV; }
    spl_hub_operator_url() { SPL_HUB_URL=https://hub.invalid; }
    do_gcp_pin_account() { echo "pin" >>"$CALLS"; GCP_ACCOUNT=sa@example.iam.gserviceaccount.com; }
    do_gcp_require_live_account() { :; }
    spl_hub_operator_call() {
      echo "hub $1 $2 ${3:-}" >>"$CALLS"
      SPL_HUB_OP_STATUS="${STUB_CODE:-200}"; SPL_HUB_OP_BODY="${STUB_BODY:-{\"key\":\"SPL-7\",\"added\":true\}}"
    }
    do_spl_issue_origin_link' >"$T/o" 2>&1
}
ORIGIN=hidden-ws
TOPIC=dddddddd-dddd-4ddd-8ddd-dddddddddddd
SET=(ENV=dev TENANT_ID=wa ISSUE_KEY=SPL-7 ORIGIN_TENANT="$ORIGIN" DISCUSSION="$TOPIC")
WANT='{"tenant":"wa","origin_tenant":"'"$ORIGIN"'","discussion":"'"$TOPIC"'"}'
named() { grep -qE "$ORIGIN|$TOPIC" "$T/o"; }

# --- 1. dry run ---------------------------------------------------------------
run "${SET[@]}"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -q "OK DRY_RUN would link SPL-7" "$T/o" && ! named \
  && pass "1. DRY_RUN (default): 0 calls, names no origin" || fail "1. dry: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 2. fail fast -------------------------------------------------------------
for bad in "ENV=" "ENV=stg" "TENANT_ID=" "ISSUE_KEY=" "ISSUE_KEY=spl-1" "ORIGIN_TENANT=" "ORIGIN_TENANT=Bad_1" "ORIGIN_TENANT=wa" "DISCUSSION=" "DRY_RUN=yes"; do
  run "${SET[@]}" DRY_RUN=0 "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q FATAL "$T/o" && ! named && pass "2. ${bad:0:24} fails fast, no call" || fail "2. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done

# --- 3. the write -------------------------------------------------------------
run "${SET[@]}" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && [[ "$(sed -n 1p "$T/calls")" == pin ]] && grep -qxF "hub POST /v1/operator/issues/SPL-7/origin-discussion $WANT" "$T/calls" \
  && grep -q "OK SPL-7 of wa (dev) links its origin topic in another workspace, added=true" "$T/o" && ! named \
  && pass "3. DRY_RUN=0 POSTs as the SA, names no origin" || fail "3. write: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 4. a refusal -------------------------------------------------------------
run "${SET[@]}" DRY_RUN=0 STUB_CODE=400 STUB_BODY='{"error":"unknown_discussion"}'; rc=$?
[[ $rc -ne 0 ]] && grep -q "FATAL SPL-7 was not linked (http 400, unknown_discussion)" "$T/o" && ! named \
  && pass "4. a refusal fails and names no origin" || fail "4. refusal: rc=$rc $(cat "$T/o")"

(( fails == 0 )) && echo "ALL PASS: spl-issue-origin-link" || { echo "FAILED: $fails"; exit 1; }
