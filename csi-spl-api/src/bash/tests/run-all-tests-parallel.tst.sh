#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: run-all-tests.sh runs its independent pieces SPL_API_TEST_JOBS at
#          a time (perf edition 20261004, E05, C2's practice) and still reads
#          like a serial run.
#   Overlap: five 2 s sleepers plus a planted failing `go test` run all at
#   once must overlap (max start < min end). A serial run cannot.
#   The failing Go test still fails the run, is named, and its output sits
#   under its own header with no other piece's lines in it.
#   SPL_API_TEST_JOBS=1 names the same failure. A value that is not a
#   positive integer is refused (rc 2). The suite default is every piece
#   at once; the old behaviour is the literal 1.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
RUNNER="$TEST_DIR/run-all-tests.sh"
# shellcheck source=../use-go-toolchain.sh
source "$TEST_DIR/../use-go-toolchain.sh"
spl_export_go_path
export GOTOOLCHAIN=local

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

# Read by run-all-tests.sh when it is sourced.
# shellcheck disable=SC2034
SPL_API_SUITE_LIB=1
# shellcheck source=run-all-tests.sh
source "$RUNNER"
unset SPL_API_SUITE_LIB
type spl_run_pieces >/dev/null 2>&1 || { echo "FAIL: spl_run_pieces was not defined"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# A one-file module whose only test fails. No dependencies, so it builds
# with GOPROXY=off (the suite exports that before this test runs).
mkdir -p "$T/mod"
cat >"$T/mod/planted_test.go" <<'EOF'
package planted

import "testing"

func TestPlanted(t *testing.T) {
	t.Fatal("planted failure token")
}
EOF
(
  cd "$T/mod" || exit 1
  go mod init planted.example >/dev/null 2>&1
)

for name in a b c d e; do
  eval "piece_$name() { date +%s >\"$T/$name.start\"; echo out-$name; sleep 2; date +%s >\"$T/$name.end\"; }"
done
piece_fail() { ( cd "$T/mod" && go test -count=1 . ); }

start=$SECONDS
rc=0
spl_run_pieces 6 \
  a-sleep piece_a b-sleep piece_b c-sleep piece_c \
  d-sleep piece_d e-sleep piece_e f-fail piece_fail \
  >"$T/out" 2>"$T/err" || rc=$?
el=$((SECONDS - start))

[ "$rc" -ne 0 ] && pass "the run still fails when a Go test fails" || fail "the run still fails when a Go test fails" "rc=$rc"
grep -qx 'FAILED: f-fail' "$T/out" && pass "the failing Go test is named" || fail "the failing Go test is named" "$(cat "$T/out")"

heads=$(grep '^== ' "$T/out" | tr '\n' ' ')
want="== a-sleep == == b-sleep == == c-sleep == == d-sleep == == e-sleep == == f-fail == "
[ "$heads" = "$want" ] && pass "headers print in piece order" || fail "headers print in piece order" "$heads"

# b's body, up to the next header, is only b's lines.
body=$(awk 'BEGIN{p=0} /^== b-sleep ==$/{p=1; next} /^== /{if(p){exit}} p{print}' "$T/out")
grep -qx 'out-b' <<<"$body" && pass "b's own line is under b's header" || fail "b's own line is under b's header" "$body"
grep -q 'out-a\|out-c\|planted failure token' <<<"$body" \
  && fail "b's body is not mixed with another piece" "$body" \
  || pass "b's body is not mixed with another piece"

# The planted failure is under f's header and nowhere earlier.
before=$(awk '/^== f-fail ==$/{exit} {print}' "$T/out")
grep -q 'planted failure token' <<<"$before" \
  && fail "the Go failure is not printed before its header" \
  || pass "the Go failure is not printed before its header"
after=$(awk 'BEGIN{p=0} /^== f-fail ==$/{p=1; next} p{print}' "$T/out")
grep -q 'planted failure token' <<<"$after" \
  && pass "the planted Go failure is under its own header" \
  || fail "the planted Go failure is under its own header" "$after"
grep -q 'out-a\|out-e' <<<"$after" \
  && fail "the Go failure body contains another piece" "$after" \
  || pass "the Go failure body contains no other piece"

# Five 2 s sleeps overlap only when they run together. Serial gives
# max(start) >= min(end). One second of skew is allowed.
max_s=0
min_e=9999999999
for name in a b c d e; do
  s=$(cat "$T/$name.start")
  e=$(cat "$T/$name.end")
  [ "$s" -gt "$max_s" ] && max_s=$s
  [ "$e" -lt "$min_e" ] && min_e=$e
done
overlap=$((min_e - max_s))
[ "$overlap" -ge 1 ] && pass "five 2 s pieces overlapped (${overlap}s, wall ${el}s)" \
  || fail "five 2 s pieces overlapped" "overlap=${overlap}s wall=${el}s (serial overlap is <= 0)"

# jobs=1: same verdict, same header order, no overlap required (instant pieces).
piece_ok() { echo out-ok; }
piece_bad() { echo out-bad; return 4; }
rc1=0
spl_run_pieces 1 ok piece_ok bad piece_bad >"$T/out1" 2>"$T/err1" || rc1=$?
[ "$rc1" -ne 0 ] && grep -qx 'FAILED: bad' "$T/out1" && grep -q 'out-ok' "$T/out1" \
  && pass "SPL_API_TEST_JOBS=1 gives the same verdict" \
  || fail "SPL_API_TEST_JOBS=1 gives the same verdict" "rc=$rc1 $(cat "$T/out1")"
heads1=$(grep '^== ' "$T/out1" | tr '\n' ' ')
[ "$heads1" = "== ok == == bad == " ] && pass "SPL_API_TEST_JOBS=1 prints in order" \
  || fail "SPL_API_TEST_JOBS=1 prints in order" "$heads1"

rcx=0
spl_run_pieces x a piece_ok >"$T/outx" 2>"$T/errx" || rcx=$?
[ "$rcx" -eq 2 ] && grep -q "SPL_API_TEST_JOBS must be a positive integer" "$T/errx" \
  && pass "a bad SPL_API_TEST_JOBS is refused (rc 2)" \
  || fail "a bad SPL_API_TEST_JOBS is refused" "rc=$rcx $(cat "$T/errx")"

grep -q 'njobs="${SPL_API_TEST_JOBS:-$npieces}"' "$RUNNER" \
  && pass "the suite default is every piece at once" \
  || fail "the suite default is every piece at once" "old behaviour is SPL_API_TEST_JOBS=1"

echo "-- run-all-tests-parallel.tst.sh: $fails failed"
[ "$fails" -eq 0 ]
