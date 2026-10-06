#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: c-366 do_spl_hub_member_access_until / _access_check /
#          _access_schedule_check, with the hub operator call, the member list,
#          sudo (systemd-run) and spool-send.sh stubbed:
#   1. dry run prints and calls nothing (no list, no hub, no sudo)
#   2. bad input and a missing ORDERED_BY are refused before any call
#   3. MEMBER_EMAIL resolves to the human id through the member list, then
#      PATCH /v1/operator/members/<id> with the time; 'clear' sends null
#   4. hub refusals (404 old hub, 409 last owner) fail
#   5. the check exits 0 when the access has ended, 1 when not, 2 when unread
#   6. the schedule helper: dry run prints the systemd-run timer and calls
#      nothing; DRY_RUN=0 schedules it with the human id, never the email;
#      CHECK_AT=now sends kind result (ended) or blocker (not ended)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

mkdir -p "$T/stub"
printf '#!/bin/sh\necho "sudo $*" >>"$CALLS"\nexit 0\n' >"$T/stub/sudo"
printf '#!/bin/sh\necho "spool-send $*" >>"$CALLS"\nexit 0\n' >"$T/stub/spool-send.sh"
chmod +x "$T/stub/"*

FUTURE="$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ)"
PAST="2026-10-01T10:00:00Z"
ROWS_ENDED='{"type" : "member", "human_id" : "HUM-42", "email" : "guest@example.com", "role" : "admin", "access_until" : "2026-10-01T10:00:00+00:00", "access_ended" : true}
{"type" : "member", "human_id" : "HUM-7", "email" : "owner@example.com", "role" : "biz_owner", "access_until" : null, "access_ended" : false}
{"type" : "invite", "email" : "guest@example.com", "role" : "admin"}'
ROWS_OPEN="${ROWS_ENDED/\"access_ended\" : true/\"access_ended\" : false}"

run() {
  : >"$T/calls"
  env PROJ_PATH="$PROJ_ROOT" ENV=dev CALLS="$T/calls" PATH="$T/stub:$PATH" SPL_SPOOL_SEND="$T/stub/spool-send.sh" \
    ROWS="${ROWS:-$ROWS_ENDED}" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_CNF=/dev/null SPL_PROJECT=csi-spl-dev; }
    spl_hub_operator_url() { SPL_HUB_URL=https://hub.invalid; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.iam.gserviceaccount.com; }
    do_gcp_require_live_account() { :; }
    do_spl_hub_member_list() { echo "list TENANT_ID=$TENANT_ID MATCH=$MATCH" >>"$CALLS"; [[ "${LIST_RC:-0}" == 0 ]] || return "$LIST_RC"; printf "%s\n" "$ROWS"; echo "OK listed"; }
    spl_hub_operator_call() { echo "hub $1 $2 $3" >>"$CALLS"; SPL_HUB_OP_STATUS="${STUB_CODE:-200}"; SPL_HUB_OP_BODY="${STUB_BODY:-}"; }
    eval "$SNIPPET"' >"$T/o" 2>&1
}
SET=(SNIPPET=do_spl_hub_member_access_until TENANT_ID=w1)
OK_BODY='{"tenant_id":"w1","human_id":"HUM-42","access_until":"'"$FUTURE"'","access_ended":false}'

# --- 1. dry run -------------------------------------------------------------------
run "${SET[@]}" MEMBER_EMAIL=Guest@Example.com ACCESS_UNTIL="$FUTURE"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -q "DRY_RUN would ask the hub https://hub.invalid to end the access" "$T/o" \
  && pass "1. set: DRY_RUN prints and calls nothing" || fail "1. set dry: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 2. refusals ------------------------------------------------------------------
run "${SET[@]}" MEMBER_EMAIL=guest@example.com ACCESS_UNTIL="$FUTURE" DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q "ORDERED_BY .* is required" "$T/o" \
  && pass "2. a missing ORDERED_BY is refused before any call" || fail "2. ordered_by: rc=$rc $(cat "$T/calls" "$T/o")"
for bad in "ACCESS_UNTIL=tomorrow" "ACCESS_UNTIL=2026-10-07T06:00:00+02:00" "ORDERED_BY=bob" "HUMAN_ID=HUM-1" "MEMBER_EMAIL=nope" "TENANT_ID=W_1"; do
  run "${SET[@]}" MEMBER_EMAIL=guest@example.com ACCESS_UNTIL="$FUTURE" ORDERED_BY=HUM-10 DRY_RUN=0 "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "2. $bad refused before any call" || fail "2. $bad: rc=$rc $(cat "$T/calls")"
