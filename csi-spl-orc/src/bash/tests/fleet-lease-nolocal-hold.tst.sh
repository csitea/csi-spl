#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-5640, one busy tick posts no NO-LOCAL-AGENT alert (owner msg
#          43a2229f, "Why ?!"). 2026-11-14 07:22Z sat posted "NO-LOCAL-AGENT
#          orch on sat ... Nobody acts as orch" while c-001 was working
#          through a 39-message backlog: one message unread over 2 min, the
#          watchdog's S1 hit fresh, one tick judged the seat not able. Two
#          stubbed machines, sx (ranked first, holds both roles) and ox
#          (degraded by its beats, so no other box can take a role); sx's
#          orch seat c-001 runs but its watchdog verdict is a fresh HIT S1:
#   1. RED CONTROL: one not-able tick logs the NO-LOCAL-AGENT line and posts
#      nothing (before SPL-5640: one #alerts post and one orch note)
#   2. LEASE_NOLOCAL_TICKS (3) ticks in a row post ONCE, and no more after
#   3. an able tick in between resets the count
#   4. LEASE_NOLOCAL_TICKS=1 is the old first-tick alert
#   5. no seat with a process at all is no busy tick: the alert at once
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
# the beats stub of fleet-lease.tst.sh section 23: `box-beat list --since <n>m` from $BEATS
cat >"$T/bin/beats" <<'STUB'
#!/bin/sh
m="${4%m}"
jq -c --argjson now "$HUB_NOW" --argjson s "$((m * 60))" \
  '{rows: [.[] | select(.e <= $now and .e > $now - $s) | {box, beat_at: (.e | todate)}]}' "$BEATS"
STUB
printf '#!/bin/sh\nf="$PANE_DIR/$1"; [ -e "$f" ] || exit 1; exec cat "$f"\n' >"$T/bin/pane"
printf '#!/bin/sh\nf="$TR_DIR/$1"; [ -e "$f" ] || exit 1; exec cat "$f"\n' >"$T/bin/tr"
printf '#!/bin/sh\ncat >>"%s/owner-dm"\n' "$T" >"$T/bin/dm"
printf '#!/bin/sh\necho "$LEASE_MACHINE $HUB_NOW :: $(cat)" >>"$ALERTS"\n' >"$T/bin/alert"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/switch"
chmod +x "$T/bin/"*

# agent <machine> <pid> <id>
agent() { mkdir -p "$T/$1/proc/$2" "$T/$1/pane" "$T/$1/tr"; echo claude >"$T/$1/proc/$2/comm"; printf 'SPOOL_AGENT_ID=%s\0' "$3" >"$T/$1/proc/$2/environ"; cp "$FX/good-turn.jsonl" "$T/$1/tr/$2"; }
B=1792000000
# beats <box> <start> <counts per 10 min>: one row per beat
beats() { jq -nc --arg b "$1" --argjson s "$2" --argjson c "[$3]" \
  '[range(0; $c | length) as $i | range(0; $c[$i]) as $k | {box: $b, e: ($s + $i * 600 + (($k + 0.5) * 600 / $c[$i] | floor))}]'; }
jq -s add <(beats sx $B "60,60,60,60,60,60") <(beats ox $B "60,60,60,5,2,1") >"$T/beats.json"
# reset: both boxes run every role seat; sx takes both rows
reset() {
  rm -rf "${T:?}/sx" "${T:?}/ox" "${T:?}/hub" "${T:?}/alerts"; mkdir -p "$T/hub"
  agent sx 600 c-001; agent sx 601 c-002; agent sx 602 c-003
  agent ox 610 c-001; agent ox 611 c-002; agent ox 612 c-003
  tick sx $((B + 2940)); tick ox $((B + 2941))
}
# tick <machine> <hub-now> [env...]: one fleet tick on that machine; the
# holder keeps its rows (no stale take-over, no handoff)
tick() {
  local m="$1" now="$2"; shift 2
  mkdir -p "$T/$m/spool"
  env PROJ_PATH="$PROJ_ROOT" SRC="$SRC" SPOOL_ROOT="$T/$m/spool" LEASE_PROC_ROOT="$T/$m/proc" LEASE_SEND="$T/bin/send" \
    LEASE_PANE_CMD="$T/bin/pane" PANE_DIR="$T/$m/pane" LEASE_TRANSCRIPT_CMD="$T/bin/tr" TR_DIR="$T/$m/tr" \
    LEASE_OWNER_CMD="$T/bin/dm" SENT="$T/$m/sent" LEASE_HUB_CMD="$T/bin/hub" HUB_DIR="$T/hub" HUB_NOW="$now" LEASE_NOW="$now" \
    LEASE_FLEET=main LEASE_MACHINE="$m" LEASE_PRIORITY=sx,ox LEASE_HOLDDOWN=0 LEASE_STALE=99999 LEASE_DEAD_WAIT=99999 LEASE_HANDOFF=0 \
    LEASE_BEATS_CMD="$T/bin/beats" BEATS="$T/beats.json" LEASE_HEALTH_TTL=0 LEASE_ALERT=1 LEASE_ALERT_CMD="$T/bin/alert" ALERTS="$T/alerts" \
    LEASE_ORCH=c-001 LEASE_MASTER=c-002 LEASE_FAILOVER=c-003 LEASE_SWITCH_RUN="$T/bin/switch" LEASE_SWITCH_SYNC=1 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$SRC"
    spl_lease_init && spl_lease_ids master failover orch && spl_fleet_ids && spl_fleet_hub_init && spl_lease_fleet_tick' >>"$T/out" 2>&1
}
# busy <hub-now> [env...]: sx's orch seat runs, its watchdog verdict a HIT S1 5 s old; one sx tick
busy() { local n="$1"; shift; echo "HIT S1 $((n - 5))" >"$T/sx/spool/dispatch/wd.c-001"; tick sx "$n" "$@"; }
# able <hub-now>: the HIT is gone; one sx tick
able() { rm -f "$T/sx/spool/dispatch/wd.c-001"; tick sx "$1"; }
alerts() { [[ -f "$T/alerts" ]] || { echo 0; return 0; }; grep -c 'NO-LOCAL-AGENT orch on sx' "$T/alerts" || true; }
notes() { [[ -f "$T/sx/sent" ]] || { echo 0; return 0; }; grep -c '^c-001 :: FLEET LEASE ALERT: NO-LOCAL-AGENT orch on sx' "$T/sx/sent" || true; }
logc() { grep -c -- "$1" "$T/sx/spool/dispatch/lease.log" 2>/dev/null || true; }
lease_log() { cat "$T/sx/spool/dispatch/lease.log" 2>&1; }
hubh() { cut -d' ' -f1 "$T/hub/main.$1" 2>/dev/null; }

