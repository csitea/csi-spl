#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: c-764 do_spl_human_email_add, with the hub operator call stubbed
# (the hub side, pending-only and the 409 squat included, is
# internal/hub/human_email_operator_test.go):
#   1. DRY_RUN (the default) prints the masked body and the current list, and
#      makes no write: only GET calls
#   2. a missing or bad required var fails fast, before any call
#   3. DRY_RUN=0 POSTs the body as the SA, then reads the list back
#   4. the hub's refusals (409 email_taken, 404, 403) fail the action with no
#      read-back
#   5. no full address reaches the output (run.sh tees it into the run logs)
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
    do_spl_human_email_add' >"$T/o" 2>&1
}
MAIN=mainaddr@example.com
SECOND=second.addr@example.org
SET=(ENV=dev HUMAN_ID=HUM-26 EMAIL=Second.Addr@Example.org ORDERED_BY=HUM-10 AGENT_ID=c-764)
WANT='{"email":"'"$SECOND"'","agent_id":"c-764","ordered_by":"HUM-10"}'
BEFORE='{"human_id":"HUM-26","emails":[{"email":"'"$MAIN"'","state":"active","providers":["google"],"main":true}]}'
ADDED='{"human_id":"HUM-26","email":"'"$SECOND"'","state":"pending","reason":"pending_until_provider_sign_in"}'
AFTER='{"human_id":"HUM-26","emails":[{"email":"'"$MAIN"'","state":"active","providers":["google"],"main":true},{"email":"'"$SECOND"'","state":"pending","providers":[],"main":false}]}'

# --- 1. dry run ---------------------------------------------------------------
run "${SET[@]}" STUB_GET_BODY="$BEFORE"; rc=$?
[[ $rc -eq 0 ]] && ! grep -q '^hub POST' "$T/calls" && grep -qxF 'hub GET /v1/operator/humans/HUM-26/emails ' "$T/calls" \
  && grep -qxF '{"email":"se***@example.org","agent_id":"c-764","ordered_by":"HUM-10"}' "$T/o" \
  && grep -qxF '{"email":"ma***@example.com","state":"active","providers":["google"],"main":true}' "$T/o" \
  && grep -q "OK DRY_RUN would POST /v1/operator/humans/HUM-26/emails to https://hub.invalid in dev" "$T/o" \
  && pass "1. DRY_RUN (default) prints the masked body and the current list, 0 writes" || fail "1. dry: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 2. fail fast -------------------------------------------------------------
for bad in "ENV=" "ENV=stg" "HUMAN_ID=" "HUMAN_ID=26" "HUMAN_ID=c-764" "EMAIL=" "EMAIL=not-an-address" "EMAIL=a@b" \
           "ORDERED_BY=" "ORDERED_BY=c-001" "AGENT_ID=" "AGENT_ID=HUM-10" "AGENT_ID=c-1" "DRY_RUN=yes"; do
  run "${SET[@]}" DRY_RUN=0 "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q FATAL "$T/o" && pass "2. ${bad:0:24} fails fast, no call" || fail "2. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done

# --- 3. the write and its read-back --------------------------------------------
run "${SET[@]}" DRY_RUN=0 STUB_BODY="$ADDED" STUB_GET_BODY="$AFTER"; rc=$?
[[ $rc -eq 0 ]] && [[ "$(sed -n 1p "$T/calls")" == pin ]] && grep -qxF "hub POST /v1/operator/humans/HUM-26/emails $WANT" "$T/calls" \
  && grep -qxF 'hub GET /v1/operator/humans/HUM-26/emails ' "$T/calls" \
  && grep -qxF '{"email":"se***@example.org","state":"pending","providers":[],"main":false,"requested":true}' "$T/o" \
  && grep -qxF '{"email":"ma***@example.com","state":"active","providers":["google"],"main":true}' "$T/o" \
  && grep -q "OK HUM-26 (dev): the address is pending on HUM-26, read back through the hub (ordered_by HUM-10, via c-764)" "$T/o" \
  && pass "3. DRY_RUN=0 POSTs as the SA (lower-cased), reads the list back: main active, the new one pending" || fail "3. write: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 4. the hub's refusals ---------------------------------------------------------
run "${SET[@]}" DRY_RUN=0 STUB_CODE=409 STUB_BODY='{"error":"email_taken","detail":"this address belongs to another account"}'; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^hub GET' "$T/calls" && grep -q "FATAL the address is active or pending on ANOTHER human (409 email_taken)" "$T/o" \
  && pass "4. a squat on another human is 409, nothing read back" || fail "4. 409: rc=$rc $(cat "$T/calls" "$T/o")"
run "${SET[@]}" DRY_RUN=0 STUB_CODE=404 STUB_BODY='{"error":"not_found","detail":"no such human"}'; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^hub GET' "$T/calls" && grep -q "FATAL the hub has no human HUM-26" "$T/o" \
  && pass "4. an unknown human is 404, nothing read back" || fail "4. 404: rc=$rc $(cat "$T/calls" "$T/o")"
run "${SET[@]}" DRY_RUN=0 STUB_CODE=403 STUB_BODY='{"error":"not_operator","detail":"this identity is not an operator of this hub"}'; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^hub GET' "$T/calls" && grep -q "FATAL the hub refused the operator call (403)" "$T/o" \
  && pass "4. a non-operator identity is refused, nothing read back" || fail "4. 403: rc=$rc $(cat "$T/calls" "$T/o")"
run "${SET[@]}" STUB_GET_CODE=404 STUB_GET_BODY='{"error":"not_found","detail":"no such route"}'; rc=$?
[[ $rc -ne 0 ]] && grep -q "FATAL the read-back of HUM-26 (now) answered http 404" "$T/o" \
  && pass "4. a dry run against an old hub (404) fails" || fail "4. dry 404: rc=$rc $(cat "$T/o")"

# --- 5. no full address in the output -----------------------------------------------
run "${SET[@]}" DRY_RUN=0 STUB_BODY="$ADDED" STUB_GET_BODY="$AFTER"
! grep -qiF -e "$SECOND" -e "$MAIN" "$T/o" && pass "5. the output carries masked addresses only" || fail "5. a full address leaked: $(cat "$T/o")"

(( fails == 0 )) && echo "ALL PASS: spl-human-email-add" || { echo "FAILED: $fails"; exit 1; }
