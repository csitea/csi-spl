#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-2521, the vendor fallback of the fleet lease (owner HUM-10, t1
#          b3e90079: "there was login on the claude and ... grok should have
#          been able to take over the orchestratio n, but it did not"; msg
#          dfe76b16: "the order is claude -> grok -> agy"). A replay of the
#          2026-10-19 07:2xZ picture on two stubbed machines, sat (ranked
#          first) and pc: every claude seat alive but its login expired
#          ("Login expired · Please run /login", an API-error last turn), the
#          grok seats g-001 / g-002 live and able.
#   1. setup: every seat able, sat holds orch (c-001) and dispatch (c-002)
#   2. BEFORE (control, LEASE_*_FALLBACK=none = the pre-SPL-2521 candidates):
#      the claude logins expire on both boxes; 10 min later the hub still
#      names the dead claude seats. Run with LEASE_SRC=<the old
#      spl-dispatch-lease.func.sh> the whole file shows this red.
#   3. AFTER: the same expiry. A fallback seat waits LEASE_STALE +
#      LEASE_FALLBACK_WAIT (silent > 240 s) so a claude seat anywhere comes
#      first; at most 300 s after the last renewal of the dead seat (LEASE_STALE
#      + LEASE_FALLBACK_WAIT + one LEASE_PERIOD: the acceptance bound, no human
#      step) grok holds both roles: g-001@sat orch, g-002@sat
#      dispatch; told ACTIVE; the owner gets ONE DM for the orch failover.
#   4. a fallback seat never takes a role from an able claude holder, even on
#      a machine ranked first (vendor before rank)
#   5. hand back: pc's claude login works again; pc's c-001/c-002 (vendor
#      claude) outrank the grok holder on sat after LEASE_HOLDDOWN; then sat's
#      claude is back and the old rank handback returns both roles to sat
#   6. an able claude seat on another box takes before the grok fallback of
#      the holder's own box (181 s, not 241 s)
#   7. agy is the third step: claude and grok seats cannot act, a-001 takes
#      orch only past LEASE_STALE + 2 x LEASE_FALLBACK_WAIT (300 s)
#   8. spl_lease_agent_pid counts an agy process (comm agy)
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
# pane of <machine> pid N: $T/<machine>/pane/N, none = no pane (able); transcript the same under tr/
printf '#!/bin/sh\nf="$PANE_DIR/$1"; [ -e "$f" ] || exit 1; exec cat "$f"\n' >"$T/bin/pane"
printf '#!/bin/sh\nf="$TR_DIR/$1"; [ -e "$f" ] || exit 1; exec cat "$f"\n' >"$T/bin/tr"
printf '#!/bin/sh\ncat >>"%s/owner-dm"\n' "$T" >"$T/bin/dm"
chmod +x "$T/bin/"*

# agent <machine> <pid> <id> [comm]
agent() { mkdir -p "$T/$1/proc/$2" "$T/$1/pane" "$T/$1/tr"; echo "${4:-claude}" >"$T/$1/proc/$2/comm"; printf 'SPOOL_AGENT_ID=%s\0' "$3" >"$T/$1/proc/$2/environ"; }
# login_expired <machine> <pid>... / login_ok <machine> <pid>...: the 2026-10-05 fixtures
login_expired() { local m="$1" p; shift; for p in "$@"; do cp "$FX/login-expired-2026-10-05.pane" "$T/$m/pane/$p"; cp "$FX/login-expired.jsonl" "$T/$m/tr/$p"; done; }
login_ok() { local m="$1" p; shift; for p in "$@"; do rm -f "${T:?}/${m:?}/pane/${p:?}"; cp "$FX/good-turn.jsonl" "$T/$m/tr/$p"; done; }
# cant_act <machine> <pid>...: a stuck dialog no key clears (a login picker)
cant_act() { local m="$1" p; shift; for p in "$@"; do printf 'Select login method:\n\n ❯ 1. Claude account\n   2. Console account\n' >"$T/$m/pane/$p"; done; }

reset() {
  rm -rf "${T:?}/sat" "${T:?}/pc" "${T:?}/hub" "${T:?}/owner-dm"; mkdir -p "$T/hub"
  agent sat 200 c-001; agent sat 201 c-002; agent sat 202 c-003; agent sat 210 g-001 grok; agent sat 211 g-002 grok
  agent pc 100 c-001; agent pc 101 c-002; agent pc 102 c-003; agent pc 110 g-001 grok; agent pc 111 g-002 grok
}

