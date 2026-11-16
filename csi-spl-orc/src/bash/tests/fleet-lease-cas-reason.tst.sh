#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-5683 (alerts panel 64ca0e0c task 5.6): a role move names its
#          reason to the hub, and the orchestrator take-over notice names the
#          real cause. Before it the cas carried no --reason, so the hub wrote
#          no system_events lease.<reason> row (0 on prd, 2026-11-16), and
#          every take-over notice read "its process is gone, stalled, or it
#          sat idle with an unread message older than 10 min", even for a
#          short watchdog S1 wait. Two stubbed machines, pc (ranked first)
#          and sat; the hub stub logs each cas as "<role> <holder> <reason>":
#   1. the first write of each role is a claim; a renewal names no reason
#   2. a dispatch seat under a rotation hold hands to its twin: rotation;
#      the move back once the hold ends: seat_move
#   3. pc goes dark: sat takes both roles past LEASE_STALE: failover, and
#      the notice says pc renewed nothing for that many seconds, never the
#      old "gone, stalled, or it sat idle" guess
#   4. pc returns: handback
#   5. a seat of this box with a fresh watchdog S1 HIT: the notice cause
#      quotes its verdict ("wd S1: HIT 40s ago")
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
mkdir -p "$T/bin" "$T/hub"

printf '#!/bin/sh\nexit 0\n' >"$T/bin/send"
# the hub stub of fleet-lease.tst.sh, plus: each cas logged to $HUB_DIR/cas.log
cat >"$T/bin/hub" <<'STUB'
#!/bin/sh
shift
fleet="" role="" holder="" ifgen="" reason=""
while [ $# -gt 0 ]; do case "$1" in --fleet) fleet="$2";; --role) role="$2";; --holder) holder="$2";; --if-gen) ifgen="$2";; --reason) reason="$2";; esac; shift 2; done
f="$HUB_DIR/$fleet.$role"; h="" g=0 at=0
[ -s "$f" ] && read -r h g at <"$f"
[ -n "$holder" ] && echo "$role $holder ${reason:--}" >>"$HUB_DIR/cas.log"
won=false
if [ -n "$holder" ] && [ "$ifgen" = "$g" ]; then g=$((g + 1)); h="$holder"; at="$HUB_NOW"; echo "$h $g $at" >"$f"; won=true; fi
age=-1; [ "$g" -gt 0 ] && age=$((HUB_NOW - at))
printf '{"fleet":"%s","role":"%s","holder":"%s","box":"b","gen":%s,"age_s":%s,"won":%s}\n' "$fleet" "$role" "$h" "$g" "$age" "$won"
STUB
printf '#!/bin/sh\nf="$PANE_DIR/$1"; [ -e "$f" ] || exit 1; exec cat "$f"\n' >"$T/bin/pane"
printf '#!/bin/sh\nf="$TR_DIR/$1"; [ -e "$f" ] || exit 1; exec cat "$f"\n' >"$T/bin/tr"
printf '#!/bin/sh\ncat >>"%s/owner-dm"; echo >>"%s/owner-dm"\n' "$T" "$T" >"$T/bin/dm"
chmod +x "$T/bin/"*

agent() { mkdir -p "$T/$1/proc/$2" "$T/$1/pane" "$T/$1/tr"; echo claude >"$T/$1/proc/$2/comm"; printf 'SPOOL_AGENT_ID=%s\0' "$3" >"$T/$1/proc/$2/environ"; cp "$FX/good-turn.jsonl" "$T/$1/tr/$2"; }
trio() { agent "$1" "${2}00" c-001; agent "$1" "${2}01" c-002; agent "$1" "${2}02" c-003; }
trio pc 1; trio sat 2

lease_env() {
  local m="$1" now="$2"
  echo PROJ_PATH="$PROJ_ROOT" SRC="$SRC" SPOOL_ROOT="$T/$m/spool" LEASE_PROC_ROOT="$T/$m/proc" LEASE_SEND="$T/bin/send" \
    LEASE_PANE_CMD="$T/bin/pane" PANE_DIR="$T/$m/pane" LEASE_TRANSCRIPT_CMD="$T/bin/tr" TR_DIR="$T/$m/tr" \
    LEASE_OWNER_CMD="$T/bin/dm" LEASE_HUB_CMD="$T/bin/hub" HUB_DIR="$T/hub" HUB_NOW="$now" LEASE_NOW="$now" \
    LEASE_FLEET=main LEASE_MACHINE="$m" LEASE_PRIORITY=pc,sat LEASE_HOLDDOWN=0 LEASE_HANDOFF=0 \
    LEASE_ORCH=c-001 LEASE_MASTER=c-002 LEASE_FAILOVER=c-003 LEASE_ORCH_FALLBACK=none LEASE_DISPATCH_FALLBACK=none
}
# tick <machine> <hub-now> [env...]: one fleet tick on that machine
tick() {
  local m="$1" now="$2"; shift 2
  mkdir -p "$T/$m/spool"
  # shellcheck disable=SC2046 # lease_env prints NAME=value words without spaces
  env $(lease_env "$m" "$now") "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$SRC"
    spl_lease_init && spl_lease_ids master failover orch && spl_fleet_ids && spl_fleet_hub_init && spl_lease_fleet_tick' >>"$T/out" 2>&1
}
cas() { grep -c -- "^$1\$" "$T/hub/cas.log" 2>/dev/null || true; }
hubh() { cut -d' ' -f1 "$T/hub/main.$1" 2>/dev/null; }
lease_log() { cat "$T/$1/spool/dispatch/lease.log" 2>&1; }

# --- 1. claim, then renewals name nothing ------------------------------------------
tick pc 1000; tick sat 1000
[[ "$(cas 'orch c-001@pc claim')" == 1 && "$(cas 'dispatch c-002@pc claim')" == 1 ]] &&
  pass "1. the first write of each role names --reason claim" ||
  fail "1. claim: $(cat "$T/hub/cas.log" 2>&1) $(tail -5 "$T/out")"
: >"$T/hub/cas.log"
tick pc 1030; tick sat 1030
[[ -s "$T/hub/cas.log" && "$(grep -vc ' -$' "$T/hub/cas.log")" == 0 ]] &&
  pass "1. a renewal (same holder) names no reason" || fail "1. renewal: $(cat "$T/hub/cas.log")"

# --- 2. rotation hold, then the move back ------------------------------------------
mkdir -p "$T/pc/spool/dispatch"
echo "c-002 1050 rid $$" >"$T/pc/spool/dispatch/rotate.hold"
tick pc 1060
[[ "$(hubh dispatch)" == c-003@pc && "$(cas 'dispatch c-003@pc rotation')" == 1 ]] &&
  pass "2. a master under a rotation hold hands to c-003: --reason rotation" ||
  fail "2. rotation: hub $(hubh dispatch) $(cat "$T/hub/cas.log") $(lease_log pc | tail -3)"
rm -f "$T/pc/spool/dispatch/rotate.hold"
for n in 1090 1120 1150; do tick pc "$n"; done
[[ "$(hubh dispatch)" == c-002@pc && "$(cas 'dispatch c-002@pc seat_move')" == 1 ]] &&
  pass "2. the move back once the hold ends: --reason seat_move" ||
  fail "2. back: hub $(hubh dispatch) $(cat "$T/hub/cas.log") $(lease_log pc | tail -3)"

# --- 3. pc goes dark: failover, and the notice says what sat knows -----------------
rm -rf "${T:?}/pc/proc"; mkdir -p "$T/pc/proc"
tick sat 1250
[[ "$(hubh orch)" == c-001@pc ]] || fail "3. setup: sat took orch at 100 s: $(hubh orch)"
tick sat 1400
[[ "$(hubh orch)" == c-001@sat && "$(hubh dispatch)" == c-002@sat &&
   "$(cas 'orch c-001@sat failover')" == 1 && "$(cas 'dispatch c-002@sat failover')" == 1 ]] &&
  pass "3. sat takes both roles past LEASE_STALE: --reason failover (the hub's lease.failover row)" ||
  fail "3. failover: hub $(hubh orch) $(hubh dispatch) $(cat "$T/hub/cas.log") $(lease_log sat | tail -4)"
dm="$(cat "$T/owner-dm" 2>/dev/null)"
[[ "$dm" == *"Orchestrator failover: c-001@sat took over from c-001@pc, silent 250s: its box pc renewed the row for none of the last 250s (LEASE_STALE 180s)"* &&
   "$dm" != *"gone, stalled"* ]] &&
  pass "3. the take-over notice says pc renewed nothing for 250 s, not 'gone, stalled, or it sat idle'" ||
  fail "3. notice: '$dm'"

# --- 4. pc returns: handback -------------------------------------------------------
trio pc 1
tick pc 1430
[[ "$(hubh orch)" == c-001@pc && "$(cas 'orch c-001@pc handback')" == 1 ]] &&
  pass "4. pc back, ranked first: --reason handback" ||
  fail "4. handback: hub $(hubh orch) $(cat "$T/hub/cas.log") $(lease_log pc | tail -3)"

# --- 5. a seat of this box on a short S1 wait: its verdict is the cause ------------
mkdir -p "$T/sat/spool/dispatch"; echo "wd S1: HIT 40s ago" >"$T/sat/spool/dispatch/able.c-001"
# shellcheck disable=SC2046
got="$(env $(lease_env sat 1500) bash -c '
  do_log() { :; }; source "$SRC"; spl_lease_init >/dev/null 2>&1
  printf "%s|" "$(spl_fleet_takeover_cause c-001@sat 200)" "$(spl_fleet_cas_reason c-001@sat c-003@sat false 0 0 200)"' 2>&1)"
[[ "$got" == "c-001 on this box cannot act (wd S1: HIT 40s ago)|seat_move|" ]] &&
  pass "5. a local seat's S1 wait is named as such in the cause, and its move is a seat_move, not a failover" ||
  fail "5. local cause: '$got'"

echo "---"
(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
