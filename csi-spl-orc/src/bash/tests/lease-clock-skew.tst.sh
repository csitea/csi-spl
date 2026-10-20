#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: clock-skew drill for the fleet lease (SPL-2139, epic SPL-2129
#          robustness 1). The fleet lease decides staleness on the HUB's age
#          (age_s); a box's own clock must neither make a fresh holder look
#          stale (flap) nor keep a silent one alive (stale holder accepted).
#          fleet-lease.tst.sh case 10 drills a box clock AHEAD; this drills the
#          rest. Two simulated machines (pc, sat), a hub stub with the real
#          contract; HUB_NOW is the hub's clock, LEASE_NOW each box's own.
#   1. sat's clock 600 s BEHIND while pc renews: over 4 ticks sat never takes
#      a role and logs no takeover (no flap)
#   2. pc's own clock jumps +600 s, then -600 s, between its renewals: pc keeps
#      both roles, its master is told ACTIVE once, nothing else is logged
#   3. pc silent: at 180 s on the hub clock sat (600 s behind) does not take
#      over; at 181 s it does, though its own clock says the stamp is fresh
#   4. a hub that answers a negative age (an instance clock behind the writer):
#      the holder is kept, AGE-UNKNOWN is logged once over 3 ticks, no takeover
#   CONTROL (red): a hub stub that ages the row on the CALLER's clock (what a
#      box-clock implementation would do) keeps the silent pc of case 3: the
#      drill tells a hub-clock age from a box-clock one.
#  NOT drilled here: the local renew + watch mode (no LEASE_FLEET) ages the
#      lease on the box clock; a +300 s jump promoted the failover while the
#      master lived, a -600 s step delayed failover 600 s (SPL-2139 report).
#  Fixtures only in a mktemp root: the test refuses to run where its roots
#  could reach the live /var/spool-hub. No tmux, no network, no real clock.
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
export SPOOL_TEST=1

