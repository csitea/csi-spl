#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the api part's timeout budget. The FULL-tier api suite (hub Postgres
#          gate ~384 s, 318..514 s measured end to end) cannot fit the 300 s
#          part default, so every full-tier push timed out on any tree.
#   1. fast tier (default)          -> 300 s, the shared part default
#   2. full tier                    -> 900 s, the api full-tier default
#   3. full tier + PRE_PUSH_PART_TIMEOUT=77  -> 77 (the override still wins)
#   4. fast tier + PRE_PUSH_PART_TIMEOUT=77  -> 77
#   5. full tier + PRE_PUSH_API_FULL_TIMEOUT=1200 -> 1200
#   6. full tier, iac part          -> 600 s, the iac full-tier default (r5-07:
#      the full-tier iac suite passed 300 s inside the gate and TIMED OUT)
#   7. fast tier, iac part          -> 300 s; PRE_PUSH_IAC_FULL_TIMEOUT=1200 -> 1200
#   8. orc part: full tier 1800 s, fast tier 300 s
#   9. CONTROL, real timeout: an iac suite that runs 2 s is TIMED OUT (rc 124)
#      under a planted 1 s full-tier budget (the 300 s that was too short) and
#      passes under the default
#   `timeout` is stubbed to print the budget it was handed, so the suites
#   themselves never run.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/check-pre-push.func.sh"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

do_log() { :; }
do_check_dist_hygiene() { return 0; }
unset PRE_PUSH_PART_TIMEOUT PRE_PUSH_API_FULL_TIMEOUT PRE_PUSH_IAC_FULL_TIMEOUT PRE_PUSH_ORC_FULL_TIMEOUT
# shellcheck source=../run/check-pre-push.func.sh
. "$FUNC"
# timeout -k 10 <budget> bash <script>: print the budget, run nothing.
timeout() { echo "$3"; }

budget() {  # <part-fn> <tier> [VAR=val ...]
  local fn="$1" tier="$2"; shift 2
  ( for kv in "$@"; do export "${kv?}"; done; _PP_TIER="$tier" "$fn" /nonexistent )
}
check() {  # <label> <want> <got>
  [[ "$3" == "$2" ]] && pass "$1" || fail "$1" "want $2, got '$3'"
}

check "1. api fast tier -> 300"                 300  "$(budget _pp_part_api fast)"
check "2. api full tier -> 900"                 900  "$(budget _pp_part_api full)"
check "3. api full + PRE_PUSH_PART_TIMEOUT=77"  77   "$(budget _pp_part_api full PRE_PUSH_PART_TIMEOUT=77)"
check "4. api fast + PRE_PUSH_PART_TIMEOUT=77"  77   "$(budget _pp_part_api fast PRE_PUSH_PART_TIMEOUT=77)"
check "5. api full + PRE_PUSH_API_FULL_TIMEOUT" 1200 "$(budget _pp_part_api full PRE_PUSH_API_FULL_TIMEOUT=1200)"
check "6. iac full tier -> 600"                 600  "$(budget _pp_part_iac full)"
check "7. iac fast tier -> 300"                 300  "$(budget _pp_part_iac fast)"
check "7. iac full + PRE_PUSH_IAC_FULL_TIMEOUT" 1200 "$(budget _pp_part_iac full PRE_PUSH_IAC_FULL_TIMEOUT=1200)"
check "8. orc full tier -> 1800"                1800 "$(_PP_TIER=full _pp_budget _pp_part_orc)"
check "8. orc fast tier -> 300"                 300  "$(_PP_TIER=fast _pp_budget _pp_part_orc)"

# 9. the real timeout on a stub iac suite that runs 2 s
unset -f timeout
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/csi-spl-iac/src/bash/tests"; echo 'sleep 2' >"$T/csi-spl-iac/src/bash/tests/run-all-tests.sh"
rc=0; ( export PRE_PUSH_IAC_FULL_TIMEOUT=1; _PP_TIER=full _pp_part_iac "$T" ) || rc=$?
check "9. CONTROL: planted 1 s full-tier budget -> TIMED OUT (rc 124)" 124 "$rc"
rc=0; ( _PP_TIER=full _pp_part_iac "$T" ) || rc=$?
check "9. the default full-tier budget -> the 2 s suite passes" 0 "$rc"

total=12
echo "--- $((total - fails))/$total passed ---"
[[ "$fails" -eq 0 ]]
