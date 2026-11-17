#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 180 FR-9, do_spl_calendar_import_outlook with the hub
# operator call stubbed (the hub side, Postgres included, is
# internal/hub/calendar_operator_import_test.go). Synthetic export only.
#   1. DRY_RUN (the default) prints the count and window, calls nothing
#   2. a bad var or a bad file fails fast, before any call; a 06.30.00 time
#      names the event's index and never its title
#   3. DRY_RUN=0 PUTs the compacted file (curl @file) to the import route
#      with tenant and owner, and logs the four counts, never a title
#   4. the hub's 404 (switch off) and 400 fail the action
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
      echo "hub $1 $2" >>"$CALLS"
      [[ "${3:0:1}" == @ ]] && cp "${3:1}" "$CALLS.body"
      SPL_HUB_OP_STATUS="${STUB_CODE:-200}"
      SPL_HUB_OP_BODY="${STUB_BODY:-{\"created\":2,\"updated\":0,\"unchanged\":0,\"deleted\":1}}"
    }
    do_spl_calendar_import_outlook' >"$T/o" 2>&1
}

export_file() { # <file> <starts_at of event 1>
  cat >"$1" <<EOF
{"format":"spool-hub-outlook-export/1","exported_at":"2027-02-01T05:00:00Z","time_zone":"Europe/Helsinki",
 "from":"2027-01-31T22:00:00Z","to":"2027-02-14T22:00:00Z","count":2,"events":[
 {"source_id":"SYN1@20270201T090000","title":"Synthetic secret title","starts_at":"2027-02-01T07:00:00Z","ends_at":"2027-02-01T07:30:00Z","all_day":false,"day":"","end_day":"","location":"","busy_status":"Busy","private":false,"recurring":false},
 {"source_id":"SYN2@20270202T090000","title":"Synthetic secret title","starts_at":"$2","ends_at":"2027-02-02T08:00:00Z","all_day":false,"day":"","end_day":"","location":"","busy_status":"Busy","private":false,"recurring":false}]}
EOF
}
GOOD="$T/good.json" FINNISH="$T/fi.json"
export_file "$GOOD" "2027-02-02T07:00:00Z"
export_file "$FINNISH" "2027-02-02T06.30.00Z"
SET=(ENV=prd TENANT_ID=csitea EVENT_OWNER=HUM-10 IMPORT_FILE="$GOOD")
ROUTE='hub PUT /v1/operator/calendar/import/outlook?tenant=csitea&owner=HUM-10'

# --- 1. dry run ---------------------------------------------------------------
run "${SET[@]}"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -q 'OK DRY_RUN would PUT /v1/operator/calendar/import/outlook?tenant=csitea&owner=HUM-10 to https://hub.invalid in prd as the csi-spl-prd service account: 2 events, 2027-01-31T22:00:00Z .. 2027-02-14T22:00:00Z' "$T/o" \
  && ! grep -q 'secret title' "$T/o" && pass "1. DRY_RUN (default) prints the count and window, 0 calls" || fail "1. dry: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 2. fail fast -------------------------------------------------------------
echo '{"format":"other"}' >"$T/fmt.json"; echo 'not json' >"$T/nojson.json"
for bad in "ENV=" "ENV=stg" "TENANT_ID=" "TENANT_ID=W_1" "EVENT_OWNER=" "EVENT_OWNER=c-042" "IMPORT_FILE=" "IMPORT_FILE=$T/none.json" \
           "IMPORT_FILE=$T/fmt.json" "IMPORT_FILE=$T/nojson.json" "DRY_RUN=yes"; do
  run "${SET[@]}" DRY_RUN=0 "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q FATAL "$T/o" && pass "2. ${bad##*/} fails fast, no call" || fail "2. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done
run "${SET[@]}" DRY_RUN=0 IMPORT_FILE="$FINNISH"; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -qF 'FATAL IMPORT_FILE refused, nothing sent: event 1: starts_at is not an RFC 3339 time' "$T/o" \
  && ! grep -q 'secret title' "$T/o" && pass "2. a 06.30.00 time names event 1, no title, no call" || fail "2. finnish: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 3. the write -------------------------------------------------------------
run "${SET[@]}" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qxF "$ROUTE" "$T/calls" && [[ "$(jq -c . "$GOOD")" == "$(cat "$T/calls.body")" ]] \
  && grep -q 'OK imported 2 events, .* into csitea (prd) for HUM-10: created=2 updated=0 unchanged=0 deleted=1' "$T/o" \
  && ! grep -q 'secret title' "$T/o" && pass "3. DRY_RUN=0 PUTs the compact file, logs the four counts, no title" || fail "3. write: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 4. the hub refuses --------------------------------------------------------
run "${SET[@]}" DRY_RUN=0 STUB_CODE=404 STUB_BODY='{"error":"not_found"}'; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL the hub answered 404: the Outlook import is off' "$T/o" && pass "4. 404 (switch off) fails" || fail "4. 404: rc=$rc $(cat "$T/o")"
run "${SET[@]}" DRY_RUN=0 STUB_CODE=400 STUB_BODY='{"error":"bad_event","detail":"event 0: source_id is empty"}'; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL the import was refused (http 400): event 0: source_id is empty' "$T/o" && pass "4. 400 fails with the hub's reason" || fail "4. 400: rc=$rc $(cat "$T/o")"

(( fails == 0 )) && echo "ALL PASS: spl-calendar-import-outlook" || { echo "FAILED: $fails"; exit 1; }
