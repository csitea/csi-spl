#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spl_box_health_verdicts (lib/bash/funcs/spl-box-health.func.sh)
#          holds a box RECOVERING for the whole hold after a bad stretch that
#          is shorter than its 60 s checkpoint step, whatever second "now"
#          falls on (SPL-2029). Replay of prd box_beats 2026-10-15: one box
#          beats every 10 s from 06:30Z with one gap 07:33:44 -> 07:36:33Z
#          (169 s, max_gap 120 s: bad for 49 s), the other every 10 s.
#           1. "now" steps 7 s at a time over the 10 min after the gap: the
#              box is recovering on every tick (RED control: the same func
#              judged only AT the checkpoints is healthy on some ticks).
#           2. the hold ends 30 min after the gap: recovering at +1799 s,
#              healthy at +1800 s.
#           3. a box with no gap over max_gap stays healthy on every tick.
#           4. hold 0 (do_spl_box_pick) judges now only: healthy after the gap.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
FUNC="$PROJ_ROOT/lib/bash/funcs/spl-box-health.func.sh"
for k in WINDOW_MIN MIN_BEAT_PCT BEAT_S MAX_GAP_S HOLD_MIN; do unset "BOX_HEALTH_$k"; done
# shellcheck source=/dev/null
source "$FUNC"
spl_box_health_cnf /nonexistent/all.env.yaml

T0=$(date -u -d 2026-10-15T06:30:04Z +%s)
G0=$(date -u -d 2026-10-15T07:33:44Z +%s)  # box-a's last beat before the gap
G1=$(date -u -d 2026-10-15T07:36:33Z +%s)  # its first beat after it
END=$(date -u -d 2026-10-15T08:20:00Z +%s)
# box-beat list rows: box-a every 10 s with the gap, box-b every 10 s from T0 + 3 s
jq -nc --argjson t0 "$T0" --argjson g0 "$G0" --argjson g1 "$G1" --argjson end "$END" '
  [range($t0; $g0 + 1; 10) | {box: "box-a", e: .}] + [range($g1; $end; 10) | {box: "box-a", e: .}]
  + [range($t0 + 3; $end; 10) | {box: "box-b", e: .}]' >"$T/beats.json"
# rows NOW: the 41 m read (spl_box_health_since) ending at NOW, plus a beat at
# NOW itself (the hub's newest beat is "now")
rows() { jq -c --argjson now "$1" --argjson s "$(( ${2%m} * 60 ))" \
  '{rows: ([.[] | select(.e <= $now and .e > $now - $s)] + [{box: "box-b", e: $now}]
    | map({box, beat_at: (.e | todate)}))}' "$T/beats.json"; }
# state BOX NOW [HOLD_S]
state() { spl_box_health_verdicts "$(rows "$2" "$(spl_box_health_since)")" "${3:-}" | jq -r --arg b "$1" '.[$b].state'; }

# the RED control: the same func with the span rule taken out (judged AT the checkpoints only)
sed 's/bad: (\$badat or \$span > \$gap)/bad: $badat/' "$FUNC" >"$T/old.func.sh"
grep -q 'bad: \$badat}' "$T/old.func.sh" || fail "control: the span rule was not found to take out"
old_state() ( source "$T/old.func.sh"; state "$@" )

# 1. every tick over the 10 min after the gap
seq1="" n1=0 rec1=0 old1=0
for now in $(seq $((G1 + 30)) 7 $((G1 + 630))); do
  n1=$((n1 + 1)); s="$(state box-a "$now")"; o="$(old_state box-a "$now")"
  [[ "$s" == recovering ]] && rec1=$((rec1 + 1)) || seq1+=" +$((now - G1)):$s"
  [[ "$o" == healthy ]] && old1=$((old1 + 1))
done
(( rec1 == n1 )) && pass "1. box-a recovering on all $n1 ticks of the 10 min after the gap" ||
  fail "1. box-a not recovering on $((n1 - rec1)) of $n1 ticks:$seq1"
(( old1 > 0 && old1 < n1 )) && pass "1. RED control: judged only at the checkpoints, box-a flips to healthy on $old1 of $n1 ticks" ||
  fail "1. RED control: the old rule was healthy on $old1 of $n1 ticks (want some, not all)"

# 2. the hold ends 30 min after the gap
s29="$(state box-a $((G1 + 1799)))" s30="$(state box-a $((G1 + 1800)))"
[[ "$s29" == recovering && "$s30" == healthy ]] && pass "2. the hold ends 30 min after the gap: +1799 s recovering, +1800 s healthy" ||
  fail "2. hold end: +1799 s $s29, +1800 s $s30"
why="$(spl_box_health_verdicts "$(rows $((G1 + 600)) "$(spl_box_health_since)")" | jq -r '.["box-a"].why')"
[[ "$why" =~ ^healthy\ for\ [0-9]+s\ \<\ hold\ 1800s$ ]] && pass "2. the why stays \"$why\"" || fail "2. why: $why"

# 3. a healthy box stays healthy
bad3=""
for now in $(seq $((G1 + 30)) 7 $((G1 + 630))); do
  s="$(state box-b "$now")"; [[ "$s" == healthy ]] || bad3+=" +$((now - G1)):$s"
done
[[ -z "$bad3" ]] && pass "3. box-b (no gap over max_gap) healthy on every tick" || fail "3. box-b:$bad3"

# 4. hold 0 judges now only
s4="$(state box-a $((G1 + 60)) 0)" d4="$(state box-a $((G0 + 150)) 0)"
[[ "$s4" == healthy && "$d4" == degraded ]] && pass "4. hold 0: degraded inside the gap, healthy after it (no hold)" ||
  fail "4. hold 0: in gap $d4, after $s4"

[[ $fails == 0 ]] && echo "ALL PASS" || { echo "$fails FAIL"; exit 1; }
