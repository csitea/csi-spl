#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: run-all-tests.sh runs the files ORC_TEST_JOBS at a time (perf round
#          4, C2) and still reads like a serial run.
#   Control: a temp suite of three barrier tests, one failing test and one
#   '# serial' test, run with ORC_TEST_JOBS=4, must: run the three
#   together (each waits until all three started: a serial run never meets
#   that barrier, and no wall-clock bound reads a loaded runner as serial,
#   c-551), still FAIL and name the failing test, print each file's
#   output right under its own header in suite order with the '# serial' test
#   last and alone, and refuse a JOBS value that is not a positive integer.
#   Timing guard: the run ends with the slowest files, their wall and CPU;
#   ORC_TEST_SHARD=<k>/<m> splits the files with no file lost or run twice,
#   and no test file inherits it (a test that runs the suite sees all of it).
#   The shards are a longest-first pack of orc-shard-weights.txt, the pool
#   starts the heaviest first, and ORC_TEST_TIMES=1 lists every file's time.
#   A suite stopped by TERM prints every finished file with its verdict and
#   '=== stopped: N of M files finished, K not run', and exits non-zero.
#   A test gets only its own stdout and stderr, never the runner's spare fd 3
#   (ORC_TEST_JOBS=1 ran each file with it open): a process the test leaves
#   behind kept the pre-push part's tee pipe open and hung the hook (SPL-3907).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
RUNNER="$PROJ_ROOT/src/bash/tests/run-all-tests.sh"
JOBS_VAR=ORC_TEST_JOBS
# the suite under test reads these; a caller's values (a CI shard, a local
# ORC_TEST_SLOWEST=300) must not reach it
unset ORC_TEST_SHARD ORC_TEST_SLOWEST ORC_TEST_WEIGHTS ORC_TEST_TIMES

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp "$RUNNER" "$T/run-all-tests.sh"
# a barrier test: marks its start, then waits (BARRIER=1, up to 60 s) until
# all three started; only a parallel run gets all three past it
for f in a b c; do
  printf '#!/usr/bin/env bash\necho "out-%s"\n: >"%s/started-%s"\n' "$f" "$T" "$f" >"$T/$f-sleep.tst.sh"
  printf '[ "${BARRIER:-1}" = 0 ] || for _ in $(seq 600); do [ -e "%s/started-a" ] && [ -e "%s/started-b" ] && [ -e "%s/started-c" ] && break; sleep 0.1; done\n' "$T" "$T" "$T" >>"$T/$f-sleep.tst.sh"
  printf '[ "${BARRIER:-1}" = 0 ] || { [ -e "%s/started-a" ] && [ -e "%s/started-b" ] && [ -e "%s/started-c" ]; } || { echo "no-barrier-%s"; exit 1; }\necho "end-%s"\n' "$T" "$T" "$T" "$f" "$f" >>"$T/$f-sleep.tst.sh"
done
printf '#!/usr/bin/env bash\necho "out-d shard=${ORC_TEST_SHARD:-unset}"\nexit 3\n' >"$T/d-fail.tst.sh"
# the serial test fails if any other test of the suite is still running
printf '#!/usr/bin/env bash\n# serial\npgrep -f "%s/[a-d]-.*tst.sh" >/dev/null && { echo "ran-alongside"; exit 1; }\necho "out-s"\n' "$T" >"$T/s-alone.tst.sh"

env "$JOBS_VAR=4" bash "$T/run-all-tests.sh" >"$T/out" 2>&1; rc=$?

[ "$rc" -ne 0 ] && pass "the suite still fails when one test fails" || fail "the suite still fails when one test fails" "rc=$rc"
grep -qx 'FAILED: d-fail.tst.sh' "$T/out" && pass "the failing test is named" || fail "the failing test is named" "$(cat "$T/out")"
! grep -q '^no-barrier-' "$T/out" && [ "$(grep -c '^end-[abc]$' "$T/out")" -eq 3 ] \
  && pass "three tests ran in parallel (all three met the barrier)" || fail "three tests ran in parallel" "$(cat "$T/out")"
heads=$(grep '^=== [a-z]' "$T/out" | tr '\n' ' ')
[ "$heads" = "=== a-sleep.tst.sh === b-sleep.tst.sh === c-sleep.tst.sh === d-fail.tst.sh === s-alone.tst.sh " ] \
  && pass "headers print in suite order, the '# serial' test last" || fail "headers print in suite order" "$heads"
