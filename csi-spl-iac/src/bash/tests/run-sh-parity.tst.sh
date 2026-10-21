#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the three copies of the run.sh framework (csi-spl-iac, -orc and
#          -utl) stay byte-identical (SPL-2756). A fix landed in one copy and
#          not the others drifts unseen: utl's do_log stayed 131 lines while
#          iac and orc split it into six steps (r14-09).
#   Checks: cmp of iac vs orc and iac vs utl.
#   Control: a copy with one byte changed fails the same cmp, so the check
#   is not blind.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../../../.." && pwd)

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ref="$REPO_ROOT/csi-spl-iac/src/bash/run/run.sh"

for mod in orc utl; do
  src="$REPO_ROOT/csi-spl-$mod/src/bash/run/run.sh"
  if cmp -s "$ref" "$src"; then
    pass "iac and $mod run.sh are byte-identical"
  else
    fail "iac and $mod run.sh differ" "diff $ref $src"
  fi
done

{ cat "$ref"; echo '# drift'; } >"$T/run.sh"
cmp -s "$ref" "$T/run.sh" && fail "CONTROL a changed copy passes cmp" \
  || pass "CONTROL a changed copy fails cmp"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
