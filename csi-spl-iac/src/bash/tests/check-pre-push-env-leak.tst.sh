#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: (SPL-5063) a pre-push suite gives the same verdict whatever gate
#          switches its caller exported: PRE_PUSH_NO_CACHE=1 in a pusher's env
#          turned three suites red, the other switches seven.
#     1. every affected suite clears every switch at its top
#     2. the override suite (~2 s) stays green with a switch exported that
#        turned it red: PRE_PUSH_NO_CACHE=1, PRE_PUSH_MODE=full
#     3. CONTROL: the same suite without its unset line goes red
#------------------------------------------------------------------------------
set -uo pipefail
unset PRE_PUSH_NO_CACHE PRE_PUSH_MODE PRE_PUSH_SKIP_PASSED PRE_PUSH_ONLY PRE_PUSH_LINT PRE_PUSH_LINT_ONLY PRE_PUSH_CROSS PRE_PUSH_E2E PRE_PUSH_FEATURES 2>/dev/null || true  # SPL-5063: the caller's gate switches must not change these verdicts; a case sets its own
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
SUITE="$TEST_DIR/check-pre-push-override.tst.sh"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

SWITCHES="PRE_PUSH_NO_CACHE PRE_PUSH_MODE PRE_PUSH_SKIP_PASSED PRE_PUSH_ONLY PRE_PUSH_LINT PRE_PUSH_LINT_ONLY PRE_PUSH_CROSS PRE_PUSH_E2E PRE_PUSH_FEATURES"
AFFECTED="check-pre-push-env-leak check-pre-push check-pre-push-errexit check-pre-push-override check-pre-push-scope check-pre-push-tree-pass check-pre-push-e2e check-pre-push-features"

# 1. the unset line, every suite, every switch
for s in $AFFECTED; do
  miss=""
  for v in $SWITCHES; do
    grep -Eq "^unset( .*)? $v( |\$)" "$TEST_DIR/$s.tst.sh" || miss="$miss $v"
  done
  [ -z "$miss" ] && pass "1. $s clears every switch" || fail "1. $s does not clear" "$miss"
done

# 2. a real run keeps its verdict
for e in PRE_PUSH_NO_CACHE=1 PRE_PUSH_MODE=full; do
  env "$e" bash "$SUITE" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] && pass "2. green with $e exported" || fail "2. red with $e exported" "rc $rc"
done

# 3. CONTROL: the suite with no unset line, in a tree that mirrors src/bash
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src/bash/tests"
for d in "$TEST_DIR"/../*; do
  [ "$(basename "$d")" = tests ] || ln -s "$(cd "$d" && pwd)" "$T/src/bash/$(basename "$d")"
done
grep -v '^unset PRE_PUSH_NO_CACHE' "$SUITE" >"$T/src/bash/tests/stripped.tst.sh"
env PRE_PUSH_NO_CACHE=1 bash "$T/src/bash/tests/stripped.tst.sh" >"$T/out" 2>&1; rc=$?
[ "$rc" -ne 0 ] && pass "3. CONTROL: without the unset line the suite is red" \
  || fail "3. CONTROL: the stripped suite stayed green" "$(tail -1 "$T/out")"
env -u PRE_PUSH_NO_CACHE bash "$T/src/bash/tests/stripped.tst.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "3. CONTROL: the stripped suite is green with the switch unset" \
  || fail "3. CONTROL: the stripped suite is red for another reason" "rc $rc"

echo "-- check-pre-push-env-leak.tst.sh: $fails failed"
[ "$fails" -eq 0 ]