grep -A2 -x '=== b-sleep.tst.sh' "$T/out" | tr '\n' ' ' | grep -x '=== b-sleep.tst.sh out-b end-b ' >/dev/null \
  && pass "a file's output is not interleaved with another's" || fail "a file's output is not interleaved" "$(cat "$T/out")"
grep -qx 'out-s' "$T/out" && pass "the '# serial' test ran alone" || fail "the '# serial' test ran alone" "$(cat "$T/out")"
grep -q '4/5 test files passed' "$T/out" && pass "the count is 4/5" || fail "the count is 4/5" "$(grep 'test files passed' "$T/out")"

env "$JOBS_VAR=1" BARRIER=0 bash "$T/run-all-tests.sh" >"$T/out1" 2>&1; rc1=$?
[ "$rc1" -ne 0 ] && grep -qx 'FAILED: d-fail.tst.sh' "$T/out1" && grep -q '4/5 test files passed' "$T/out1" \
  && pass "$JOBS_VAR=1 gives the same verdicts" || fail "$JOBS_VAR=1 gives the same verdicts" "rc=$rc1 $(cat "$T/out1")"

F3=$T/fd3; mkdir -p "$F3"
cp "$RUNNER" "$F3/run-all-tests.sh"
printf '#!/usr/bin/env bash\nif [ -e /dev/fd/3 ]; then echo "fd3-open"; else echo "fd3-closed"; fi\n' >"$F3/a-fd.tst.sh"
env "$JOBS_VAR=1" bash "$F3/run-all-tests.sh" >"$T/outfd" 2>&1
grep -qx 'fd3-closed' "$T/outfd" && pass "$JOBS_VAR=1 hands a test no fd beyond its stdout and stderr" \
  || fail "$JOBS_VAR=1 hands a test no fd beyond its stdout and stderr" "$(cat "$T/outfd")"

env "$JOBS_VAR=x" bash "$T/run-all-tests.sh" >"$T/outx" 2>&1; rcx=$?
[ "$rcx" -eq 2 ] && grep -q "$JOBS_VAR must be a positive integer" "$T/outx" \
  && pass "a bad $JOBS_VAR is refused (rc 2)" || fail "a bad $JOBS_VAR is refused" "rc=$rcx $(cat "$T/outx")"

slow=$(sed -n '/^--- slowest 10 test files (wall s, cpu s)$/,$p' "$T/out")
[ "$(grep -cE '^ +[0-9]+\.[0-9] +[0-9]+\.[0-9]  [a-z]-[a-z]+\.tst\.sh$' <<<"$slow")" -eq 5 ] \
  && grep -qE '^--- sum over 5 files: wall [0-9]+ s, cpu [0-9]+ s$' <<<"$slow" \
  && pass "the run ends with the slowest files, their wall and cpu time" || fail "the slowest-files report" "$(cat "$T/out")"
ORC_TEST_SLOWEST=2 BARRIER=0 bash "$T/run-all-tests.sh" >"$T/out2" 2>&1
[ "$(grep -cE '^ +[0-9]+\.[0-9] +[0-9]+\.[0-9]  ' "$T/out2")" -eq 2 ] && pass "ORC_TEST_SLOWEST=2 lists two files" || fail "ORC_TEST_SLOWEST=2" "$(cat "$T/out2")"
ORC_TEST_JOBS=1 BARRIER=0 bash "$T/run-all-tests.sh" >"$T/out1s" 2>&1
[ "$(grep -cE '^ +[0-9]+\.[0-9] +[0-9]+\.[0-9]  [a-z]-[a-z]+\.tst\.sh$' "$T/out1s")" -eq 5 ] \
  && pass "ORC_TEST_JOBS=1 reports the same timings" || fail "ORC_TEST_JOBS=1 timings" "$(cat "$T/out1s")"

: >"$T/shards"
for k in 1 2; do
  ORC_TEST_SHARD=$k/2 BARRIER=0 bash "$T/run-all-tests.sh" >"$T/outs$k" 2>&1
  grep '^=== [a-z]' "$T/outs$k" >>"$T/shards"
done
[ "$(sort "$T/shards" | tr '\n' ' ')" = "=== a-sleep.tst.sh === b-sleep.tst.sh === c-sleep.tst.sh === d-fail.tst.sh === s-alone.tst.sh " ] \
  && grep -q '^--- shard 1/2: 3 of 5 files$' "$T/outs1" && grep -q '^--- shard 2/2: 2 of 5 files$' "$T/outs2" \
  && pass "ORC_TEST_SHARD 1/2 + 2/2 run every file exactly once" || fail "shards" "$(cat "$T/outs1" "$T/outs2")"
