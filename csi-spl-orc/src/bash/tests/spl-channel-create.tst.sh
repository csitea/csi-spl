#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: c-843 do_spl_channel_create, with the hub operator call stubbed
# (the hub side, tenant isolation included, is
# internal/hub/channel_operator_test.go):
#   1. DRY_RUN (the default) prints the exact body and calls nothing: 0 writes
#   2. a missing or bad required var fails fast, before any call
#   3. DRY_RUN=0 POSTs the body as the SA, then reads the channel back
#   4. tenant A cannot write into tenant B: the body names only TENANT_ID,
#      and the hub's refusals (403 tenant_mismatch, 404 not_a_member, 409
#      channel_exists) fail the action with no read-back
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
      if [[ "$1" == POST ]]; then SPL_HUB_OP_STATUS="${STUB_CODE:-201}"; SPL_HUB_OP_BODY="${STUB_BODY:-}"
      else SPL_HUB_OP_STATUS=200; SPL_HUB_OP_BODY="${STUB_GET_BODY:-}"; fi
    }
    do_spl_channel_create' >"$T/o" 2>&1
}
DESC_BG='Преглед на GitHub връзките'
SET=(ENV=dev TENANT_ID=wa CHANNEL=trading ORDERED_BY=HUM-10 DESCRIPTION="$DESC_BG")
WANT='{"tenant":"wa","channel":"trading","ordered_by":"HUM-10","privacy":"members","description":"'"$DESC_BG"'"}'
CREATED='{"channel":"trading","name":"trading","privacy":"members","created_by":"HUM-10","default":false}'
READ='{"channel":"trading","name":"trading","description":"'"$DESC_BG"'","created_by":"HUM-10","created_at":"2026-10-10T15:00:00Z","default":false,"members":["HUM-10"]}'

# --- 1. dry run ---------------------------------------------------------------
run "${SET[@]}"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -qxF "$WANT" "$T/o" && grep -q "OK DRY_RUN would POST /v1/operator/channels to https://hub.invalid in dev" "$T/o" \
  && pass "1. DRY_RUN (default) prints the exact body, 0 calls, 0 writes" || fail "1. dry: rc=$rc $(cat "$T/calls" "$T/o")"
run "${SET[@]}" DRY_RUN=1 ORDERED_BY= NAME='Trading desk' DESCRIPTION= PRIVACY=members; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -qxF '{"tenant":"wa","channel":"trading","ordered_by":"","privacy":"members","name":"Trading desk"}' "$T/o" \
  && pass "1. a DRY_RUN with a name and no ORDERED_BY yet, 0 calls" || fail "1. name: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 2. fail fast -------------------------------------------------------------
for bad in "ENV=" "ENV=stg" "TENANT_ID=" "TENANT_ID=W_1" "CHANNEL=" "CHANNEL=Trading" "CHANNEL=-x" "CHANNEL=lobby" "CHANNEL=general" \
           "CHANNEL=issues" "CHANNEL=tasks" "PRIVACY=public" "ORDERED_BY=" "ORDERED_BY=c-843" "ORDERED_BY=bob" \
           "NAME=$(printf 'n%.0s' {1..81})" "DESCRIPTION=$(printf 'd%.0s' {1..501})" "DRY_RUN=yes"; do
  run "${SET[@]}" DRY_RUN=0 "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q FATAL "$T/o" && pass "2. ${bad:0:24} fails fast, no call" || fail "2. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done

# --- 3. the write and its read-back --------------------------------------------
run "${SET[@]}" DRY_RUN=0 STUB_BODY="$CREATED" STUB_GET_BODY="$READ"; rc=$?
[[ $rc -eq 0 ]] && [[ "$(sed -n 1p "$T/calls")" == pin ]] && grep -qxF "hub POST /v1/operator/channels $WANT" "$T/calls" \
  && grep -qxF "hub GET /v1/operator/channels/trading?tenant=wa " "$T/calls" \
  && grep -q "OK #trading in wa (dev), read back through the hub, created_by HUM-10, members HUM-10" "$T/o" \
  && pass "3. DRY_RUN=0 POSTs as the SA, reads the channel back, created_by the ordering human" || fail "3. write: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 4. tenant A cannot write into tenant B -----------------------------------------
run "${SET[@]}" DRY_RUN=1 TENANT_ID=wb; rc=$?
[[ $rc -eq 0 ]] && grep -q '^{"tenant":"wb",' "$T/o" && ! grep -q '"wa"' "$T/o" \
  && pass "4. the body names TENANT_ID and no other workspace" || fail "4. body tenant: $(cat "$T/o")"
run "${SET[@]}" DRY_RUN=0 STUB_CODE=403 STUB_BODY='{"error":"tenant_mismatch","detail":"the credential belongs to another tenant"}'; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^hub GET' "$T/calls" && grep -q "FATAL the hub refused the operator call (403): the credential belongs to another tenant" "$T/o" \
  && pass "4. a hub 403 tenant_mismatch fails, nothing read back" || fail "4. 403: rc=$rc $(cat "$T/calls" "$T/o")"
run "${SET[@]}" DRY_RUN=0 STUB_CODE=404 STUB_BODY='{"error":"not_a_member","detail":"HUM-10 is not a member of this tenant"}'; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^hub GET' "$T/calls" && grep -q "FATAL ORDERED_BY HUM-10 is not a member of wa" "$T/o" \
  && pass "4. an ordering human of another workspace is refused, nothing read back" || fail "4. not_a_member: rc=$rc $(cat "$T/calls" "$T/o")"
run "${SET[@]}" DRY_RUN=0 STUB_CODE=409 STUB_BODY='{"error":"channel_exists","detail":"channel trading exists or is reserved"}'; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^hub GET' "$T/calls" && grep -q "FATAL #trading was not created in wa (409): channel trading exists" "$T/o" \
  && pass "4. an existing channel is 409, nothing read back" || fail "4. 409: rc=$rc $(cat "$T/calls" "$T/o")"
run "${SET[@]}" DRY_RUN=0 STUB_CODE=404 STUB_BODY='{"error":"not_found"}'; rc=$?
[[ $rc -ne 0 ]] && grep -q "deploy a hub with it" "$T/o" && pass "4. an old hub (404) fails" || fail "4. 404: rc=$rc $(cat "$T/o")"

(( fails == 0 )) && echo "ALL PASS: spl-channel-create" || { echo "FAILED: $fails"; exit 1; }
