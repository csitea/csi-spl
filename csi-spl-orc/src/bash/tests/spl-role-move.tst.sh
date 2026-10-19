#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_role_move (SPL-2643) moves a fleet lease role to a named box
#          through a hub pin row that every box's fleet loop reads.
#   1. the action exists; bad ROLE / TO_BOX / DRY_RUN are refused
#   2. dry run: the checks run, PLAN + the DRY_RUN=0 command, no pin written
#   3. move orch sat -> pc: the pin lands, pc takes orch by the handback, sat
#      does not take it back (STANDBY), pc's seat is told ACTIVE, the action
#      returns 0 once the row is renewed from pc; dispatch stays on sat
#   4. the pin sticks: sat ranks first in every lease.conf and still keeps off
#   5. move orch back pc -> sat (this machine: its own seat is checked)
#   6. refused, nothing written: a box in no ranking; a box the hub beats call
#      degraded; a box with no beats; this machine with no live orch seat
#   7. a target whose seat never takes it: past ROLE_MOVE_WAIT the action
#      fails and the pin is undone (pinned to box none)
#   8. TO_BOX=none undoes a pin: the rankings decide again (sat takes it back)
#   9. the pin expires: a row older than LEASE_PIN_TTL pins nothing
#  Fixtures only in a mktemp root: never the live /var/spool-hub.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
ACTION="$PROJ_ROOT/src/bash/run/spl-role-move.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
case "$(readlink -f "$T")" in /var/spool-hub|/var/spool-hub/*) echo "FAIL: refusing to run inside the live spool root ($T)"; exit 1 ;; esac
export T PROJ_ROOT

# --- 1. the action exists ------------------------------------------------------
[[ -f "$ACTION" ]] && pass "1. $ACTION exists" || { fail "1. $ACTION is missing"; exit 1; }

mkdir -p "$T/bin" "$T/hub" "$T/pane"
echo 1000 >"$T/clock"
cat >"$T/bin/send" <<'STUB'
#!/bin/sh
to="" body=""
while [ $# -gt 0 ]; do case "$1" in --to) to="$2"; shift 2 ;; --body) body="$2"; shift 2 ;; *) shift ;; esac; done
echo "$to :: $body" >>"$SENT"
STUB
# the hub stub (fleet-lease.tst.sh's contract): one file per fleet+role,
# "holder gen at"; its clock is $T/clock
cat >"$T/bin/hub" <<'STUB'
#!/bin/sh
now=$(cat "$T/clock")
shift
fleet="" role="" holder="" ifgen=""
while [ $# -gt 0 ]; do case "$1" in --fleet) fleet="$2";; --role) role="$2";; --holder) holder="$2";; --if-gen) ifgen="$2";; esac; shift 2; done
f="$T/hub/$fleet.$role"; h="" g=0 at=0
[ -s "$f" ] && read -r h g at <"$f"
won=false
if [ -n "$holder" ] && [ "$ifgen" = "$g" ]; then g=$((g + 1)); h="$holder"; at="$now"; echo "$h $g $at" >"$f"; won=true; fi
age=-1; [ "$g" -gt 0 ] && age=$((now - at))
printf '{"fleet":"%s","role":"%s","holder":"%s","box":"b","gen":%s,"age_s":%s,"won":%s}\n' "$fleet" "$role" "$h" "$g" "$age" "$won"
STUB
printf '#!/bin/sh\nf="%s/pane/$1"; [ -e "$f" ] || exit 1; exec cat "$f"\n' "$T" >"$T/bin/pane"
# tick <machine>: one fleet loop tick on that machine, the pins on
cat >"$T/bin/tick" <<'STUB'
#!/usr/bin/env bash
m="$1"; now=$(cat "$T/clock")
env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$T/$m/spool" LEASE_PROC_ROOT="$T/$m/proc" LEASE_SEND="$T/bin/send" LEASE_PANE_CMD="$T/bin/pane" \
  SENT="$T/$m/sent" LEASE_HUB_CMD="$T/bin/hub" LEASE_NOW="$now" LEASE_PIN="${LEASE_PIN:-1}" LEASE_PIN_READ=0 LEASE_DESK_GATE=0 LEASE_ROLE_SWITCH=0 \
  LEASE_MACHINE="$m" LEASE_LIMIT_TZ=Etc/GMT-3 LEASE_HOLDDOWN=0 bash -c '
  set -uo pipefail
  do_log() { echo "$*"; }
  source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
  spl_lease_init && spl_lease_ids master failover orch && spl_fleet_ids && spl_fleet_hub_init && spl_lease_fleet_tick' >>"$T/ticks.out" 2>&1
STUB
# the action's sleep: the clock moves on and both loops tick (unless $T/frozen)
cat >"$T/bin/sleep" <<'STUB'
#!/usr/bin/env bash
echo $(( $(cat "$T/clock") + $1 )) >"$T/clock"
[[ -e "$T/frozen" ]] && exit 0
for m in pc sat; do [[ -e "$T/$m/noloop" ]] || "$T/bin/tick" "$m"; done
STUB
chmod +x "$T/bin/"*

agent() { mkdir -p "$T/$1/proc/$2"; echo claude >"$T/$1/proc/$2/comm"; printf 'SPOOL_AGENT_ID=%s\0' "$3" >"$T/$1/proc/$2/environ"; }
for m in sat pc; do
  mkdir -p "$T/$m/spool/dispatch"
  printf '%s\n' LEASE_MASTER=c-002 LEASE_FAILOVER=c-003 LEASE_ORCH=c-001 LEASE_FLEET=main \
    LEASE_PRIORITY=sat,pc LEASE_ENV=prd LEASE_TENANT=t1 >"$T/$m/spool/dispatch/lease.conf"
done
agent sat 100 c-001; agent sat 101 c-002; agent sat 102 c-003
agent pc 200 c-001; agent pc 201 c-002; agent pc 202 c-003
# the hub beats as the loops' cache holds them (spl_fleet_health_get)
health() { printf '%s %s\n' "$(cat "$T/clock")" "$1" >"$T/sat/spool/dispatch/fleet.health"; }
HEALTHY='{"sat":{"state":"healthy","why":"ok"},"pc":{"state":"healthy","why":"ok"}}'

# move [env...]: run the action on sat
move() {
  health "${MOVE_HEALTH:-$HEALTHY}"
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$T/sat/spool" LEASE_PROC_ROOT="$T/sat/proc" LEASE_PANE_CMD="$T/bin/pane" \
    LEASE_HUB_CMD="$T/bin/hub" LEASE_BEATS_CMD=false LEASE_HEALTH_TTL=100000 LEASE_NOW="$(cat "$T/clock")" \
    LEASE_MACHINE=sat LEASE_DESK_GATE=0 LEASE_HOLDDOWN=0 LEASE_PIN_READ=0 ROLE_MOVE_SLEEP="$T/bin/sleep" ROLE_MOVE_POLL=60 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "'"$ACTION"'"
    do_spl_role_move' >"$T/out" 2>&1
}
hubh() { cut -d' ' -f1 "$T/hub/main.$1" 2>/dev/null; }
mirror() { cut -d' ' -f1 "$T/$1/spool/dispatch/lease${2:+.$2}" 2>/dev/null; }
sentc() { grep -c -- "$2" "$T/$1/sent" 2>/dev/null || true; }
ticks() { local i; for ((i = 0; i < $1; i++)); do "$T/bin/sleep" 60; done; }

# both boxes run: sat ranks first, holds both roles; the notices start empty
"$T/bin/tick" sat; ticks 1; rm -f "$T"/*/sent
[[ "$(hubh orch)" == c-001@sat && "$(hubh dispatch)" == c-002@sat ]] &&
  pass "0. fixture: sat holds orch and dispatch" || { fail "0. fixture: $(hubh orch) $(hubh dispatch): $(cat "$T/ticks.out")"; exit 1; }