grep -qx 'out-d shard=unset' "$T/outs2" && pass "a test file does not inherit ORC_TEST_SHARD" || fail "ORC_TEST_SHARD leaks into a test" "$(cat "$T/outs2")"
ORC_TEST_SHARD=3/2 bash "$T/run-all-tests.sh" >"$T/outb" 2>&1; rcb=$?
[ "$rcb" -eq 2 ] && pass "a bad ORC_TEST_SHARD is refused (rc 2)" || fail "a bad ORC_TEST_SHARD" "rc=$rcb $(cat "$T/outb")"

# L5 (2026-10-12): the shards are a longest-first pack of the weights file.
# a=50 b=40 c=30, the rest 1: a->1, b->2, c->2 (40 < 50), d and s->1.
# CONTROL: the old every-2nd-file split gives 1/2 = a c s, so it fails this.
W=$T/weights; mkdir -p "$W"
cp "$RUNNER" "$W/run-all-tests.sh"
# W_TWO=1: a file waits (max 5 s) until two files have started, so the
# first two cannot finish before both are logged; with sleep 0.3 alone a
# loaded runner logged "d a s" (CI job 121089521604, SPL-3297).
for f in a b c d s; do printf '#!/usr/bin/env bash\necho "%s" >>"%s/started"\n[ -z "${W_TWO:-}" ] || for _ in $(seq 50); do [ "$(wc -l <"%s/started")" -ge 2 ] && break; sleep 0.1; done\nsleep 0.3\n' "$f" "$W" "$W" >"$W/$f-w.tst.sh"; done
printf '# test weights\n* 1\na-w.tst.sh 50\nb-w.tst.sh 40\nc-w.tst.sh 30\n' >"$W/orc-shard-weights.txt"
ORC_TEST_SHARD=1/2 bash "$W/run-all-tests.sh" >"$W/out1" 2>&1
ORC_TEST_SHARD=2/2 bash "$W/run-all-tests.sh" >"$W/out2" 2>&1
[ "$(grep '^=== [a-z]-w' "$W/out1" | tr '\n' ' ')" = "=== a-w.tst.sh === d-w.tst.sh === s-w.tst.sh " ] \
  && [ "$(grep '^=== [a-z]-w' "$W/out2" | tr '\n' ' ')" = "=== b-w.tst.sh === c-w.tst.sh " ] \
  && grep -qx -- '--- shard 1/2 weight: 52 of 122 s' "$W/out1" && grep -qx -- '--- shard 2/2 weight: 70 of 122 s' "$W/out2" \
  && pass "ORC_TEST_SHARD packs the weights longest-first (1/2 = a d s, 2/2 = b c), in suite order" \
  || fail "weighted shards" "$(cat "$W/out1" "$W/out2")"
printf '* x\n' >"$W/bad-weights.txt"
ORC_TEST_WEIGHTS="$W/bad-weights.txt" bash "$W/run-all-tests.sh" >"$W/outbad" 2>&1; rcw=$?
[ "$rcw" -eq 2 ] && grep -q 'orc shard weights: bad line' "$W/outbad" \
  && pass "a bad weights line is refused (rc 2)" || fail "a bad weights line" "rc=$rcw $(cat "$W/outbad")"
# the pool starts the heaviest files first: with 2 jobs, a (50) and b (40)
# start before c, d and s; the suite-order log is unchanged
: >"$W/started"
W_TWO=1 ORC_TEST_JOBS=2 bash "$W/run-all-tests.sh" >"$W/outj" 2>&1
[ "$(head -2 "$W/started" | sort | tr '\n' ' ')" = "a b " ] \
  && [ "$(grep '^=== [a-z]-w' "$W/outj" | tr '\n' ' ')" = "=== a-w.tst.sh === b-w.tst.sh === c-w.tst.sh === d-w.tst.sh === s-w.tst.sh " ] \
  && pass "the pool starts the heaviest files first and still prints in suite order" \
  || fail "heaviest first" "started: $(tr '\n' ' ' <"$W/started") $(cat "$W/outj")"
