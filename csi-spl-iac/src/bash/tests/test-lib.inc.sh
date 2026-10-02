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
