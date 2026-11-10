#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: one budget rule for every pre-push part, on both tiers (SPL-5238):
#          the part's own variable, when set, wins; else PRE_PUSH_PART_TIMEOUT;
#          else the part's default. And the TIMED OUT note names a variable
#          that really raises that part.
#          c-463, n=1 at load 34..58: a push with PRE_PUSH_PART_TIMEOUT=1500
#          still TIMED OUT wui at 420 s and wui-e2e at 600 s, because
#          _pp_budget read only PRE_PUSH_WUI_TIMEOUT / PRE_PUSH_E2E_TIMEOUT.
#   1. every part x tier + PRE_PUSH_PART_TIMEOUT=77           -> 77
#   2. every part x tier with an own variable, own=4321 and
#      PRE_PUSH_PART_TIMEOUT=77                               -> 4321
#   3. every part x tier, no env budget: the default note ends
#      "raise it with <VAR>", and <VAR>=4321 makes the budget 4321
#   4. every part x tier with a budget variable set: the note names it
#   5. the real runners of wui and wui-e2e, `timeout` stubbed to print the
#      budget it is handed: PRE_PUSH_PART_TIMEOUT=1500 -> 1500, the own
#      variable 4321 -> 4321 (c-508's R7 W1: wui-e2e read only its own
#      variable at check-pre-push-e2e.func.sh, so _pp_budget said 1500 while
#      the run got 600)
#   6. every `timeout -k 10 "..."` a check-pre-push*.func.sh part runs reads
#      $(_pp_budget ...): no part reads its budget variable on its own
#   RED CONTROL: see the commit body (origin/master before SPL-5238).
#   `timeout` and the suites never run: _pp_budget and _pp_budget_why are
#   read directly, at a planted idle load.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/check-pre-push.func.sh"

fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
check() {  # <label> <want> <got>
  [[ "$3" == "$2" ]] && pass "$1" || fail "$1" "want '$2', got '$3'"
}

do_log() { :; }
unset PRE_PUSH_PART_TIMEOUT PRE_PUSH_API_FULL_TIMEOUT PRE_PUSH_API_FULL_CAP PRE_PUSH_IAC_FULL_TIMEOUT \
  PRE_PUSH_IAC_FAST_CAP PRE_PUSH_ORC_FULL_TIMEOUT PRE_PUSH_ORC_FULL_CAP PRE_PUSH_ORC_FAST_CAP \
  PRE_PUSH_WUI_TIMEOUT PRE_PUSH_E2E_TIMEOUT PRE_PUSH_FEATURES_TIMEOUT
# shellcheck source=../run/check-pre-push.func.sh
. "$FUNC"
_pp_load_read() { _PP_LOAD="0.5 16"; }

# <part-fn> <tier> <the part's own variable on that tier, or ->
CASES=(
  "_pp_part_api fast -"
  "_pp_part_api full PRE_PUSH_API_FULL_TIMEOUT"
  "_pp_part_iac fast -"
  "_pp_part_iac full PRE_PUSH_IAC_FULL_TIMEOUT"
  "_pp_part_orc fast -"
  "_pp_part_orc full PRE_PUSH_ORC_FULL_TIMEOUT"
  "_pp_part_wui fast PRE_PUSH_WUI_TIMEOUT"
  "_pp_part_wui full PRE_PUSH_WUI_TIMEOUT"
  "_pp_part_wui_e2e fast PRE_PUSH_E2E_TIMEOUT"
  "_pp_part_wui_e2e full PRE_PUSH_E2E_TIMEOUT"
  "_pp_part_orc_features fast PRE_PUSH_FEATURES_TIMEOUT"
  "_pp_part_orc_features full PRE_PUSH_FEATURES_TIMEOUT"
  "_pp_part_blog fast -"
  "_pp_part_blog full -"
)

at() {  # <tier> <fn> <part-fn> [VAR=val ...] -> <fn>'s output in a clean subshell
  local tier="$1" fn="$2" part="$3"; shift 3
  ( for kv in "$@"; do export "${kv?}"; done; _PP_TIER="$tier" "$fn" "$part" )
}

for c in "${CASES[@]}"; do
  read -r part tier own <<<"$c"
  check "1. $part $tier + PRE_PUSH_PART_TIMEOUT=77" 77 \
    "$(at "$tier" _pp_budget "$part" PRE_PUSH_PART_TIMEOUT=77)"
  check "4. $part $tier + PRE_PUSH_PART_TIMEOUT: the note names it" PRE_PUSH_PART_TIMEOUT \
    "$(at "$tier" _pp_budget_why "$part" PRE_PUSH_PART_TIMEOUT=77)"
  if [[ "$own" != - ]]; then
    check "2. $part $tier: $own wins over PRE_PUSH_PART_TIMEOUT" 4321 \
      "$(at "$tier" _pp_budget "$part" "$own=4321" PRE_PUSH_PART_TIMEOUT=77)"
    check "4. $part $tier + $own: the note names it" "$own" \
      "$(at "$tier" _pp_budget_why "$part" "$own=4321" PRE_PUSH_PART_TIMEOUT=77)"
  fi
  why="$(at "$tier" _pp_budget_why "$part")"
  knob="${why##*raise it with }"
  if [[ "$why" != *"raise it with "* || ! "$knob" =~ ^PRE_PUSH_[A-Z0-9_]+$ ]]; then
    fail "3. $part $tier: the default note names a knob" "got '$why'"
    continue
  fi
  check "3. $part $tier: the default note's knob $knob raises it" 4321 \
    "$(at "$tier" _pp_budget "$part" "$knob=4321")"
done

# 5. the real runners: `timeout` prints the budget it was handed, runs nothing.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/csi-spl-wui"
ran() {  # <part-fn> [VAR=val ...] -> the budget the runner handed `timeout`
  local part="$1"; shift
  ( for kv in "$@"; do export "${kv?}"; done
    timeout() { echo "$3"; }
    _pp_pnpm() { echo pnpm; }
    _PPE_FILES="tests/e2e/x.test.mjs" _PPE_CUT=""
    "$part" "$T" 2>/dev/null | tail -1 )
}
for part in _pp_part_wui _pp_part_wui_e2e; do
  own="$(_pp_part_var "$part")"
  check "5. $part runs under PRE_PUSH_PART_TIMEOUT=1500" 1500 "$(ran "$part" PRE_PUSH_PART_TIMEOUT=1500)"
  check "5. $part runs under $own=4321 over PRE_PUSH_PART_TIMEOUT" 4321 \
    "$(ran "$part" "$own=4321" PRE_PUSH_PART_TIMEOUT=1500)"
done

# 6. no part's `timeout` reads its budget past _pp_budget.
bad="$(grep -nE 'timeout -k [0-9]+ "' "$PROJ_ROOT"/src/bash/run/check-pre-push*.func.sh | grep -v '"\$(_pp_budget ' || true)"
check "6. every part's timeout reads \$(_pp_budget ...)" "" "$bad"

echo "--- $((n - fails))/$n passed ---"
[[ "$fails" -eq 0 ]]
