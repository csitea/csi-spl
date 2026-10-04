#!/usr/bin/env bash
# spawn-window.sh PLACEMENT (owner GO 2026-10-03, real load 2026-10-04): a
# new lane (TITLE auto) starts on the fleet box with the fewest BUSY agents -
# the agents live there NOW (this box: its tmux panes; another box: its own
# BOX-0 report row) - then the most free memory, then here; and the lane
# map's header shows that load per box. Measured before: 9 agents on the box the
# orchestrator runs on, 2 on the other, because every lane started where the
# orchestrator was.
#
# The load comes from the REAL lane map action (do_spl_lane_map, json) over a
# stub hub and a stub tmux (the panes of this box); spawn-remote.sh is a stub. Nothing is spawned: a placement that
# stays here runs into "no tmux session" (exit 5, no tmux server here), one
# that goes elsewhere prints the stub's "<ID>@<box> <PANE>".
#   1. busy 8 elsewhere, 0 here -> here; CONTROL busy 0 elsewhere, 8 here -> there
#   2. a tie -> here; CONTROL one more here -> there
#   3. SPAWN_BOX=local wins over a lighter box; SPAWN_BOX=<box> wins over the
#      load; CONTROL the same load without it -> there
#   4. the remote does not answer (spawn-remote exit 5) -> here, with a WARN;
#      CONTROL exit 0 -> its line, no WARN; an explicit SPAWN_BOX does not fall back
#   5. role seats (001-003, lease.conf ids) are not busy; CONTROL the same
#      count of build ids is
#   6. the header: one line per box (lease.conf boxes too), busy, seats, mem;
#      CONTROL a box outside lease.conf with no row is not listed
#   7. guards: an explicit TITLE never moves; no fleet = no lane map call;
#      another box holding the orch lease = here
#   8. a lane running 3 h with a live pane is busy (the 2 h row window said
#      0); CONTROL its pane dead -> not busy; another box's report counts its
#      lanes 3 h old too
#   9. a finished lane (row still live, written 10 min ago, its pane gone) is
#      not busy; CONTROL the panes alive; another box: a lane written done
#      after its report leaves the count, one written live after it joins
#  10. memory breaks a busy tie: the other box has more free memory -> there;
#      CONTROL the same memory -> here
#  11. a box under SPAWN_MEM_FLOOR_MB (default 4096) is skipped even when
#      idle; CONTROL a lower floor -> there; this box under the floor -> there
#  12. the BOX-0 report: this box publishes `mem_kb=<n> live=<ids>` (at most
#      every LANE_BOX_ROW_S); the header shows the other box's mem from its
#      report; a stale report (LANE_BOX_ROW_MAX_S) falls back to its rows;
#      BOX-0 is never listed as a lane
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
unset LEASE_MACHINE LANE_FLEET SPAWN_BOX SPAWN_REMOTE_CMD SPAWN_PLACE_MAP_CMD SPAWN_DRY_RUN SPAWN_BOX_PICK_CMD
command -v jq >/dev/null || { nok "jq is required"; t_done; exit 1; }
SW="$T_SCRIPTS/spawn-window.sh"
ORC="$T_REPO/csi-spl-orc"
HERE_BOX=box-a OTHER=box-b
export SPOOL_DESK_BOX="$HERE_BOX"
mkdir -p "$SPOOL_ROOT/dispatch" "$T_TMP/bin" "$T_TMP/wd"
conf() {  # [SEAT_IDS (3, default c-001..c-003)] extra lease.conf lines
  local ids="c-002 c-003 c-001"; case "${1:-}" in seats=*) ids="${1#seats=}"; shift ;; esac
  set -- $ids "$@"
  printf '%s\n' "LEASE_MASTER=$1" "LEASE_FAILOVER=$2" "LEASE_ORCH=$3" LEASE_FLEET=main \
    "LEASE_PRIORITY=$HERE_BOX,$OTHER" "${@:4}" > "$SPOOL_ROOT/dispatch/lease.conf"
}
conf
echo "c-001@$HERE_BOX 1" > "$SPOOL_ROOT/dispatch/lease.orch"
printf 'MemTotal: 1 kB\nMemAvailable: 4194304 kB\n' > "$T_TMP/meminfo"
G=1048576  # kB per GB

