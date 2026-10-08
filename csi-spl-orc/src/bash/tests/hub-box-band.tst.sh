#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_hub_box_band (rdb 0134 / 0152, t1 338e5258), with the hub
#          operator call stubbed:
#   1. bad input (box id, band, cap, ORDERED_BY) is refused before any call
#   2. no BAND / RUNNER_CPU_PCT reads (GET only) and prints the box's band and cap
#   3. DRY_RUN reads and prints the PATCH body, writes nothing
#   4. RUNNER_CPU_PCT sets the box's cap inside its band; the other boxes go back as read
#   5. BAND keeps the box's own cap (the WUI's band save); 'default' drops the cap
#   6. a cap on a box with no band is refused; a 400 fails with the hub's detail
#   7. BAND=default drops the box's entry, cap and all; with a cap it is refused
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

GET_BODY='{"low":50,"high":75,"runner_cpu_pct":80,"boxes":{"box-a":{"low":40,"high":70,"runner_cpu_pct":60},"box-b":{"low":10,"high":20}}}'
run() {
  : >"$T/calls"
  env PROJ_PATH="$PROJ_ROOT" ENV=dev CALLS="$T/calls" STUB_GET="$GET_BODY" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_CNF=/dev/null SPL_PROJECT=csi-spl-dev; }
    spl_hub_operator_url() { SPL_HUB_URL=https://hub.invalid; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.iam.gserviceaccount.com; }
    do_gcp_require_live_account() { :; }
    spl_hub_operator_call() {
      echo "hub $1 $2 ${3:-}" >>"$CALLS"
      SPL_HUB_OP_STATUS="${STUB_CODE:-200}"
      if [[ "$1" == GET ]]; then SPL_HUB_OP_STATUS=200; SPL_HUB_OP_BODY="$STUB_GET"; else SPL_HUB_OP_BODY="${STUB_BODY:-$STUB_GET}"; fi
    }
    do_spl_hub_box_band' >"$T/o" 2>&1
}

# --- 1. refusals ------------------------------------------------------------------
for bad in "BOX=Box_A" "BOX=" "BAND=70..40" "BAND=0..40" "BAND=40..101" "BAND=40-70" "RUNNER_CPU_PCT=0" "RUNNER_CPU_PCT=101" "RUNNER_CPU_PCT=08" "ORDERED_BY=bob"; do
  run BOX=box-a RUNNER_CPU_PCT=60 ORDERED_BY=HUM-10 DRY_RUN=0 "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "1. $bad refused before any call" || fail "1. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done
run BOX=box-a RUNNER_CPU_PCT=60 DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'ORDERED_BY .* is required' "$T/o" \
  && pass "1. DRY_RUN=0 without ORDERED_BY is refused" || fail "1. ordered_by: rc=$rc $(cat "$T/o")"

# --- 2. read ----------------------------------------------------------------------
run BOX=box-a; rc=$?
[[ $rc -eq 0 ]] && [[ "$(cat "$T/calls")" == "hub GET /v1/operator/fleet-load " ]] \
  && grep -qxF "OK dev box box-a: band 40..70, runner CPU cap 60% (its own)" "$T/o" \
  && pass "2. a read GETs and prints the box's own cap" || fail "2. read: rc=$rc $(cat "$T/calls" "$T/o")"
run BOX=box-b; rc=$?
[[ $rc -eq 0 ]] && grep -qxF "OK dev box box-b: band 10..20, runner CPU cap 80% (the fleet's)" "$T/o" \
  && pass "2. a box with no cap of its own reads the fleet's" || fail "2. read b: rc=$rc $(cat "$T/o")"

