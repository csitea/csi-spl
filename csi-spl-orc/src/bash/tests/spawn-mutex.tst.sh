#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the mutexes + fence of the OD seats (spec 068 sections 4.2 and 5,
#          lane L5): do_spl_peer_gate, its hook in spawn-window.sh, the prd
#          wrapper do_spl_peer_prd and do_spl_fleet_config. No live agent, no
#          hub, no tmux: a lease stub (the fleet_leases `lease cas` contract:
#          read, compare-and-set on gen, under a flock) and a claim stub (the
#          fence: `claim --check`) on a fake clock.
#   1. order A: no <spool root>/peer/seats = the gate is a no-op - no hub
#      call, spawn-window goes on to its next step, the prd action runs
#   2. two peers spawn at once: exactly one takes `spawn`, the other is
#      refused (n=10); the mutex runs out after 120 s; its holder renews
#   3. spawn-window: a lost fence, an unconfirmed fence and a held mutex each
#      refuse the spawn (exit 7) before an id is claimed; a dry run with the
#      mutex free takes nothing
#   4. a lost fence stops a deploy (do_spl_peer_prd): exit 3, the action
#      never runs; unconfirmed: exit 4; control: a held fence runs it under
#      ENV=prd; a second seat on the same target is refused (5)
#   5. a non-seat caller is not gated; a seat without its message is refused
#   6. do_spl_fleet_config writes every machine or none: both written; a
#      stage failure on one box writes none; a commit failure on the second
#      box puts the first back; a box with no way in is refused up front
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
case "$(readlink -f "$T")" in /var/spool-hub|/var/spool-hub/*) echo "FAIL: refusing to run inside the live spool root ($T)"; exit 1 ;; esac
mkdir -p "$T/bin"
T0=1800000000

# The lease stub: one file per fleet+role "holder gen at" under a flock.
cat >"$T/bin/lease" <<'STUB'
#!/usr/bin/env bash
shift
echo "lease $*" >>"$HUB_DIR/calls"
[ -e "$HUB_DIR/down" ] && { echo "dial: connection refused" >&2; exit 1; }
fleet="" role="" holder="" ifgen=""
while [ $# -gt 0 ]; do case "$1" in --fleet) fleet="$2";; --role) role="$2";; --holder) holder="$2";; --if-gen) ifgen="$2";; esac; shift 2; done
exec 9>"$HUB_DIR/lock"; flock 9
f="$HUB_DIR/$fleet.$role"; h="" g=0 at=0
[ -s "$f" ] && read -r h g at <"$f"
won=false
if [ -n "$holder" ] && [ "$ifgen" = "$g" ]; then sleep 0.1; g=$((g + 1)); h="$holder"; at="$LEASE_NOW"; echo "$h $g $at" >"$f"; won=true; fi
age=-1; [ "$g" -gt 0 ] && age=$((LEASE_NOW - at))
printf '{"fleet":"%s","role":"%s","holder":"%s","box":"b","gen":%s,"age_s":%s,"won":%s}\n' "$fleet" "$role" "$h" "$g" "$age" "$won"
STUB
# The claim stub (the fence): $HUB_DIR/msg.<id> holds "<seat@box> <gen>";
# $HUB_DIR/cut makes every call fail as an unreachable hub would.
cat >"$T/bin/claim" <<'STUB'
#!/usr/bin/env bash
shift
echo "claim $*" >>"$HUB_DIR/calls"
[ -e "$HUB_DIR/cut" ] && exit 75
seat="" msg="" gen=""
while [ $# -gt 0 ]; do case "$1" in --seat) seat="$2"; shift 2;; --msg) msg="$2"; shift 2;; --gen) gen="$2"; shift 2;; *) shift;; esac; done
[ "$(cat "$HUB_DIR/msg.$msg" 2>/dev/null)" = "$seat $gen" ]
STUB
chmod +x "$T/bin/"*

# fresh: an empty hub and the spool root of box sat with (or without) seats
fresh() {
  rm -rf "$T/hub" "$T/sat"; mkdir -p "$T/hub" "$T/sat/dispatch"
  [[ "${1:-seats}" == seats ]] && { mkdir -p "$T/sat/peer"; printf 'c-001 claude\nc-002 claude\ng-003 grok\n' >"$T/sat/peer/seats"; }
  return 0
}
hold() { echo "$2@sat $3" >"$T/hub/msg.$1"; }   # hold <msg> <seat> <gen>
calls() { cat "$T/hub/calls" 2>/dev/null | grep -c -- "${1:-.}"; }
NOW=0
penv() {
  env SPOOL_ROOT="$T/sat" PEER_BOX=sat LEASE_FLEET=fl LEASE_NOW="$((T0 + NOW))" HUB_DIR="$T/hub" \
    LEASE_HUB_CMD="$T/bin/lease" PEER_HUB_CMD="$T/bin/claim" SPOOL_AGENT_ID= "$@"
}
# act <action> [VAR=value...]: one action in a fresh shell, its rc in $T/rc
act() {
  local a="$1"; shift
  penv "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in spl-peer-gate spl-peer-prd spl-fleet-config; do source "'"$PROJ_ROOT"'/src/bash/run/$f.func.sh"; done
    do_fake_deploy() { echo "DEPLOYED ENV=$ENV" >>"'"$T"'/deployed"; }
    '"$a" >"$T/o" 2>&1
  echo $? >"$T/rc"
}
rc() { cat "$T/rc"; }
spawnw() {
  penv SPOOL_TMUX_SOCKET="$T/no-tmux.sock" SPOOL_SESSION='' SPAWN_DRY_RUN=1 "$@" \
    bash "$PROJ_ROOT/src/bash/features/spawn-agents/scripts/spawn-window.sh" claude auto "$T" >"$T/so" 2>&1
  echo $? >"$T/src"
}

# ---- 1. order A: no seats file ------------------------------------------------
fresh none
act do_spl_peer_gate PEER_GATE_ROLE=spawn PEER_SEAT=c-001 PEER_MSG=m1 PEER_GEN=1
[[ "$(rc)" == 0 && "$(calls)" == 0 ]] && pass "1. no seats: the gate exits 0 and calls no hub (n=1)" || fail "1. gate rc=$(rc) calls=$(calls) $(cat "$T/o")"
spawnw PEER_SEAT=c-001 PEER_MSG=m1 PEER_GEN=1
[[ "$(cat "$T/src")" == 5 ]] && ! grep -q 'peer gate' "$T/so" && [[ "$(calls)" == 0 ]] &&
  pass "1. no seats: spawn-window passes the gate untouched and stops at its next step (no tmux: exit 5)" || fail "1. spawn-window rc=$(cat "$T/src") $(cat "$T/so")"
rm -f "$T/deployed"; act do_spl_peer_prd PRD_ACTION=do_fake_deploy
[[ "$(rc)" == 0 && "$(cat "$T/deployed" 2>/dev/null)" == "DEPLOYED ENV=prd" && "$(calls)" == 0 ]] &&
  pass "1. no seats: the prd wrapper runs the action under ENV=prd, no hub call" || fail "1. prd rc=$(rc) $(cat "$T/o")"

# ---- 2. two peers spawn at once ---------------------------------------------
won=0; lost=0; bad=0
for i in $(seq 1 10); do
  fresh; hold "a$i" c-001 3; hold "b$i" c-002 5
  ( act do_spl_peer_gate PEER_GATE_ROLE=spawn PEER_SEAT=c-001 PEER_MSG="a$i" PEER_GEN=3; cp "$T/rc" "$T/rc1" ) 2>/dev/null &
  sleep 0.01
  T2="$T/x"; mkdir -p "$T2"
  penv PEER_GATE_ROLE=spawn PEER_SEAT=c-002 PEER_MSG="b$i" PEER_GEN=5 bash -c '
    do_log() { echo "$*"; }
    source "'"$PROJ_ROOT"'/src/bash/run/spl-peer-gate.func.sh"; do_spl_peer_gate' >"$T2/o" 2>&1; echo $? >"$T/rc2"
  wait
  r="$(cat "$T/rc1") $(cat "$T/rc2")"
  case "$r" in "0 5"|"5 0") won=$((won + 1)); lost=$((lost + 1)) ;; *) bad=$((bad + 1)); echo "  round $i: rc $r" ;; esac
done
[[ "$won" == 10 && "$bad" == 0 ]] && pass "2. two seats gate a spawn at once: one takes spawn, one is refused (exit 5), n=10/10" || fail "2. won=$won bad=$bad"
fresh; hold m1 c-001 1; hold m2 c-002 1
act do_spl_peer_gate PEER_GATE_ROLE=spawn PEER_SEAT=c-001 PEER_MSG=m1 PEER_GEN=1
NOW=119; act do_spl_peer_gate PEER_GATE_ROLE=spawn PEER_SEAT=c-002 PEER_MSG=m2 PEER_GEN=1; r119="$(rc)"
NOW=60; act do_spl_peer_gate PEER_GATE_ROLE=spawn PEER_SEAT=c-001 PEER_MSG=m1 PEER_GEN=1; rown="$(rc)"
NOW=180; act do_spl_peer_gate PEER_GATE_ROLE=spawn PEER_SEAT=c-002 PEER_MSG=m2 PEER_GEN=1; r180="$(rc)"
[[ "$r119" == 5 && "$rown" == 0 && "$r180" == 0 && "$(cut -d' ' -f1 "$T/hub/fl.spawn")" == c-002@sat ]] &&
  pass "2. held at 119 s, renewed by its holder at 60 s, free 120 s after that (180 s)" || fail "2. ttl: 119=$r119 own=$rown 180=$r180 $(cat "$T/hub/fl.spawn")"
NOW=0

# ---- 3. spawn-window refuses before the claim --------------------------------
fresh; hold m1 c-002 4
spawnw PEER_SEAT=c-002 PEER_MSG=m1 PEER_GEN=3
[[ "$(cat "$T/src")" == 7 ]] && grep -q 'exit 3' "$T/so" && ! grep -q 'PLAN claim' "$T/so" && [[ "$(calls lease)" == 0 ]] &&
  pass "3. a lost fence refuses the spawn (exit 7, gate exit 3), no mutex call, no claim" || fail "3. lost: rc=$(cat "$T/src") $(cat "$T/so")"
fresh; hold m1 c-002 3; touch "$T/hub/cut"
spawnw PEER_SEAT=c-002 PEER_MSG=m1 PEER_GEN=3
[[ "$(cat "$T/src")" == 7 ]] && grep -q 'exit 4' "$T/so" && pass "3. an unconfirmed fence refuses the spawn (gate exit 4)" || fail "3. cut: rc=$(cat "$T/src") $(cat "$T/so")"
fresh; hold m1 c-002 3; echo "c-001@pc 7 $T0" >"$T/hub/fl.spawn"
spawnw PEER_SEAT=c-002 PEER_MSG=m1 PEER_GEN=3
[[ "$(cat "$T/src")" == 7 ]] && grep -q 'exit 5' "$T/so" && ! grep -q 'PLAN claim' "$T/so" &&
  pass "3. the spawn mutex held by c-001@pc refuses the spawn (gate exit 5)" || fail "3. held: rc=$(cat "$T/src") $(cat "$T/so")"
fresh; hold m1 c-002 3
spawnw PEER_SEAT=c-002 PEER_MSG=m1 PEER_GEN=3
[[ "$(cat "$T/src")" == 5 && ! -e "$T/hub/fl.spawn" ]] && [[ "$(calls 'holder')" == 0 ]] &&
  pass "3. dry run, mutex free: the gate passes and takes nothing" || fail "3. dry: rc=$(cat "$T/src") $(ls "$T/hub") $(cat "$T/so")"

# ---- 4. a lost fence stops a deploy ------------------------------------------
fresh; hold m1 c-001 2; rm -f "$T/deployed"
act do_spl_peer_prd PRD_ACTION=do_fake_deploy PEER_SEAT=c-001 PEER_MSG=m1 PEER_GEN=1
[[ "$(rc)" == 3 && ! -e "$T/deployed" ]] && pass "4. a lost fence stops the deploy: exit 3, the action never ran" || fail "4. lost: rc=$(rc) $(cat "$T/o")"
touch "$T/hub/cut"
act do_spl_peer_prd PRD_ACTION=do_fake_deploy PEER_SEAT=c-001 PEER_MSG=m1 PEER_GEN=2
[[ "$(rc)" == 4 && ! -e "$T/deployed" ]] && pass "4. an unconfirmed fence stops the deploy: exit 4" || fail "4. cut: rc=$(rc) $(cat "$T/o")"
rm -f "$T/hub/cut"
act do_spl_peer_prd PRD_ACTION=do_fake_deploy PEER_SEAT=c-001 PEER_MSG=m1 PEER_GEN=2
[[ "$(rc)" == 0 && "$(cat "$T/deployed")" == "DEPLOYED ENV=prd" && "$(cut -d' ' -f1 "$T/hub/fl.prd-fake-deploy")" == c-001@sat ]] &&
  pass "4. control: a held fence deploys under mutex prd-fake-deploy, ENV=prd" || fail "4. control: rc=$(rc) $(cat "$T/o")"
hold m9 g-003 1; rm -f "$T/deployed"
act do_spl_peer_prd PRD_ACTION=do_fake_deploy PEER_SEAT=g-003 PEER_MSG=m9 PEER_GEN=1
[[ "$(rc)" == 5 && ! -e "$T/deployed" ]] && pass "4. a second seat on the same target is refused (exit 5), no second deploy" || fail "4. second: rc=$(rc) $(cat "$T/o")"

# ---- 5. callers ---------------------------------------------------------------
fresh
act do_spl_peer_gate PEER_GATE_ROLE=spawn PEER_SEAT=c-077
[[ "$(rc)" == 0 && "$(calls)" == 0 ]] && pass "5. a non-seat caller (a lane, a human) is not gated" || fail "5. non-seat: rc=$(rc) $(cat "$T/o")"
act do_spl_peer_gate PEER_GATE_ROLE=spawn PEER_SEAT=c-001
[[ "$(rc)" == 1 ]] && grep -q 'PEER_MSG and PEER_GEN are required' "$T/o" && pass "5. a seat without the message it acts for is refused (exit 1)" || fail "5. no msg: rc=$(rc) $(cat "$T/o")"
act do_spl_peer_gate PEER_GATE_ROLE=prod PEER_SEAT=c-001 PEER_MSG=m1 PEER_GEN=1
[[ "$(rc)" == 1 ]] && pass "5. an unknown mutex role is refused" || fail "5. role: rc=$(rc)"

# ---- 6. fleet config: every machine or none ----------------------------------
fcfresh() {
  fresh; hold m1 c-001 1; rm -rf "$T/pc"; mkdir -p "$T/pc/peer"
  printf 'old\n' >"$T/sat/peer/rank"; printf 'old\n' >"$T/pc/peer/rank"; printf 'new\n' >"$T/new"
}
fc() { act do_spl_fleet_config FLEET_CONFIG_FILE=peer/rank FLEET_CONFIG_SRC="$T/new" FLEET_CONFIG_BOXES="sat pc" \
         FLEET_CONFIG_ROOT_PC="$T/pc" PEER_SEAT=c-001 PEER_MSG=m1 PEER_GEN=1 "$@"; }
both() { echo "$(cat "$T/sat/peer/rank" 2>/dev/null)/$(cat "$T/pc/peer/rank" 2>/dev/null)"; }
left() { find "$T/sat/peer" "$T/pc/peer" -name 'rank.*' 2>/dev/null | wc -l; }
fcfresh; fc
[[ "$(rc)" == 0 && "$(both)" == new/new && "$(left)" == 0 && "$(cut -d' ' -f1 "$T/hub/fl.fleet-config")" == c-001@sat ]] &&
  pass "6. both boxes written under mutex fleet-config, no stage or prev left" || fail "6. ok: rc=$(rc) $(both) left=$(left) $(cat "$T/o")"
fcfresh; rm -rf "$T/pc"; echo blocker >"$T/pc"
fc
[[ "$(rc)" == 1 && "$(cat "$T/sat/peer/rank")" == old && "$(left)" == 0 ]] &&
  pass "6. a stage failure on pc writes none (sat keeps old, no stage left)" || fail "6. stage: rc=$(rc) $(cat "$T/sat/peer/rank") left=$(left) $(cat "$T/o")"
rm -f "$T/pc"
# pc over a fake ssh that runs the step locally and fails the commit
cat >"$T/bin/ssh" <<STUB
#!/usr/bin/env bash
shift 3
case "\$1" in *" commit "*) exit 1 ;; esac
eval "\$1"
STUB
chmod +x "$T/bin/ssh"
fcfresh
fc FLEET_CONFIG_ROOT_PC= FLEET_CONFIG_SSH_PC=pc-host FLEET_CONFIG_ROOT_PC="$T/pc" FLEET_CONFIG_SSH_CMD="$T/bin/ssh"
[[ "$(rc)" == 1 && "$(both)" == old/old && "$(left)" == 0 ]] && grep -q 'putting back sat' "$T/o" &&
  pass "6. a commit failure on pc puts sat back: none written, nothing left" || fail "6. commit: rc=$(rc) $(both) left=$(left) $(cat "$T/o")"
fcfresh; : >"$T/hub/calls"
act do_spl_fleet_config FLEET_CONFIG_FILE=peer/rank FLEET_CONFIG_SRC="$T/new" FLEET_CONFIG_BOXES="sat pc" PEER_SEAT=c-001 PEER_MSG=m1 PEER_GEN=1
[[ "$(rc)" == 1 && "$(both)" == old/old && "$(calls)" == 0 ]] && grep -q 'box pc: no way in' "$T/o" &&
  pass "6. a box with no way in is refused before the gate: nothing written" || fail "6. no way: rc=$(rc) $(both) $(cat "$T/o")"

echo
(( fails == 0 )) && { echo "spawn-mutex: all passed"; exit 0; }
echo "spawn-mutex: $fails failed"; exit 1
