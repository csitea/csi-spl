#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the four copies of the run.sh framework (csi-spl-iac, -orc, -utl
#          and the repo root's src/bash/run/run.sh, SPL-5550) stay
#          byte-identical (SPL-2756). A fix landed in one copy and
#          not the others drifts unseen: utl's do_log stayed 131 lines while
#          iac and orc split it into six steps (r14-09). The three copies
#          of lib/bash/funcs/validate-params.func.sh (iac, orc, utl) are
#          held the same way (r82-02): orc's lost two comments in r3-28.
#   Checks: cmp of iac vs orc, utl and the root copy; the root copy is a
#   real file, not a link to a module's; cmp of iac's validate-params.func.sh
#   vs orc's and utl's.
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

for mod in orc utl root; do
  src="$REPO_ROOT/csi-spl-$mod/src/bash/run/run.sh"
  [[ "$mod" == root ]] && src="$REPO_ROOT/src/bash/run/run.sh"
  if cmp -s "$ref" "$src"; then
    pass "iac and $mod run.sh are byte-identical"
  else
    fail "iac and $mod run.sh differ" "diff $ref $src"
  fi
done
vp="$REPO_ROOT/csi-spl-iac/lib/bash/funcs/validate-params.func.sh"
for mod in orc utl; do
  if cmp -s "$vp" "$REPO_ROOT/csi-spl-$mod/lib/bash/funcs/validate-params.func.sh"; then
    pass "iac and $mod validate-params.func.sh are byte-identical"
  else
    fail "iac and $mod validate-params.func.sh differ" "diff $vp $REPO_ROOT/csi-spl-$mod/lib/bash/funcs/validate-params.func.sh"
  fi
done
if [[ -f "$REPO_ROOT/src/bash/run/run.sh" && ! -L "$REPO_ROOT/src/bash/run/run.sh" ]]; then
  pass "the root run.sh is a real file"
else
  fail "the root run.sh is a real file" "$REPO_ROOT/src/bash/run/run.sh"
fi

{ cat "$ref"; echo '# drift'; } >"$T/run.sh"
cmp -s "$ref" "$T/run.sh" && fail "CONTROL a changed copy passes cmp" \
  || pass "CONTROL a changed copy fails cmp"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
