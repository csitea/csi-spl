#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the two CI shards of the orc suite are balanced by recorded file
#          time (spec 131 C3). On 2026-10-11 the every-2nd-file split ran a
#          median 918 s on shard 1 and 520 s on shard 2 against a 1,200 s
#          timeout, and shard 1 timed out 4 times in 11 started runs.
#   1. ORC_TEST_SHARD=1/2 + 2/2 (--list) name every *.tst.sh exactly once
#   2. the two shards' summed shard-times.tsv seconds are within 10 %
#   3. a file the table does not know lands in exactly one shard
#   CONTROL a. ORC_TEST_SHARD_BALANCE=0 (the round-robin split) on the same
#              table is more than 10 % apart, so check 2 FAILS without the
#              balance
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
RAT="$TEST_DIR/run-all-tests.sh"
TIMES="$TEST_DIR/shard-times.tsv"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
unset ORC_TEST_SHARD ORC_TEST_SHARD_BALANCE ORC_TEST_SHARD_TIMES

# shard_list <k> [VAR=value ...] - the files shard k/2 would run
shard_list() { local k=$1; shift; env ORC_TEST_SHARD="$k/2" "$@" bash "$RAT" --list; }
# weight <list file> - the summed table seconds of those files
weight() { awk -F'\t' 'NR == FNR { w[$1] = $2; next } { s += w[$0] } END { printf "%d\n", s }' "$TIMES" "$1"; }
# apart <a> <b> - how far apart, in % of the larger
apart() { awk -v a="$1" -v b="$2" 'BEGIN { m = (a > b ? a : b); printf "%d\n", (m ? (a > b ? a - b : b - a) * 100 / m : 0) }'; }

[[ -s "$TIMES" ]] && pass "the table exists: $(wc -l <"$TIMES") files" || { fail "no $TIMES"; exit 1; }

# --- 1. every file exactly once -------------------------------------------------
shard_list 1 >"$T/s1"; shard_list 2 >"$T/s2"
ls "$TEST_DIR"/*.tst.sh | sed 's|.*/||' | sort >"$T/all"
sort "$T/s1" "$T/s2" >"$T/both"
if cmp -s "$T/all" "$T/both"; then
  pass "1. shards 1/2 + 2/2 name all $(wc -l <"$T/all") *.tst.sh files, each exactly once ($(wc -l <"$T/s1") + $(wc -l <"$T/s2"))"
else
  fail "1. a file is lost or run twice: $(diff "$T/all" "$T/both" | head -5 | tr '\n' ' ')"
fi

# --- 2. balanced within 10 % --------------------------------------------------
w1=$(weight "$T/s1"); w2=$(weight "$T/s2"); d=$(apart "$w1" "$w2")
(( d <= 10 )) && pass "2. balanced: shard 1 $w1 s, shard 2 $w2 s, $d % apart (<= 10 %)" \
  || fail "2. shard 1 $w1 s vs shard 2 $w2 s: $d % apart (> 10 %)"

# --- CONTROL a. round-robin on the same table -------------------------------------
shard_list 1 ORC_TEST_SHARD_BALANCE=0 >"$T/r1"; shard_list 2 ORC_TEST_SHARD_BALANCE=0 >"$T/r2"
r1=$(weight "$T/r1"); r2=$(weight "$T/r2"); rd=$(apart "$r1" "$r2")
(( rd > 10 )) && pass "CONTROL a. round-robin: shard 1 $r1 s, shard 2 $r2 s, $rd % apart, so check 2 FAILS without the balance" \
  || fail "CONTROL a. round-robin is only $rd % apart: check 2 proves nothing"

# --- 3. a file the table does not know --------------------------------------------
mkdir -p "$T/d"; cp "$RAT" "$T/d/"
for f in a b c d new; do printf '#!/bin/sh\nexit 0\n' >"$T/d/$f.tst.sh"; done
printf 'a.tst.sh\t100\nb.tst.sh\t60\nc.tst.sh\t50\nd.tst.sh\t10\n' >"$T/d/shard-times.tsv"
o1=$(ORC_TEST_SHARD=1/2 bash "$T/d/run-all-tests.sh" --list); o2=$(ORC_TEST_SHARD=2/2 bash "$T/d/run-all-tests.sh" --list)
if [[ "$(printf '%s\n%s\n' "$o1" "$o2" | grep -cx 'new.tst.sh')" == 1 ]] && [[ "$o1" == $'a.tst.sh\nc.tst.sh' ]]; then
  pass "3. an unknown file weighs the mean and runs in exactly one shard (mean 55; 1/2: a + c = 150, 2/2: b + new + d = 125)"
else
  fail "3. the unknown file: 1/2=[$(tr '\n' ' ' <<<"$o1")] 2/2=[$(tr '\n' ' ' <<<"$o2")]"
fi

echo "--- $fails failure(s)"
[[ "$fails" -eq 0 ]]