# rows <box> <n> <first-id-number> [age_s] [state]: n lanes on that box
ROWS="$T_TMP/rows.json" PANES="$T_TMP/panes"
rows() { local i; for ((i = 0; i < $2; i++)); do printf 'c-%03d %s %s %s\n' $(( $3 + i )) "$1" "${4:-60}" "${5:-live}"; done; }
# report <box> <mem_kb> <age_s> <id,id,...>: that box's BOX-0 load row
report() { printf 'BOX-0 %s %s live mem_kb=%s live=%s\n' "$1" "$3" "$2" "$4"; }
set_rows() {  # "<id> <box> [age_s] [state] [scope...]" lines on stdin; this box's live rows are its live panes
  jq -R -s -c '{lanes: [split("\n")[] | select(length > 0) | split(" ") |
    {agent_id: .[0], agent_box: .[1], repo: "r", branch: "b", scope: (.[4:] | join(" ")), files: [], topic: "",
     state: (.[3] // "live"), age_s: ((.[2] // "60") | tonumber)}]}' > "$ROWS"
  jq -r --arg b "$HERE_BOX" '.lanes[] | select(.agent_box == $b and .state == "live" and .agent_id != "BOX-0") | "0 \(.agent_id)@sat build"' "$ROWS" > "$PANES"
}
panes() { printf '%s\n' "$@" > "$PANES"; }  # "<pane_dead> <window name>" lines
cat > "$T_TMP/bin/hub" <<STUB
#!/usr/bin/env bash
case " \$* " in *" --agent "*) echo "\$*" >> "$T_TMP/hub.puts" ;; esac
cat "$ROWS"
STUB
# The real action, as lane-map.sh --json runs it.
cat > "$T_TMP/bin/map" <<STUB
#!/usr/bin/env bash
cd "$ORC" && SPOOL_ROOT="$SPOOL_ROOT" LANE_BOX="$HERE_BOX" LANE_HUB_CMD="$T_TMP/bin/hub" LANE_MEMINFO="$T_TMP/meminfo" \
  LANE_REPO_DIRS="$T_TMP/none" LANE_PANES_CMD="cat $PANES" LANE_FORMAT=\${FMT:-json} bash -c '
  do_log() { echo "\$*" >&2; }
  source src/bash/run/spl-lane-map.func.sh
  do_spl_lane_map'
STUB
# spawn-remote stub: logs its args, answers REMOTE_RC / "<ID>@<box> %9"
cat > "$T_TMP/bin/remote" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$T_TMP/remote.calls"
[ "\${REMOTE_RC:-0}" = 0 ] || { echo "spawn-remote: no reply" >&2; exit "\$REMOTE_RC"; }
echo "c-200@\$2 %9"
STUB
chmod +x "$T_TMP/bin/"*
export SPAWN_PLACE_MAP_CMD="$T_TMP/bin/map" SPAWN_REMOTE_CMD="$T_TMP/bin/remote"
# The busy count alone; the load target pick has its own test (test-spawn-load-target.sh).
export SPAWN_BOX_PICK=0

spawn() {  # [TITLE] -> OUT, RC
  rm -f "$T_TMP/remote.calls"
  OUT="$(bash "$SW" claude "${1:-auto}" "$T_TMP/wd" 2>&1)"; RC=$?
}
went_here() { [ "$RC" = 5 ] && [[ "$OUT" == *"no tmux session"* ]] && [ ! -e "$T_TMP/remote.calls" ]; }
went_there() { [ "$RC" = 0 ] && [[ "$OUT" == *"c-200@$OTHER %9"* ]] && grep -q -- "--box $OTHER claude auto $T_TMP/wd" "$T_TMP/remote.calls"; }

# 1.
{ rows "$OTHER" 8 100; } | set_rows
spawn; check "1. busy 8 there, 0 here: stays here" went_here
{ rows "$HERE_BOX" 8 100; echo "c-002 $OTHER"; } | set_rows
spawn; check "1. CONTROL busy 8 here, 0 there: starts there, prints <ID>@<box> <PANE>" went_there
has "1. ... and says why on stderr" "placing auto on $OTHER (fewest busy agents, then most free memory)" "$OUT"

# 2.
{ rows "$HERE_BOX" 3 100; rows "$OTHER" 3 200; } | set_rows
spawn; check "2. a tie (3 = 3) stays here" went_here
{ rows "$HERE_BOX" 4 100; rows "$OTHER" 3 200; } | set_rows
spawn; check "2. CONTROL 4 here, 3 there: starts there" went_there

# 3.
{ rows "$HERE_BOX" 8 100; echo "c-002 $OTHER"; } | set_rows
rm -f "$T_TMP/remote.calls"
OUT="$(SPAWN_BOX=local bash "$SW" claude auto "$T_TMP/wd" 2>&1)"; RC=$?
check "3. SPAWN_BOX=local wins over a lighter box" went_here
OUT="$(SPAWN_BOX=$HERE_BOX bash "$SW" claude auto "$T_TMP/wd" 2>&1)"; RC=$?
check "3. SPAWN_BOX=<this box> wins too" went_here
{ rows "$OTHER" 8 100; } | set_rows
rm -f "$T_TMP/remote.calls"
OUT="$(SPAWN_BOX=$OTHER bash "$SW" claude auto "$T_TMP/wd" 2>&1)"; RC=$?
check "3. SPAWN_BOX=<other box> wins over its heavier load" went_there
spawn; check "3. CONTROL the same load without SPAWN_BOX stays here" went_here
OUT="$(SPAWN_BOX='a b' bash "$SW" claude auto "$T_TMP/wd" 2>&1)"; RC=$?
eq "3. a SPAWN_BOX that is not one box id: usage exit 2" 2 "$RC"

# 4.
{ rows "$HERE_BOX" 8 100; echo "c-002 $OTHER"; } | set_rows
rm -f "$T_TMP/remote.calls"
OUT="$(REMOTE_RC=5 bash "$SW" claude auto "$T_TMP/wd" 2>&1)"; RC=$?
check "4. the remote does not answer: asked it, then starts here" \
  bash -c '[ "$1" = 5 ] && [[ "$2" == *"no tmux session"* ]] && [ -e "$3" ]' _ "$RC" "$OUT" "$T_TMP/remote.calls"
has "4. ... with a WARN on stderr" "WARN the spawn on $OTHER did not start (spawn-remote exit 5" "$OUT"
spawn; check "4. CONTROL the remote answers: its line" went_there
hasnt "4. CONTROL ... and no placement WARN (spool-env may WARN about a stale bin)" "WARN the spawn on" "$OUT"
OUT="$(SPAWN_BOX=$OTHER REMOTE_RC=5 bash "$SW" claude auto "$T_TMP/wd" 2>&1)"; RC=$?
eq "4. an explicit SPAWN_BOX does not fall back: exit 8" 8 "$RC"

# 5. c-001..c-003 and the lease.conf ids are role seats
conf 'seats=c-077 c-078 c-079'
{ printf 'c-001 %s\nc-002 %s\nc-003 %s\nc-077 %s\n' "$HERE_BOX" "$HERE_BOX" "$HERE_BOX" "$HERE_BOX"; rows "$OTHER" 1 200; } | set_rows
spawn; check "5. 4 role seats here, 1 build lane there: stays here" went_here
load="$(FMT=json "$T_TMP/bin/map" 2>/dev/null | jq -c --arg b "$HERE_BOX" '.load[] | select(.box == $b) | [.busy, .seats]')"
eq "5. here: busy 0, seats 4" "[0,4]" "$load"
{ rows "$HERE_BOX" 4 100; rows "$OTHER" 1 200; } | set_rows
spawn; check "5. CONTROL 4 build lanes here, 1 there: starts there" went_there
conf

# 6. the header
{ rows "$HERE_BOX" 2 100; echo "c-001 $HERE_BOX"; rows "$OTHER" 8 200; } | set_rows
hdr="$(FMT=table "$T_TMP/bin/map" 2>/dev/null)"
has "6. header: this box, busy, seats, mem from meminfo" "BOX $HERE_BOX (here)  busy 2  seats 1  mem 4.0G" "$hdr"
has "6. header: the other box (no report), mem ?, read from its rows" "BOX $OTHER  busy 8  seats 0  mem ?  (rows < 2h)" "$hdr"
eq "6. header lines come first, one per box" "BOX BOX AGENT@BOX" "$(head -3 <<<"$hdr" | awk '{printf "%s%s", (NR > 1 ? " " : ""), $1}')"
hasnt "6. CONTROL a box outside lease.conf with no row is not listed" "BOX box-c" "$hdr"
conf "LEASE_PRIORITY_ORCH=$OTHER,box-c"
has "6. ... and is listed once lease.conf ranks it, marked no live row" "BOX box-c  busy 0  seats 0  mem ?  (no live row)" \
  "$(FMT=table "$T_TMP/bin/map" 2>/dev/null)"
conf

# 7. guards (CONTROL for the down box: 1. CONTROL, the same load plus one seat there)
{ rows "$HERE_BOX" 8 100; } | set_rows
spawn; check "7. a box with no live row at all is down: stays here" went_here
{ rows "$HERE_BOX" 8 100; echo "c-002 $OTHER"; } | set_rows
spawn c-150; check "7. an explicit TITLE never moves" went_here
echo "c-001@$OTHER 1" > "$SPOOL_ROOT/dispatch/lease.orch"
spawn; check "7. the orch lease is held on another box: stays here (its serve would refuse us)" went_here
echo "c-001@$HERE_BOX 1" > "$SPOOL_ROOT/dispatch/lease.orch"
conf; grep -v LEASE_FLEET "$SPOOL_ROOT/dispatch/lease.conf" > "$T_TMP/c" && mv "$T_TMP/c" "$SPOOL_ROOT/dispatch/lease.conf"
OUT="$(SPAWN_PLACE_MAP_CMD="touch $T_TMP/map.called" bash "$SW" claude auto "$T_TMP/wd" 2>&1)"; RC=$?
check "7. no fleet: the lane map is never called" test ! -e "$T_TMP/map.called"
conf
OUT="$(SPAWN_PLACE_MAP_CMD="touch $T_TMP/map.called" bash "$SW" claude auto "$T_TMP/wd" 2>&1)"; RC=$?
check "7. CONTROL in a fleet it is" test -e "$T_TMP/map.called"
has "7. ... and an unreadable map stays here with a WARN" "WARN no lane map load" "$OUT"

# load <box> <field>: one field of a box's load, as the placement reads it
load() { FMT=json "$T_TMP/bin/map" 2>/dev/null | jq -c --arg b "$1" ".load[] | select(.box == \$b) | $2"; }

# 8. long-running lanes
{ rows "$HERE_BOX" 2 100 10800; report "$OTHER" $((32 * G)) 60 c-200; rows "$OTHER" 1 200 10800; } | set_rows
eq "8. here: 2 lanes 3 h old with live panes are busy 2" 2 "$(load "$HERE_BOX" .busy)"
eq "8. there: its report counts a lane 3 h old, busy 1" 1 "$(load "$OTHER" .busy)"
spawn; check "8. 2 busy here, 1 there: starts there" went_there
panes "1 c-100@sat build" "1 c-101@sat build"
eq "8. CONTROL the same rows with dead panes: busy 0 here" 0 "$(load "$HERE_BOX" .busy)"
spawn; check "8. CONTROL ... and stays here" went_here

# 9. finished lanes
{ rows "$HERE_BOX" 4 100 600; report "$OTHER" $((32 * G)) 60 c-200; rows "$OTHER" 1 200 60; } | set_rows
panes
eq "9. 4 rows still live, written 10 min ago, no pane left: busy 0 here" 0 "$(load "$HERE_BOX" .busy)"
spawn; check "9. 0 busy here, 1 there: stays here" went_here
{ rows "$HERE_BOX" 4 100 600; report "$OTHER" $((32 * G)) 60 c-200; rows "$OTHER" 1 200 60; } | set_rows
spawn; check "9. CONTROL the same rows with their panes alive (busy 4): starts there" went_there
{ report "$OTHER" $((32 * G)) 300 c-200,c-201,c-202; rows "$OTHER" 1 201 120 "done"; rows "$OTHER" 1 205 30; rows "$OTHER" 1 202 400 "done"; } | set_rows
eq "9. there: report 3, minus c-201 done after it, plus c-205 live after it (c-202 done before: ignored)" 3 "$(load "$OTHER" .busy)"

# 10. memory breaks a tie
{ rows "$HERE_BOX" 2 100; report "$OTHER" $((32 * G)) 60 c-200,c-201; } | set_rows
spawn; check "10. 2 busy each, 32G there vs 4G here: starts there" went_there
{ rows "$HERE_BOX" 2 100; report "$OTHER" $((4 * G)) 60 c-200,c-201; } | set_rows
spawn; check "10. CONTROL 2 busy each, the same 4G: stays here" went_here
{ rows "$HERE_BOX" 2 100; report "$OTHER" $((32 * G)) 60 c-200,c-201,c-202; } | set_rows
spawn; check "10. memory never beats a lower busy count: 2 here, 3 there with 32G: here" went_here

# 11. the low-memory floor
{ rows "$HERE_BOX" 5 100; report "$OTHER" $((1 * G)) 60 ""; } | set_rows
spawn; check "11. idle there but 1G free (floor 4096 MB): skipped, stays here" went_here
rm -f "$T_TMP/remote.calls"
OUT="$(SPAWN_MEM_FLOOR_MB=512 bash "$SW" claude auto "$T_TMP/wd" 2>&1)"; RC=$?
check "11. CONTROL a 512 MB floor: starts there" went_there
{ rows "$HERE_BOX" 1 100; report "$OTHER" $((32 * G)) 60 c-200,c-201,c-202; } | set_rows
rm -f "$T_TMP/remote.calls"
OUT="$(SPAWN_MEM_FLOOR_MB=8192 bash "$SW" claude auto "$T_TMP/wd" 2>&1)"; RC=$?
check "11. this box under the floor (4G < 8G): the busier box with room wins" went_there
OUT="$(SPAWN_MEM_FLOOR_MB=lots bash "$SW" claude auto "$T_TMP/wd" 2>&1)"; RC=$?
eq "11. a SPAWN_MEM_FLOOR_MB that is not a number: usage exit 2" 2 "$RC"

# 12. the report
rm -f "$T_TMP/hub.puts"
{ rows "$HERE_BOX" 1 100; echo "c-001 $HERE_BOX"; report "$OTHER" $((32 * G)) 60 c-200; } | set_rows
hdr="$(FMT=table "$T_TMP/bin/map" 2>/dev/null)"
has "12. this box publishes its BOX-0 row: free kB and its live pane ids" \
  "lane --fleet main --agent BOX-0 --box $HERE_BOX --scope mem_kb=4194304 live=c-001,c-100 --state live" "$(cat "$T_TMP/hub.puts" 2>/dev/null)"
has "12. the header shows the other box's mem from its report" "BOX $OTHER  busy 1  seats 0  mem 32.0G" "$hdr"
hasnt "12. BOX-0 is never a lane in the table" "BOX-0" "$hdr"
eq "12. ... nor in the json lanes" "[]" "$(FMT=json "$T_TMP/bin/map" 2>/dev/null | jq -c '[.lanes[] | select(.agent_id == "BOX-0")]')"
rm -f "$T_TMP/hub.puts"
{ rows "$HERE_BOX" 1 100; report "$HERE_BOX" 1 120 c-100; } | set_rows
FMT=table "$T_TMP/bin/map" >/dev/null 2>&1
check "12. a report of this box 2 min old is not rewritten" test ! -e "$T_TMP/hub.puts"
{ rows "$HERE_BOX" 1 100; report "$HERE_BOX" 1 400 c-100; } | set_rows
FMT=table "$T_TMP/bin/map" >/dev/null 2>&1
check "12. CONTROL one 400 s old is" test -s "$T_TMP/hub.puts"
{ rows "$HERE_BOX" 1 100; report "$OTHER" $((32 * G)) 4000 c-200,c-201,c-202; rows "$OTHER" 1 200 60; } | set_rows
eq "12. a report over an hour old is not read: the other box falls back to its rows" '[1,"?","rows"]' "$(load "$OTHER" '[.busy, .mem, .src]')"

t_done
