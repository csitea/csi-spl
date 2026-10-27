#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the api part's timeout budget. The FULL-tier api suite (hub Postgres
#          gate ~384 s, 318..514 s measured end to end) cannot fit the 300 s
#          part default, so every full-tier push timed out on any tree.
#   1. fast tier (default)          -> 300 s, the shared part default
#   2. full tier                    -> 1950 s, the api full-tier default
#   3. full tier + PRE_PUSH_PART_TIMEOUT=77  -> 77 (the override still wins)
#   4. fast tier + PRE_PUSH_PART_TIMEOUT=77  -> 77
#   5. full tier + PRE_PUSH_API_FULL_TIMEOUT=1200 -> 1200
#   6. full tier, iac part          -> 600 s, the iac full-tier default (r5-07:
#      the full-tier iac suite passed 300 s inside the gate and TIMED OUT)
#   7. fast tier, iac part          -> 300 s; PRE_PUSH_IAC_FULL_TIMEOUT=1200 -> 1200
#   8. orc part: full tier 4000 s on an idle box, fast tier 300 s
#   8b. orc-features part: full tier 900 s (every feature ran 308 s on a
#      loaded sat and TIMED OUT at 300 s), fast tier 300 s;
#      PRE_PUSH_FEATURES_TIMEOUT wins on both tiers
#   9. CONTROL, real timeout: an iac suite that runs 2 s is TIMED OUT (rc 124)
#      under a planted 1 s full-tier budget (the 300 s that was too short) and
#      passes under the default
#  10. the api full-tier default fits the box load (2026-10-11, sat load ~33 on
#      16 cpus: the api part TIMED OUT at the fixed 900 s on every tree). The
#      load reader is stubbed (_pp_load_read), the box running the test never
#      moves a number: load/cpu 0.5 -> 1950, 1.25 -> 2438, a huge load -> the cap,
#      PRE_PUSH_API_FULL_CAP moves the cap, PRE_PUSH_API_FULL_TIMEOUT and
#      PRE_PUSH_PART_TIMEOUT still win over the load, the fast tier keeps 300
#  11. the budget's reason names the load it read and the cap
#  12. a green trunk fits the idle-box default (2026-10-23, 16 cpus, trunk
#      814d8fe84, n=2: the full-tier api suite ran 1111 s and 842 s below
#      1 load per cpu, where the old 900 s base TIMED OUT it): the idle
#      default is at least 1.75x the slowest, 1111 s
#  13. the orc full-tier default fits the box load the same way (c-001@sat,
#      2026-10-26: at load1 14..52 on 16 cpus the orc part TIMED OUT at the
#      fixed 1800 s on 4 of 4 runs of one tree and 2 of 2 trunk re-checks):
#      load/cpu 0.5 -> 4000, 1.25 -> 5000, 2 -> 6000 (the cap), a huge load
#      -> the cap, PRE_PUSH_ORC_FULL_CAP moves the cap, PRE_PUSH_ORC_FULL_TIMEOUT
#      and PRE_PUSH_PART_TIMEOUT still win, the fast tier keeps 300, the reason
#      names the load, the cap and the variable that raises it
#  14. a green full-tier orc suite fits the idle-box default (SPL-3748, sat 16
#      cpus, box user's pre-push log x sar 10-14..10-27, n=12 below 1 load per cpu:
#      1941..2274 s, every one over the old 1800 s base): the idle default is
#      at least 1.75x the slowest, 2274 s
#  15. the planted run, time scaled 1/1000 (a stubbed `timeout` hands the real
#      one budget/1000 s): a stub orc suite that sleeps 2.274 s (the slowest
#      measured, 2274 s) TIMES OUT (rc 124) under the old 1800 s base and
#      passes under the default
#   RED CONTROL (SPL-3748): against the 1800 s base and 3600 s cap
#   (origin/master 323d69f79) 9 of 39 fail: 8, 11, 5 of the 9 cases in 13
#   (load 8, 20, 32, 9999, the reason), 14 and the pass of 15.
#   RED CONTROL: against the fixed orc 1800 s (origin/master 9575ee69a) 5 of
#   the 9 cases in 13 fail (load 20, 32, 9999, the cap override, the reason).
#   RED CONTROL: against the old fixed default (900) case 10's load-2 check fails;
#   against the old 900 s base (origin/master 814d8fe84) 6 of 27 fail: 2, 11, 12
#   and three of 10 (load 8, 20 and 32).
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
unset PRE_PUSH_PART_TIMEOUT PRE_PUSH_API_FULL_TIMEOUT PRE_PUSH_API_FULL_CAP PRE_PUSH_ORC_FULL_CAP PRE_PUSH_IAC_FULL_TIMEOUT PRE_PUSH_ORC_FULL_TIMEOUT PRE_PUSH_FEATURES_TIMEOUT
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
check "2. api full tier -> 1950"                1950 "$(budget _pp_part_api full)"
check "3. api full + PRE_PUSH_PART_TIMEOUT=77"  77   "$(budget _pp_part_api full PRE_PUSH_PART_TIMEOUT=77)"
check "4. api fast + PRE_PUSH_PART_TIMEOUT=77"  77   "$(budget _pp_part_api fast PRE_PUSH_PART_TIMEOUT=77)"
check "5. api full + PRE_PUSH_API_FULL_TIMEOUT" 1200 "$(budget _pp_part_api full PRE_PUSH_API_FULL_TIMEOUT=1200)"
check "6. iac full tier -> 600"                 600  "$(budget _pp_part_iac full)"
check "7. iac fast tier -> 300"                 300  "$(budget _pp_part_iac fast)"
check "7. iac full + PRE_PUSH_IAC_FULL_TIMEOUT" 1200 "$(budget _pp_part_iac full PRE_PUSH_IAC_FULL_TIMEOUT=1200)"
check "8. orc full tier -> 4000"                4000 "$(_PP_TIER=full _pp_budget _pp_part_orc)"
check "8. orc fast tier -> 300"                 300  "$(_PP_TIER=fast _pp_budget _pp_part_orc)"
check "8b. orc-features full tier -> 900"        900  "$(_PP_TIER=full _pp_budget _pp_part_orc_features)"
check "8b. orc-features fast tier -> 300"        300  "$(_PP_TIER=fast _pp_budget _pp_part_orc_features)"
check "8b. orc-features full + PRE_PUSH_FEATURES_TIMEOUT" 1800 "$(PRE_PUSH_FEATURES_TIMEOUT=1800 _PP_TIER=full _pp_budget _pp_part_orc_features)"
check "8b. orc-features fast + PRE_PUSH_FEATURES_TIMEOUT" 50   "$(PRE_PUSH_FEATURES_TIMEOUT=50 _PP_TIER=fast _pp_budget _pp_part_orc_features)"

