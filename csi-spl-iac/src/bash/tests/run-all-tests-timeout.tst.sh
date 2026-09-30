#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: run-all-tests.sh runs each test under a per-test timeout, so a
#          hanging test is KILLED and reported, never a hang (the tf-steps
#          five-hour hang that made the pre-push hook dangerous).
#   Control: a temp suite dir with one passing test and one sleeping test, run
#   with a 2 s timeout, must finish quickly, report the sleeper as TIMED OUT,
#   and exit non-zero.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
RUNNER="$PROJ_ROOT/src/bash/tests/run-all-tests.sh"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp "$RUNNER" "$T/run-all-tests.sh"
printf '#!/usr/bin/env bash\nexit 0\n'  >"$T/aaa-pass.tst.sh"
printf '#!/usr/bin/env bash\nsleep 30\n' >"$T/zzz-hang.tst.sh"

start=$SECONDS
IAC_TEST_TIMEOUT=2 bash "$T/run-all-tests.sh" >"$T/out" 2>&1; rc=$?
el=$((SECONDS - start))

[ "$rc" -ne 0 ] && pass "the suite fails when a test hangs" || fail "the suite fails when a test hangs" "rc=$rc"
[ "$el" -lt 20 ] && pass "it finished quickly (${el}s), not the full 30s" || fail "it finished quickly" "took ${el}s"
grep -q 'TIMED OUT.*zzz-hang' "$T/out" && pass "the hanging test is named as TIMED OUT" || fail "the hanging test is named as TIMED OUT" "$(cat "$T/out")"
grep -q '1/2 test files passed' "$T/out" && pass "the passing test still counted" || fail "the passing test still counted" "$(grep 'test files passed' "$T/out")"

echo "-- run-all-tests-timeout.tst.sh: $fails failed"
[ "$fails" -eq 0 ]
