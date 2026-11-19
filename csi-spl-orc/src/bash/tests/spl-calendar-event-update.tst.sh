#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-5720 do_spl_calendar_event_update, with the hub operator call
# stubbed (the hub side, who reaches a private event, on memory and Postgres,
# is internal/hub/calendar_operator_private_write_test.go):
#   1. DRY_RUN (the default) prints the PATCH and calls nothing
#   2. a missing or bad var, or nothing to change, fails fast, before any call
#   3. REMINDERS=15m with ORDERED_BY: the PATCH carries only the reminders and
#      the target; the read-back names ordered_by and must hold them
#   4. TITLE + DAY: title and the whole day; empty REMINDERS / DESCRIPTION clear
#   5. a 404, a read-back that does not hold, or a read-back 404 fails the run
#   6. SPL-5963: AUDIENCE=private with ORDERED_BY sends audience private and
#      the read-back must hold it; any other value, or no ORDERED_BY, fails
#      fast with no call
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# STUB_CODE: the PATCH answers it; STUB_RB: the read-back body (default: the
# PATCH body as the event); STUB_RB_CODE: the read-back status.
run() {
  : >"$T/calls"
  env PROJ_PATH="$PROJ_ROOT" CALLS="$T/calls" LAST="$T/last" "$@" bash -c '
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
      if [[ "$1" == PATCH ]]; then
        printf "%s" "$3" >"$LAST"
        SPL_HUB_OP_STATUS="${STUB_CODE:-200}"; SPL_HUB_OP_BODY="{\"event\":{\"id\":\"$id\"},\"error\":\"not_found\"}"
        return 0
      fi
      SPL_HUB_OP_STATUS="${STUB_RB_CODE:-200}"
      SPL_HUB_OP_BODY="${STUB_RB:-$(jq -c --arg id "$id" "{event: ({title: \"Trip\", starts_at: \"2026-11-20T00:00:00Z\", audience: \"private\", creator_type: \"agent\", creator_id: \"c-840\", mentions: [\"HUM-10\"], reminders: []} + del(.tenant, .agent_id, .ordered_by) + {id: \$id} | .reminders |= [.[] | . + {method: \"popup\"}])}" "$LAST")}"
    }
    do_spl_calendar_event_update' >"$T/o" 2>&1
}
A=94cd492a-4587-4769-921d-e6ad59e2c8ec
SET=(ENV=dev TENANT_ID=wa EVENT_ID="$A" AGENT_ID=c-841 ORDERED_BY=HUM-10)
P="/v1/operator/calendar/events/$A"

# --- 1. dry run -----------------------------------------------------------------
run "${SET[@]}" REMINDERS=15m; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] \
  && grep -qxF "PATCH $P {\"tenant\":\"wa\",\"agent_id\":\"c-841\",\"ordered_by\":\"HUM-10\",\"reminders\":[{\"amount\":15,\"unit\":\"minutes\",\"method\":\"popup\"}]}" "$T/o" \
  && grep -q "OK DRY_RUN would PATCH $P through https://hub.invalid in dev" "$T/o" \
  && pass "1. DRY_RUN (default) prints the PATCH, 0 calls" || fail "1. dry: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 2. fail fast ---------------------------------------------------------------
for bad in "ENV=" "ENV=stg" "TENANT_ID=" "TENANT_ID=W_1" "EVENT_ID=" "EVENT_ID=nope" "EVENT_ID=$A;rm" \
           "AGENT_ID=" "AGENT_ID=HUM-10" "ORDERED_BY=bob" "TITLE= " "DAY=2026-02-30" "DAY=2026-11-20 STARTS_AT=2026-11-20T09:00:00Z" \
           "STARTS_AT=2026-11-20T09:00:00Z" "STARTS_AT=2026-11-20T10:00:00Z ENDS_AT=2026-11-20T09:00:00Z" \
           "REMINDERS=15x" "REMINDERS=5w" "DRY_RUN=yes"; do
  # shellcheck disable=SC2086 # a case may set two vars
  run "${SET[@]}" REMINDERS=15m DRY_RUN=0 $bad; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q FATAL "$T/o" && pass "2. $bad fails fast, no call" || fail "2. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done
run "${SET[@]}" DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q "FATAL nothing to change" "$T/o" \
  && pass "2. no field to change fails fast, no call" || fail "2. nothing: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 3. reminders on a private entry --------------------------------------------
run "${SET[@]}" REMINDERS=15m DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && [[ "$(sed -n 1p "$T/calls")" == pin ]] \
  && grep -qxF "hub PATCH $P {\"tenant\":\"wa\",\"agent_id\":\"c-841\",\"ordered_by\":\"HUM-10\",\"reminders\":[{\"amount\":15,\"unit\":\"minutes\",\"method\":\"popup\"}]}" "$T/calls" \
  && grep -qxF "hub GET $P?tenant=wa&ordered_by=HUM-10 " "$T/calls" && [[ "$(grep -c '^hub ' "$T/calls")" == 2 ]] \
  && grep -qF "link=https://wa.spool.invalid/calendar?d=2026-11-20&event=$A" "$T/o" \
  && grep -q "OK event $A in wa (dev) changed (reminders) and read back through the hub" "$T/o" \
  && pass "3. REMINDERS=15m: PATCH of the reminders only, read back with ordered_by" || fail "3. reminders: rc=$rc $(cat "$T/calls" "$T/o")"
