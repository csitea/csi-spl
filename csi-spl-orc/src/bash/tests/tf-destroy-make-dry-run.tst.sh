#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: every make target that runs a terraform destroy action in the
#          tf-runner hands DRY_RUN into the container (SPL-2624). The iac
#          destroy actions are a dry run unless DRY_RUN=0 (SPL-2570); a make
#          target that drops it makes every destroy through make plan-only,
#          whatever the caller set.
#          Static: `make -n` only, nothing runs, no terraform, no docker.
#          1. each do-tf-destroy* target in src/make/*.mk passes
#             `-e DRY_RUN="0"` when the caller sets DRY_RUN=0, and an empty
#             value when unset (the action's own default, 1, then applies).
#          CONTROL: the same recipe with its DRY_RUN line removed is refused.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ORC=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

cd "$ORC" || exit 1

# <make -n output> <want value> -> problem line, or nothing
check_recipe() {
  local out="$1" want="$2"
  grep -q -- './run -a do_tf_destroy' <<<"$out" || { echo "no do_tf_destroy* action in the recipe"; return; }
  grep -qF -- "-e DRY_RUN=\"$want\"" <<<"$out" || echo "no -e DRY_RUN=\"$want\" into the tf-runner"
}

targets=$(sed -n 's/^\(do-tf-destroy[A-Za-z0-9_-]*\):.*/\1/p' src/make/*.mk | sort -u)
if [[ -z "$targets" ]]; then
  fail "no do-tf-destroy* make target found under src/make"
fi
for tgt in $targets; do
  for want in 0 ""; do
    out=$(env -u PLAN_REF ENV=dev STEP=000-x TARGET=a.b DRY_RUN="$want" \
      make --no-print-directory -n "$tgt" 2>&1)
    prob=$(check_recipe "$out" "$want")
    if [[ -z "$prob" ]]; then
      pass "make $tgt DRY_RUN='$want' -> -e DRY_RUN=\"$want\""
    else
      fail "make $tgt DRY_RUN='$want': $prob"
    fi
  done
  dropped=$(grep -v -- '-e DRY_RUN=' <<<"$out")
  [[ -n "$(check_recipe "$dropped" "")" ]] \
    && pass "control: $tgt without its DRY_RUN line is refused" \
    || fail "control: $tgt without its DRY_RUN line passed"
done

echo "fails=$fails"
[[ $fails -eq 0 ]]