refused() {
  local label="$1"; shift
  local before; before="$(cat "$T/hub/main.pin-orch" 2>/dev/null)"
  move "$@"; local rc=$?
  [[ $rc != 0 && "$(cat "$T/hub/main.pin-orch" 2>/dev/null)" == "$before" ]] && grep -q FATAL "$T/out" &&
    [[ "$(grep -c . "$T/out")" == 1 ]] &&
    pass "$label: refused in one line, no pin written ($(cat "$T/out"))" || fail "$label: rc=$rc $(cat "$T/out")"
}
refused "1. ROLE missing" TO_BOX=pc
refused "1. a bad ROLE" ROLE=boss TO_BOX=pc
refused "1. a bad TO_BOX" ROLE=orch "TO_BOX=t nk"
refused "1. DRY_RUN=2" ROLE=orch TO_BOX=pc DRY_RUN=2

# --- 2. dry run ----------------------------------------------------------------
move ROLE=orch TO_BOX=pc; rc=$?
[[ $rc == 0 && ! -e "$T/hub/main.pin-orch" ]] && grep -q '^PLAN pin orch to c-001@pc (holder now c-001@sat)' "$T/out" &&
  grep -qx 'RUN ROLE=orch TO_BOX=pc DRY_RUN=0 ./run -a do_spl_role_move' "$T/out" &&
  pass "2. dry run: PLAN and the exact DRY_RUN=0 command, no pin written" || fail "2. rc=$rc $(cat "$T/out")"

