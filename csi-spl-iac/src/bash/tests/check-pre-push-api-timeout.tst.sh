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
#   8b. orc-features part: full tier 900 s (every feature ran 308 s on a
#      loaded sat and TIMED OUT at 300 s), fast tier 300 s;
#      PRE_PUSH_FEATURES_TIMEOUT wins on both tiers
#   9. CONTROL, real timeout: an iac suite that runs 2 s is TIMED OUT (rc 124)
#      under a planted 1 s full-tier budget (the 300 s that was too short) and
#      passes under the default
#  10. the api full-tier default fits the box load (2026-10-11, sat load ~33 on
#      16 cpus: the api part TIMED OUT at the fixed 900 s on every tree). The
#      load reader is stubbed (_pp_load_read), the box running the test never
#      moves a number: load/cpu 0.5 -> 900, 2 -> 1800, a huge load -> the cap,
#      PRE_PUSH_API_FULL_CAP moves the cap, PRE_PUSH_API_FULL_TIMEOUT and
#      PRE_PUSH_PART_TIMEOUT still win over the load, the fast tier keeps 300
#  11. the budget's reason names the load it read and the cap
#   RED CONTROL: against the old fixed default (900) case 10's load-2 check fails.
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
unset PRE_PUSH_PART_TIMEOUT PRE_PUSH_API_FULL_TIMEOUT PRE_PUSH_API_FULL_CAP PRE_PUSH_IAC_FULL_TIMEOUT PRE_PUSH_ORC_FULL_TIMEOUT PRE_PUSH_FEATURES_TIMEOUT
# shellcheck source=../run/check-pre-push.func.sh
. "$FUNC"
# timeout -k 10 <budget> bash <script>: print the budget, run nothing.
timeout() { echo "$3"; }
# The load reader, stubbed: PLANT_LOAD on 16 cpus (idle unless a case plants one).
_pp_load_read() { _PP_LOAD="${PLANT_LOAD:-0} 16"; }

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
check "8b. orc-features full tier -> 900"        900  "$(_PP_TIER=full _pp_budget _pp_part_orc_features)"
check "8b. orc-features fast tier -> 300"        300  "$(_PP_TIER=fast _pp_budget _pp_part_orc_features)"
check "8b. orc-features full + PRE_PUSH_FEATURES_TIMEOUT" 1800 "$(PRE_PUSH_FEATURES_TIMEOUT=1800 _PP_TIER=full _pp_budget _pp_part_orc_features)"
check "8b. orc-features fast + PRE_PUSH_FEATURES_TIMEOUT" 50   "$(PRE_PUSH_FEATURES_TIMEOUT=50 _PP_TIER=fast _pp_budget _pp_part_orc_features)"

check "10. api full, load 8/16 (0.5 per cpu) -> 900"      900  "$(budget _pp_part_api full PLANT_LOAD=8)"
check "10. api full, load 32/16 (2 per cpu) -> 1800"       1800 "$(budget _pp_part_api full PLANT_LOAD=32)"
check "10. api full, load 40.5/16 -> 2279 (rounded up)"    2279 "$(budget _pp_part_api full PLANT_LOAD=40.5)"
check "10. api full, load 9999/16 -> the 2700 s cap"         2700 "$(budget _pp_part_api full PLANT_LOAD=9999)"
check "10. api full, load 9999 + PRE_PUSH_API_FULL_CAP=1000" 1000 "$(budget _pp_part_api full PLANT_LOAD=9999 PRE_PUSH_API_FULL_CAP=1000)"
check "10. api full, load 32 + PRE_PUSH_API_FULL_TIMEOUT wins" 1200 "$(budget _pp_part_api full PLANT_LOAD=32 PRE_PUSH_API_FULL_TIMEOUT=1200)"
check "10. api full, load 32 + PRE_PUSH_PART_TIMEOUT wins"  77   "$(budget _pp_part_api full PLANT_LOAD=32 PRE_PUSH_PART_TIMEOUT=77)"
check "10. api fast, load 32 -> 300 (the fast tier is not scaled)" 300 "$(budget _pp_part_api fast PLANT_LOAD=32)"
check "11. the reason names the load and the cap" "api full default 900s x load 32/16 cpus, cap 2700s" \
  "$(PLANT_LOAD=32 _PP_TIER=full _pp_budget_why _pp_part_api)"
check "11. an env budget names its variable" "PRE_PUSH_API_FULL_TIMEOUT" \
  "$(PRE_PUSH_API_FULL_TIMEOUT=1200 _PP_TIER=full _pp_budget_why _pp_part_api)"

# 9. the real timeout on a stub iac suite that runs 2 s
unset -f timeout
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/csi-spl-iac/src/bash/tests"; echo 'sleep 2' >"$T/csi-spl-iac/src/bash/tests/run-all-tests.sh"
rc=0; ( export PRE_PUSH_IAC_FULL_TIMEOUT=1; _PP_TIER=full _pp_part_iac "$T" ) || rc=$?
check "9. CONTROL: planted 1 s full-tier budget -> TIMED OUT (rc 124)" 124 "$rc"
rc=0; ( _PP_TIER=full _pp_part_iac "$T" ) || rc=$?
check "9. the default full-tier budget -> the 2 s suite passes" 0 "$rc"

total=26
echo "--- $((total - fails))/$total passed ---"
[[ "$fails" -eq 0 ]]
