#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-6236, a same-box seat move (LEASE_SEAT_HOLD, SPL-3069) is made
#          on slow ticks too. sat 2026-11-22 05:55-06:03Z (load avg 93-104):
#          "SEAT-HOLD dispatch" at 05:55:44Z, 05:59:32Z, 06:02:42Z, ticks 228 s
#          and 190 s apart, both over LEASE_STALE 180. The count restarted on
#          every tick (fleet.dispatch.seat-move read "c-003@sat c-002@sat 1
#          ..."), the lease stayed on the failover and the master rotation
#          20261122T0545Z-master ended RELEASE FAIL. One stubbed machine, pc,
#          runs the dispatch seats CLE-002 (master) and CLE-003 (failover);
#          the failover holds the row and the master is able again:
#   1. the 1st able tick of the master moves nothing (one tick never moves)
#   2. the 2nd able tick 200 s later (> LEASE_STALE 180) moves it back
#      (RED before SPL-6236: n restarted at 1, the failover kept it)
#   3. CONTROL: a count left for another pair (the holder changed since) is a
#      stray tick: it holds, n restarts at 1
#   4. CONTROL: a gap over 2 x LEASE_STALE (the loop hung, the box was off)
#      restarts the count: the next wanting tick holds, n=1
#   5. CONTROL: LEASE_SEAT_HOLD=1 moves on the 1st tick
#  Fixtures only in a mktemp root: the test refuses to run where its roots
#  could reach the live /var/spool-hub.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
SRC="${LEASE_SRC:-$PROJ_ROOT/src/bash/run/spl-dispatch-lease.func.sh}"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
case "$(readlink -f "$T")" in /var/spool-hub|/var/spool-hub/*) echo "FAIL: refusing to run inside the live spool root ($T)"; exit 1 ;; esac
mkdir -p "$T/bin" "$T/hub" "$T/pane"

cat >"$T/bin/send" <<'STUB'
#!/bin/sh
to="" body=""
while [ $# -gt 0 ]; do case "$1" in --to) to="$2"; shift 2 ;; --body) body="$2"; shift 2 ;; *) shift ;; esac; done
echo "$to :: $body" >>"$SENT"
STUB
# the hub stub of fleet-lease.tst.sh: "holder gen at" per fleet+role, HUB_NOW its clock
cat >"$T/bin/hub" <<'STUB'
#!/bin/sh
shift
fleet="" role="" holder="" ifgen=""
while [ $# -gt 0 ]; do case "$1" in --fleet) fleet="$2";; --role) role="$2";; --holder) holder="$2";; --if-gen) ifgen="$2";; esac; shift 2; done
f="$HUB_DIR/$fleet.$role"; h="" g=0 at=0
[ -s "$f" ] && read -r h g at <"$f"
won=false
if [ -n "$holder" ] && [ "$ifgen" = "$g" ]; then g=$((g + 1)); h="$holder"; at="$HUB_NOW"; echo "$h $g $at" >"$f"; won=true; fi
age=-1; [ "$g" -gt 0 ] && age=$((HUB_NOW - at))
printf '{"fleet":"%s","role":"%s","holder":"%s","box":"b","gen":%s,"age_s":%s,"won":%s}\n' "$fleet" "$role" "$h" "$g" "$age" "$won"
STUB
printf '#!/bin/sh\nf="%s/pane/$1"; [ -e "$f" ] || exit 1; exec cat "$f"\n' "$T" >"$T/bin/pane"
chmod +x "$T/bin/"*

agent() { mkdir -p "$T/pc/proc/$1"; echo claude >"$T/pc/proc/$1/comm"; printf 'SPOOL_AGENT_ID=%s\0' "$2" >"$T/pc/proc/$1/environ"; }
# tick <hub-now> [env...]: one fleet tick on pc
tick() {
  local now="$1"; shift
  env PROJ_PATH="$PROJ_ROOT" SRC="$SRC" SPOOL_ROOT="$T/pc/spool" LEASE_PROC_ROOT="$T/pc/proc" LEASE_SEND="$T/bin/send" \
    LEASE_PANE_CMD="$T/bin/pane" SENT="$T/pc/sent" LEASE_HUB_CMD="$T/bin/hub" HUB_DIR="$T/hub" HUB_NOW="$now" LEASE_NOW="$now" \
    LEASE_FLEET=main LEASE_MACHINE=pc LEASE_PRIORITY=pc,sat LEASE_HOLDDOWN=0 LEASE_STALE=180 LEASE_ASKS=0 LEASE_HEALTH=0 \
    LEASE_ORCH=CLE-001 LEASE_MASTER=CLE-002 LEASE_FAILOVER=CLE-003 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$SRC"
    spl_lease_init && spl_lease_ids master failover orch && spl_fleet_ids && spl_fleet_hub_init && spl_lease_fleet_tick' >>"$T/out" 2>&1
}
hubh() { cut -d' ' -f1 "$T/hub/main.dispatch" 2>/dev/null; }
D="$T/pc/spool/dispatch"
W="$D/wd.CLE-002"
SM="$D/fleet.dispatch.seat-move"
# setup <t>: the failover CLE-003 holds dispatch (the master was on an S2 limit HIT), then the master is able
setup() {
  rm -rf "${T:?}/pc" "${T:?}/hub"/*; mkdir -p "$D"
  agent 100 CLE-001; agent 101 CLE-002; agent 102 CLE-003
  echo "HIT S2 $(($1 - 10))" >"$W"; tick "$1"
  rm -f "$W"
}
why() { echo "hub $(hubh) seat-move $(cat "$SM" 2>&1): $(cat "$D/lease.log" 2>&1)"; }

# --- 1, 2: two wanting ticks 200 s apart --------------------------------------
setup 60000
[[ "$(hubh)" == CLE-003@pc ]] && pass "0. setup: the failover holds dispatch" || fail "0. setup: $(why)"
tick 60200
[[ "$(hubh)" == CLE-003@pc && "$(cat "$SM" 2>/dev/null)" == "CLE-003@pc CLE-002@pc 1 60200" ]] &&
  pass "1. the 1st able tick of the master moves nothing, n=1" || fail "1. 1st: $(why)"
tick 60400
[[ "$(hubh)" == CLE-002@pc && ! -e "$SM" ]] &&
  pass "2. the 2nd able tick 200 s later (> LEASE_STALE 180) moves it back" || fail "2. 2nd: $(why)"

# --- 3. CONTROL: a count of another pair is a stray tick ----------------------
setup 61000
echo "CLE-001@pc CLE-002@pc 1 61000" >"$SM"; tick 61200
[[ "$(hubh)" == CLE-003@pc && "$(cat "$SM" 2>/dev/null)" == "CLE-003@pc CLE-002@pc 1 61200" ]] &&
  pass "3. CONTROL: a count of another pair 200 s old does not move the seat, n restarts at 1" || fail "3. stray: $(why)"

# --- 4. CONTROL: a gap over 2 x LEASE_STALE restarts the count ----------------
setup 62000
tick 62200; tick 62570
[[ "$(hubh)" == CLE-003@pc && "$(cat "$SM" 2>/dev/null)" == "CLE-003@pc CLE-002@pc 1 62570" ]] &&
  pass "4. CONTROL: the next wanting tick 370 s later (> 2 x LEASE_STALE) holds, n=1" || fail "4. gap: $(why)"
tick 62770
[[ "$(hubh)" == CLE-002@pc ]] && pass "4. ... and the tick after it moves" || fail "4. after gap: $(why)"

# --- 5. CONTROL: LEASE_SEAT_HOLD=1 --------------------------------------------
setup 63000
tick 63200 LEASE_SEAT_HOLD=1
[[ "$(hubh)" == CLE-002@pc ]] && pass "5. CONTROL: LEASE_SEAT_HOLD=1 moves on the 1st able tick" || fail "5. hold=1: $(why)"

(( fails == 0 )) && { echo; echo "PASS: all fleet-lease-seat-hold-slow-tick.tst.sh assertions"; exit 0; }
echo; echo "FAIL: $fails assertion(s) in fleet-lease-seat-hold-slow-tick.tst.sh"; exit 1