# reorder the weights so the lightest names are heaviest: d and s start first
printf '* 1\nd-w.tst.sh 50\ns-w.tst.sh 40\n' >"$W/rev.txt"; : >"$W/started"
W_TWO=1 ORC_TEST_WEIGHTS="$W/rev.txt" ORC_TEST_JOBS=2 bash "$W/run-all-tests.sh" >/dev/null 2>&1
[ "$(head -2 "$W/started" | sort | tr '\n' ' ')" = "d s " ] \
  && pass "CONTROL: the start order follows the weights, not the names" \
  || fail "CONTROL start order" "started: $(tr '\n' ' ' <"$W/started")"
ORC_TEST_TIMES=1 ORC_TEST_JOBS=2 bash "$W/run-all-tests.sh" >"$W/outt" 2>&1
[ "$(sed -n '/^--- every file (wall s)/,$p' "$W/outt" | grep -cE '^[a-z]-w\.tst\.sh [0-9]+$')" -eq 5 ] \
  && pass "ORC_TEST_TIMES=1 prints every file's wall seconds" || fail "every-file times" "$(cat "$W/outt")"

# Round 8 row 02, red control: a stopped suite prints what it proved. File 1
# blocks (until released, at most 30 s), files 2-4 pass at once; TERM once
# 2-4 are finished (their <i>.rc in the runner's work dir, under TMPDIR) ->
# their 3 verdicts and 'stopped: 3 of 4'. The old runner printed none.
# stop_suite <dir> <expected line>: run <dir>'s suite, TERM it, check it
stop_suite() {
  local d=$1 want=$2 pid rc _
  mkdir -p "$d/tmp"
  TMPDIR="$d/tmp" env "$JOBS_VAR=4" bash "$d/run-all-tests.sh" >"$d/out" 2>&1 & pid=$!
  for _ in $(seq 300); do
    compgen -G "$d/tmp/*/3.rc" >/dev/null && compgen -G "$d/tmp/*/2.rc" >/dev/null \
      && compgen -G "$d/tmp/*/1.rc" >/dev/null && break
    sleep 0.1
  done
  kill -TERM "$pid"; wait "$pid"; rc=$?
  : >"$d/release"
  [ "$rc" -ne 0 ] && pass "a stopped suite exits non-zero ($d)" || fail "a stopped suite exits non-zero" "rc=$rc"
  [ "$(grep -E '^=== [a-z]+-[a-z]+\.tst\.sh$' "$d/out" | tr '\n' ' ')" = "=== b-pass.tst.sh === c-pass.tst.sh === d-pass.tst.sh " ] \
    && [ "$(grep -c '^PASS: [bcd]$' "$d/out")" -eq 3 ] \
    && pass "a stopped suite prints the 3 finished files in suite order, each with its verdict" \
    || fail "a stopped suite prints the finished files" "$(cat "$d/out")"
  grep -qx "$want" "$d/out" && pass "the stop line reads '$want'" || fail "the stop line" "$(cat "$d/out")"
  [ -z "$(find "$d/tmp" -mindepth 1 -type d)" ] && pass "the stopped suite still removes its work dir" \
    || fail "the work dir is left" "$(find "$d/tmp" -mindepth 1 -type d)"
}
S=$T/stop; mkdir -p "$S"
cp "$RUNNER" "$S/run-all-tests.sh"
printf '#!/usr/bin/env bash\nfor _ in $(seq 300); do [ -e "%s/release" ] && break; sleep 0.1; done\necho "PASS: a"\n' "$S" >"$S/a-block.tst.sh"
for f in b c d; do printf '#!/usr/bin/env bash\necho "PASS: %s"\n' "$f" >"$S/$f-pass.tst.sh"; done
stop_suite "$S" '=== stopped: 3 of 4 files finished, 0 not run'
# a '# serial' file starts only after the pool: it is counted as not run
S2=$T/stop2; mkdir -p "$S2"
cp "$S/run-all-tests.sh" "$S2/"
sed "s#$S/release#$S2/release#" "$S/a-block.tst.sh" >"$S2/a-block.tst.sh"
cp "$S"/[bcd]-pass.tst.sh "$S2/"
printf '#!/usr/bin/env bash\n# serial\necho "PASS: e"\n' >"$S2/e-serial.tst.sh"
stop_suite "$S2" '=== stopped: 3 of 5 files finished, 1 not run'

echo "-- run-all-tests-parallel.tst.sh: $fails failed"
[ "$fails" -eq 0 ]
