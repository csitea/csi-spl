#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the placer's supply lead (spec 166 row B3, section 4.3; owner
#          HUM-10, t1 c0b0d572 msg 421e479a). From SPAWN_SUPPLY_LEAD_MIN
#          (120) before the night (do_spl_rhythm_phase: day now, night then)
#          the refactor supply blocker asks for the night's rows when fewer
#          than twice the night's refactor lanes are queued, so a planner by
#          day has rows ready at 20:00 CET/CEST. By day otherwise the hourly
#          blocker is today's, byte for byte.
#   The share: 10 live lanes with a class, refactor 10% (under the owner's
#   24 h floor of 20%), bug 30% (in band). The night band's refactor floor is
#   40%: 4 lanes, so the lead wants 2 x 4 = 8 queued refactor rows.
#   1. 17:30Z in January (18:30 CET), 0 refactor rows queued: ONE blocker,
#      the lead's, naming the night of 2026-01-15; no hourly one besides
#      (RED on origin/master: no blocker names the night)
#   2. noon, the same queue: only today's hourly refactor blocker, the same
#      bytes as origin/master's placer sends
#   3. July (CEST): 16:30Z -> the lead (night at 18:00Z); 15:30Z -> only the
#      hourly one (17:30Z is 19:30 CEST, still day): the phase decides, not
#      a fixed offset
#   4. a second tick the same night, the hourly gap passed: no second lead
#   5. 7 refactor rows queued -> the lead; 8 -> no blocker at all
#   6. refactor in its 24 h band, 0 queued: the lead still asks (it supplies
#      the night, not the 24 h floor)
#   7. at night (22:00Z) and with SPAWN_SUPPLY_LEAD_MIN=0: no lead, the
#      hourly one only
#   8. cnf env.rhythm.night_start 21: 17:30Z is no lead (19:30Z is 20:30
#      CET, day): the window is do_spl_rhythm_phase's
# Red control: SPAWN_PLACE_FUNC=<origin/master's spl-spawn-place.func.sh>.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
PLACE_FUNC="${SPAWN_PLACE_FUNC:-$PROJ_ROOT/src/bash/run/spl-spawn-place.func.sh}"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export SPOOL_TEST=1
mkdir -p "$T/asks" "$T/spool"

# share REFACTOR_PCT: 10 known lanes, refactor at REFACTOR_PCT, bug 30%; the
# 24 h floors are the owner's 20%.
share() {
  jq -n -c --argjson r "$1" '{known: 10, unknown: 0, lanes: [], bypasses: [],
    h24: {by: {refactor: {lo: 20, hi: 30}, bug: {lo: 20, hi: 30}}},
    by: {refactor: {n: ($r / 10), pct: $r, lo: 10, hi: 20}, bug: {n: 3, pct: 30, lo: 15, hi: 20},
         feature: {n: (7 - $r / 10), pct: (70 - $r), lo: 60, hi: 100}}}' >"$T/share.json"
}
# rows N: N queued refactor rows and one feature row.
rows() {
  jq -n -c --argjson n "$1" '[range($n) | {ask_id: "r\(.)", state: "queued", class: "refactor", position: (. + 1)}]
    + [{ask_id: "f0", state: "queued", class: "feature", position: ($n + 1)}]' >"$T/rows.json"
}
# tick NOW [ENV...]: one supply check at NOW; the blockers sent go to
# $T/send.log (cleared first), the log lines to $T/out. KEEP=1 keeps the
# stamps of the last tick, otherwise they are cleared too.
tick() {
  local now="$1"; shift
  : >"$T/send.log"; [[ "${KEEP:-0}" == 1 ]] || rm -f "$T/asks"/.share.*
  env SPOOL_ROOT="$T/spool" SPOOL_ASKS_DIR="$T/asks" PROJ_PATH="$PROJ_ROOT" APP_PATH="$T" SPAWN_SHARE_DISPATCH=c-002@sat \
    RHYTHM_NOW="$now" SHARE="$T/share.json" SEND_LOG="$T/send.log" PLACE_FUNC="$PLACE_FUNC" "$@" bash -c '
    do_log() { printf "%s\n" "$*"; }
    source "$1/src/bash/features/spawn-agents/lib/spool-asks.inc.sh"
    source "$1/src/bash/run/spl-spawn-share.func.sh"
    spl_spawn_group_feed() { :; }
    source "$PLACE_FUNC"
    SPOOL_PARTICIPANT_RX="[a-z]-[0-9]{3}"
    spl_spawn_share() { cat "$SHARE"; }
    spl_spawn_q_send() { printf "%s %s %s %s %s\n" "$@" >>"$SEND_LOG"; }
    spl_spawn_place_supply c-001@sat "$(cat "$2")"' _ "$PROJ_ROOT" "$T/rows.json" >"$T/out" 2>&1
}
nsend() { wc -l <"$T/send.log" | tr -d ' '; }
lead() { grep -c "blocker spawn-share \*\*SPAWN SUPPLY LEAD: the night of $1 starts within 120 min" "$T/send.log"; }
hourly() { grep -c "blocker spawn-share \*\*SPAWN SHARE: refactor share 10% < 20%" "$T/send.log"; }
seen() { echo "sends: $(cat "$T/send.log") | log: $(head -c 400 "$T/out")"; }