done

# --- 3. email -> id, then the PATCH ----------------------------------------------
run "${SET[@]}" MEMBER_EMAIL=Guest@Example.com ACCESS_UNTIL="$FUTURE" ORDERED_BY=HUM-10 ORDERED_VIA=c-001 DRY_RUN=0 STUB_BODY="$OK_BODY"; rc=$?
[[ $rc -eq 0 ]] && grep -qx "list TENANT_ID=w1 MATCH=guest@example.com" "$T/calls" \
  && grep -qxF "hub PATCH /v1/operator/members/HUM-42 {\"tenant\":\"w1\",\"access_until\":\"$FUTURE\",\"ordered_by\":\"HUM-10\",\"ordered_via\":\"c-001\"}" "$T/calls" \
  && grep -q "OK w1 member HUM-42: access_until=$FUTURE access_ended=false" "$T/o" \
  && pass "3. the email resolves to HUM-42 (not the invite row), then PATCH as the SA" || fail "3. resolve: rc=$rc $(cat "$T/calls" "$T/o")"
run "${SET[@]}" HUMAN_ID=HUM-42 ACCESS_UNTIL=clear ORDERED_BY=HUM-10 DRY_RUN=0 STUB_BODY='{"human_id":"HUM-42","access_until":null,"access_ended":false}'; rc=$?
[[ $rc -eq 0 ]] && ! grep -q '^list' "$T/calls" && grep -qxF 'hub PATCH /v1/operator/members/HUM-42 {"tenant":"w1","access_until":null,"ordered_by":"HUM-10"}' "$T/calls" \
  && grep -q "access_until=none" "$T/o" && pass "3. 'clear' sends access_until null; HUMAN_ID skips the list" || fail "3. clear: rc=$rc $(cat "$T/calls" "$T/o")"
run "${SET[@]}" MEMBER_EMAIL=stranger@example.com ACCESS_UNTIL="$FUTURE" ORDERED_BY=HUM-10 DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^hub' "$T/calls" && pass "3. an email that is no member: no hub call" || fail "3. stranger: rc=$rc $(cat "$T/calls")"

# --- 4. hub refusals ----------------------------------------------------------------
run "${SET[@]}" HUMAN_ID=HUM-7 ACCESS_UNTIL="$FUTURE" ORDERED_BY=HUM-10 DRY_RUN=0 STUB_CODE=409 STUB_BODY='{"error":"last_owner","detail":"the tenant'"'"'s last owner cannot be removed or demoted"}'; rc=$?
[[ $rc -eq 1 ]] && grep -q "last owner" "$T/o" && pass "4. 409 last owner fails" || fail "4. 409: rc=$rc $(cat "$T/o")"
run "${SET[@]}" HUMAN_ID=HUM-42 ACCESS_UNTIL="$FUTURE" ORDERED_BY=HUM-10 DRY_RUN=0 STUB_CODE=404 STUB_BODY='404 page not found'; rc=$?
[[ $rc -eq 1 ]] && grep -q "deploy a hub with it" "$T/o" && pass "4. 404 from an old hub names the deploy" || fail "4. 404: rc=$rc $(cat "$T/o")"

# --- 5. the check's exit codes ------------------------------------------------------
CHK=(SNIPPET=do_spl_hub_member_access_check TENANT_ID=w1)
run "${CHK[@]}" MEMBER_EMAIL=guest@example.com; rc=$?
[[ $rc -eq 0 ]] && grep -qF '{"tenant_id":null,"human_id":"HUM-42","role":"admin","access_until":"2026-10-01T10:00:00+00:00","access_ended":true}' "$T/o" \
  && grep -q "HAS ENDED" "$T/o" && pass "5. ended -> exit 0, prints access_until" || fail "5. ended: rc=$rc $(cat "$T/o")"
