#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-5524 (spec 157 section 4.1, csitea weekly item 10). The owner's
#          prio word sets the topic to priority 1 on the hub, so its queued
#          ask is the queue's head (the hub's Go test
#          TestOwnerPrioWordMovesAskToHead); the placer then takes a priority
#          1 head as it is, ahead of the class bands and a review seat.
#   1. a priority 1 feature head, bug UNDER its band, a review seat queued:
#      the head is placed, "INFO priority 1 head" logged (RED on
#      origin/master: the band pick takes the bug)
#   2. CONTROL: the same rows at priority 3 -> the band pick takes the bug
#   3. CONTROL: a priority 2 head is not taken first either
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export SPOOL_TEST=1
GO=994f2257-8ad1-4010-88c8-4f0a16230937

# A share: refactor 30% ok, bug 10% UNDER, feature 60% ok.
jq -n -c '{known: 10, unknown: 0, lanes: [], bypasses: [],
  by: {refactor: {n: 3, pct: 30, lo: 20, hi: 30, verdict: "ok"}, bug: {n: 1, pct: 10, lo: 20, hi: 30, verdict: "UNDER"},
       feature: {n: 6, pct: 60, lo: 40, hi: 100, verdict: "ok"}}}' >"$T/share.json"
# rows PRIO: a feature head at PRIO, a bug at 2, a logged review seat at 3.
rows() {
  jq -n -c --argjson p "$1" '[
    {ask_id: "f0000000-0", state: "queued", class: "feature", position: 1, priority: $p, placement: "claude:owner-prio-word"},
    {ask_id: "b0000000-0", state: "queued", class: "bug", position: 2, priority: 3, placement: "claude:a-bug"},
    {ask_id: "s0000000-0000-4000-8000-000000000001", state: "queued", class: "bug", position: 3, priority: 3, placement: "agy:x-reviewer"}]'
}
mkdir -p "$T/asks" "$T/spool"
printf '2026-11-14T00:00:00Z\ts0000000-0000-4000-8000-000000000001\t%s\tc-001@sat\tseat\n' "$GO" >"$T/asks/bypass.tsv"
# run FN ARGS...: FN from the placer, with stubs; stdout to $T/out, stderr to $T/err.
run() {
  env SPOOL_ROOT="$T/spool" SPOOL_ASKS_DIR="$T/asks" PROJ_PATH="$PROJ_ROOT" SPAWN_SHARE_DISPATCH=c-002@sat RHYTHM_NOW=2026-01-15T12:00Z \
    SPL_SPAWN_REVIEW_SEAT_GO="$GO" SHARE="$T/share.json" bash -c '
    do_log() { printf "%s\n" "$*"; }
    source "$1/src/bash/features/spawn-agents/lib/spool-asks.inc.sh"
    source "$1/src/bash/run/spl-spawn-share.func.sh"
    source "$1/src/bash/run/spl-spawn-place.func.sh"
    spl_spawn_share() { cat "$SHARE"; }
    shift; "$@"' _ "$PROJ_ROOT" "$@" >"$T/out" 2>"$T/err"
}
picked() { jq -r .ask_id "$T/out" 2>/dev/null; }

# 1. priority 1 head
r="$(rows 1)"
run spl_spawn_place_band "$(jq -c '.[0]' <<<"$r")" "$r"
if [[ "$(picked)" == f0000000-0 ]] && grep -q "INFO priority 1 head: ask f0000000 (feature claude:owner-prio-word) is placed first, ahead of the bands" "$T/err" &&
   ! grep -q "band pick\|review-seat pick" "$T/err"; then
  pass "1 a priority 1 feature head is placed first: ahead of the bug under its band and the review seat"
else fail "1 priority 1 head: out $(head -c 200 "$T/out") | err $(head -c 400 "$T/err")"; fi

# 2. CONTROL: priority 3, the bands decide (the review seat first, then the bug)
r="$(rows 3)"
run spl_spawn_place_band "$(jq -c '.[0]' <<<"$r")" "$r"
[[ "$(picked)" == s0000000-0000-4000-8000-000000000001 ]] && ! grep -q "priority 1 head" "$T/err" &&
  pass "2 CONTROL: the same head at priority 3 -> the review seat is picked, as before" ||
  fail "2 control: out $(head -c 200 "$T/out") | err $(head -c 400 "$T/err")"
r="$(rows 3 | jq -c '[.[] | select(.placement != "agy:x-reviewer")]')"
run spl_spawn_place_band "$(jq -c '.[0]' <<<"$r")" "$r"
[[ "$(picked)" == b0000000-0 ]] && grep -q "INFO band pick: ask b0000000 (bug at 10%" "$T/err" &&
  pass "2 CONTROL: no seat, priority 3 -> the band pick takes the bug" ||
  fail "2 control bands: out $(head -c 200 "$T/out") | err $(head -c 400 "$T/err")"

# 3. CONTROL: priority 2 is no prio word
r="$(rows 2 | jq -c '[.[] | select(.placement != "agy:x-reviewer")]')"
run spl_spawn_place_band "$(jq -c '.[0]' <<<"$r")" "$r"
[[ "$(picked)" == b0000000-0 ]] && ! grep -q "priority 1 head" "$T/err" &&
  pass "3 CONTROL: a priority 2 head goes through the bands" || fail "3 priority 2: out $(head -c 200 "$T/out") | err $(head -c 400 "$T/err")"

echo
(( fails == 0 )) && { echo "PASS: all"; exit 0; }
echo "FAIL: $fails"
exit 1
