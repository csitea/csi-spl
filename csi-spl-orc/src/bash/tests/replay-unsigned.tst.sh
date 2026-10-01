#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_replay_unsigned (CLE-77876): the hub call is a stub that
#          records the body and answers a canned status.
#   1. bad TENANT_ID / SINCE fail before any call
#   2. DRY_RUN (default) sends dry_run:true and reports the list
#   3. DRY_RUN=0 sends dry_run:false; a skipped row fails the run
#   4. 409 (unpinned) and 404 (old hub) fail naming the fix
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

run() {
  env PROJ_PATH="$PROJ_ROOT" ENV=prd CALLS="$T/calls" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { :; }
    do_spl_cloud_cnf() { SPL_CNF=/dev/null; }
    spl_hub_operator_url() { :; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.iam.gserviceaccount.com; }
    do_gcp_require_live_account() { :; }
    spl_dry_run() { local d="${DRY_RUN:-1}"; [[ "$d" == 0 || "$d" == 1 ]] || return 2; [[ "$d" == 1 ]]; }
    spl_hub_operator_call() { echo "$1 $2 $3" >>"$CALLS"; SPL_HUB_OP_STATUS="${STUB_CODE:-200}"; SPL_HUB_OP_BODY="${STUB_BODY:-}"; }
    source "$PROJ_PATH/src/bash/run/spl-replay-unsigned.func.sh"
    do_spl_replay_unsigned' >"$T/o" 2>&1
}
OK_DRY='{"tenant":"w1","since":"2026-09-29T12:00:00Z","dry_run":true,"found":3,"resigned":0,"skipped":0,"channels":["ops","lobby"],"msg_ids":["a","b","c"]}'
OK_RUN='{"tenant":"w1","since":"2026-09-29T12:00:00Z","dry_run":false,"found":3,"resigned":3,"skipped":0,"channels":["ops"],"msg_ids":["a","b","c"]}'
SKIP_RUN='{"tenant":"w1","since":"2026-09-29T12:00:00Z","dry_run":false,"found":3,"resigned":2,"skipped":1,"channels":["ops"],"msg_ids":["a","b"]}'

: >"$T/calls"
run TENANT_ID=W1 SINCE=2026-09-29T12:00:00Z; r1=$?
run TENANT_ID=w1 SINCE=yesterday; r2=$?
[[ $r1 -ne 0 && $r2 -ne 0 && ! -s "$T/calls" ]] && pass "1. bad TENANT_ID / SINCE fail before any call" || fail "1. r1=$r1 r2=$r2 $(cat "$T/calls")"

run TENANT_ID=w1 SINCE=2026-09-29T12:00:00Z STUB_BODY="$OK_DRY"; rc=$?
[[ $rc -eq 0 ]] && grep -q '"dry_run":true' "$T/calls" && grep -q 'POST /v1/operator/replay-unsigned' "$T/calls" &&
  grep -q 'DRY_RUN w1: 3 unsigned human post(s) since 2026-09-29T12:00:00Z in #ops #lobby' "$T/o" &&
  pass "2. the dry run asks for the list only" || fail "2. rc=$rc $(cat "$T/calls" "$T/o")"

: >"$T/calls"
run TENANT_ID=w1 SINCE=2026-09-29T12:00:00Z DRY_RUN=0 STUB_BODY="$OK_RUN"; rc=$?
[[ $rc -eq 0 ]] && grep -q '"dry_run":false' "$T/calls" && grep -q 'OK w1: 3 of 3 unsigned post(s) signed and routed' "$T/o" &&
  pass "3. DRY_RUN=0 replays" || fail "3. rc=$rc $(cat "$T/calls" "$T/o")"
run TENANT_ID=w1 SINCE=2026-09-29T12:00:00Z DRY_RUN=0 STUB_BODY="$SKIP_RUN"; rc=$?
[[ $rc -eq 1 ]] && grep -q '(1 skipped)' "$T/o" && pass "3. a skipped row fails the run" || fail "3. skip rc=$rc $(cat "$T/o")"

run TENANT_ID=w1 SINCE=2026-09-29T12:00:00Z STUB_CODE=409 STUB_BODY='{"error":"wui_unpinned"}'; rc=$?
[[ $rc -eq 1 ]] && grep -q 'do_spl_cloud_pin_box_wui first' "$T/o" && pass "4. 409 names the pin" || fail "4. 409 rc=$rc $(cat "$T/o")"
run TENANT_ID=w1 SINCE=2026-09-29T12:00:00Z STUB_CODE=404 STUB_BODY='{}'; rc=$?
[[ $rc -eq 1 ]] && grep -q 'deploy the hub first' "$T/o" && pass "4. 404 names the deploy" || fail "4. 404 rc=$rc $(cat "$T/o")"

(( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
