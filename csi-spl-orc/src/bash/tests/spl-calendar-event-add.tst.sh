#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: c-840 do_spl_calendar_event_add, with the hub operator call stubbed
# (the hub side, tenant isolation on Postgres included, is
# internal/hub/calendar_operator_test.go):
#   1. DRY_RUN (the default) prints the exact body and calls nothing: 0 writes
#   2. a missing or bad required var fails fast, before any call
#   3. DRY_RUN=0 POSTs the body as the SA, then reads the event back by id
#   4. tenant A cannot write into tenant B: the body names only TENANT_ID,
#      and the hub's refusals (403 tenant_mismatch, 400 topic of another
#      workspace) fail the action with no read-back
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
      else SPL_HUB_OP_STATUS=200; SPL_HUB_OP_BODY="${STUB_BODY:-}"; fi
    }
    do_spl_calendar_event_add' >"$T/o" 2>&1
}
TITLE_BG='Плащане: ДДС 2026-08, EUR 4 108,82'
SET=(ENV=dev TENANT_ID=wa TITLE="$TITLE_BG" DAY=2026-10-12 AGENT_ID=c-840 ORDERED_BY=HUM-10 DESCRIPTION="source msg 59c8455d")
WANT='{"tenant":"wa","agent_id":"c-840","title":"'"$TITLE_BG"'","description":"source msg 59c8455d","starts_at":"2026-10-12T00:00:00Z","ends_at":"2026-10-13T00:00:00Z","all_day":true,"ordered_by":"HUM-10"}'
EV='{"event":{"id":"0a1b2c3d","title":"'"$TITLE_BG"'","starts_at":"2026-10-12T00:00:00Z","ends_at":"2026-10-13T00:00:00Z","all_day":true,"creator_type":"agent","creator_id":"c-840","topic_id":"","audience":"workspace"}}'

# --- 1. dry run ---------------------------------------------------------------
run "${SET[@]}"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -qxF "$WANT" "$T/o" && grep -q "OK DRY_RUN would POST /v1/operator/calendar/events to https://hub.invalid in dev" "$T/o" \
  && pass "1. DRY_RUN (default) prints the exact body, 0 calls, 0 writes" || fail "1. dry: rc=$rc $(cat "$T/calls" "$T/o")"
run "${SET[@]}" DRY_RUN=1 ALL_DAY=0 DAY= STARTS_AT=2026-10-12T09:00:00Z ENDS_AT=2026-10-12T10:00:00Z TOPIC_ID=2eba6c6f-5a1b-4570-80df-7f7f478d36ad; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -q '"starts_at":"2026-10-12T09:00:00Z","ends_at":"2026-10-12T10:00:00Z","all_day":false,"ordered_by":"HUM-10","topic_id":"2eba6c6f-5a1b-4570-80df-7f7f478d36ad"}' "$T/o" \
  && pass "1. a timed DRY_RUN with a topic, 0 calls" || fail "1. timed: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 2. fail fast -------------------------------------------------------------
for bad in "ENV=" "ENV=stg" "TENANT_ID=" "TENANT_ID=W_1" "TITLE=" "DAY=" "DAY=2026-02-30" "DAY=12.10.2026" "AGENT_ID=" "AGENT_ID=HUM-10" \
           "ORDERED_BY=bob" "TOPIC_ID=a/b" "ALL_DAY=2" "DRY_RUN=yes"; do
  run "${SET[@]}" DRY_RUN=0 "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q FATAL "$T/o" && pass "2. $bad fails fast, no call" || fail "2. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done
for bad in "STARTS_AT=" "ENDS_AT=2026-10-12T08:00:00Z" "STARTS_AT=2026-10-12T09:00:00+02:00"; do
  run "${SET[@]}" DRY_RUN=0 ALL_DAY=0 DAY= STARTS_AT=2026-10-12T09:00:00Z ENDS_AT=2026-10-12T10:00:00Z "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "2. ALL_DAY=0 $bad fails fast" || fail "2. timed $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done

# --- 3. the write and its read-back --------------------------------------------
run "${SET[@]}" DRY_RUN=0 STUB_BODY="$EV"; rc=$?
[[ $rc -eq 0 ]] && [[ "$(sed -n 1p "$T/calls")" == pin ]] && grep -qxF "hub POST /v1/operator/calendar/events $WANT" "$T/calls" \
  && grep -qxF "hub GET /v1/operator/calendar/events/0a1b2c3d?tenant=wa " "$T/calls" \
  && grep -q '"creator_type":"agent","creator_id":"c-840"' "$T/o" && grep -q "OK event 0a1b2c3d in wa (dev), read back through the hub, creator agent c-840" "$T/o" \
  && pass "3. DRY_RUN=0 POSTs as the SA, reads the event back, creator the agent" || fail "3. write: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 4. tenant A cannot write into tenant B -----------------------------------------
run "${SET[@]}" DRY_RUN=1 TENANT_ID=wb; rc=$?
[[ $rc -eq 0 ]] && grep -q '^{"tenant":"wb",' "$T/o" && ! grep -q '"wa"' "$T/o" \
  && pass "4. the body names TENANT_ID and no other workspace" || fail "4. body tenant: $(cat "$T/o")"
run "${SET[@]}" DRY_RUN=0 STUB_CODE=403 STUB_BODY='{"error":"tenant_mismatch","detail":"the credential belongs to another tenant"}'; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^hub GET' "$T/calls" && grep -q "FATAL the hub refused the operator call (403): the credential belongs to another tenant" "$T/o" \
  && pass "4. a hub 403 tenant_mismatch fails, nothing read back" || fail "4. 403: rc=$rc $(cat "$T/calls" "$T/o")"
run "${SET[@]}" DRY_RUN=0 TOPIC_ID=topic-of-b STUB_CODE=400 STUB_BODY='{"error":"bad_event","detail":"topic_id is not a topic of this workspace"}'; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^hub GET' "$T/calls" && grep -q "FATAL the event was not written (http 400): topic_id is not a topic of this workspace" "$T/o" \
  && pass "4. a topic of another workspace is refused, nothing read back" || fail "4. topic: rc=$rc $(cat "$T/calls" "$T/o")"
run "${SET[@]}" DRY_RUN=0 STUB_CODE=404 STUB_BODY='{"error":"not_found"}'; rc=$?
[[ $rc -ne 0 ]] && grep -q "deploy a hub with it" "$T/o" && pass "4. an old hub (404) fails" || fail "4. 404: rc=$rc $(cat "$T/o")"

(( fails == 0 )) && echo "ALL PASS: spl-calendar-event-add" || { echo "FAILED: $fails"; exit 1; }
