#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_hub_agent_kinds (rdb 0149, t1 41fa1f2d), with the hub
#          operator call stubbed:
#   1. dry run prints and calls nothing
#   2. bad input (an unknown kind, every kind off, a bad ORDERED_BY, no
#      ORDERED_BY with DRY_RUN=0) is refused before any call
#   3. KINDS_OFF=grok PATCHes {agent_kinds_off:[grok], ordered_by, ordered_via};
#      'none' sends []; the order is the hub's, whatever the input order
#   4. KINDS_OFF unset reads (GET) and prints the kinds off and the pauses
#   5. hub refusals (400, 403) fail
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

run() {
  : >"$T/calls"
  env PROJ_PATH="$PROJ_ROOT" ENV=dev CALLS="$T/calls" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_CNF=/dev/null SPL_PROJECT=csi-spl-dev; }
    spl_hub_operator_url() { SPL_HUB_URL=https://hub.invalid; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.iam.gserviceaccount.com; }
    do_gcp_require_live_account() { :; }
    spl_hub_operator_call() { echo "hub $1 $2 ${3:-}" >>"$CALLS"; SPL_HUB_OP_STATUS="${STUB_CODE:-200}"; SPL_HUB_OP_BODY="${STUB_BODY:-}"; }
    do_spl_hub_agent_kinds' >"$T/o" 2>&1
}
OK_BODY='{"low":50,"high":75,"agent_kinds_off":["grok"],"agent_kinds_paused":{"agy":{"until":"2026-10-08T01:00:00Z","reason":"usage limit: a-1","box":"b1"}},"source":"hub"}'

# --- 1. dry run ---------------------------------------------------------------
run KINDS_OFF=grok; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -q 'DRY_RUN would ask the hub https://hub.invalid to switch off the agent kinds \[grok\]' "$T/o" \
  && pass "1. dry run prints and calls nothing" || fail "1. dry: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 2. refusals --------------------------------------------------------------
for bad in "KINDS_OFF=gpt" "KINDS_OFF=vibe" "KINDS_OFF=claude,grok,agy,qwen,mistral" "KINDS_OFF=grok;rm" "ORDERED_BY=bob" "DRY_RUN=2"; do
  run KINDS_OFF=grok ORDERED_BY=HUM-10 DRY_RUN=0 "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "2. $bad refused before any call" || fail "2. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done
run KINDS_OFF=grok DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'ORDERED_BY .* is required' "$T/o" \
  && pass "2. DRY_RUN=0 without ORDERED_BY is refused" || fail "2. ordered_by: rc=$rc $(cat "$T/o")"

# --- 3. set ---------------------------------------------------------------------
run KINDS_OFF=grok ORDERED_BY=HUM-10 ORDERED_VIA=c-496 DRY_RUN=0 STUB_BODY="$OK_BODY"; rc=$?
[[ $rc -eq 0 ]] && grep -qxF 'hub PATCH /v1/operator/fleet-load {"agent_kinds_off":["grok"],"ordered_by":"HUM-10","ordered_via":"c-496"}' "$T/calls" \
  && grep -q '^OK dev instance agent kinds: off \[grok\], paused \[agy until 2026-10-08T01:00:00Z (usage limit: a-1)\] (set by ordered_by=HUM-10 via c-496' "$T/o" \
  && pass "3. KINDS_OFF=grok PATCHes the set as the SA" || fail "3. set: rc=$rc $(cat "$T/calls" "$T/o")"
run KINDS_OFF="qwen, grok" ORDERED_BY=HUM-10 DRY_RUN=0 STUB_BODY="$OK_BODY"; rc=$?
grep -qF '{"agent_kinds_off":["grok","qwen"],"ordered_by":"HUM-10"}' "$T/calls" \
  && pass "3. the set goes in the hub's order, spaces dropped" || fail "3. order: $(cat "$T/calls" "$T/o")"
run KINDS_OFF=none ORDERED_BY=HUM-10 DRY_RUN=0 STUB_BODY='{"agent_kinds_off":[],"agent_kinds_paused":{}}'; rc=$?
[[ $rc -eq 0 ]] && grep -qF '{"agent_kinds_off":[],"ordered_by":"HUM-10"}' "$T/calls" && grep -q 'off \[\], paused \[\]' "$T/o" \
  && pass "3. 'none' switches every kind on" || fail "3. none: rc=$rc $(cat "$T/calls" "$T/o")"
run KINDS_OFF="mistral,grok" ORDERED_BY=HUM-10 DRY_RUN=0 STUB_BODY="$OK_BODY"; rc=$?
[[ $rc -eq 0 ]] && grep -qF '{"agent_kinds_off":["grok","mistral"],"ordered_by":"HUM-10"}' "$T/calls" \
  && pass "3. mistral is a kind (spec 110), last in the hub's order" || fail "3. mistral: rc=$rc $(cat "$T/calls" "$T/o")"
run KINDS_OFF=claude,grok,agy,qwen ORDERED_BY=HUM-10 DRY_RUN=0 STUB_BODY="$OK_BODY"; rc=$?
[[ $rc -eq 0 ]] && grep -qF '{"agent_kinds_off":["claude","grok","agy","qwen"],"ordered_by":"HUM-10"}' "$T/calls" \
  && pass "3. control: four kinds off is no longer every kind (mistral stays on)" || fail "3. four off: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 4. read --------------------------------------------------------------------
run STUB_BODY="$OK_BODY"; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'hub GET /v1/operator/fleet-load ' "$T/calls" && grep -q '^OK dev instance agent kinds: off \[grok\]' "$T/o" \
  && ! grep -q 'set by' "$T/o" && pass "4. KINDS_OFF unset reads (no DRY_RUN needed)" || fail "4. read: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 5. hub refusals ------------------------------------------------------------
run KINDS_OFF=grok ORDERED_BY=HUM-10 DRY_RUN=0 STUB_CODE=400 STUB_BODY='{"error":"bad_setting","detail":"never all four"}'; rc=$?
[[ $rc -eq 1 ]] && grep -q 'refused the setting (400): never all four' "$T/o" && pass "5. 400 fails with the hub's detail" || fail "5. 400: rc=$rc $(cat "$T/o")"
run STUB_CODE=403 STUB_BODY='{"error":"not_operator"}'; rc=$?
[[ $rc -eq 1 ]] && grep -q 'SPOOL_HUB_OPERATOR_EMAILS' "$T/o" && pass "5. 403 names the operator allowlist" || fail "5. 403: rc=$rc $(cat "$T/o")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
