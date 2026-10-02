#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Shared preamble of the orc action tests (CLE-77915, refactor item 6): 38 tests
# carried the same 7 lines, 17 the same in_orc runner and 12 the same stub
# loop, copied. Source it right after TEST_DIR is set:
#   TEST_DIR=$(cd "$(dirname "$0")" && pwd)
#   source "$TEST_DIR/test-lib.inc.sh"
# It sets PROJ_ROOT, APP_ROOT, pass(), fail() and T (a temp dir removed on
# exit). The test owns its verdict counter: it sets fails=0 right after the
# source line (shellcheck, which does not follow the source, then sees it
# assigned). Not a test itself: run-all-tests.sh runs *.tst.sh only.
#------------------------------------------------------------------------------
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
# specs/061 FR-004: pin the clock the legacy agent-id cutoff reads, so the
# CLE-/PRB-/ORC- fixtures here do not turn the suite red at
# SPOOL_LEGACY_ID_UNTIL on their own. The cutoff itself is tested in
# features/spawn-agents/tests/test-agent-id.sh; L9c drops this pin when it
# converts the fixtures to c-NNN.
export SPOOL_NOW="${SPOOL_NOW:-2026-10-01T00:00:00Z}"
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# orc_stub <exit-code> <bin>... - a stub per bin in $T/stub that appends
# "<bin> <args>" to $STUB_LOG and exits <exit-code>: the test's proof of which
# external calls an action made (none, in a dry run).
orc_stub() {
  local code="$1" b; shift
  mkdir -p "$T/stub"
  for b in "$@"; do
    printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit %s\n' "$b" "$code" >"$T/stub/$b"
  done
  chmod +x "$T/stub/"*
}

# in_orc [VAR=value]... - every orc lib + action sourced in a fresh bash, the
# stubs first on PATH, ENV=dev, then eval "$SNIPPET".
in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" STUB_LOG="$T/calls.log" \
    PATH="$T/stub:$PATH" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}