# 1. two hours before the night ---------------------------------------------------
share 10; rows 0
tick 2026-01-15T17:30Z
if [[ "$(nsend)" == 1 && "$(lead 2026-01-15)" == 1 ]] &&
   grep -q "0 refactor row(s) queued, fewer than 2 x 4 (the night band floor 40% of 10 live lanes with a class)" "$T/send.log" &&
   grep -q "OK supply lead: the night of 2026-01-15" "$T/out"; then
  pass "1 17:30Z January, 0 refactor queued: ONE blocker, the lead's, naming the night of 2026-01-15"
else fail "1 lead before the night: $(seen)"; fi

# 2. noon: today's hourly one, byte for byte -----------------------------------------
tick 2026-01-15T12:00Z
cp "$T/send.log" "$T/noon.mine"
if [[ "$(nsend)" == 1 && "$(hourly)" == 1 && "$(lead 2026-01-15)" == 0 ]]; then
  pass "2 noon, the same queue: only today's hourly refactor blocker"
else fail "2 noon: $(seen)"; fi
if git -C "$PROJ_ROOT" cat-file -e origin/master:csi-spl-orc/src/bash/run/spl-spawn-place.func.sh 2>/dev/null; then
  git -C "$PROJ_ROOT" show origin/master:csi-spl-orc/src/bash/run/spl-spawn-place.func.sh >"$T/master.func.sh"
  PLACE_FUNC="$T/master.func.sh" tick 2026-01-15T12:00Z
  cmp -s "$T/send.log" "$T/noon.mine" && pass "2 noon: the same bytes as origin/master's placer sends" ||
    fail "2 noon differs from origin/master: mine $(cat "$T/noon.mine") | master $(cat "$T/send.log")"
else echo "SKIP: 2 no origin/master to compare the noon bytes with"; fi

# 3. summer time: the phase decides -------------------------------------------------
tick 2026-07-15T16:30Z
[[ "$(nsend)" == 1 && "$(lead 2026-07-15)" == 1 ]] && pass "3 16:30Z July (CEST): the lead, the night starts at 18:00Z" ||
  fail "3 July lead: $(seen)"
tick 2026-07-15T15:30Z
[[ "$(nsend)" == 1 && "$(hourly)" == 1 ]] && pass "3 15:30Z July: only the hourly one (17:30Z is 19:30 CEST, day)" ||
  fail "3 July before the lead: $(seen)"

# 4. once per night -------------------------------------------------------------------
tick 2026-01-15T17:10Z
rm -f "$T/asks/.share.refactor.last"
KEEP=1 tick 2026-01-15T18:20Z
[[ "$(lead 2026-01-15)" == 0 && "$(hourly)" == 1 ]] && pass "4 a second tick the same night: no second lead, the hourly check as by day" ||
  fail "4 second tick: $(seen)"

# 5. the 2 x night-lanes threshold ------------------------------------------------------
rows 7; tick 2026-01-15T17:30Z
[[ "$(nsend)" == 1 && "$(lead 2026-01-15)" == 1 ]] && grep -q "7 refactor row(s) queued, fewer than 2 x 4" "$T/send.log" &&
  pass "5 7 refactor rows queued (< 8): the lead" || fail "5 seven queued: $(seen)"
rows 8; tick 2026-01-15T17:30Z
[[ "$(nsend)" == 0 ]] && pass "5 8 refactor rows queued: no blocker" || fail "5 eight queued: $(seen)"

# 6. refactor in its 24 h band ---------------------------------------------------------
share 20; rows 0; tick 2026-01-15T17:30Z
[[ "$(nsend)" == 1 && "$(lead 2026-01-15)" == 1 ]] && pass "6 refactor 20% (in its 24 h band), 0 queued: the lead still asks" ||
  fail "6 in band: $(seen)"
tick 2026-01-15T12:00Z
[[ "$(nsend)" == 0 ]] && pass "6 CONTROL: the same at noon sends nothing" || fail "6 noon in band: $(seen)"

# 7. at night, and the lead off ----------------------------------------------------------
share 10
tick 2026-01-15T22:00Z
[[ "$(nsend)" == 1 && "$(hourly)" == 1 ]] && pass "7 22:00Z (night): no lead, the hourly one" || fail "7 night: $(seen)"
tick 2026-01-15T17:30Z SPAWN_SUPPLY_LEAD_MIN=0
[[ "$(nsend)" == 1 && "$(hourly)" == 1 ]] && pass "7 SPAWN_SUPPLY_LEAD_MIN=0: no lead, the hourly one" || fail "7 lead off: $(seen)"

# 8. the window is do_spl_rhythm_phase's -------------------------------------------------
if command -v yq >/dev/null; then
  printf 'env:\n  rhythm:\n    timezone: Europe/Berlin\n    night_start: 21\n    night_end: 7\n' >"$T/rhythm.yaml"
  tick 2026-01-15T17:30Z RHYTHM_CNF="$T/rhythm.yaml"
  [[ "$(nsend)" == 1 && "$(hourly)" == 1 ]] && pass "8 night_start 21: 17:30Z is no lead (19:30Z is 20:30 CET, day)" || fail "8 cnf window: $(seen)"
  tick 2026-01-15T18:30Z RHYTHM_CNF="$T/rhythm.yaml"
  [[ "$(lead 2026-01-15)" == 1 ]] && pass "8 night_start 21: 18:30Z is the lead" || fail "8 cnf lead: $(seen)"
else echo "SKIP: 8 no yq"; fi

echo
((fails == 0)) && { echo "spl-spawn-place-supply: all passed"; exit 0; }
echo "spl-spawn-place-supply: $fails failure(s)"; exit 1