check "10. api full, load 8/16 (0.5 per cpu) -> 1950"     1950 "$(budget _pp_part_api full PLANT_LOAD=8)"
check "10. api full, load 20/16 (1.25 per cpu) -> 2438 (rounded up)" 2438 "$(budget _pp_part_api full PLANT_LOAD=20)"
check "10. api full, load 32/16 (2 per cpu) -> the 2700 s cap" 2700 "$(budget _pp_part_api full PLANT_LOAD=32)"
check "10. api full, load 9999/16 -> the 2700 s cap"         2700 "$(budget _pp_part_api full PLANT_LOAD=9999)"
check "10. api full, load 9999 + PRE_PUSH_API_FULL_CAP=3000" 3000 "$(budget _pp_part_api full PLANT_LOAD=9999 PRE_PUSH_API_FULL_CAP=3000)"
check "10. api full, load 32 + PRE_PUSH_API_FULL_TIMEOUT wins" 1200 "$(budget _pp_part_api full PLANT_LOAD=32 PRE_PUSH_API_FULL_TIMEOUT=1200)"
check "10. api full, load 32 + PRE_PUSH_PART_TIMEOUT wins"  77   "$(budget _pp_part_api full PLANT_LOAD=32 PRE_PUSH_PART_TIMEOUT=77)"
check "10. api fast, load 32 -> 300 (the fast tier is not scaled)" 300 "$(budget _pp_part_api fast PLANT_LOAD=32)"
check "11. the reason names the load, the cap and the variable" "api full default 1950s x load 32/16 cpus, cap 2700s; raise it with PRE_PUSH_API_FULL_TIMEOUT" \
  "$(PLANT_LOAD=32 _PP_TIER=full _pp_budget_why _pp_part_api)"
check "11. an env budget names its variable" "PRE_PUSH_API_FULL_TIMEOUT" \
  "$(PRE_PUSH_API_FULL_TIMEOUT=1200 _PP_TIER=full _pp_budget_why _pp_part_api)"

# 12. the idle default fits the measured green trunk (slowest 1111 s) x 1.75
idle="$(budget _pp_part_api full PLANT_LOAD=0)"
[[ "$idle" =~ ^[0-9]+$ ]] && (( idle * 100 >= 1111 * 175 )) \
  && pass "12. idle full-tier api budget ${idle}s >= 1.75 x 1111 s (measured trunk)" \
  || fail "12. idle full-tier api budget >= 1.75 x 1111 s (measured trunk)" "got '$idle'"

