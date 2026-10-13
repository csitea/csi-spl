#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spl_docs_box_pick sends an agy specs_and_docs lane (and the review
#          aliases) to sat when sat has the agy CLI, else to the one other
#          box in the measured map that has it. The CLI map is an argument.
#          No live box, no spawn-window (that wiring is the placement lane).
#          The stand-in id "pc" is the other box. The home box id is not
#          written here: the distribution sweep forbids it.
#------------------------------------------------------------------------------
set -uo pipefail
unset SPOOL_BOX_TAG DOCS_BOX_FALLBACK
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
# shellcheck disable=SC1091
source "$PROJ_ROOT/src/bash/run/spl-docs-box.func.sh"
pick() { spl_docs_box_pick "$@" >"$T/out"; echo $?; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
line() { cat "$T/out"; }

rc=$(pick agy specs_and_docs "sat=claude,agy pc=claude,agy")
[[ $rc -eq 0 && "$(line)" == "pick=sat reason=agy specs_and_docs goes to sat: sat has the agy CLI" ]] \
  && pass "1. agy specs_and_docs, sat has agy: sat" || fail "1. sat: rc=$rc $(line)"

rc=$(pick agy code_review "sat=claude pc=claude,agy")
[[ $rc -eq 0 && "$(line)" == "pick=pc reason=agy code_review falls back to pc: sat has no agy CLI" ]] \
  && pass "2. agy code_review, sat has no agy: the other box, reason logged" || fail "2. fallback: rc=$rc $(line)"

rc=$(pick agy review "sat=agy pc=")
[[ $rc -eq 0 && "$(line)" == pick=sat\ * ]] \
  && pass "3. agy review, sat has agy: sat" || fail "3. review: rc=$rc $(line)"

rc=$(pick agy spec "pc=agy")
[[ $rc -eq 0 && "$(line)" == pick=pc\ * ]] \
  && pass "4. agy spec, sat not in the map: the other box" || fail "4. spec: rc=$rc $(line)"

rc=$(pick agy simple_coding "sat=claude,agy pc=claude,agy")
[[ $rc -eq 0 && -z "$(line)" ]] \
  && pass "5. agy simple_coding: not this rule" || fail "5. coding: rc=$rc $(line)"

rc=$(pick claude specs_and_docs "sat=claude,agy pc=claude,agy")
[[ $rc -eq 0 && -z "$(line)" ]] \
  && pass "6. claude specs_and_docs: not this rule" || fail "6. claude: rc=$rc $(line)"

rc=$(pick agy specs_and_docs "sat=claude pc=claude")
[[ $rc -eq 2 && "$(line)" == "pick= reason=agy specs_and_docs has nowhere to go: sat has no agy CLI" ]] \
  && pass "7. neither box has agy: return 2, reason logged" || fail "7. none: rc=$rc $(line)"

rc=$(pick agy specs_and_docs "sat=claude pc=agy desk=agy")
[[ $rc -eq 2 ]] \
  && pass "8. two other boxes and no fallback: return 2" || fail "8. ambiguous: rc=$rc $(line)"

rc=$(DOCS_BOX_FALLBACK=pc pick agy code_review "sat=claude pc=agy desk=agy")
[[ $rc -eq 0 && "$(line)" == "pick=pc reason=agy code_review falls back to pc: sat has no agy CLI" ]] \
  && pass "9. DOCS_BOX_FALLBACK names the box when several have agy" || fail "9. fallback env: rc=$rc $(line)"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