# --- 3. move orch sat -> pc ---------------------------------------------------
move ROLE=orch TO_BOX=pc DRY_RUN=0; rc=$?
[[ $rc == 0 && "$(hubh pin-orch)" == c-001@pc && "$(hubh orch)" == c-001@pc && "$(hubh dispatch)" == c-002@sat ]] &&
  grep -q '^DONE orch held by c-001@pc on the hub, renewed' "$T/out" &&
  pass "3. orch moved to pc, the action returned 0 once pc renewed it; dispatch stays on sat" ||
  fail "3. rc=$rc pin $(hubh pin-orch) orch $(hubh orch) dispatch $(hubh dispatch): $(cat "$T/out")"
[[ "$(mirror pc orch)" == c-001@pc && "$(mirror sat orch)" == c-001@pc &&
   "$(sentc pc 'c-001 :: FLEET LEASE orch: you are now ACTIVE')" == 1 && "$(sentc sat 'c-001 :: FLEET LEASE orch: STANDBY')" == 1 ]] &&
  pass "3. pc's seat told ACTIVE, sat's STANDBY; both boxes name c-001@pc" ||
  fail "3. mirrors pc $(mirror pc orch) sat $(mirror sat orch); sent pc: $(cat "$T/pc/sent" 2>&1) sat: $(cat "$T/sat/sent" 2>&1)"
grep -q 'MOVE orch: pinned to c-001@pc by do_spl_role_move' "$T/sat/spool/dispatch/lease.log" &&
  grep -q 'PIN orch: none -> pc (row c-001@pc' "$T/pc/spool/dispatch/lease.log" &&
  pass "3. the move and the pin are logged" || fail "3. logs: $(cat "$T/sat/spool/dispatch/lease.log")"

# --- 4. the pin sticks ---------------------------------------------------------
ticks 5
[[ "$(hubh orch)" == c-001@pc && "$(sentc sat 'c-001 :: FLEET LEASE orch: you are now ACTIVE')" == 0 ]] &&
  pass "4. five ticks later pc still holds orch although every lease.conf ranks sat first" ||
  fail "4. orch $(hubh orch): $(cat "$T/sat/spool/dispatch/lease.log")"
# CONTROL: without the pin read (old code) sat takes it back on rank
cp -r "$T/hub" "$T/hub.keep"
LEASE_PIN=0 "$T/bin/tick" sat
[[ "$(hubh orch)" == c-001@sat ]] && pass "4. CONTROL: a loop that reads no pin takes orch back on rank" || fail "4. CONTROL: orch $(hubh orch)"
rm -rf "$T/hub"; mv "$T/hub.keep" "$T/hub"

# --- 5. move orch back pc -> sat (this machine) -------------------------------
move ROLE=orch TO_BOX=sat DRY_RUN=0; rc=$?
[[ $rc == 0 && "$(hubh pin-orch)" == c-001@sat && "$(hubh orch)" == c-001@sat ]] && grep -q '^DONE orch held by c-001@sat' "$T/out" &&
  pass "5. orch moved back to sat" || fail "5. rc=$rc pin $(hubh pin-orch) orch $(hubh orch): $(cat "$T/out")"