# --- 1. one busy tick: the log line, no alert ----------------------------------
reset
[[ "$(hubh orch) $(hubh dispatch)" == "c-001@sx c-002@sx" ]] || fail "1. setup: hub $(hubh orch) $(hubh dispatch) $(cat "$T/out")"
busy $((B + 3000))
[[ "$(logc 'NO-LOCAL-AGENT orch: this machine holds it (c-001@sx) but has no live candidate able to act (c-001: wd S1: HIT 5s ago)')" == 1 ]] &&
  pass "1. the NO-LOCAL-AGENT line is logged on the first busy tick, as before" || fail "1. log line: $(lease_log)"
[[ "$(alerts) $(notes)" == "0 0" && "$(logc 'NO-LOCAL-HOLD orch')" == 1 ]] &&
  pass "1. RED CONTROL: one busy tick posts nothing to #alerts and sends no orch note (NO-LOCAL-HOLD logged)" ||
  fail "1. one tick: alerts $(alerts) notes $(notes) $(cat "$T/alerts" 2>&1) $(lease_log)"

# --- 2. LEASE_NOLOCAL_TICKS ticks in a row post once -----------------------------
busy $((B + 3060))
[[ "$(alerts) $(notes)" == "0 0" ]] && pass "2. two busy ticks: still nothing" || fail "2. two ticks: alerts $(alerts) notes $(notes)"
busy $((B + 3120))
[[ "$(alerts) $(notes)" == "1 1" && "$(logc 'NO-LOCAL-ALERT orch: no other fresh box (ox: degraded)')" == 1 ]] &&
  pass "2. the third busy tick in a row: ONE #alerts post and ONE note to the orch holder" ||
  fail "2. three ticks: alerts $(alerts) notes $(notes) $(lease_log)"
busy $((B + 3180)); busy $((B + 3240))
[[ "$(alerts) $(notes)" == "1 1" && "$(logc 'NO-LOCAL-HOLD orch')" == 1 ]] &&
  pass "2. more busy ticks of the same episode post nothing more" || fail "2. episode: alerts $(alerts) notes $(notes)"

# --- 3. an able tick in between resets the count ----------------------------------
reset
busy $((B + 3000)); busy $((B + 3060)); able $((B + 3120))
[[ ! -e "$T/sx/spool/dispatch/fleet.orch.nolocal-ticks" ]] && pass "3. an able tick clears the count" ||
  fail "3. count kept: $(cat "$T/sx/spool/dispatch/fleet.orch.nolocal-ticks")"
busy $((B + 3180)); busy $((B + 3240))
[[ "$(alerts) $(notes)" == "0 0" ]] && pass "3. busy, busy, able, busy, busy: nothing posted" ||
  fail "3. reset: alerts $(alerts) notes $(notes) $(lease_log)"
busy $((B + 3300))
[[ "$(alerts) $(notes)" == "1 1" ]] && pass "3. the third busy tick after the able one posts once" ||
  fail "3. after reset: alerts $(alerts) notes $(notes) $(lease_log)"

# --- 4. LEASE_NOLOCAL_TICKS=1: the old first-tick alert -----------------------------
reset
busy $((B + 3000)) LEASE_NOLOCAL_TICKS=1
[[ "$(alerts) $(notes)" == "1 1" && "$(logc 'NO-LOCAL-HOLD')" == 0 ]] &&
  pass "4. LEASE_NOLOCAL_TICKS=1 alerts on the first busy tick" || fail "4. ticks=1: alerts $(alerts) notes $(notes) $(lease_log)"

# --- 5. no seat with a process: no busy tick, the alert at once -----------------------
reset
rm -rf "${T:?}/sx/proc/600"
tick sx $((B + 3000))
[[ "$(alerts) $(notes)" == "1 1" && "$(logc 'NO-LOCAL-HOLD')" == 0 ]] &&
  pass "5. CONTROL: the orch seat has no process: the alert on the first tick, as before" ||
  fail "5. dead seat: alerts $(alerts) notes $(notes) $(lease_log)"

echo "---"
(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