ROWS="$ROWS_OPEN" run "${CHK[@]}" HUMAN_ID=HUM-42; rc=$?
[[ $rc -eq 1 ]] && grep -q "has NOT ended" "$T/o" && pass "5. not ended -> exit 1" || fail "5. open: rc=$rc $(cat "$T/o")"
run "${CHK[@]}" HUMAN_ID=HUM-7; rc=$?
[[ $rc -eq 1 ]] && grep -q "access_until none" "$T/o" && pass "5. no end -> exit 1" || fail "5. none: rc=$rc $(cat "$T/o")"
run "${CHK[@]}" HUMAN_ID=HUM-42 LIST_RC=1; rc=$?
[[ $rc -eq 2 ]] && pass "5. unreadable list -> exit 2" || fail "5. unread: rc=$rc $(cat "$T/o")"
run "${CHK[@]}" HUMAN_ID=HUM-9; rc=$?
[[ $rc -eq 2 ]] && pass "5. not a member -> exit 2" || fail "5. missing: rc=$rc $(cat "$T/o")"

# --- 6. the schedule helper ----------------------------------------------------------
TASK=18e4f8ee-b9fb-4345-95bc-9cea3dc7ed72
SCH=(SNIPPET=do_spl_hub_member_access_schedule_check TENANT_ID=w1 REPORT_FROM=c-001 REPORT_TO=c-001 "REPORT_TASK=$TASK")
run "${SCH[@]}" MEMBER_EMAIL=guest@example.com CHECK_AT="$FUTURE"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -q "DRY_RUN would schedule" "$T/o" && grep -q "systemd-run" "$T/o" \
  && grep -qF -- "--on-calendar=$(date -u -d "$FUTURE" '+%Y-%m-%d\ %H:%M:%S')\ UTC" "$T/o" && grep -q "CHECK_AT=now" "$T/o" \
  && pass "6. schedule DRY_RUN prints the systemd-run timer and calls nothing" || fail "6. dry: rc=$rc $(cat "$T/calls" "$T/o")"
run "${SCH[@]}" MEMBER_EMAIL=guest@example.com CHECK_AT="$FUTURE" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q "^sudo -n systemd-run --unit=spl-access-check-dev-w1-HUM-42-" "$T/calls" && grep -q "HUMAN_ID=HUM-42" "$T/calls" \
  && ! grep "^sudo.*guest@" "$T/calls" >/dev/null && grep -q "do_spl_hub_member_access_schedule_check" "$T/calls" \
  && pass "6. DRY_RUN=0 schedules the timer with the human id, never the email" || fail "6. real: rc=$rc $(cat "$T/calls" "$T/o")"
for bad in "CHECK_AT=$PAST" "CHECK_AT=soon" "REPORT_TASK=x" "REPORT_TO=a b"; do
  run "${SCH[@]}" HUMAN_ID=HUM-42 CHECK_AT="$FUTURE" DRY_RUN=0 "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "6. ${bad} refused before any call" || fail "6. $bad: rc=$rc $(cat "$T/calls")"
done
run "${SCH[@]}" HUMAN_ID=HUM-42 CHECK_AT=now; rc=$?
[[ $rc -eq 0 ]] && ! grep -q '^spool-send' "$T/calls" && grep -q "would send c-001 (task $TASK, kind result" "$T/o" \
  && pass "6. CHECK_AT=now dry: prints the report, sends nothing" || fail "6. now dry: rc=$rc $(cat "$T/calls" "$T/o")"
run "${SCH[@]}" HUMAN_ID=HUM-42 CHECK_AT=now DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q "^spool-send --from c-001 --to c-001 --kind result --task $TASK --body " "$T/calls" && grep -q "^ACCESS ENDED" "$T/calls" \
  && pass "6. CHECK_AT=now, ended: kind result" || fail "6. now ended: rc=$rc $(cat "$T/calls" "$T/o")"
ROWS="$ROWS_OPEN" run "${SCH[@]}" HUMAN_ID=HUM-42 CHECK_AT=now DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q "^spool-send .*--kind blocker " "$T/calls" && grep -q "^ACCESS NOT ENDED" "$T/calls" \
  && pass "6. CHECK_AT=now, not ended: kind blocker" || fail "6. now open: rc=$rc $(cat "$T/calls" "$T/o")"
grep -q "@example.com" "$T/calls" && fail "6. the report carries an email" || pass "6. the report carries no email"

echo
(( fails == 0 )) && echo "ALL HUB MEMBER ACCESS-UNTIL CHECKS PASSED" || echo "$fails CHECK(S) FAILED"
exit $(( fails > 0 ))
