#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_hub_runner_cpu (rdb 0152, t1 338e5258), with the hub
#          operator call stubbed:
#   1. dry run prints and calls nothing
#   2. bad input (0, 101, not a number, a bad ORDERED_BY, no ORDERED_BY with
#      DRY_RUN=0) is refused before any call
#   3. RUNNER_CPU_PCT=80 PATCHes {runner_cpu_pct:80, ordered_by, ordered_via};
#      'default' sends null
#   4. RUNNER_CPU_PCT unset reads (GET) and prints the cap in force and stored
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
    do_spl_hub_runner_cpu' >"$T/o" 2>&1
}
OK_BODY='{"low":50,"high":75,"runner_cpu_pct":80,"stored":{"runner_cpu_pct":80},"source":"hub"}'

# --- 1. dry run ---------------------------------------------------------------
run RUNNER_CPU_PCT=80; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -q 'DRY_RUN would ask the hub https://hub.invalid to set the runner CPU cap to 80' "$T/o" \
  && pass "1. dry run prints and calls nothing" || fail "1. dry: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 2. refusals --------------------------------------------------------------
for bad in "RUNNER_CPU_PCT=0" "RUNNER_CPU_PCT=101" "RUNNER_CPU_PCT=08" "RUNNER_CPU_PCT=8x" "ORDERED_BY=bob" "DRY_RUN=2"; do
  run RUNNER_CPU_PCT=80 ORDERED_BY=HUM-10 DRY_RUN=0 "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "2. $bad refused before any call" || fail "2. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done
run RUNNER_CPU_PCT=80 DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'ORDERED_BY .* is required' "$T/o" \
  && pass "2. DRY_RUN=0 without ORDERED_BY is refused" || fail "2. ordered_by: rc=$rc $(cat "$T/o")"

# --- 3. set ---------------------------------------------------------------------
run RUNNER_CPU_PCT=80 ORDERED_BY=HUM-10 ORDERED_VIA=c-543 DRY_RUN=0 STUB_BODY="$OK_BODY"; rc=$?
[[ $rc -eq 0 ]] && grep -qxF 'hub PATCH /v1/operator/fleet-load {"runner_cpu_pct":80,"ordered_by":"HUM-10","ordered_via":"c-543"}' "$T/calls" \
  && grep -q '^OK dev instance runner CPU cap: 80% in force, stored 80 (set by ordered_by=HUM-10 via c-543' "$T/o" \
  && pass "3. RUNNER_CPU_PCT=80 PATCHes the cap as the SA" || fail "3. set: rc=$rc $(cat "$T/calls" "$T/o")"
run RUNNER_CPU_PCT=default ORDERED_BY=HUM-10 DRY_RUN=0 STUB_BODY='{"runner_cpu_pct":80,"stored":{"runner_cpu_pct":null}}'; rc=$?
[[ $rc -eq 0 ]] && grep -qF '{"runner_cpu_pct":null,"ordered_by":"HUM-10"}' "$T/calls" && grep -q '80% in force, stored unset' "$T/o" \
  && pass "3. 'default' resets it (null)" || fail "3. default: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 4. read --------------------------------------------------------------------
run STUB_BODY="$OK_BODY"; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'hub GET /v1/operator/fleet-load ' "$T/calls" && grep -q '^OK dev instance runner CPU cap: 80% in force' "$T/o" \
  && ! grep -q 'set by' "$T/o" && pass "4. RUNNER_CPU_PCT unset reads (no DRY_RUN needed)" || fail "4. read: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 5. hub refusals ------------------------------------------------------------
run RUNNER_CPU_PCT=80 ORDERED_BY=HUM-10 DRY_RUN=0 STUB_CODE=400 STUB_BODY='{"error":"bad_setting","detail":"runner_cpu_pct is 1..100"}'; rc=$?
[[ $rc -eq 1 ]] && grep -q 'refused the setting (400): runner_cpu_pct is 1..100' "$T/o" && pass "5. 400 fails with the hub's detail" || fail "5. 400: rc=$rc $(cat "$T/o")"
run STUB_CODE=403 STUB_BODY='{"error":"not_operator"}'; rc=$?
[[ $rc -eq 1 ]] && grep -q 'SPOOL_HUB_OPERATOR_EMAILS' "$T/o" && pass "5. 403 names the operator allowlist" || fail "5. 403: rc=$rc $(cat "$T/o")"

# --- 6. r01-02 one copy and standalone lazy-source ------------------------------
run STUB_CODE=404 STUB_BODY='{"error":"no_op"}'; rc=$?
[[ $rc -eq 1 ]] && grep -qxF 'FATAL the hub answered 404 (no_op): no operator workspace, or a hub without this door yet. Nothing changed.' "$T/o" \
  && pass "6. runner-cpu 404 fails with exact message" || fail "6. cpu 404: rc=$rc $(cat "$T/o")"
run STUB_CODE=500 STUB_BODY='{"detail":"boom"}'; rc=$?
[[ $rc -eq 1 ]] && grep -qxF 'FATAL the instance runner CPU cap was not read or changed (http 500): boom' "$T/o" \
  && pass "6. runner-cpu 500 fails with exact subject_verb message" || fail "6. cpu 500: rc=$rc $(cat "$T/o")"
rc_f="$PROJ_ROOT/src/bash/run/spl-hub-runner-cpu.func.sh"
own="$(grep -nE "FATAL the hub refused the setting \(400\):|SPOOL_HUB_OPERATOR_EMAILS\?|FATAL the hub answered 404 \(" "$rc_f" || true)"
[[ -z "$own" ]] && grep -q "_spl_hub_fleet_load_error " "$rc_f" \
  && pass "6. one copy: spl-hub-runner-cpu.func.sh delegates errors to _spl_hub_fleet_load_error" || fail "6. cpu one copy: own=[$own]"
out=$(env PROJ_PATH="$PROJ_ROOT" ENV=dev bash -c '
  set -uo pipefail; do_log(){ echo "$*"; }; do_require_bin(){ :; }
  do_spl_cloud_cnf(){ SPL_CNF=/dev/null SPL_PROJECT=csi-spl-dev; }
  spl_hub_operator_url(){ SPL_HUB_URL=https://hub.invalid; }
  do_gcp_pin_account(){ GCP_ACCOUNT=sa@example.test; }
  do_gcp_require_live_account(){ :; }
  spl_hub_operator_call(){ SPL_HUB_OP_STATUS=400; SPL_HUB_OP_BODY="{\"detail\":\"bad\"}"; }
  source "$PROJ_PATH/src/bash/run/spl-hub-runner-cpu.func.sh"
  do_spl_hub_runner_cpu' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == "FATAL the hub refused the setting (400): bad. Nothing changed." && "$out" != *"command not found"* ]] \
  && pass "6. lazy load: spl-hub-runner-cpu.func.sh loads _spl_hub_fleet_load_error standalone" || fail "6. lazy cpu: rc=$rc $out"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
