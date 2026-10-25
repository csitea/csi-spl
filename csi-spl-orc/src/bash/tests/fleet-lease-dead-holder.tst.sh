#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-3345, the orch lease on a dead holder seat (c-001's call, msg
#          aee024ef, 2026-10-25). sat's lease.log: 11:01:45Z sat's c-001 sat
#          on its claude session limit and the SPL-2892 HANDOFF wrote the orch
#          row to c-001@pc, a seat with no process, no window and no agents
#          record on pc. pc never renewed it, sat re-launched its in-place
#          grok switch every ~2 min (20 tries to 11:49Z, grok on its weekly
#          limit, agy "no pick", claude2 dormant) and the hub named the dead
#          seat for 45 min. Two stubbed machines, sat (ranked first) and pc:
#   1. RED CONTROL: sat's seats on a far-off limit hand both rows to pc,
#      whose role seats have no process. pc hands each row to the next box
#      of the ranking (sat, whose seat exists) on its next tick past
#      LEASE_DEAD_WAIT, and no row moves again (one hop each way, no
#      ping-pong); pc launches no in-place switch of a seat it does not
#      have (before SPL-3345 the rows stayed on c-001@pc / c-002@pc)
#   2. a dead seat under a rotation hold (rotate.hold names it) is a planned
#      gap: no dead handoff
#   3. the limit loop: sat holds orch, its seat on a limit 50 min away, the
#      grok switch fails. After the first failed switch the next one waits
#      LEASE_SWITCH_LIMIT_RETRY (900 s), not LEASE_SWITCH_RETRY (120 s), and
#      lease.log says once that the seat is on a vendor limit until the
#      reset; the NO-LOCAL-AGENT line names the reset
#   4. LEASE_HANDOFF=0 turns the dead handoff off
#  Fixtures only in a mktemp root: the test refuses to run where its roots
#  could reach the live /var/spool-hub.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
SRC="${LEASE_SRC:-$PROJ_ROOT/src/bash/run/spl-dispatch-lease.func.sh}"
FX="$TEST_DIR/fixtures/fleet-lease"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
case "$(readlink -f "$T")" in /var/spool-hub|/var/spool-hub/*) echo "FAIL: refusing to run inside the live spool root ($T)"; exit 1 ;; esac
mkdir -p "$T/bin"

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
printf '#!/bin/sh\nf="$PANE_DIR/$1"; [ -e "$f" ] || exit 1; exec cat "$f"\n' >"$T/bin/pane"
printf '#!/bin/sh\nf="$TR_DIR/$1"; [ -e "$f" ] || exit 1; exec cat "$f"\n' >"$T/bin/tr"
printf '#!/bin/sh\ncat >>"%s/owner-dm"\n' "$T" >"$T/bin/dm"
# the in-place switch (do_spl_role_failover) as it ran on 2026-10-25: every
# vendor skipped, the seat unchanged; one line per launch
cat >"$T/bin/switch" <<'STUB'
#!/bin/sh
echo "$ROLE_FAILOVER_ROLE $ROLE_FAILOVER_SEAT silent=$ROLE_FAILOVER_SILENT" >>"$(dirname "$SPOOL_ROOT")/switches"
exit 0
STUB
chmod +x "$T/bin/"*

# agent <machine> <pid> <id>
agent() { mkdir -p "$T/$1/proc/$2" "$T/$1/pane" "$T/$1/tr"; echo claude >"$T/$1/proc/$2/comm"; printf 'SPOOL_AGENT_ID=%s\0' "$3" >"$T/$1/proc/$2/environ"; cp "$FX/good-turn.jsonl" "$T/$1/tr/$2"; }
# on_limit <machine> <now> <reset> <id>...: the watchdog's S2 kind=limit verdict and its reset
on_limit() {
  local m="$1" now="$2" r="$3" id; shift 3
  mkdir -p "$T/$m/spool/dispatch/wd"
  for id in "$@"; do echo "HIT S2 $now" >"$T/$m/spool/dispatch/wd.$id"; echo "$r" >"$T/$m/spool/dispatch/wd/$id.limit"; done
}
# reset: sat runs every role seat; pc runs none (no process, no window)
reset() {
  rm -rf "${T:?}/sat" "${T:?}/pc" "${T:?}/hub" "${T:?}/owner-dm"; mkdir -p "$T/hub" "$T/pc/proc"
  agent sat 200 c-001; agent sat 201 c-002; agent sat 202 c-003
}

PRIO=sat,pc
# tick <machine> <hub-now> [env...]: one fleet tick on that machine
tick() {
  local m="$1" now="$2"; shift 2
  mkdir -p "$T/$m/spool"
  env PROJ_PATH="$PROJ_ROOT" SRC="$SRC" SPOOL_ROOT="$T/$m/spool" LEASE_PROC_ROOT="$T/$m/proc" LEASE_SEND="$T/bin/send" \
    LEASE_PANE_CMD="$T/bin/pane" PANE_DIR="$T/$m/pane" LEASE_TRANSCRIPT_CMD="$T/bin/tr" TR_DIR="$T/$m/tr" \
    LEASE_OWNER_CMD="$T/bin/dm" SENT="$T/$m/sent" LEASE_HUB_CMD="$T/bin/hub" HUB_DIR="$T/hub" HUB_NOW="$now" LEASE_NOW="$now" \
    LEASE_FLEET=main LEASE_MACHINE="$m" LEASE_PRIORITY="$PRIO" LEASE_LIMIT_TZ=Etc/GMT-3 LEASE_HOLDDOWN=0 \
    LEASE_ORCH=c-001 LEASE_MASTER=c-002 LEASE_FAILOVER=c-003 LEASE_SWITCH_RUN="$T/bin/switch" LEASE_SWITCH_SYNC=1 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$SRC"
    spl_lease_init && spl_lease_ids master failover orch && spl_fleet_ids && spl_fleet_hub_init && spl_lease_fleet_tick' >>"$T/out" 2>&1
}
# both <hub-now> [env...]: sat ticks, then pc
both() { local n="$1"; shift; tick sat "$n" "$@"; tick pc "$n" "$@"; }
hubh() { cut -d' ' -f1 "$T/hub/main.$1" 2>/dev/null; }
hub2() { echo "$(hubh orch) $(hubh dispatch)"; }
logc() { grep -c -- "$2" "$T/$1/spool/dispatch/lease.log" 2>/dev/null || true; }
swc() { [[ -f "$T/$1/switches" ]] || { echo 0; return 0; }; grep -c -- "$2" "$T/$1/switches" || true; }
lease_log() { cat "$T/$1/spool/dispatch/lease.log" 2>&1; }
# the dead seat's clock starts at pc's first tick (100000): the hand-back
# comes on pc's first tick with the row, LEASE_DEAD_WAIT (60 s) already past

# --- 1. the 2026-10-25 picture: the row handed to a dead seat comes back --------
reset
both 100000
[[ "$(hub2)" == "c-001@sat c-002@sat" ]] || fail "1. setup: hub $(hub2) $(cat "$T/out")"
lim=$((100060 + 3000))
on_limit sat 100060 "$lim" c-001 c-002 c-003
tick sat 100060
[[ "$(hub2)" == "c-001@pc c-002@pc" && "$(logc sat 'HANDOFF orch: c-001 cannot act until')" == 1 ]] ||
  fail "1. setup: sat's limit HANDOFF did not write the rows to pc: hub $(hub2) $(lease_log sat)"
tick pc 100060
for n in 100120 100180 100240 100300 100360 100420 100480 100540 100600; do
  on_limit sat "$n" "$lim" c-001 c-002 c-003
  both "$n"
done
[[ "$(hub2)" == "c-001@sat c-002@sat" ]] &&
  pass "1. RED CONTROL: pc's role seats have no process: it hands orch and dispatch to the next box of the ranking (sat), not the dead c-001@pc / c-002@pc for 45 min" ||
  fail "1. dead holder: hub $(hub2) (pc: $(lease_log pc | tail -4))"
[[ "$(logc pc 'HANDOFF-DEAD orch: c-001 has no live process on pc')" == 1 && "$(logc pc 'HANDOFF-DEAD dispatch: c-002 has no live process on pc')" == 1 &&
   "$(logc sat 'HANDOFF orch')" == 1 && "$(logc sat 'HANDOFF dispatch')" == 1 ]] &&
  pass "1. one hop each way: pc logs ONE HANDOFF-DEAD per role, sat's limit HANDOFF never fires again (no ping-pong)" ||
  fail "1. hops: pc $(logc pc HANDOFF-DEAD) sat $(logc sat HANDOFF) $(lease_log pc)"
[[ "$(swc pc .)" == 0 && "$(logc pc 'SWITCH-DEAD orch: c-001 has no live process')" == 1 ]] &&
  pass "1. pc launches no in-place switch of a seat it does not have (SWITCH-DEAD logged once)" ||
  fail "1. pc switches: $(cat "$T/pc/switches" 2>&1) $(lease_log pc)"
t0="$(grep -m1 'HANDOFF-DEAD orch' "$T/pc/spool/dispatch/lease.log" >/dev/null && cut -d' ' -f3 "$T/hub/main.orch")"
[[ "$t0" =~ ^[0-9]+$ ]] && (( t0 - 100060 <= 120 )) &&
  pass "1. the row is back on sat $(( t0 - 100060 ))s after it was handed to the dead seat (bound: LEASE_DEAD_WAIT 60 s + one LEASE_PERIOD)" ||
  fail "1. hand-back time: row at '$t0'"

# --- 2. a rotation hold is a planned gap: no dead handoff --------------------------
reset
both 200000
on_limit sat 200060 $((200060 + 3000)) c-001 c-002 c-003
mkdir -p "$T/pc/spool/dispatch"
for n in 200060 200120 200180 200240; do
  echo "c-001 $((n - 10)) rid $$" >"$T/pc/spool/dispatch/rotate.hold"
  on_limit sat "$n" $((200060 + 3000)) c-001 c-002 c-003
  both "$n"
done
[[ "$(hubh orch)" == c-001@pc && "$(logc pc 'HANDOFF-DEAD orch')" == 0 ]] &&
  pass "2. a seat under a rotation hold (rotate.hold names c-001) is not dead: orch stays on c-001@pc" ||
  fail "2. hold: hub $(hubh orch) $(lease_log pc)"

# --- 3. the limit loop: one failed switch, then wait for the limit -----------------
reset
both 300000
lim=$((300060 + 3000))
for n in $(seq 300060 60 301020); do on_limit sat "$n" "$lim" c-001; tick sat "$n" LEASE_HANDOFF=0; done
[[ "$(hubh orch)" == c-001@sat && "$(swc sat '^orch c-001')" == 1 ]] &&
  pass "3. RED CONTROL: sat's only orch seat on a limit 50 min away, the grok switch failed: ONE switch in 960 s, not one per LEASE_SWITCH_RETRY (120 s)" ||
  fail "3. switches: $(swc sat '^orch c-001') $(cat "$T/sat/switches" 2>&1)"
[[ "$(logc sat "SWITCH-LIMIT orch: c-001 (claude) sits on a vendor limit until $(date -u -d "@$lim" +%FT%TZ)")" == 1 ]] &&
  pass "3. lease.log says once that c-001 sits on a vendor limit until the reset" || fail "3. log: $(lease_log sat)"
[[ "$(grep -c "NO-LOCAL-AGENT orch: .*vendor limit until $(date -u -d "@$lim" +%FT%TZ)" "$T/sat/spool/dispatch/lease.log")" == 1 ]] &&
  pass "3. the NO-LOCAL-AGENT line names the limit's reset" || fail "3. nolocal: $(grep NO-LOCAL "$T/sat/spool/dispatch/lease.log")"
on_limit sat 301200 "$lim" c-001; tick sat 301200 LEASE_HANDOFF=0
[[ "$(swc sat '^orch c-001')" == 2 ]] &&
  pass "3. past LEASE_SWITCH_LIMIT_RETRY (900 s) the switch is tried again" || fail "3. retry: $(cat "$T/sat/switches" 2>&1)"

# --- 4. LEASE_HANDOFF=0: no dead handoff --------------------------------------------
reset
both 400000
for n in 400060 400120 400180 400240; do on_limit sat "$n" $((400060 + 3000)) c-001 c-002 c-003; tick sat "$n"; tick pc "$n" LEASE_HANDOFF=0; done
[[ "$(hub2)" == "c-001@pc c-002@pc" && "$(logc pc HANDOFF-DEAD)" == 0 ]] &&
  pass "4. LEASE_HANDOFF=0 on pc turns the dead handoff off" || fail "4. off: hub $(hub2) $(lease_log pc)"

echo "---"
(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
