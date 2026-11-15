#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: every pre-push part reads its budget from ONE cnf table,
#          env.prepush.part_budget_s (csi-spl-cnf/csi-spl/all.env.yaml,
#          SPL-5574); no part carries a literal budget in code.
#   1. the gate's awk reader of the real table equals yq's read of it
#      (skipped when yq is absent)
#   2. the real table has a default row, and every row is a positive integer
#   3. every _pp_part_* of check-pre-push*.func.sh, both tiers, under a fixture
#      table with a distinct row per part and tier -> exactly that row
#   4. a fixture with only `default: 7` -> 7 for every part and tier
#   5. a fixture with no table -> every part's _pp_budget fails (rc != 0,
#      empty): there is no fallback literal in code
#   6. a <row>_cap scales the row by the load, PRE_PUSH_<ROW>_CAP moves the cap
#   7. no check-pre-push*.func.sh line hands `timeout -k` a literal, or
#      defaults a PRE_PUSH_*_TIMEOUT / *_CAP variable to a literal
#   RED CONTROL (commit body): a part whose _pp_budget echoes a literal fails
#   3 and 5; a planted `timeout -k 10 300` fails 7.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
RUN_DIR="$PROJ_ROOT/src/bash/run"
CNF="$PROJ_ROOT/../csi-spl-cnf/csi-spl/all.env.yaml"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
check() { [[ "$3" == "$2" ]] && pass "$1" || fail "$1" "want '$2', got '$3'"; }

do_log() { :; }
for v in $(compgen -e); do [[ "$v" == PRE_PUSH_* ]] && unset "$v"; done
for f in "$RUN_DIR"/check-pre-push*.func.sh; do
  # shellcheck source=/dev/null
  . "$f"
done
_pp_load_read() { _PP_LOAD="${PLANT_LOAD:-0.5} 16"; }
mapfile -t PARTS < <(declare -F | awk '$3 ~ /^_pp_part_/ { print $3 }' | sort)
(( ${#PARTS[@]} >= 10 )) && pass "0. ${#PARTS[@]} part functions found" \
  || fail "0. part functions found" "${#PARTS[@]}"

# <cnf> <tier> <fn> <part-fn> [VAR=val ...] -> <fn>'s output, fresh table read
at() {
  local cnf="$1" tier="$2" fn="$3" part="$4"; shift 4
  ( for kv in "$@"; do export "${kv?}"; done
    for v in $(compgen -v); do [[ "$v" == _pp_b_* ]] && unset "$v"; done
    unset _PP_BUDGETS_LOADED
    PRE_PUSH_BUDGET_CNF="$cnf" _PP_TIER="$tier" "$fn" "$part" 2>/dev/null )
}

# 1 and 2: the real table.
awk_rows="$(_pp_budget_table "$CNF" | sort)"
if command -v yq >/dev/null 2>&1; then
  yq_rows="$(yq '.env.prepush.part_budget_s | to_entries | .[] | .key + " " + (.value | tostring)' "$CNF" | sort)"
  check "1. awk reader == yq on the real table" "$yq_rows" "$awk_rows"
else
  echo "SKIP: 1. yq absent"
fi
grep -q '^default [1-9][0-9]*$' <<<"$awk_rows" && pass "2. the real table has a default row" \
  || fail "2. the real table has a default row" "$awk_rows"
bad="$(yq '.env.prepush.part_budget_s | to_entries | .[] | select((.value | tag) != "!!int" or .value < 1) | .key' "$CNF" 2>/dev/null || true)"
check "2. every real row is a positive integer" "" "$bad"

# 3: a distinct row per part and tier.
fx="$T/rows.yaml" i=0
{ echo "env:"; echo "  prepush:"; echo "    part_budget_s:"; echo "      default: 7"
  for p in "${PARTS[@]}"; do i=$((i + 1))
    echo "      ${p#_pp_part_}_fast: $((1000 + i))"; echo "      ${p#_pp_part_}_full: $((2000 + i))"
  done; } >"$fx"
i=0
for p in "${PARTS[@]}"; do i=$((i + 1))
  check "3. $p fast reads its row" "$((1000 + i))" "$(at "$fx" fast _pp_budget "$p")"
  check "3. $p full reads its row" "$((2000 + i))" "$(at "$fx" full _pp_budget "$p")"
done

# 4 and 5: default only; no table at all.
printf 'env:\n  prepush:\n    part_budget_s:\n      default: 7\n' >"$T/default.yaml"
printf 'env:\n  other:\n    x: 1\n' >"$T/none.yaml"
for p in "${PARTS[@]}"; do
  for tier in fast full; do
    check "4. $p $tier falls back to default" 7 "$(at "$T/default.yaml" "$tier" _pp_budget "$p")"
    got="$(at "$T/none.yaml" "$tier" _pp_budget "$p")"; rc=$?
    [[ $rc -ne 0 && -z "$got" ]] && pass "5. $p $tier: no table, no budget (rc $rc)" \
      || fail "5. $p $tier: no table, no budget" "rc=$rc got='$got' (a literal in code?)"
  done
done

# 6: a load-scaled row.
printf 'env:\n  prepush:\n    part_budget_s:\n      default: 7\n      api_full: 100\n      api_full_cap: 250\n' >"$T/cap.yaml"
check "6. load 0.5/cpu -> the row" 100 "$(at "$T/cap.yaml" full _pp_budget _pp_part_api PLANT_LOAD=8)"
check "6. load 2/cpu -> 2 x the row" 200 "$(at "$T/cap.yaml" full _pp_budget _pp_part_api PLANT_LOAD=32)"
check "6. load 9/cpu -> the cap" 250 "$(at "$T/cap.yaml" full _pp_budget _pp_part_api PLANT_LOAD=144)"
check "6. PRE_PUSH_API_FULL_CAP moves the cap" 300 \
  "$(at "$T/cap.yaml" full _pp_budget _pp_part_api PLANT_LOAD=144 PRE_PUSH_API_FULL_CAP=300)"

# 7: no literal budget in the gate's code.
lit="$(grep -nE 'timeout -k [0-9]+ +[0-9]|PRE_PUSH_[A-Z_]*(TIMEOUT|CAP)(:-|-)[0-9]' "$RUN_DIR"/check-pre-push*.func.sh | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
check "7. no literal budget in check-pre-push*.func.sh" "" "$lit"

echo "--- $((n - fails))/$n passed"
(( fails == 0 ))
