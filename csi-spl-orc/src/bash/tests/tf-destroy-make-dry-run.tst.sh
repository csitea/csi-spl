#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: every make target that runs a terraform dry-run action in the
#          tf-runner hands DRY_RUN into the container (SPL-2624, SPL-2679).
#          The iac destroy (SPL-2570), replace-target and state-push
#          (SPL-2664) actions are a dry run unless DRY_RUN=0; a make target
#          that drops it makes the action through make plan-only, whatever
#          the caller set.
#          Static: `make -n` only, nothing runs, no terraform, no docker.
#          1. each do-tf-destroy* target in src/make/*.mk, and
#             do-tf-replace-target, do-tf-state-push, do-tf-state-remove, passes
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
  grep -q -- './run -a do_tf_' <<<"$out" || { echo "no do_tf_* action in the recipe"; return; }
  grep -qF -- "-e DRY_RUN=\"$want\"" <<<"$out" || echo "no -e DRY_RUN=\"$want\" into the tf-runner"
}

targets=$(sed -n 's/^\(do-tf-destroy[A-Za-z0-9_-]*\):.*/\1/p' src/make/*.mk | sort -u)
if [[ -z "$targets" ]]; then
  fail "no do-tf-destroy* make target found under src/make"
fi
for tgt in do-tf-replace-target do-tf-state-push do-tf-state-remove; do
  grep -q "^$tgt:" src/make/*.mk && targets+=$'\n'"$tgt" \
    || fail "no $tgt make target found under src/make"
done
for tgt in $targets; do
  for want in 0 ""; do
    if [[ -n "$want" ]]; then
      out=$(env -u PLAN_REF ENV=dev STEP=000-x TARGET=a.b TFSTATE_FILE=x.tfstate \
        DRY_RUN="$want" make --no-print-directory -n "$tgt" 2>&1)
    else
      out=$(env -u PLAN_REF -u DRY_RUN ENV=dev STEP=000-x TARGET=a.b \
        TFSTATE_FILE=x.tfstate make --no-print-directory -n "$tgt" 2>&1)
    fi
    prob=$(check_recipe "$out" "$want")
    if [[ -z "$prob" ]]; then
      pass "make $tgt DRY_RUN='${want:-<unset>}' -> -e DRY_RUN=\"$want\""
    else
      fail "make $tgt DRY_RUN='${want:-<unset>}': $prob"
    fi
  done
  dropped=$(grep -v -- '-e DRY_RUN=' <<<"$out")
  [[ -n "$(check_recipe "$dropped" "")" ]] \
    && pass "control: $tgt without its DRY_RUN line is refused" \
    || fail "control: $tgt without its DRY_RUN line passed"
done

echo "fails=$fails"
[[ $fails -eq 0 ]]
