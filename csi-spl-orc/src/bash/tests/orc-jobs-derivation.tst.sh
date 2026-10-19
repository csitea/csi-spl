#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: run-all-tests.sh sizes its pool to the runner and its shard
#          weights stay measured (test round 2 row 03, SPL-2571).
#   Jobs: the default pool (6 on CI, 4 elsewhere) is capped at the CPUs
#   (ORC_TEST_NPROC, else nproc); an explicit ORC_TEST_JOBS is taken as
#   given; a bad value is refused. CI ran 6 files at once on nproc=4 runners.
#   Weights: --check-weights names a file whose weight and measured median
#   differ by > 2x and > 60 s, --weights-from prints each file's median of
#   n >= 3 lines, and every name in orc-shard-weights.txt is a test here.
#   Controls: a copy of the runner without the cap, and one with njobs=99
#   hard-coded, both fail the cap check; the pre-refresh weight of
#   spl-session-prune (243 s against 21 s measured) is named stale.
#   Hermetic: --print-jobs and the weights modes run no test file.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
RUNNER="$TEST_DIR/run-all-tests.sh"
unset ORC_TEST_JOBS ORC_TEST_NPROC ORC_TEST_WEIGHTS ORC_TEST_SHARD GITHUB_ACTIONS

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# jobs <runner> <env>...: the pool size the runner derives under <env>
jobs() { local r=$1; shift; env "$@" bash "$r" --print-jobs 2>&1; }

# cap_ok <runner>: every default the runner derives is <= the CPUs
cap_ok() {
  [[ "$(jobs "$1" GITHUB_ACTIONS=true ORC_TEST_NPROC=4)" == 4 ]] \
    && [[ "$(jobs "$1" GITHUB_ACTIONS=true ORC_TEST_NPROC=2)" == 2 ]] \
    && [[ "$(jobs "$1" ORC_TEST_NPROC=1)" == 1 ]]
}

# --- the pool size --------------------------------------------------------
got=$(jobs "$RUNNER" GITHUB_ACTIONS=true ORC_TEST_NPROC=4)
[[ "$got" == 4 ]] && pass "CI on nproc=4: 4 jobs, not 6" || fail "CI on nproc=4: 4 jobs" "got '$got'"
got=$(jobs "$RUNNER" GITHUB_ACTIONS=true ORC_TEST_NPROC=8)
[[ "$got" == 6 ]] && pass "CI on nproc=8: the CI default 6" || fail "CI on nproc=8: 6 jobs" "got '$got'"
got=$(jobs "$RUNNER" ORC_TEST_NPROC=16)
[[ "$got" == 4 ]] && pass "a lane box with 16 CPUs: the default 4" || fail "lane box nproc=16: 4 jobs" "got '$got'"
got=$(jobs "$RUNNER" ORC_TEST_NPROC=2)
[[ "$got" == 2 ]] && pass "a lane box with 2 CPUs: 2 jobs" || fail "lane box nproc=2: 2 jobs" "got '$got'"
cap_ok "$RUNNER" && pass "every default is capped at the CPUs" || fail "every default is capped at the CPUs"
got=$(jobs "$RUNNER" GITHUB_ACTIONS=true ORC_TEST_NPROC=4 ORC_TEST_JOBS=9)
[[ "$got" == 9 ]] && pass "an explicit ORC_TEST_JOBS is taken as given" || fail "explicit ORC_TEST_JOBS=9" "got '$got'"
n=$(nproc 2>/dev/null || echo 4) got=$(jobs "$RUNNER")
[[ "$got" =~ ^[1-9][0-9]*$ ]] && (( got <= n && got <= 4 )) \
  && pass "with no override the real nproc ($n) caps it: $got" || fail "the real nproc caps it" "nproc=$n got '$got'"
jobs "$RUNNER" ORC_TEST_NPROC=abc >"$T/bad" ; rc=$?
[[ $rc -eq 2 ]] && grep -q 'ORC_TEST_NPROC must be a positive integer' "$T/bad" \
  && pass "a bad ORC_TEST_NPROC is refused" || fail "a bad ORC_TEST_NPROC is refused" "rc=$rc $(cat "$T/bad")"
jobs "$RUNNER" ORC_TEST_JOBS=0 >"$T/bad" ; rc=$?
[[ $rc -eq 2 ]] && pass "ORC_TEST_JOBS=0 is refused" || fail "ORC_TEST_JOBS=0 is refused" "rc=$rc"

