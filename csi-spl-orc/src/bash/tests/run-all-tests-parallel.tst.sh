#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: run-all-tests.sh runs the files ORC_TEST_JOBS at a time (perf round
#          4, C2) and still reads like a serial run.
#   Control: a temp suite of three 2 s sleepers, one failing test and one
#   '# serial' test, run with ORC_TEST_JOBS=4, must: take well under the 8 s a
#   serial run needs, still FAIL and name the failing test, print each file's
#   output right under its own header in suite order with the '# serial' test
#   last and alone, and refuse a JOBS value that is not a positive integer.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
RUNNER="$PROJ_ROOT/src/bash/tests/run-all-tests.sh"
JOBS_VAR=ORC_TEST_JOBS

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp "$RUNNER" "$T/run-all-tests.sh"
for f in a b c; do printf '#!/usr/bin/env bash\necho "out-%s"\nsleep 2\necho "end-%s"\n' "$f" "$f" >"$T/$f-sleep.tst.sh"; done
printf '#!/usr/bin/env bash\necho "out-d"\nexit 3\n' >"$T/d-fail.tst.sh"
# the serial test fails if any other test of the suite is still running
printf '#!/usr/bin/env bash\n# serial\npgrep -f "%s/[a-d]-.*tst.sh" >/dev/null && { echo "ran-alongside"; exit 1; }\necho "out-s"\n' "$T" >"$T/s-alone.tst.sh"

start=$SECONDS
env "$JOBS_VAR=4" bash "$T/run-all-tests.sh" >"$T/out" 2>&1; rc=$?
el=$((SECONDS - start))

[ "$rc" -ne 0 ] && pass "the suite still fails when one test fails" || fail "the suite still fails when one test fails" "rc=$rc"
grep -qx 'FAILED: d-fail.tst.sh' "$T/out" && pass "the failing test is named" || fail "the failing test is named" "$(cat "$T/out")"
[ "$el" -lt 6 ] && pass "three 2 s tests ran in parallel (${el}s, serial needs 6+)" || fail "three 2 s tests ran in parallel" "took ${el}s"
heads=$(grep '^=== [a-z]' "$T/out" | tr '\n' ' ')
[ "$heads" = "=== a-sleep.tst.sh === b-sleep.tst.sh === c-sleep.tst.sh === d-fail.tst.sh === s-alone.tst.sh " ] \
  && pass "headers print in suite order, the '# serial' test last" || fail "headers print in suite order" "$heads"
grep -A2 -x '=== b-sleep.tst.sh' "$T/out" | tr '\n' ' ' | grep -qx '=== b-sleep.tst.sh out-b end-b ' \
  && pass "a file's output is not interleaved with another's" || fail "a file's output is not interleaved" "$(cat "$T/out")"
grep -qx 'out-s' "$T/out" && pass "the '# serial' test ran alone" || fail "the '# serial' test ran alone" "$(cat "$T/out")"
grep -q '4/5 test files passed' "$T/out" && pass "the count is 4/5" || fail "the count is 4/5" "$(grep 'test files passed' "$T/out")"

env "$JOBS_VAR=1" bash "$T/run-all-tests.sh" >"$T/out1" 2>&1; rc1=$?
[ "$rc1" -ne 0 ] && grep -qx 'FAILED: d-fail.tst.sh' "$T/out1" && grep -q '4/5 test files passed' "$T/out1" \
  && pass "$JOBS_VAR=1 gives the same verdicts" || fail "$JOBS_VAR=1 gives the same verdicts" "rc=$rc1 $(cat "$T/out1")"

env "$JOBS_VAR=x" bash "$T/run-all-tests.sh" >"$T/outx" 2>&1; rcx=$?
[ "$rcx" -eq 2 ] && grep -q "$JOBS_VAR must be a positive integer" "$T/outx" \
  && pass "a bad $JOBS_VAR is refused (rc 2)" || fail "a bad $JOBS_VAR is refused" "rc=$rcx $(cat "$T/outx")"

echo "-- run-all-tests-parallel.tst.sh: $fails failed"
[ "$fails" -eq 0 ]