PRIO=sat,pc
# tick <machine> <hub-now> [env...]: one fleet tick on that machine
tick() {
  local m="$1" now="$2"; shift 2
  env PROJ_PATH="$PROJ_ROOT" SRC="$SRC" SPOOL_ROOT="$T/$m/spool" LEASE_PROC_ROOT="$T/$m/proc" LEASE_SEND="$T/bin/send" \
    LEASE_PANE_CMD="$T/bin/pane" PANE_DIR="$T/$m/pane" LEASE_TRANSCRIPT_CMD="$T/bin/tr" TR_DIR="$T/$m/tr" \
    LEASE_OWNER_CMD="$T/bin/dm" SENT="$T/$m/sent" LEASE_HUB_CMD="$T/bin/hub" HUB_DIR="$T/hub" HUB_NOW="$now" LEASE_NOW="$now" \
    LEASE_FLEET=main LEASE_MACHINE="$m" LEASE_PRIORITY="$PRIO" LEASE_LIMIT_TZ=Etc/GMT-3 LEASE_HOLDDOWN=0 \
    LEASE_ORCH=c-001 LEASE_MASTER=c-002 LEASE_FAILOVER=c-003 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$SRC"
    spl_lease_init && spl_lease_ids master failover orch && spl_fleet_ids && spl_fleet_hub_init && spl_lease_fleet_tick' >>"$T/out" 2>&1
}
# both <hub-now> [env...]: sat ticks, then pc
both() { local n="$1"; shift; tick sat "$n" "$@"; tick pc "$n" "$@"; }
hubh() { cut -d' ' -f1 "$T/hub/main.$1" 2>/dev/null; }
hub2() { echo "$(hubh orch) $(hubh dispatch)"; }
sentc() { grep -c -- "$2" "$T/$1/sent" 2>/dev/null || true; }
logc() { grep -c -- "$2" "$T/$1/spool/dispatch/lease.log" 2>/dev/null || true; }
dms() { grep -c '^Orchestrator failover' "$T/owner-dm" 2>/dev/null || true; }

# --- 1. setup ---------------------------------------------------------------------
reset
both 10000
[[ "$(hub2)" == "c-001@sat c-002@sat" ]] && pass "1. every seat able: sat holds orch c-001 and dispatch c-002" || fail "1. hub: $(hub2) $(cat "$T/out")"

# --- 2. BEFORE: no fallback, the lease stays on the dead claude seats ----------------
OFF=(LEASE_ORCH_FALLBACK=none LEASE_DISPATCH_FALLBACK=none)
both 10060 "${OFF[@]}"
login_expired sat 200 201 202; login_expired pc 100 101 102
for n in 10120 10180 10240 10300 10360 10420 10480 10540 10600 10660; do both "$n" "${OFF[@]}"; done
[[ "$(hub2)" == "c-001@sat c-002@sat" ]] &&
  pass "2. CONTROL (no fallback, the pre-SPL-2521 rule): 600 s after the logins expired the hub still names the dead c-001@sat / c-002@sat" ||
  fail "2. control: hub $(hub2)"

# --- 3. AFTER: grok takes both roles within 300 s --------------------------------------
reset
both 20000; both 20060
login_expired sat 200 201 202; login_expired pc 100 101 102
# the last renewal by an able seat was at 20060; tick every 60 s from there
for n in 20120 20180 20240 20300; do both "$n"; done
[[ "$(hub2)" == "c-001@sat c-002@sat" ]] &&
  pass "3. 240 s after the last renewal no grok seat has taken a role yet (a claude seat anywhere takes at 181 s)" || fail "3. early: hub $(hub2)"
[[ "$(logc sat 'FALLBACK-WAIT orch')" == 1 && "$(logc sat 'FALLBACK-WAIT dispatch')" == 1 ]] &&
  pass "3. sat logs FALLBACK-WAIT once per role while it waits" || fail "3. wait log: $(cat "$T/sat/spool/dispatch/lease.log")"
both 20360
dt=$(( $(cut -d' ' -f3 "$T/hub/main.orch") - 20060 ))
[[ "$(hub2)" == "g-001@sat g-002@sat" ]] && (( dt <= 300 )) &&
  pass "3. AFTER: grok holds orch g-001@sat and dispatch g-002@sat ${dt}s after the last renewal (bound: 300 s, no human step)" ||
  fail "3. after: hub $(hub2) dt=$dt $(tail -5 "$T/sat/spool/dispatch/lease.log")"
[[ "$(sentc sat 'g-001 :: FLEET LEASE orch: you are now ACTIVE')" == 1 && "$(sentc sat 'g-002 :: FLEET LEASE dispatch: you are now ACTIVE')" == 1 &&
   "$(sentc sat 'c-001 :: FLEET LEASE orch: STANDBY')" == 1 ]] &&
  pass "3. g-001 and g-002 are told ACTIVE once, c-001 STANDBY" || fail "3. sent: $(cat "$T/sat/sent")"
[[ "$(dms)" == 1 && "$(logc sat 'VENDOR orch: c-001@sat (claude) -> g-001@sat (grok)')" == 1 ]] &&
  pass "3. the owner gets ONE DM for the orch failover; lease.log names the vendor switch" || fail "3. dms $(dms): $(cat "$T/sat/spool/dispatch/lease.log")"
for n in 20420 20480; do both "$n"; done
[[ "$(hub2)" == "g-001@sat g-002@sat" && "$(dms)" == 1 ]] &&
  pass "3. grok renews; pc's grok (same vendor, ranked second) leaves it" || fail "3. renew: hub $(hub2)"

