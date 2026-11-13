#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-5453 do_spl_calendar_event_delete and do_spl_calendar_event_pin,
# with the hub operator call stubbed (the hub side, tenant isolation and the
# trash owner on Postgres, is internal/hub/calendar_operator_write_test.go):
#   1. DRY_RUN (the default) prints each request and calls nothing
#   2. a missing or bad var fails fast, before any call
#   3. delete: DELETE per id as the SA with tenant, agent_id, ordered_by;
#      each read back 404
#   4. pin: PATCH with props.pinned and nothing else; each read back pinned
#   5. a refused id or a read-back that does not hold fails the run, the
#      other ids still run
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# STUB_FAIL_ID: the write of that id answers 403; STUB_LIVE=1: a deleted id
# still reads back 200; STUB_UNPINNED=1: a pinned id reads back unpinned.
run() {
  local action="$1"; shift
  : >"$T/calls"
  env PROJ_PATH="$PROJ_ROOT" CALLS="$T/calls" ACTION="$action" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_CNF=/dev/null SPL_PROJECT=csi-spl-$ENV SPL_FQDN=spool.invalid; }
    spl_hub_operator_url() { SPL_HUB_URL=https://hub.invalid; }
    do_gcp_pin_account() { echo "pin" >>"$CALLS"; GCP_ACCOUNT=sa@example.iam.gserviceaccount.com; }
    do_gcp_require_live_account() { :; }
    spl_hub_operator_call() {
      echo "hub $1 $2 ${3:-}" >>"$CALLS"
      local id="${2#/v1/operator/calendar/events/}"; id="${id%%[?]*}"
      case "$1" in
        GET)
          if [[ "$ACTION" == do_spl_calendar_event_delete && -z "${STUB_LIVE:-}" ]]; then SPL_HUB_OP_STATUS=404; SPL_HUB_OP_BODY="{\"error\":\"not_found\"}"
          elif [[ -n "${STUB_UNPINNED:-}" ]]; then SPL_HUB_OP_STATUS=200; SPL_HUB_OP_BODY="{\"event\":{\"id\":\"$id\"}}"
          else SPL_HUB_OP_STATUS=200; SPL_HUB_OP_BODY="{\"event\":{\"id\":\"$id\",\"pinned\":true}}"; fi ;;
        *)
          if [[ "$id" == "${STUB_FAIL_ID:-none}" ]]; then SPL_HUB_OP_STATUS=403; SPL_HUB_OP_BODY="{\"error\":\"tenant_mismatch\",\"detail\":\"another tenant\"}"
          else SPL_HUB_OP_STATUS=200; SPL_HUB_OP_BODY="{\"event\":{\"id\":\"$id\",\"title\":\"NL\"}}"; fi ;;
      esac
    }
    "$ACTION"' >"$T/o" 2>&1
}
A=94cd492a-4587-4769-921d-e6ad59e2c8ec
B=4f8e0384-898f-4f2d-a44c-5b78a0786447
SET=(ENV=dev TENANT_ID=wa EVENT_IDS="$A,$B" AGENT_ID=c-840 ORDERED_BY=HUM-10)
DEL=do_spl_calendar_event_delete PIN=do_spl_calendar_event_pin

# --- 1. dry run ---------------------------------------------------------------
run $DEL "${SET[@]}"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -qxF "DELETE /v1/operator/calendar/events/$A?tenant=wa&agent_id=c-840&ordered_by=HUM-10" "$T/o" \
  && grep -q "OK DRY_RUN would delete 2 event(s) of wa through https://hub.invalid in dev" "$T/o" \
  && pass "1. delete DRY_RUN (default) prints each request, 0 calls" || fail "1. delete dry: rc=$rc $(cat "$T/calls" "$T/o")"
run $PIN "${SET[@]}" EVENT_IDS="$A $B"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -qxF "PATCH /v1/operator/calendar/events/$B {\"tenant\":\"wa\",\"agent_id\":\"c-840\",\"ordered_by\":\"HUM-10\",\"props\":{\"pinned\":true}}" "$T/o" \
  && pass "1. pin DRY_RUN prints the PATCH with props.pinned only, 0 calls" || fail "1. pin dry: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 2. fail fast -------------------------------------------------------------