# stubs: the spool sender, the ./run for background actions, the pane, the hub
mkdir -p "$T/bin" "$T/pane"
cat >"$T/bin/send" <<'STUB'
#!/bin/sh
to="" body=""
while [ $# -gt 0 ]; do case "$1" in --to) to="$2"; shift 2 ;; --body) body="$2"; shift 2 ;; *) shift ;; esac; done
echo "$to :: $body" >>"$SENT"
STUB
printf '#!/bin/sh\nexit 0\n' >"$T/bin/asksrun"
printf '#!/bin/sh\nf="%s/pane/$1"; [ -e "$f" ] || exit 1; exec cat "$f"\n' "$T" >"$T/bin/pane"
# The hub stub: one file per fleet+role, "holder gen at"; HUB_NOW is its clock.
# HUB_AGE_SKEW is added to the age it answers (an instance whose clock is off);
# HUB_AGE_FROM_CALLER=1 ages the row on LEASE_NOW, the caller's clock (CONTROL).
cat >"$T/bin/hub" <<'STUB'
#!/bin/sh
shift
fleet="" role="" holder="" ifgen=""
while [ $# -gt 0 ]; do case "$1" in --fleet) fleet="$2";; --role) role="$2";; --holder) holder="$2";; --if-gen) ifgen="$2";; esac; shift 2; done
f="$HUB_DIR/$fleet.$role"; h="" g=0 at=0
[ -s "$f" ] && read -r h g at <"$f"
won=false
if [ -n "$holder" ] && [ "$ifgen" = "$g" ]; then g=$((g + 1)); h="$holder"; at="$HUB_NOW"; echo "$h $g $at" >"$f"; won=true; fi
clock="$HUB_NOW"; [ "${HUB_AGE_FROM_CALLER:-0}" = 1 ] && clock="$LEASE_NOW"
age=-1; [ "$g" -gt 0 ] && age=$((clock - at + ${HUB_AGE_SKEW:-0}))
printf '{"fleet":"%s","role":"%s","holder":"%s","box":"b","gen":%s,"age_s":%s,"won":%s}\n' "$fleet" "$role" "$h" "$g" "$age" "$won"
STUB
chmod +x "$T/bin/send" "$T/bin/asksrun" "$T/bin/pane" "$T/bin/hub"

# agent <machine> <pid> <id>: a fake live claude in that machine's /proc
agent() { mkdir -p "$T/$1/proc/$2"; echo claude >"$T/$1/proc/$2/comm"; printf 'SPOOL_AGENT_ID=%s\0' "$3" >"$T/$1/proc/$2/environ"; }

# tick <machine> <hub-now> <box-now> [env...]: one fleet tick on that machine
tick() {
  local m="$1" hub_now="$2" box_now="$3"; shift 3
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$T/$m/spool" LEASE_PROC_ROOT="$T/$m/proc" LEASE_SEND="$T/bin/send" LEASE_PANE_CMD="$T/bin/pane" \
    SENT="$T/$m/sent" LEASE_ASKS_RUN="$T/bin/asksrun" LEASE_HUB_CMD="$T/bin/hub" HUB_DIR="$T/hub" HUB_NOW="$hub_now" LEASE_NOW="$box_now" \
    LEASE_FLEET=main LEASE_MACHINE="$m" LEASE_PRIORITY=pc,sat LEASE_LIMIT_TZ=Etc/GMT-3 LEASE_HOLDDOWN=0 \
    LEASE_ORCH=CLE-001 LEASE_MASTER=CLE-002 LEASE_FAILOVER=CLE-003 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    spl_lease_init && spl_lease_ids master failover orch && spl_fleet_ids && spl_fleet_hub_init && spl_lease_fleet_tick' >>"$T/out" 2>&1
}
hubh() { cut -d' ' -f1 "$T/hub/main.$1" 2>/dev/null; }
hubg() { cut -d' ' -f2 "$T/hub/main.$1" 2>/dev/null; }
sentc() { grep -c -- "$2" "$T/$1/sent" 2>/dev/null || true; }
logc() { grep -c -- "$2" "$T/$1/spool/dispatch/lease.log" 2>/dev/null || true; }

# fresh: a new world, pc and sat each with CLE-001..003 alive
fresh() {
  rm -rf "$T/hub" "$T/pc" "$T/sat" "$T/out"; mkdir -p "$T/hub" "$T/pc/proc" "$T/sat/proc"
  agent pc 100 CLE-001; agent pc 101 CLE-002; agent pc 102 CLE-003
  agent sat 200 CLE-001; agent sat 201 CLE-002; agent sat 202 CLE-003
}
# drill3 [env...]: pc takes both roles at 1000, then goes silent; sat, its
# clock 600 s behind, ticks at hub 1180 and hub 1181
drill3() {
  fresh
  tick pc 1000 1000 "$@"
  tick sat 1180 580 "$@"; S180="$(hubh dispatch)/$(hubh orch)"
  tick sat 1181 581 "$@"; S181="$(hubh dispatch)/$(hubh orch)"
}

# --- CONTROL first: a box-clock age keeps a silent holder -------------------------
drill3 HUB_AGE_FROM_CALLER=1
[[ "$S181" == CLE-002@pc/CLE-001@pc ]] &&
  pass "CONTROL: aged on the caller's clock (600 s behind), silent pc is still the holder at hub 181 s - the drill can see it" ||
  fail "CONTROL: a box-clock age moved the lease ($S181): the drill cannot tell the clocks apart: $(cat "$T/out")"

# --- 1. a box clock behind does not flap ------------------------------------------
fresh
tick pc 1000 1000
for n in 1 2 3 4; do
  tick sat $((1000 + 60 * n)) $((400 + 60 * n))
  tick pc $((1030 + 60 * n)) $((1030 + 60 * n))
done
[[ "$(hubh dispatch)" == CLE-002@pc && "$(hubh orch)" == CLE-001@pc && "$(hubg dispatch)" == 5 &&
   "$(logc sat 'takes over')" == 0 && "$(sentc sat ACTIVE)" == 0 ]] &&
  pass "1. sat 600 s behind: 4 ticks, no takeover, only pc writes (gen 5)" ||
  fail "1. hub $(hubh dispatch)/$(hubh orch) gen $(hubg dispatch) sat log: $(cat "$T/sat/spool/dispatch/lease.log" 2>&1)"

# --- 2. the holder's own clock jumps both ways ------------------------------------
fresh
tick pc 1000 1000
n0=$(wc -l <"$T/pc/spool/dispatch/lease.log")
tick pc 1060 1660; tick pc 1120 520; tick pc 1180 1180
tick sat 1200 1200
[[ "$(hubh dispatch)" == CLE-002@pc && "$(hubh orch)" == CLE-001@pc && "$(wc -l <"$T/pc/spool/dispatch/lease.log")" == "$n0" &&
   "$(sentc pc 'CLE-002 :: FLEET LEASE dispatch: you are now ACTIVE')" == 1 && "$(logc sat 'takes over')" == 0 ]] &&
  pass "2. pc's clock +600 s then -600 s: it keeps both roles, ACTIVE told once, nothing logged" ||
  fail "2. hub $(hubh dispatch)/$(hubh orch) pc log: $(cat "$T/pc/spool/dispatch/lease.log")"

# --- 3. a box clock behind does not keep a silent holder --------------------------
drill3
[[ "$S180" == CLE-002@pc/CLE-001@pc ]] && pass "3. hub 180 s: not stale, though sat's clock is 600 s behind" || fail "3. took over at 180 s: $S180"
[[ "$S181" == CLE-002@sat/CLE-001@sat && "$(logc sat 'takes over from CLE-002@pc')" == 1 ]] &&
  pass "3. hub 181 s: sat takes both roles; its own clock (stamp 419 s in its future) is not asked" ||
  fail "3. hub $S181: $(cat "$T/sat/spool/dispatch/lease.log" 2>&1) $(cat "$T/out")"

# --- 4. the hub answers a negative age ---------------------------------------------
fresh
tick pc 1000 1000
for n in 1 2 3; do tick sat $((1000 + 60 * n)) $((1000 + 60 * n)) HUB_AGE_SKEW=-600; done
[[ "$(hubh dispatch)" == CLE-002@pc && "$(hubh orch)" == CLE-001@pc && "$(logc sat 'takes over')" == 0 &&
   "$(logc sat 'AGE-UNKNOWN dispatch')" == 1 ]] &&
  pass "4. hub age below 0: pc kept, AGE-UNKNOWN logged once in 3 ticks" ||
  fail "4. hub $(hubh dispatch)/$(hubh orch) sat log: $(cat "$T/sat/spool/dispatch/lease.log" 2>&1)"

echo "--- lease-clock-skew: $fails failure(s)"
exit $((fails > 0))