# red controls: the cap check fails a runner without the cap, and one that
# hard-codes a pool
sed '/(( njobs > ncpu )) && njobs=\$ncpu/d' "$RUNNER" >"$T/nocap.sh"
grep -q 'njobs > ncpu' "$T/nocap.sh" && fail "control: the cap line was removed" "sed missed it"
! cap_ok "$T/nocap.sh" && pass "control: a runner without the cap fails the cap check" \
  || fail "control: a runner without the cap fails the cap check" "$(jobs "$T/nocap.sh" GITHUB_ACTIONS=true ORC_TEST_NPROC=4)"
sed 's/^\[\[ "\$njobs" =~/njobs=99\n&/' "$RUNNER" >"$T/hard99.sh"
[[ "$(jobs "$T/hard99.sh" ORC_TEST_NPROC=4)" == 99 ]] && ! cap_ok "$T/hard99.sh" \
  && pass "control: njobs=99 hard-coded fails the cap check" || fail "control: njobs=99 fails the cap check"

# --- the weights ----------------------------------------------------------
W="$T/w"; mkdir -p "$W"; cp "$RUNNER" "$W/run-all-tests.sh"
printf '* 10\nspl-session-prune.tst.sh 243\nb.tst.sh 30\n' >"$W/stale.txt"
printf '* 10\nspl-session-prune.tst.sh 21\nb.tst.sh 30\n' >"$W/fresh.txt"
# the CI block, as a job log prints it (timestamp column first) and plain
{ for s in 20 21 22; do echo "2026-10-19T17:33:08.4432361Z spl-session-prune.tst.sh $s"; done
  printf 'b.tst.sh 40\nb.tst.sh 50\nb.tst.sh 45\nb.tst.sh 44\nlone.tst.sh 900\nnoise line\n'; } >"$W/times"
ORC_TEST_WEIGHTS="$W/stale.txt" bash "$W/run-all-tests.sh" --check-weights "$W/times" >"$T/chk" 2>&1; rc=$?
[[ $rc -eq 1 ]] && grep -q '^stale weight: spl-session-prune.tst.sh weight 243 s, measured median 21 s (n=3)$' "$T/chk" \
  && pass "control: a stale weight (243 s, 21 s measured) is named and exits 1" || fail "a stale weight is named" "rc=$rc $(cat "$T/chk")"
grep -q '^stale weight: b.tst.sh' "$T/chk" && fail "30 s against 44.5 s is within 2x" "$(cat "$T/chk")" \
  || pass "a weight within 2x of its median is not stale"
grep -q '^stale weight: lone.tst.sh weight 10 s, measured median 900 s (n=1)$' "$T/chk" \
  && pass "an unlisted file is checked against '*'" || fail "an unlisted file is checked against '*'" "$(cat "$T/chk")"
printf 'lone.tst.sh 900\n' >>"$W/fresh.txt"
ORC_TEST_WEIGHTS="$W/fresh.txt" bash "$W/run-all-tests.sh" --check-weights "$W/times" >"$T/chk" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -qx -- '--- weights: 3 files checked, 0 stale' "$T/chk" \
  && pass "fresh weights pass the check" || fail "fresh weights pass the check" "rc=$rc $(cat "$T/chk")"
ORC_TEST_WEIGHTS="$W/stale.txt" bash "$W/run-all-tests.sh" --weights-from "$W/times" >"$T/new" 2>&1; rc=$?
[[ $rc -eq 0 && "$(tr '\n' ' ' <"$T/new")" == "* 32 b.tst.sh 44 spl-session-prune.tst.sh 21 " ]] \
  && pass "--weights-from: medians of n >= 3, '*' their median" || fail "--weights-from" "rc=$rc $(tr '\n' ' ' <"$T/new")"
extra=()
for f in "$W"/*; do
  case "${f##*/}" in run-all-tests.sh | stale.txt | fresh.txt | times) ;; *) extra+=("${f##*/}") ;; esac
done
(( ${#extra[@]} == 0 )) && pass "the weights modes ran no test and left no file" \
  || fail "the weights modes ran no test and left no file" "${extra[*]}"

# every name in the committed weights is a test file here (a renamed or
# removed test leaves a stale line); '*' is set once
bad=$(awk '!/^#/ && NF && $1 != "*" { print $1 }' "$TEST_DIR/orc-shard-weights.txt" | while read -r f; do [[ -f "$TEST_DIR/$f" ]] || echo "$f"; done)
[[ -z "$bad" ]] && pass "every name in orc-shard-weights.txt is a test here" || fail "names with no test file" "$bad"
[[ "$(grep -c '^\* [0-9][0-9]*$' "$TEST_DIR/orc-shard-weights.txt")" == 1 ]] \
  && pass "orc-shard-weights.txt sets '*' once" || fail "orc-shard-weights.txt sets '*' once"

echo "--- orc-jobs-derivation: $fails failure(s)"
[[ $fails -eq 0 ]]
