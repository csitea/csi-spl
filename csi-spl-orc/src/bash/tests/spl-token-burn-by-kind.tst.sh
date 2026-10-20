#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_token_burn_by_kind (SPL-2577) on synthetic query rows and a
# mktemp briefs dir; the hub is never read.
#   1. the kind comes from the brief's Kind: under a dispatcher prefix
#      (c002-tst.md for branch slug tst), then from the ask (simp), else
#      unkinded; the picker's alias hard reads as complex_coding, and a
#      hand-placed branch (<box>hand-hrd) finds brief hrd.md
#   2. medians per kind x vendor: tests claude 10, grok 30 -> ratio 3.00,
#      uncached 3 vs 12 -> 4.00; simple_coding 10 vs 15 -> 1.50 ok
#   3. a cell with n < 3 is never over (complex_coding grok 5x, n=1)
#   4. left out: a role seat (g-001), an unattributed row, a lane still
#      running (last minute < 60 min ago), a lane that began within 60 min of
#      its vendor's first minute in the record (c-104), and one from before
#      the window
#   5. the verdict: grok_over=tests; control: TOKEN_KIND_OVER=3 gives none
#      (3.00 is not over 3)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

NOW=1000000 B="$T/briefs" R="$T/rows.txt"
mkdir -p "$B"
printf 'Class: refactor. Kind: tests (claude main).\n' >"$B/c002-tst.md"
printf 'Kind: hard\n' >"$B/hrd.md"
printf 'No kind line here.\n' >"$B/simp.md"
# t <box> <agent> <vendor> <in> <out> <cache read> <cache write> <first min> <last min>
t() { echo " T @@ $1 @@ $2 @@ $3 @@ $4 @@ $5 @@ $6 @@ $7 @@ $8 @@ $9"; }
{
  echo " N @@ $NOW"
  echo " F @@ claude @@ 400000"
  echo " F @@ grok @@ 300000"
  for i in 1 2 3; do
    t sat "c-10$i" claude 1 1 7 1 500000 510000; t sat "g-20$i" grok 6 6 18 0 500000 510000
    t pc "c-11$i" claude 1 1 7 1 500000 510000; t pc "g-21$i" grok 2 2 11 0 500000 510000
    echo " L @@ c-10$i @@ sat @@ c-10$i-tst"; echo " L @@ g-20$i @@ sat @@ g-20$i-tst"
    echo " L @@ c-11$i @@ pc @@ c-11$i-simp"; echo " L @@ g-21$i @@ pc @@ g-21$i-simp"
  done
  t sat c-121 claude 1 1 7 1 500000 510000; t sat g-221 grok 10 10 30 0 500000 510000
  echo " L @@ c-121 @@ sat @@ c-121-hrd"; echo " L @@ g-221 @@ sat @@ g-221-sathand-hrd"
  t sat c-131 claude 1 1 7 1 500000 510000
  t sat g-001 grok 900 900 900 0 500000 510000; echo " L @@ g-001 @@ sat @@ g-001-tst"
  t sat 'unattributed (cwd /opt)' grok 900 900 900 0 500000 510000
  t sat g-204 grok 900 900 900 0 500000 $(( NOW - 600 )); echo " L @@ g-204 @@ sat @@ g-204-tst"
  t sat c-104 claude 900 900 900 0 400600 510000; echo " L @@ c-104 @@ sat @@ c-104-tst"
  t sat g-205 grok 900 900 900 0 350000 360000; echo " L @@ g-205 @@ sat @@ g-205-tst"
  echo " A @@ simp @@ simple_coding"
  echo " A @@ simp"
  echo "(52 rows)"
} >"$R"

run() { env TOKEN_KIND_ROWS="$R" TOKEN_KIND_BRIEFS="$B" TOKEN_KIND_LANES=1 "$@" \
  bash -c 'do_log() { echo "$*"; }; source "$1/src/bash/run/spl-token-burn-by-kind.func.sh"; do_spl_token_burn_by_kind' _ "$PROJ_ROOT" 2>&1; }
out="$(run)"
row() { grep -P "^$1\t" <<<"$out"; }
lane() { grep -P "^[a-z]+\t[a-z]+\t$1\t" <<<"$out"; }

grep -qP '\ttests\tbrief\ttst\t' <<<"$(lane g-201)" && grep -qP '\tsimple_coding\task\tsimp\t' <<<"$(lane c-111)" \
  && grep -qP '\tunkinded\tnone\t-\t' <<<"$(lane c-131)" && grep -qP '\tcomplex_coding\tbrief\tsathand-hrd\t' <<<"$(lane g-221)" \
  && pass "1. kind: brief Kind under c002-, then the ask, else unkinded; hard = complex_coding" || fail "1. kind ($out)"
[ "$(row tests)" = "$(printf 'tests\t3\t10\t3\t3\t30\t12\t3.00\t4.00\tgrok over 2x')" ] \
  && [ "$(row simple_coding)" = "$(printf 'simple_coding\t3\t10\t3\t3\t15\t4\t1.50\t1.33\tok')" ] \
  && pass "2. medians and ratios per kind x vendor" || fail "2. medians ($(row tests) | $(row simple_coding))"
[ "$(row complex_coding)" = "$(printf 'complex_coding\t1\t10\t3\t1\t50\t20\t5.00\t6.67\tn<3')" ] \
  && pass "3. n < 3 is never over" || fail "3. small n ($(row complex_coding))"
for x in g-001 unattributed g-204 c-104 g-205; do
  grep -q -- "$x" <<<"$out" && fail "4. $x left in ($(grep -- "$x" <<<"$out"))"
done
[ "$(grep -cP '^(claude|grok)\t' <<<"$out")" = 15 ] \
  && pass "4. seat, unattributed, running, record-edge and pre-window lanes left out" || fail "4. lane count"
grep -q '^grok_over=tests ' <<<"$out" && pass "5. verdict grok_over=tests" || fail "5. verdict ($out)"
grep -q '^grok_over=none ' <<<"$(run TOKEN_KIND_OVER=3)" && pass "5. control: TOKEN_KIND_OVER=3 -> none" || fail "5. control"
grep -q 'FATAL TOKEN_KIND_DAYS' <<<"$(run TOKEN_KIND_DAYS=0)" && pass "6. a bad window is refused" || fail "6. window"

echo "spl-token-burn-by-kind: $fails failure(s)"
[ "$fails" -eq 0 ]
