#!/usr/bin/env bash
# spawn-window.sh LOAD TARGET (owner HUM-10, t1 c13e8023): a new lane (TITLE
# auto) asks do_spl_box_pick first (stubbed here by SPAWN_BOX_PICK_CMD).
#   1. pick=<other box> -> it starts there (spawn-remote), and says why
#   2. pick=<this box> -> it stays here, no lane map read, no remote call
#   3. pick=hold -> exit 10, nothing spawned, no remote call, says queue it
#   4. no pick line (the action failed) -> WARN, then the busy count decides
#   5. SPAWN_BOX wins over a hold; CONTROL an explicit TITLE never asks
#   6. the spawner is not SPOOL_BOX_USER (an agent user): the real action
#      runs as SPOOL_BOX_USER with its HOME (the seated desk lives there), and
#      its pick is used, no WARN; CONTROL the caller's own HOME (no hop, the
#      code before the fix) is "not pinned" -> the WARN
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
unset LEASE_MACHINE LANE_FLEET SPAWN_BOX SPAWN_REMOTE_CMD SPAWN_PLACE_MAP_CMD SPAWN_DRY_RUN SPAWN_BOX_PICK SPAWN_BOX_PICK_CMD SPAWN_ORC_RUN SPAWN_PICK_HOP_CMD
SW="$T_SCRIPTS/spawn-window.sh"
HERE_BOX=box-a OTHER=box-b
export SPOOL_DESK_BOX="$HERE_BOX"
mkdir -p "$SPOOL_ROOT/dispatch" "$T_TMP/bin" "$T_TMP/wd"
printf '%s\n' LEASE_MASTER=c-002 LEASE_FAILOVER=c-003 LEASE_ORCH=c-001 LEASE_FLEET=main \
  "LEASE_PRIORITY=$HERE_BOX,$OTHER" > "$SPOOL_ROOT/dispatch/lease.conf"
echo "c-001@$HERE_BOX 1" > "$SPOOL_ROOT/dispatch/lease.orch"

cat > "$T_TMP/bin/pick" <<STUB
#!/usr/bin/env bash
touch "$T_TMP/pick.called"
printf '%s\n' "\$PICK_OUT"
STUB
cat > "$T_TMP/bin/map" <<STUB
#!/usr/bin/env bash
touch "$T_TMP/map.called"
echo '{"load":[{"box":"$HERE_BOX","busy":5,"live":true},{"box":"$OTHER","busy":0,"live":true}]}'
STUB
cat > "$T_TMP/bin/remote" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$T_TMP/remote.calls"
echo "c-200@\$2 %9"
STUB
chmod +x "$T_TMP/bin/"*
export SPAWN_BOX_PICK_CMD="$T_TMP/bin/pick" SPAWN_PLACE_MAP_CMD="$T_TMP/bin/map" SPAWN_REMOTE_CMD="$T_TMP/bin/remote"

spawn() {  # [TITLE] -> OUT, RC
  rm -f "$T_TMP/remote.calls" "$T_TMP/map.called" "$T_TMP/pick.called"
  OUT="$(bash "$SW" claude "${1:-auto}" "$T_TMP/wd" 2>&1)"; RC=$?
}
went_here() { [ "$RC" = 5 ] && [[ "$OUT" == *"no tmux session"* ]] && [ ! -e "$T_TMP/remote.calls" ]; }
went_there() { [ "$RC" = 0 ] && [[ "$OUT" == *"c-200@$OTHER %9"* ]] && grep -q -- "--box $OTHER claude auto" "$T_TMP/remote.calls"; }
held() { [ "$RC" = 10 ] && [[ "$OUT" == *"HOLD auto"*"Queue it; nothing was spawned."* ]] && [ ! -e "$T_TMP/remote.calls" ]; }
no_map() { [ ! -e "$T_TMP/map.called" ]; }

