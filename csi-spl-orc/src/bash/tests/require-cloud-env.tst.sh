#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spl_require_cloud_env is the ONE copy of the cloud-env rule (dev and
#          prd only, SPL-1038): dev / prd pass silently; anything else logs
#          "FATAL ENV must be dev or prd, got: '<v>'" and returns 1; an
#          explicit value is checked instead of $ENV. Gate: the pasted guard
#          does not come back into any orc action.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/lib/bash/funcs/spl-cloud-cnf.func.sh"
fails=0
check() { if [[ "$1" == "$2" ]]; then echo "PASS: $3"; else echo "FAIL: $3 (got '$1', want '$2')"; fails=$((fails + 1)); fi; }
bash -n "$FUNC" || { echo "FAIL: bash -n $FUNC"; exit 1; }
do_log() { echo "$*"; }
# shellcheck disable=SC1090
source "$FUNC"

for e in dev prd; do
  out=$(ENV=$e spl_require_cloud_env); check "$?:$out" "0:" "ENV=$e passes silently"
done
for e in "" prod lde tst "dev "; do
  out=$(ENV=$e spl_require_cloud_env); check "$?:$out" "1:FATAL ENV must be dev or prd, got: '$e'" "ENV='$e' is refused"
done
out=$(unset ENV; spl_require_cloud_env); check "$?:$out" "1:FATAL ENV must be dev or prd, got: ''" "unset ENV is refused"
out=$(ENV=dev spl_require_cloud_env prod); check "$?:$out" "1:FATAL ENV must be dev or prd, got: 'prod'" "an explicit value wins over ENV"
out=$(ENV=prod spl_require_cloud_env prd); check "$?:$out" "0:" "an explicit good value passes"

# The gate: the rule lives in the helper only (was pasted 6 times).
n=$(grep -rnF "FATAL ENV must be dev or prd, got: '\${ENV:-}'" "$PROJ_ROOT/src/bash/run" "$PROJ_ROOT/lib/bash/funcs" | wc -l)
check "$n" 0 "no action re-pastes the cloud-env guard (use spl_require_cloud_env)"

[[ $fails == 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
