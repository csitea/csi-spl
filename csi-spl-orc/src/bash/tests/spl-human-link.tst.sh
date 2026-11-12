#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_human_link (spec 042 "Note to self", SPL-5372), with the hub
# operator call stubbed (the hub side, both directions and its refusals, is
# internal/hub/human_links_operator_test.go):
#   1. DRY_RUN (the default) prints the body and the current links, and makes
#      no write: only GET calls
#   2. a missing or bad required var (the same account twice included) fails
#      fast, before any call
#   3. DRY_RUN=0 POSTs the body as the SA, then reads the links back
#   4. the hub's refusals (404, 409 technical, 403) fail the action with no
#      read-back
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
      if [[ "$1" == POST ]]; then SPL_HUB_OP_STATUS="${STUB_CODE:-200}"; SPL_HUB_OP_BODY="${STUB_BODY:-}"
      else SPL_HUB_OP_STATUS="${STUB_GET_CODE:-200}"; SPL_HUB_OP_BODY="${STUB_GET_BODY:-}"; fi
    }
    do_spl_human_link' >"$T/o" 2>&1
}
SET=(ENV=dev HUMAN_ID=HUM-10 LINKED_HUMAN_ID=HUM-5 ORDERED_BY=HUM-10 AGENT_ID=c-308)
WANT='{"linked_human_id":"HUM-5","agent_id":"c-308","ordered_by":"HUM-10"}'
BEFORE='{"human_id":"HUM-10","linked":[]}'
AFTER='{"human_id":"HUM-10","linked":["HUM-5"]}'

# --- 1. dry run ---------------------------------------------------------------
run "${SET[@]}" STUB_GET_BODY="$BEFORE"; rc=$?
[[ $rc -eq 0 ]] && ! grep -q '^hub POST' "$T/calls" && grep -qxF 'hub GET /v1/operator/humans/HUM-10/links ' "$T/calls" \
  && grep -qxF "$WANT" "$T/o" && grep -qF 'INFO the accounts linked to HUM-10 (now): []' "$T/o" \
  && grep -q "OK DRY_RUN would POST /v1/operator/humans/HUM-10/links to https://hub.invalid in dev" "$T/o" \
  && pass "1. DRY_RUN (default) prints the body and the current links, 0 writes" || fail "1. dry: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 2. fail fast -------------------------------------------------------------
for bad in "ENV=" "ENV=stg" "HUMAN_ID=" "HUMAN_ID=10" "HUMAN_ID=c-308" "LINKED_HUMAN_ID=" "LINKED_HUMAN_ID=HUM-10" \
           "LINKED_HUMAN_ID=GST-4" "ORDERED_BY=" "ORDERED_BY=c-001" "AGENT_ID=" "AGENT_ID=HUM-10" "AGENT_ID=c-1" "DRY_RUN=yes"; do
  run "${SET[@]}" DRY_RUN=0 "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q FATAL "$T/o" && pass "2. ${bad:0:24} fails fast, no call" || fail "2. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done

# --- 3. the write and its read-back --------------------------------------------
run "${SET[@]}" DRY_RUN=0 STUB_BODY="$AFTER" STUB_GET_BODY="$AFTER"; rc=$?
[[ $rc -eq 0 ]] && [[ "$(sed -n 1p "$T/calls")" == pin ]] && grep -qxF "hub POST /v1/operator/humans/HUM-10/links $WANT" "$T/calls" \
  && grep -qxF 'hub GET /v1/operator/humans/HUM-10/links ' "$T/calls" \
  && grep -qF 'INFO the accounts linked to HUM-10 (after the link): ["HUM-5"]' "$T/o" \
  && grep -q "OK HUM-10 (dev): linked to HUM-5 both ways, read back through the hub (ordered_by HUM-10, via c-308)" "$T/o" \
  && pass "3. DRY_RUN=0 POSTs as the SA and reads the links back" || fail "3. write: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 4. the hub's refusals ---------------------------------------------------------
run "${SET[@]}" DRY_RUN=0 STUB_CODE=404 STUB_BODY='{"error":"not_found","detail":"no such human"}'; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^hub GET' "$T/calls" && grep -q "FATAL the hub has no human HUM-10 or HUM-5" "$T/o" \
  && pass "4. an unknown human is 404, nothing read back" || fail "4. 404: rc=$rc $(cat "$T/calls" "$T/o")"
run "${SET[@]}" DRY_RUN=0 STUB_CODE=409 STUB_BODY='{"error":"technical","detail":"an agent or a clone is not a person account"}'; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^hub GET' "$T/calls" && grep -q "FATAL one of them is an agent or a clone" "$T/o" \
  && pass "4. a technical human is 409, nothing read back" || fail "4. 409: rc=$rc $(cat "$T/calls" "$T/o")"
run "${SET[@]}" DRY_RUN=0 STUB_CODE=403 STUB_BODY='{"error":"not_operator","detail":"this identity is not an operator of this hub"}'; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^hub GET' "$T/calls" && grep -q "FATAL the hub refused the operator call (403)" "$T/o" \
  && pass "4. a non-operator identity is refused, nothing read back" || fail "4. 403: rc=$rc $(cat "$T/calls" "$T/o")"
run "${SET[@]}" STUB_GET_CODE=404 STUB_GET_BODY='{"error":"not_found","detail":"no such route"}'; rc=$?
[[ $rc -ne 0 ]] && grep -q "FATAL the read-back of HUM-10 (now) answered http 404" "$T/o" \
  && pass "4. a dry run against an old hub (404) fails" || fail "4. dry 404: rc=$rc $(cat "$T/o")"

(( fails == 0 )) && echo "ALL PASS: spl-human-link" || { echo "FAILED: $fails"; exit 1; }