for act in $DEL $PIN; do
  for bad in "ENV=" "ENV=stg" "TENANT_ID=" "TENANT_ID=W_1" "EVENT_IDS=" "EVENT_IDS=$A,nope" "EVENT_IDS=$A;rm" \
             "AGENT_ID=" "AGENT_ID=HUM-10" "ORDERED_BY=bob" "DRY_RUN=yes"; do
    run $act "${SET[@]}" DRY_RUN=0 "$bad"; rc=$?
    [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q FATAL "$T/o" && pass "2. $act $bad fails fast, no call" || fail "2. $act $bad: rc=$rc $(cat "$T/calls" "$T/o")"
  done
done
run $PIN "${SET[@]}" DRY_RUN=0 PINNED=yes; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "2. PINNED=yes fails fast" || fail "2. pinned: rc=$rc $(cat "$T/o")"
many=$(printf "$A,%.0s" $(seq 1 201))
run $DEL "${SET[@]}" DRY_RUN=0 EVENT_IDS="$many"; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "2. 201 ids fail fast" || fail "2. many: rc=$rc $(cat "$T/o")"

# --- 3. delete ------------------------------------------------------------------
run $DEL "${SET[@]}" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && [[ "$(sed -n 1p "$T/calls")" == pin ]] \
  && grep -qxF "hub DELETE /v1/operator/calendar/events/$A?tenant=wa&agent_id=c-840&ordered_by=HUM-10 " "$T/calls" \
  && grep -qxF "hub GET /v1/operator/calendar/events/$B?tenant=wa " "$T/calls" \
  && [[ "$(grep -c '^hub ' "$T/calls")" == 4 ]] && grep -q "OK trashed $A (NL): read back 404, in the trash" "$T/o" \
  && grep -q "OK delete: 2 of 2 event(s) of wa (dev) done and read back through the hub" "$T/o" \
  && pass "3. DELETE per id as the SA, each read back 404" || fail "3. delete: rc=$rc $(cat "$T/calls" "$T/o")"
run $DEL "${SET[@]}" DRY_RUN=0 ORDERED_BY=; rc=$?
[[ $rc -eq 0 ]] && grep -qxF "hub DELETE /v1/operator/calendar/events/$A?tenant=wa&agent_id=c-840 " "$T/calls" \
  && pass "3. no ORDERED_BY: the query names none" || fail "3. no ordby: rc=$rc $(cat "$T/calls")"

# --- 4. pin -----------------------------------------------------------------------
run $PIN "${SET[@]}" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qxF "hub PATCH /v1/operator/calendar/events/$A {\"tenant\":\"wa\",\"agent_id\":\"c-840\",\"ordered_by\":\"HUM-10\",\"props\":{\"pinned\":true}}" "$T/calls" \
  && grep -q "OK pinned=true $B (NL): read back" "$T/o" && grep -q "OK pin: 2 of 2 event(s)" "$T/o" \
  && pass "4. PATCH props.pinned per id, each read back pinned" || fail "4. pin: rc=$rc $(cat "$T/calls" "$T/o")"
run $PIN "${SET[@]}" DRY_RUN=0 PINNED=0 STUB_UNPINNED=1; rc=$?
[[ $rc -eq 0 ]] && grep -q '"props":{"pinned":false}' "$T/calls" && grep -q "OK pinned=false $A" "$T/o" \
  && pass "4. PINNED=0 unpins, read back unpinned" || fail "4. unpin: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 5. a failure fails the run, the others still run -----------------------------
run $DEL "${SET[@]}" DRY_RUN=0 STUB_FAIL_ID="$A"; rc=$?
[[ $rc -ne 0 ]] && grep -q "FAIL delete $A: http 403 another tenant" "$T/o" && grep -q "OK trashed $B" "$T/o" \
  && grep -q "FATAL delete: 1 of 2 event(s) of wa (dev) done and read back, 1 failed" "$T/o" \
  && pass "5. a refused id fails the run; the other id still runs" || fail "5. refused: rc=$rc $(cat "$T/o")"
run $DEL "${SET[@]}" DRY_RUN=0 STUB_LIVE=1; rc=$?
[[ $rc -ne 0 ]] && grep -q "FAIL delete $A: the read-back answered http 200, not 404" "$T/o" \
  && pass "5. a delete that still reads back live fails" || fail "5. live: rc=$rc $(cat "$T/o")"
run $PIN "${SET[@]}" DRY_RUN=0 STUB_UNPINNED=1; rc=$?
[[ $rc -ne 0 ]] && grep -q "FAIL pin $A: read back http 200 pinned=false, want true" "$T/o" \
  && pass "5. a pin that does not read back pinned fails" || fail "5. unpinned: rc=$rc $(cat "$T/o")"

(( fails == 0 )) && echo "ALL PASS: spl-calendar-event-change" || { echo "FAILED: $fails"; exit 1; }