run ENV=dev TENANT_ID=wa EVENT_ID="$A" AGENT_ID=c-841 TITLE=x DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qxF "hub GET $P?tenant=wa " "$T/calls" && ! grep -q ordered_by "$T/calls" \
  && pass "3. no ORDERED_BY: neither call names one" || fail "3. no ordby: rc=$rc $(cat "$T/calls")"

# --- 4. title, day, clears -------------------------------------------------------
run "${SET[@]}" TITLE='Trip, 15 min alert' DAY=2026-11-21 DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qF '"title":"Trip, 15 min alert","starts_at":"2026-11-21T00:00:00Z","ends_at":"2026-11-22T00:00:00Z","all_day":true}' "$T/calls" \
  && ! grep -q reminders "$T/last" && grep -q "changed (all_day, ends_at, starts_at, title)" "$T/o" \
  && pass "4. TITLE + DAY: the title and the whole day, reminders left" || fail "4. title day: rc=$rc $(cat "$T/calls" "$T/o")"
run "${SET[@]}" REMINDERS= DESCRIPTION= DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qF '"description":"","reminders":[]}' "$T/calls" \
  && pass "4. empty REMINDERS and DESCRIPTION clear them" || fail "4. clears: rc=$rc $(cat "$T/calls" "$T/o")"
run "${SET[@]}" STARTS_AT=2026-11-20T09:00:00Z ENDS_AT=2026-11-20T09:30:00Z DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qF '"starts_at":"2026-11-20T09:00:00Z","ends_at":"2026-11-20T09:30:00Z","all_day":false}' "$T/calls" \
  && pass "4. STARTS_AT + ENDS_AT: a timed slot" || fail "4. timed: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 5. failures -----------------------------------------------------------------
run "${SET[@]}" REMINDERS=15m DRY_RUN=0 STUB_CODE=404; rc=$?
[[ $rc -ne 0 ]] && grep -q "FATAL event $A is not one the operator reaches (404" "$T/o" && [[ "$(grep -c '^hub ' "$T/calls")" == 1 ]] \
  && pass "5. a 404 fails with the private-entry hint, no read-back" || fail "5. 404: rc=$rc $(cat "$T/calls" "$T/o")"
run "${SET[@]}" REMINDERS=15m DRY_RUN=0 STUB_RB="{\"event\":{\"id\":\"$A\",\"starts_at\":\"2026-11-20T00:00:00Z\",\"reminders\":[{\"amount\":30,\"unit\":\"minutes\"}]}}"; rc=$?
[[ $rc -ne 0 ]] && grep -q "FATAL event $A read back with reminders not as sent" "$T/o" \
  && pass "5. a read-back without the reminders fails" || fail "5. mismatch: rc=$rc $(cat "$T/o")"
run "${SET[@]}" TITLE=New DRY_RUN=0 STUB_RB="{\"event\":{\"id\":\"$A\",\"title\":\"Old\",\"starts_at\":\"2026-11-20T00:00:00Z\"}}"; rc=$?
[[ $rc -ne 0 ]] && grep -q "read back with title not as sent" "$T/o" \
  && pass "5. a read-back with the old title fails" || fail "5. title mismatch: rc=$rc $(cat "$T/o")"
run "${SET[@]}" REMINDERS=15m DRY_RUN=0 STUB_RB_CODE=404; rc=$?
[[ $rc -ne 0 ]] && grep -q "was changed but its read-back answered http 404" "$T/o" \
  && pass "5. a read-back 404 fails" || fail "5. rb 404: rc=$rc $(cat "$T/o")"

# --- 6. AUDIENCE=private (SPL-5963) -------------------------------------------------
run "${SET[@]}" AUDIENCE=private DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qxF "hub PATCH $P {\"tenant\":\"wa\",\"agent_id\":\"c-841\",\"ordered_by\":\"HUM-10\",\"audience\":\"private\"}" "$T/calls" \
  && grep -qxF "hub GET $P?tenant=wa&ordered_by=HUM-10 " "$T/calls" && grep -q "changed (audience)" "$T/o" \
  && pass "6. AUDIENCE=private: PATCH of the audience only, read back with ordered_by" || fail "6. private: rc=$rc $(cat "$T/calls" "$T/o")"
for bad in "AUDIENCE=workspace" "AUDIENCE=Private" "AUDIENCE=private ORDERED_BY="; do
  # shellcheck disable=SC2086 # a case may set two vars
  run "${SET[@]}" DRY_RUN=0 $bad; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q "FATAL AUDIENCE takes only private" "$T/o" && pass "6. $bad fails fast, no call" || fail "6. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done
run "${SET[@]}" AUDIENCE=private DRY_RUN=0 STUB_RB="{\"event\":{\"id\":\"$A\",\"audience\":\"workspace\",\"starts_at\":\"2026-11-20T00:00:00Z\"}}"; rc=$?
[[ $rc -ne 0 ]] && grep -q "read back with audience not as sent" "$T/o" \
  && pass "6. a read-back still shared fails" || fail "6. audience mismatch: rc=$rc $(cat "$T/o")"

(( fails == 0 )) && echo "ALL PASS: spl-calendar-event-update" || { echo "FAILED: $fails"; exit 1; }
