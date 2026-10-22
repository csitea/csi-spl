#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spl_spawn_share_lanes (do_spl_spawn_share's input) keeps only the
#          lanes the lane map itself calls recent (SPL-2836, bug round 3 row
#          01): the share was computed over hub rows nobody refreshed for days
#          and over leftover local worktrees. The lane map is a stub
#          (SPAWN_SHARE_LANES_CMD).
#   1. a live row 600 s old stays, one 330000 s old goes (red before the fix)
#   2. the hub answered: a local row with no age goes (red before the fix)
#   3. the hub did not answer (or the input has no .hub): a row with no age
#      stays, as the old stubs of spl-spawn-queue / spl-spawn-fill build them
#   4. a live role seat stays at any age; a done row never counts
#   5. LANE_RECENT_S moves the cut; an age of exactly the cut goes
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

# ids LANES_JSON [VAR=value...]: the ids spl_spawn_share_lanes keeps.
ids() {
  local json="$1"; shift
  printf '%s\n' "$json" >"$T/lanes.json"
  env "$@" SPAWN_SHARE_LANES_CMD="cat $T/lanes.json" bash -c '
    source "$1/src/bash/run/spl-spawn-share.func.sh"
    spl_spawn_share_lanes' _ "$PROJ_ROOT" | jq -r '[.[] | .agent_id + "@" + .agent_box] | join(",")'
}
check() {  # NAME WANT GOT
  if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1: want '$2', got '$3'"; fi
}

# 1. a stale hub row goes
got="$(ids '{"lanes":[{"agent_id":"c-101","agent_box":"sat","state":"live","age_s":600},{"agent_id":"a-313","agent_box":"sat","state":"live","age_s":330000}]}')"
check "1 a 330000 s old live row is left out" "c-101@sat" "$got"

# 2. the hub answered: a local leftover with no age goes
got="$(ids '{"hub":"ok","lanes":[{"agent_id":"c-101","agent_box":"sat","state":"live","age_s":600,"src":"hub"},{"agent_id":"c-102","agent_box":"sat","state":"live","age_s":-1,"src":"local"}]}')"
check "2 hub ok: a local row with no age is left out" "c-101@sat" "$got"

# 3. the hub did not answer, or no .hub: rows with no age are the whole map
got="$(ids '{"hub":"unreachable","lanes":[{"agent_id":"c-102","agent_box":"sat","state":"live","age_s":-1,"src":"local"}]}')"
check "3 hub unreachable: a row with no age stays" "c-102@sat" "$got"
got="$(ids '{"lanes":[{"agent_id":"c-201","agent_box":"box2","state":"live"},{"agent_id":"c-202","agent_box":"sat","state":"live"}]}')"
check "3 no .hub, no age_s (the old stubs): both rows stay" "c-201@box2,c-202@sat" "$got"

# 4. role seats stay at any age; done rows never count
got="$(ids '{"hub":"ok","lanes":[{"agent_id":"c-001","agent_box":"sat","state":"live","age_s":330000},{"agent_id":"g-002","agent_box":"box2","state":"live","age_s":-1},{"agent_id":"c-103","agent_box":"sat","state":"done","age_s":60},{"agent_id":"c-004","agent_box":"sat","state":"live","age_s":330000}]}')"
check "4 live role seats stay, a done row and a stale c-004 go" "c-001@sat,g-002@box2" "$got"

# 5. LANE_RECENT_S moves the cut
lanes='{"hub":"ok","lanes":[{"agent_id":"c-101","agent_box":"sat","state":"live","age_s":0},{"agent_id":"c-102","agent_box":"sat","state":"live","age_s":7199},{"agent_id":"c-103","agent_box":"sat","state":"live","age_s":7200}]}'
check "5 default cut 7200 s: 0 and 7199 stay, 7200 goes" "c-101@sat,c-102@sat" "$(ids "$lanes")"
check "5 LANE_RECENT_S=100: only the 0 s row stays" "c-101@sat" "$(ids "$lanes" LANE_RECENT_S=100)"

echo "$fails failure(s)"
((fails == 0))
