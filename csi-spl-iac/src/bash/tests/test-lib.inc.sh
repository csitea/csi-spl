#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Shared preamble of the iac tests (CLE-77928, clean-code round: one helper,
# not 52 copies). 52 tests carried the same PROJ_ROOT / APP_ROOT / pass / fail
# lines, copied. Source it right after TEST_DIR is set:
#   TEST_DIR=$(cd "$(dirname "$0")" && pwd)
#   source "$TEST_DIR/test-lib.inc.sh"
# It sets PROJ_ROOT (csi-spl-iac), APP_ROOT (the repo root), pass() and fail().
# The test owns its verdict counter: it sets fails=0 itself (shellcheck, which
# does not follow the source, then sees it assigned). Same contract as
# csi-spl-orc/src/bash/tests/test-lib.inc.sh. Not a test itself:
# run-all-tests.sh runs *.tst.sh only.
#------------------------------------------------------------------------------
# shellcheck disable=SC2034  # PROJ_ROOT / APP_ROOT are read by the sourcing test
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
# shellcheck disable=SC2034
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# require_action <file> - the action under test exists, or the test stops here
# (nothing below it could prove anything). Was a copied 2-line guard in 10 tests.
require_action() {
  [[ -f "$1" ]] && pass "the action lives where the run framework discovers it" \
    || { echo "FAIL: no $1"; exit 1; }
}

# stub <name> <body> - an executable $T/bin/<name> running <body>; the test
# puts $T/bin first on PATH. reset_bin empties it between cases. The caller
# owns T (mktemp -d + its EXIT trap). Was copied into 8 + 4 sec-* tests.
stub() { mkdir -p "$T/bin"; printf '#!/bin/bash\n%s\n' "$2" >"$T/bin/$1"; chmod +x "$T/bin/$1"; }
reset_bin() { rm -rf "${T:?}/bin"; mkdir -p "$T/bin"; }