orc() {  # <tier> [VAR=val ...] -> the orc part's budget
  local tier="$1"; shift
  ( for kv in "$@"; do export "${kv?}"; done; _PP_TIER="$tier" _pp_budget _pp_part_orc )
}
check "13. orc full, load 8/16 (0.5 per cpu) -> 4000"      4000 "$(orc full PLANT_LOAD=8)"
check "13. orc full, load 20/16 (1.25 per cpu) -> 5000"    5000 "$(orc full PLANT_LOAD=20)"
check "13. orc full, load 32/16 (2 per cpu) -> the 6000 s cap" 6000 "$(orc full PLANT_LOAD=32)"
check "13. orc full, load 9999/16 -> the 6000 s cap"       6000 "$(orc full PLANT_LOAD=9999)"
check "13. orc full, load 9999 + PRE_PUSH_ORC_FULL_CAP=7000" 7000 "$(orc full PLANT_LOAD=9999 PRE_PUSH_ORC_FULL_CAP=7000)"
check "13. orc full, load 32 + PRE_PUSH_ORC_FULL_TIMEOUT wins" 1200 "$(orc full PLANT_LOAD=32 PRE_PUSH_ORC_FULL_TIMEOUT=1200)"
check "13. orc full, load 32 + PRE_PUSH_PART_TIMEOUT wins" 77   "$(orc full PLANT_LOAD=32 PRE_PUSH_PART_TIMEOUT=77)"
check "13. orc fast, load 32 -> 300 (the fast tier is not scaled)" 300 "$(orc fast PLANT_LOAD=32)"
check "13. the orc reason names the load, the cap and the variable" "orc full default 4000s x load 32/16 cpus, cap 6000s; raise it with PRE_PUSH_ORC_FULL_TIMEOUT" \
  "$(PLANT_LOAD=32 _PP_TIER=full _pp_budget_why _pp_part_orc)"

# 14. the idle default fits the measured green full-tier orc suite (slowest 2274 s) x 1.75
idle="$(orc full PLANT_LOAD=0)"
[[ "$idle" =~ ^[0-9]+$ ]] && (( idle * 100 >= 2274 * 175 )) \
  && pass "14. idle full-tier orc budget ${idle}s >= 1.75 x 2274 s (measured on sat)" \
  || fail "14. idle full-tier orc budget >= 1.75 x 2274 s (measured on sat)" "got '$idle'"

# 9. the real timeout on a stub iac suite that runs 2 s
unset -f timeout
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/csi-spl-iac/src/bash/tests"; echo 'sleep 2' >"$T/csi-spl-iac/src/bash/tests/run-all-tests.sh"
rc=0; ( export PRE_PUSH_IAC_FULL_TIMEOUT=1; _PP_TIER=full _pp_part_iac "$T" ) || rc=$?
check "9. CONTROL: planted 1 s full-tier budget -> TIMED OUT (rc 124)" 124 "$rc"
rc=0; ( _PP_TIER=full _pp_part_iac "$T" ) || rc=$?
check "9. the default full-tier budget -> the 2 s suite passes" 0 "$rc"

# 15. the planted orc run, time scaled 1/1000: the slowest measured suite
# (2274 s -> 2.274 s) against the old base (1800 s -> 1.8 s) and the default.
mkdir -p "$T/csi-spl-orc/src/bash/tests"
echo 'sleep 2.274' >"$T/csi-spl-orc/src/bash/tests/run-all-tests.sh"
echo 'exit 0' >"$T/csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh"
timeout() {  # -k <k> <budget s> <cmd...>: the real timeout, budget / 1000
  local k="$2" b="$3"; shift 3
  command timeout -k "$k" "$(awk -v b="$b" 'BEGIN { printf "%.3f", b / 1000 }')" "$@"
}
rc=0; ( _pp_orc_full_base=1800; _PP_TIER=full _pp_part_orc "$T" ) >/dev/null 2>&1 || rc=$?
check "15. CONTROL: the 2274 s suite under the old 1800 s base -> TIMED OUT (rc 124)" 124 "$rc"
rc=0; ( _PP_TIER=full _pp_part_orc "$T" ) >/dev/null 2>&1 || rc=$?
check "15. the 2274 s suite under the default full-tier orc budget -> passes" 0 "$rc"

total=39
echo "--- $((total - fails))/$total passed ---"
[[ "$fails" -eq 0 ]]
