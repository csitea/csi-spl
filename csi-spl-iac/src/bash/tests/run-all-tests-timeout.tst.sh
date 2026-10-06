#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: run-all-tests.sh runs each test under a per-test timeout, so a
#          hanging test is KILLED and reported, never a hang (the tf-steps
#          five-hour hang that made the pre-push hook dangerous).
#   Control: a temp suite dir with one passing test and one sleeping test, run
#   with a 2 s timeout, must finish quickly, report the sleeper as TIMED OUT,
#   and exit non-zero.
#   Control (c-411): a test whose header says '# test-timeout: 10' and sleeps 4 s
#   PASSES under the same 2 s global bound (a named heavy test is not a hang),
#   and every verdict block ends with that file's wall time.
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
printf '#!/usr/bin/env bash\n# test-timeout: 10 -- heavy\nsleep 4\n' >"$T/mmm-heavy.tst.sh"

start=$SECONDS
IAC_TEST_TIMEOUT=2 bash "$T/run-all-tests.sh" >"$T/out" 2>&1; rc=$?
el=$((SECONDS - start))

[ "$rc" -ne 0 ] && pass "the suite fails when a test hangs" || fail "the suite fails when a test hangs" "rc=$rc"
[ "$el" -lt 20 ] && pass "it finished quickly (${el}s), not the full 30s" || fail "it finished quickly" "took ${el}s"
grep -q 'TIMED OUT.*zzz-hang' "$T/out" && pass "the hanging test is named as TIMED OUT" || fail "the hanging test is named as TIMED OUT" "$(cat "$T/out")"
grep -q '2/3 test files passed' "$T/out" && pass "the passing tests still counted" || fail "the passing tests still counted" "$(grep 'test files passed' "$T/out")"
grep -q 'TIMED OUT.*mmm-heavy' "$T/out" && fail "a '# test-timeout:' header lifts that file's bound" "$(cat "$T/out")" || pass "a '# test-timeout:' header lifts that file's bound"
grep -q 'TIMED OUT (>2s), killed: zzz-hang' "$T/out" && pass "a file without the header keeps the global bound" || fail "a file without the header keeps the global bound" "$(grep 'TIMED OUT' "$T/out")"
grep -qE '^--- mmm-heavy.tst.sh took [4-9]s$' "$T/out" && pass "each verdict block prints the file's wall time" || fail "each verdict block prints the file's wall time" "$(grep '^--- ' "$T/out")"

echo "-- run-all-tests-timeout.tst.sh: $fails failed"
[ "$fails" -eq 0 ]
