#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: run-ci-tests.sh, stopped by TERM, names EVERY file it did not finish
#          even when a second TERM follows. GNU timeout (the pre-push part's
#          stop) signals the child and then its whole process group, so the
#          runner gets TERM twice; on_term used to begin with `trap - TERM`,
#          and a second TERM landing after that killed it mid-listing, silent
#          (wf 10 38708771369, check-pre-push-features case 6: "orc-features:
#          runs quick slow" and nothing named; measured 7/640 under load, 0/640
#          with the fix). The listing is made long (300 planned files, one job)
#          so the second TERM lands inside it every time:
#   1. TERM, then TERM 50 ms later -> rc 124 and all 300 files named
#   2. CONTROL: the runner with `trap - TERM` back dies 143 with < 300 named
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
RUNNER="$PROJ_ROOT/src/bash/features/run-ci-tests.sh"
N=300

# term_twice <runner> -> "rc=<rc> named=<n>"
term_twice() {
  local R="$T/tree.$RANDOM" F i pid rc t
  F="$R/csi-spl-orc/src/bash/features"
  mkdir -p "$F/slow/tests" "$R/csi-spl-orc/src/bash/tests" "$R/bin"
  cp "$1" "$F/run-ci-tests.sh"
  for (( i = 1; i <= N; i++ )); do printf 'sleep 30\n' >"$F/slow/tests/test-s$(printf '%03d' "$i").sh"; done
  printf '#!/bin/sh\nexit 0\n' >"$R/bin/tmux"; chmod +x "$R/bin/tmux"
  ( cd "$R" && PATH="$R/bin:$PATH" FEATURE_TEST_JOBS=1 exec setsid bash csi-spl-orc/src/bash/features/run-ci-tests.sh slow ) >"$R/out" 2>&1 &
  pid=$!
  # the first file has started: its sleep is the runner's grandchild
  for (( t = 0; t < 100; t++ )); do pgrep -g "$pid" -x sleep >/dev/null && break; sleep 0.1; done
  kill -TERM "$pid"; sleep 0.05; kill -TERM "$pid" 2>/dev/null
  wait "$pid"; rc=$?
  kill -KILL -- "-$pid" 2>/dev/null
  echo "rc=$rc named=$(grep -c '^UNFINISHED ' "$R/out")"
}

# --- 1. the runner as shipped ---------------------------------------------------
got="$(term_twice "$RUNNER")"
[[ "$got" == "rc=124 named=$N" ]] && pass "1 TERM twice: rc 124 and all $N unfinished files named" || fail "1 TERM twice: $got (want rc=124 named=$N)"

# --- 2. CONTROL: on_term resetting TERM to its default ------------------------------
sed "s/^  trap '' TERM\$/  trap - TERM/" "$RUNNER" >"$T/runner-reset.sh"
if grep -q "^  trap - TERM\$" "$T/runner-reset.sh"; then
  got="$(term_twice "$T/runner-reset.sh")"
  [[ "$got" =~ ^rc=143\ named=([0-9]+)$ ]] && (( BASH_REMATCH[1] < N )) &&
    pass "2 CONTROL with trap - TERM the second TERM kills it mid-listing ($got)" ||
    fail "2 CONTROL the reset runner still named every file: $got (the check proves nothing)"
else
  fail "2 CONTROL could not plant 'trap - TERM' (on_term changed?)"
fi

echo "---- $(basename "$0"): $fails failed"
[[ "$fails" -eq 0 ]]