# --- 3. dry run -------------------------------------------------------------------
run BOX=box-b RUNNER_CPU_PCT=55; rc=$?
[[ $rc -eq 0 ]] && ! grep -q PATCH "$T/calls" \
  && grep -qF 'would PATCH the hub https://hub.invalid as the csi-spl-dev service account with: {"boxes":{"box-a":{"low":40,"high":70,"runner_cpu_pct":60},"box-b":{"low":10,"high":20,"runner_cpu_pct":55}},"ordered_by":""}' "$T/o" \
  && pass "3. DRY_RUN reads, prints the body, writes nothing" || fail "3. dry: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 4. set a cap -----------------------------------------------------------------
run BOX=box-b RUNNER_CPU_PCT=55 ORDERED_BY=HUM-10 ORDERED_VIA=c-540 DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qxF 'hub PATCH /v1/operator/fleet-load {"boxes":{"box-a":{"low":40,"high":70,"runner_cpu_pct":60},"box-b":{"low":10,"high":20,"runner_cpu_pct":55}},"ordered_by":"HUM-10","ordered_via":"c-540"}' "$T/calls" \
  && pass "4. RUNNER_CPU_PCT sets the cap inside the band; box-a goes back with its cap" || fail "4. set: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 5. band keeps the cap; default drops it --------------------------------------
run BOX=box-a BAND=45..75 ORDERED_BY=HUM-10 DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qxF 'hub PATCH /v1/operator/fleet-load {"boxes":{"box-a":{"low":45,"high":75,"runner_cpu_pct":60},"box-b":{"low":10,"high":20}},"ordered_by":"HUM-10"}' "$T/calls" \
  && pass "5. BAND keeps the box's own runner_cpu_pct" || fail "5. band: rc=$rc $(cat "$T/calls" "$T/o")"
run BOX=box-a RUNNER_CPU_PCT=default ORDERED_BY=HUM-10 DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qxF 'hub PATCH /v1/operator/fleet-load {"boxes":{"box-a":{"low":40,"high":70},"box-b":{"low":10,"high":20}},"ordered_by":"HUM-10"}' "$T/calls" \
  && pass "5. 'default' drops the box's cap and keeps its band" || fail "5. default: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 6. no band; hub refusal --------------------------------------------------------
run BOX=box-c RUNNER_CPU_PCT=60 ORDERED_BY=HUM-10 DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && ! grep -q PATCH "$T/calls" && grep -q 'box box-c has no band of its own' "$T/o" \
  && pass "6. a cap on a box with no band is refused, no PATCH" || fail "6. no band: rc=$rc $(cat "$T/calls" "$T/o")"
run BOX=box-c BAND=30..60 RUNNER_CPU_PCT=60 ORDERED_BY=HUM-10 DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qF '"box-c":{"low":30,"high":60,"runner_cpu_pct":60}' "$T/calls" \
  && pass "6. BAND with the cap adds the box" || fail "6. add: rc=$rc $(cat "$T/calls" "$T/o")"
run BOX=box-a RUNNER_CPU_PCT=60 ORDERED_BY=HUM-10 DRY_RUN=0 STUB_CODE=400 STUB_BODY='{"error":"bad_setting","detail":"runner_cpu_pct is 1..100"}'; rc=$?
[[ $rc -eq 1 ]] && grep -q 'refused the setting (400): runner_cpu_pct is 1..100' "$T/o" && pass "6. 400 fails with the hub's detail" || fail "6. 400: rc=$rc $(cat "$T/o")"

# --- 7. BAND=default ---------------------------------------------------------------
run BOX=box-a BAND=default ORDERED_BY=HUM-10 DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qxF 'hub PATCH /v1/operator/fleet-load {"boxes":{"box-b":{"low":10,"high":20}},"ordered_by":"HUM-10"}' "$T/calls" \
  && pass "7. BAND=default drops box-a's entry, the rest goes back as read" || fail "7. drop: rc=$rc $(cat "$T/calls" "$T/o")"
run BOX=box-a BAND=default RUNNER_CPU_PCT=60 ORDERED_BY=HUM-10 DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "7. BAND=default with a cap is refused before any call" || fail "7. drop+cap: rc=$rc $(cat "$T/calls" "$T/o")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