ticks 3
[[ "$(hubh orch)" == c-001@sat && "$(mirror pc orch)" == c-001@sat ]] && pass "5. it stays on sat" || fail "5. orch $(hubh orch)"

# --- 6. refusals ---------------------------------------------------------------
refused "6. a box in no ranking" ROLE=orch TO_BOX=lab DRY_RUN=0
MOVE_HEALTH='{"sat":{"state":"healthy","why":"ok"},"pc":{"state":"degraded","why":"3 of 60 beats"}}' \
  refused "6. a box the beats call degraded" ROLE=orch TO_BOX=pc DRY_RUN=0
MOVE_HEALTH='{"sat":{"state":"healthy","why":"ok"}}' refused "6. a box with no beats (no live box)" ROLE=orch TO_BOX=pc DRY_RUN=0
mv "$T/sat/proc/100" "$T/sat/proc.100"
refused "6. this machine with no live orch seat" ROLE=orch TO_BOX=sat DRY_RUN=0
mv "$T/sat/proc.100" "$T/sat/proc/100"

# --- 7. the target never takes it: the pin is undone ---------------------------
touch "$T/pc/noloop"
move ROLE=orch TO_BOX=pc DRY_RUN=0 ROLE_MOVE_WAIT=300; rc=$?
[[ $rc != 0 && "$(hubh pin-orch)" == c-001@none && "$(hubh orch)" == c-001@sat ]] &&
  grep -q '^FATAL pc did not take orch in 300s' "$T/out" && grep -q 'MOVE orch: pc did not take it; pin undone' "$T/sat/spool/dispatch/lease.log" &&
  pass "7. a target whose seat never takes it: rc $rc, one FATAL line, pin undone (c-001@none)" ||
  fail "7. rc=$rc pin $(hubh pin-orch) orch $(hubh orch): $(cat "$T/out")"
rm -f "$T/pc/noloop"

# --- 8. undo -------------------------------------------------------------------
move ROLE=orch TO_BOX=pc DRY_RUN=0 >/dev/null; [[ "$(hubh orch)" == c-001@pc ]] || fail "8. setup: orch $(hubh orch)"
move ROLE=orch TO_BOX=none; rc=$?
[[ $rc == 0 && "$(hubh pin-orch)" == c-001@pc ]] && grep -q '^PLAN unpin orch' "$T/out" &&
  pass "8. TO_BOX=none dry run writes nothing" || fail "8. rc=$rc $(cat "$T/out")"
move ROLE=orch TO_BOX=none DRY_RUN=0; rc=$?
[[ $rc == 0 && "$(hubh pin-orch)" == c-001@none ]] && grep -q '^DONE orch unpinned' "$T/out" &&
  pass "8. TO_BOX=none DRY_RUN=0 writes the pin to box none" || fail "8. rc=$rc $(cat "$T/out")"
ticks 2
[[ "$(hubh orch)" == c-001@sat ]] && pass "8. unpinned, the ranking decides again: sat takes orch back" || fail "8. orch $(hubh orch)"
move ROLE=orch TO_BOX=none DRY_RUN=0; rc=$?
[[ $rc == 0 ]] && grep -q '^OK orch is pinned to no box' "$T/out" && pass "8. undo again is OK, nothing written" || fail "8. rc=$rc $(cat "$T/out")"

# --- 9. the pin expires --------------------------------------------------------
move ROLE=orch TO_BOX=pc DRY_RUN=0 >/dev/null; [[ "$(hubh orch)" == c-001@pc ]] || fail "9. setup: orch $(hubh orch)"
sed -i 's/LEASE_HOLDDOWN=0/LEASE_HOLDDOWN=0 LEASE_PIN_TTL=120/' "$T/bin/tick"
ticks 4
[[ "$(hubh orch)" == c-001@sat ]] && grep -q 'PIN orch: pc -> none (row c-001@pc, LEASE_PIN_TTL 120s)' "$T/sat/spool/dispatch/lease.log" &&
  pass "9. a pin older than LEASE_PIN_TTL pins nothing: sat takes orch back" ||
  fail "9. orch $(hubh orch): $(tail -5 "$T/sat/spool/dispatch/lease.log")"

echo
[[ $fails == 0 ]] && { echo "ALL PASS: spl-role-move"; exit 0; }
echo "FAILED: $fails"; exit 1