# --- 4. vendor before rank: a fallback never takes from an able claude holder ------------
reset
login_expired pc 100 101 102
both 30000
for n in 30060 30120 30480 30900; do both "$n" LEASE_PRIORITY=pc,sat; done
[[ "$(hub2)" == "c-001@sat c-002@sat" && "$(logc pc 'FLEET orch: none -> c-001@sat')" == 1 && "$(logc pc 'takes over')" == 0 ]] &&
  pass "4. pc ranked first with only grok able never takes a role from sat's able claude seats" || fail "4. hub $(hub2): $(cat "$T/pc/spool/dispatch/lease.log")"

# --- 5. hand back to claude ---------------------------------------------------------
reset
both 40000; login_expired sat 200 201 202; login_expired pc 100 101 102
for n in 40060 40120 40180 40240 40300 40360; do both "$n"; done
[[ "$(hub2)" == "g-001@sat g-002@sat" ]] || fail "5. setup: hub $(hub2)"
login_ok pc 100 101 102
both 40420 LEASE_HOLDDOWN=120; both 40480 LEASE_HOLDDOWN=120
[[ "$(hub2)" == "g-001@sat g-002@sat" && "$(logc pc 'HOLD orch: pc able 0s < LEASE_HOLDDOWN 120s: g-001@sat keeps it')" == 1 ]] &&
  pass "5. pc's claude able again: grok keeps both roles inside LEASE_HOLDDOWN" || fail "5. hold: hub $(hub2) $(cat "$T/pc/spool/dispatch/lease.log")"
both 40540 LEASE_HOLDDOWN=120
[[ "$(hub2)" == "c-001@pc c-002@pc" ]] &&
  pass "5. after LEASE_HOLDDOWN pc's claude (vendor before rank) takes both roles back from sat's grok" || fail "5. handback: hub $(hub2)"
both 40600 LEASE_HOLDDOWN=120; both 40660 LEASE_HOLDDOWN=120
[[ "$(sentc sat 'g-001 :: FLEET LEASE orch: STANDBY')" == 1 && "$(sentc pc 'c-001 :: FLEET LEASE orch: you are now ACTIVE')" == 1 &&
   "$(cut -d' ' -f1 "$T/sat/spool/dispatch/lease.orch")" == c-001@pc ]] &&
  pass "5. g-001 stood down (STANDBY), pc's c-001 told ACTIVE once" || fail "5. sent sat: $(cat "$T/sat/sent") pc: $(cat "$T/pc/sent")"
login_ok sat 200 201 202
for n in 40720 40780 40840 40900; do both "$n" LEASE_HOLDDOWN=120; done
[[ "$(hub2)" == "c-001@sat c-002@sat" ]] &&
  pass "5. sat's claude back: the rank handback (unchanged) returns both roles to sat" || fail "5. rank: hub $(hub2)"

# --- 6. a claude seat on another box comes before the holder box's grok -----------------
reset
both 50000
login_expired sat 200 201 202
for n in 50060 50120 50180; do both "$n"; done
[[ "$(hub2)" == "c-001@sat c-002@sat" ]] || fail "6. early: hub $(hub2)"
both 50240
[[ "$(hub2)" == "c-001@pc c-002@pc" && "$(logc sat 'VENDOR')" == 0 ]] &&
  pass "6. sat's claude dead, pc's able: pc's claude takes both at 181..240 s, sat's grok never does" || fail "6. hub $(hub2) $(cat "$T/sat/spool/dispatch/lease.log")"

# --- 7. agy, the third step -------------------------------------------------------------
reset
agent pc 120 a-001 agy
both 60000
cant_act sat 210 211; cant_act pc 110 111
login_expired sat 200 201 202; login_expired pc 100 101 102
for n in 60060 60120 60180 60240 60300; do both "$n"; done
[[ "$(hubh orch)" == c-001@sat ]] && pass "7. agy waits past grok's 240 s (silent 300 s, still c-001@sat)" || fail "7. early: hub $(hub2)"
both 60360
[[ "$(hubh orch)" == a-001@pc ]] &&
  pass "7. claude and grok cannot act anywhere: agy a-001@pc holds orch (> LEASE_STALE + 2 x 60 s)" || fail "7. hub $(hub2) $(cat "$T/pc/spool/dispatch/lease.log")"

# --- 8. an agy process counts -----------------------------------------------------------
got="$(env SRC="$SRC" LEASE_PROC_ROOT="$T/pc/proc" bash -c 'do_log() { :; }; source "$SRC"; spl_lease_agent_pid a-001' 2>&1)"
[[ "$got" == 120 ]] && pass "8. spl_lease_agent_pid finds the agy process" || fail "8. agy pid: '$got'"

(( fails == 0 )) && { echo "PASS: all fleet-lease-vendor-failover.tst.sh assertions"; exit 0; }
echo "FAIL: $fails fleet-lease-vendor-failover.tst.sh assertion(s)"; exit 1
