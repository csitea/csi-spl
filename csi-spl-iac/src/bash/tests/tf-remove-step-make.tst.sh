#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: `make tf-remove-step` in csi-spl-orc reaches iac's do_tf_remove_step
#          (SPL-5062; orc's own ./run has no such action). Only `make -n`: the
#          recipe is printed, never run, because the action deletes step files.
#   1. the recipe runs ./run in a dir whose src/bash/run defines the action
#   2. the recipe hands STEP to the action
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
ORC="$APP_ROOT/csi-spl-orc"

mk=$(cd "$ORC" && STEP=014-foo GITHUB_TOKEN=x make --no-print-directory -n tf-remove-step 2>&1 | grep -- '-a do_tf_remove_step')
dir=$(sed -n 's/^cd \([^ ]*\) && .*/\1/p' <<<"$mk"); dir=${dir:-.}
if [[ -n "$mk" && -d "$ORC/$dir/src/bash/run" ]] && grep -qs '^do_tf_remove_step()' "$ORC/$dir/src/bash/run/"*.func.sh; then
  pass "make -n tf-remove-step runs ./run in $dir, which defines do_tf_remove_step"
else
  fail "make -n tf-remove-step cannot reach do_tf_remove_step: '${mk}' (run dir $dir)"
fi
if grep -q 'STEP=014-foo' <<<"$mk"; then
  pass "the recipe hands STEP to the action"
else
  fail "the recipe does not hand STEP to the action: '${mk}'"
fi

echo "---- $(basename "$0"): $fails failed"
[ "$fails" -eq 0 ]