# 1.
export PICK_OUT="BOX $HERE_BOX  load5 13  cpus 16  81%  full
pick=$OTHER reason=$OTHER is the first box in order below its high mark (53% < 75%)"
spawn; check "1. pick=$OTHER: starts there" went_there
has "1. ... and says the load target's reason" "load target: $OTHER is the first box in order below its high mark (53% < 75%)" "$OUT"
check "1. ... without reading the lane map" no_map

# 2.
export PICK_OUT="pick=$HERE_BOX reason=$HERE_BOX is the first box in order below its high mark (40% < 75%)"
spawn; check "2. pick=$HERE_BOX (this box): stays here although the busy count says $OTHER" went_here
check "2. ... without reading the lane map" no_map

# 3.
export PICK_OUT="pick=hold reason=no box with a sample is below its high mark (75%): queue the lane, spawn nothing"
spawn; check "3. pick=hold: exit 10, nothing spawned, no remote call" held
has "3. ... and says why" "no box with a sample is below its high mark (75%)" "$OUT"

# 4.
export PICK_OUT="FATAL the hub did not answer the box stats read: dial: refused"
spawn; check "4. no pick line: the busy count places it ($OTHER has 0 busy)" went_there
has "4. ... with a WARN" "WARN no load target pick (FATAL the hub did not answer the box stats read" "$OUT"

# 5.
export PICK_OUT="pick=hold reason=all full"
OUT="$(SPAWN_BOX="$OTHER" bash "$SW" claude auto "$T_TMP/wd" 2>&1)"; RC=$?
check "5. SPAWN_BOX=$OTHER wins over a hold" went_there
rm -f "$T_TMP/pick.called"
spawn c-777
check "5. CONTROL an explicit TITLE never asks the pick" test ! -e "$T_TMP/pick.called"

# 6. A box user other than the caller: any account with a passwd HOME will do.
DESK_USER=root DESK_HOME="$(getent passwd root | cut -d: -f6)"
cat > "$T_TMP/bin/hop" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$T_TMP/hop.calls"
shift; exec "\$@"
STUB
cat > "$T_TMP/bin/orc-run" <<STUB
#!/usr/bin/env bash
[ "\$1 \$2" = "-a do_spl_box_pick" ] || exit 0
if [ "\$HOME" = "$DESK_HOME" ]; then echo "pick=$OTHER reason=$OTHER is below its low mark (10% < 50%)"
else echo "FATAL $HERE_BOX is not pinned in t1 (\$HOME/.local/share/csi-spl/cloud/prd/desk/t1/$HERE_BOX): seat a desk there first"; fi
STUB
chmod +x "$T_TMP/bin/hop" "$T_TMP/bin/orc-run"
agent_spawn() {  # BOX_USER -> OUT, RC (a dry run: the PLAN, no remote call)
  rm -f "$T_TMP/hop.calls" "$T_TMP/map.called"
  OUT="$(env -u SPAWN_BOX_PICK_CMD -u SPAWN_REMOTE_CMD SPOOL_BOX_USER="$1" SPAWN_ORC_RUN="$T_TMP/bin/orc-run" \
    SPAWN_PICK_HOP_CMD="$T_TMP/bin/hop" SPAWN_DRY_RUN=1 bash "$SW" claude auto "$T_TMP/wd" 2>&1)"; RC=$?
}
agent_spawn "$DESK_USER"
has "6. agent-user spawner: the pick runs as the box user" "$DESK_USER env HOME=$DESK_HOME SPOOL_ROOT=$SPOOL_ROOT" "$(cat "$T_TMP/hop.calls" 2>/dev/null)"
has "6. ... and is used" "placing auto on $OTHER" "$OUT"
check "6. ... exit 0, no WARN" eval '[ "$RC" = 0 ] && [[ "$OUT" != *WARN* ]]'
check "6. ... without reading the lane map" no_map
agent_spawn "$(id -un)"
has "6. CONTROL no hop (the caller's HOME): the old WARN" "WARN no load target pick (FATAL $HERE_BOX is not pinned in t1" "$OUT"
check "6. CONTROL ... and no hop ran" test ! -e "$T_TMP/hop.calls"

t_done
