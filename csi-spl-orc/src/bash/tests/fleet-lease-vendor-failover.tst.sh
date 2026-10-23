#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-2521 + SPL-2544, the vendor fallback of the fleet lease (owner
#          HUM-10, t1 b3e90079: "there was login on the claude and ... grok
#          should have been able to take over the orchestratio n, but it did
#          not"; msg dfe76b16: "the order is claude -> grok -> agy"). A replay
#          of the 2026-10-19 07:2xZ picture on two stubbed machines, sat
#          (ranked first) and pc: every claude seat alive but its login
#          expired ("Login expired · Please run /login", an API-error last
#          turn). SPL-2544: no separate standby seat; the role's own seat
#          switches vendor IN PLACE (do_spl_role_failover). Here its effect is
#          the LEASE_SWITCH_RUN stub: the seat's dir moves to the new letter
#          (the old letters link to it), the old process ends, the new vendor's
#          process carries the new id (role-failover.tst.sh tests the action).
#   1. setup: every seat able, sat holds orch (c-001) and dispatch (c-002)
#   2. BEFORE (control, LEASE_*_FALLBACK=none = no switch): the claude logins
#      expire on both boxes; 10 min later the hub still names the dead claude
#      seats and no switch was launched
#   3. AFTER: the same expiry. No switch while the holder is silent <= 240 s
#      (LEASE_STALE + LEASE_FALLBACK_WAIT, so a claude seat anywhere comes
#      first); at most 300 s after the last renewal (+ one LEASE_PERIOD, no
#      human step) each box switches its seat in place (c-001 -> g-001, c-002
#      -> g-002), ONE launch per seat, and the next tick sat's grok holds both
#      roles: g-001@sat orch, g-002@sat dispatch; the seat's new id is told
#      ACTIVE; the owner gets ONE DM for the orch failover
#   4. no switch while an able claude seat holds the role, even on a machine
#      ranked first (vendor before rank)
#   5. hand back: pc's seats back on claude (the rotation's handback) outrank
#      the grok holder on sat after LEASE_HOLDDOWN; then sat's claude is back
#      and the old rank handback returns both roles to sat
#   6. an able claude seat on another box takes before the holder box's
#      switch (181 s, not 241 s): no SWITCH on sat
#   7. agy is the third step: the seat's grok cannot act either; it switches
#      g-001 -> a-001 only past LEASE_STALE + 2 x LEASE_FALLBACK_WAIT (300 s),
#      then a-001 holds orch
#   8. spl_lease_agent_pid counts an agy process (comm agy)
#   9. LEASE_ROLE_SWITCH=0 launches no switch; a failed switch (the seat
#      unchanged) is launched again only after LEASE_SWITCH_RETRY
#  10. SPL-2865 (a), the 2026-10-22 09:46-09:53Z store_unavailable outage:
#      nobody can renew while the hub is down, so the holder's silence when
#      it comes back is the outage's. A seat that cannot act on either box
#      is not switched on the first read after the outage (the holder's age
#      300 s, its last renewal before the hub went down); the silence counts
#      from this box's last failed hub call, so the switch comes only once
#      the holder stays silent past the wait with the hub up
#      (RED CONTROL: before SPL-2865 both boxes switched at the first read)
#  11. SPL-2892, the 2026-10-22 10:23..11:01Z picture: the holder box's role
#      seats sit on a weekly limit (watchdog S2 kind=limit, reset 2 days
#      away) and no vendor is left on it. It writes the hub row over to the
#      role's seat on the next box of the ranking at once, and that box's
#      able seat holds the role the same tick (RED CONTROL: before SPL-2892
#      the row stayed on the limited seat until it went stale, 181..240 s);
#      a limit that resets inside LEASE_STALE moves nothing; with the other
#      box limited too the row moves ONE hop, never back (no ping-pong)
#  12. SPL-2943, the second claude login: a claude process whose environ
#      carries CLAUDE_CONFIG_DIR runs claude2; after agy the next vendor
#      step is claude2, and after claude2 none is left
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
[ -n "${HUB_DOWN:-}" ] && { echo 'spool: hub unreachable: received close frame: reason = "store_unavailable"' >&2; exit 1; }
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
# the in-place switch's effect (do_spl_role_failover), on the machine of
# SPOOL_ROOT ($T/<m>/spool): c-00N -> g-00N, g-00N -> a-00N. SWITCH_FAIL=<vendor>:
# nothing changes; SWITCH_BAD=<vendor>: the new process sits on a login picker.
cat >"$T/bin/switch" <<'STUB'
#!/usr/bin/env bash
M="$(dirname "$SPOOL_ROOT")"; seat="$ROLE_FAILOVER_SEAT"; n="${seat#*-}"
case "${seat%%-*}" in c) v=grok l=g base=300 ;; g) v=agy l=a base=400 ;; *) exit 0 ;; esac
new="$l-$n"
echo "$ROLE_FAILOVER_ROLE $seat -> $new silent=$ROLE_FAILOVER_SILENT" >>"$M/switches"
[ "${SWITCH_FAIL:-}" = "$v" ] && exit 0
R="$SPOOL_ROOT"; [ -L "$R/$new" ] && rm -f "$R/$new"; mkdir -p "$R/$new"
for x in a c g; do [ "$x-$n" = "$new" ] || { rm -rf "${R:?}/$x-$n"; ln -s "$new" "$R/$x-$n"; }; done
for d in "$M/proc"/*; do grep -qzx "SPOOL_AGENT_ID=$seat" "$d/environ" 2>/dev/null && rm -rf "$d"; done
pid=$((base + 10#$n)); mkdir -p "$M/proc/$pid" "$M/pane"; echo "$v" >"$M/proc/$pid/comm"; printf 'SPOOL_AGENT_ID=%s\0' "$new" >"$M/proc/$pid/environ"
[ "${SWITCH_BAD:-}" = "$v" ] && printf 'Select login method:\n\n ❯ 1. Account\n' >"$M/pane/$pid"
exit 0
STUB
chmod +x "$T/bin/"*

# agent <machine> <pid> <id> [comm]
agent() { mkdir -p "$T/$1/proc/$2" "$T/$1/pane" "$T/$1/tr"; echo "${4:-claude}" >"$T/$1/proc/$2/comm"; printf 'SPOOL_AGENT_ID=%s\0' "$3" >"$T/$1/proc/$2/environ"; }
# login_expired <machine> <pid>... / login_ok <machine> <pid>...: the 2026-10-05 fixtures
login_expired() { local m="$1" p; shift; for p in "$@"; do cp "$FX/login-expired-2026-10-05.pane" "$T/$m/pane/$p"; cp "$FX/login-expired.jsonl" "$T/$m/tr/$p"; done; }
login_ok() { local m="$1" p; shift; for p in "$@"; do rm -f "${T:?}/${m:?}/pane/${p:?}"; cp "$FX/good-turn.jsonl" "$T/$m/tr/$p"; done; }
# back_to_claude <machine> <pid> <seat>: the rotation's handback: the seat's
# dir is the claude letter's again, a claude process carries it, able
back_to_claude() {
  local m="$1" p="$2" seat="$3" n="${3#*-}" R="$T/$1/spool" x d
  for x in a g; do rm -rf "${R:?}/$x-$n"; done; rm -rf "${R:?}/$seat"; mkdir -p "$R/$seat"
  for x in a g; do ln -s "$seat" "$R/$x-$n"; done
  for d in "$T/$m/proc"/*; do grep -qzE "SPOOL_AGENT_ID=[ag]-$n" "$d/environ" 2>/dev/null && rm -rf "$d"; done
  agent "$m" "$p" "$seat"; login_ok "$m" "$p"
}

reset() {
  rm -rf "${T:?}/sat" "${T:?}/pc" "${T:?}/hub" "${T:?}/owner-dm"; mkdir -p "$T/hub"
  agent sat 200 c-001; agent sat 201 c-002; agent sat 202 c-003
  agent pc 100 c-001; agent pc 101 c-002; agent pc 102 c-003
}

PRIO=sat,pc
# tick <machine> <hub-now> [env...]: one fleet tick on that machine
tick() {
  local m="$1" now="$2"; shift 2
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
sentc() { grep -c -- "$2" "$T/$1/sent" 2>/dev/null || true; }
logc() { grep -c -- "$2" "$T/$1/spool/dispatch/lease.log" 2>/dev/null || true; }
dms() { grep -c '^Orchestrator failover' "$T/owner-dm" 2>/dev/null || true; }
swc() { [[ -f "$T/$1/switches" ]] || { echo 0; return 0; }; grep -c -- "$2" "$T/$1/switches" || true; }

# --- 1. setup ---------------------------------------------------------------------
reset
both 10000
[[ "$(hub2)" == "c-001@sat c-002@sat" ]] && pass "1. every seat able: sat holds orch c-001 and dispatch c-002" || fail "1. hub: $(hub2) $(cat "$T/out")"

# --- 2. BEFORE: no switch, the lease stays on the dead claude seats ----------------
OFF=(LEASE_ORCH_FALLBACK=none LEASE_DISPATCH_FALLBACK=none)
both 10060 "${OFF[@]}"
login_expired sat 200 201 202; login_expired pc 100 101 102
for n in 10120 10180 10240 10300 10360 10420 10480 10540 10600 10660; do both "$n" "${OFF[@]}"; done
[[ "$(hub2)" == "c-001@sat c-002@sat" && "$(swc sat .)" == 0 && "$(swc pc .)" == 0 ]] &&
  pass "2. CONTROL (LEASE_*_FALLBACK=none: no switch): 600 s after the logins expired the hub still names the dead c-001@sat / c-002@sat, 0 switches" ||
  fail "2. control: hub $(hub2) switches sat $(swc sat .) pc $(swc pc .)"

# --- 3. AFTER: each seat switches in place; grok holds both roles ------------------------
reset
both 20000; both 20060
login_expired sat 200 201 202; login_expired pc 100 101 102
# the last renewal by an able seat was at 20060; tick every 60 s from there
for n in 20120 20180 20240 20300; do both "$n"; done
[[ "$(hub2)" == "c-001@sat c-002@sat" && "$(swc sat .)" == 0 && "$(swc pc .)" == 0 ]] &&
  pass "3. 240 s after the last renewal no seat has switched yet (a claude seat anywhere takes at 181 s)" || fail "3. early: hub $(hub2) switches $(cat "$T/sat/switches" 2>&1)"
both 20360
[[ "$(swc sat '^orch c-001 -> g-001 silent=300$')" == 1 && "$(swc sat '^dispatch c-002 -> g-002 silent=300$')" == 1 &&
   "$(swc pc '^orch c-001 -> g-001')" == 1 && "$(swc pc '^dispatch c-002 -> g-002')" == 1 ]] &&
  pass "3. 300 s after the last renewal (bound: LEASE_STALE + LEASE_FALLBACK_WAIT + one LEASE_PERIOD) each box switches its seats in place: c-001 -> g-001, c-002 -> g-002" ||
  fail "3. switch: sat $(cat "$T/sat/switches" 2>&1) pc $(cat "$T/pc/switches" 2>&1)"
[[ "$(logc sat 'SWITCH orch: c-001 (claude) cannot act')" == 1 && "$(logc sat 'SWITCH dispatch: c-002 (claude) cannot act')" == 1 ]] &&
  pass "3. lease.log names each switch" || fail "3. log: $(cat "$T/sat/spool/dispatch/lease.log")"
both 20420
dt=$(( $(cut -d' ' -f3 "$T/hub/main.orch") - 20060 ))
[[ "$(hub2)" == "g-001@sat g-002@sat" && "$dt" == 360 ]] &&
  pass "3. AFTER: the next tick grok holds orch g-001@sat and dispatch g-002@sat (${dt}s after the last renewal, no human step)" ||
  fail "3. after: hub $(hub2) dt=$dt $(tail -5 "$T/sat/spool/dispatch/lease.log")"
[[ "$(sentc sat 'g-001 :: FLEET LEASE orch: you are now ACTIVE')" == 1 && "$(sentc sat 'g-002 :: FLEET LEASE dispatch: you are now ACTIVE')" == 1 ]] &&
  pass "3. the seats' new ids g-001 and g-002 are told ACTIVE once" || fail "3. sent: $(cat "$T/sat/sent")"
[[ "$(dms)" == 1 && "$(logc sat 'VENDOR orch: c-001@sat (claude) -> g-001@sat (grok)')" == 1 ]] &&
  pass "3. the owner gets ONE DM for the orch failover; lease.log names the vendor switch" || fail "3. dms $(dms): $(cat "$T/sat/spool/dispatch/lease.log")"
for n in 20480 20540 20600; do both "$n"; done
[[ "$(hub2)" == "g-001@sat g-002@sat" && "$(dms)" == 1 && "$(swc sat .)" == 2 && "$(swc pc .)" == 2 ]] &&
  pass "3. grok renews; pc's grok (same vendor, ranked second) leaves it; no second switch" || fail "3. renew: hub $(hub2) switches sat $(swc sat .) pc $(swc pc .)"

# --- 4. vendor before rank: no switch while an able claude holds ------------------------
reset
login_expired pc 100 101 102
both 30000
for n in 30060 30120 30480 30900; do both "$n" LEASE_PRIORITY=pc,sat; done
[[ "$(hub2)" == "c-001@sat c-002@sat" && "$(logc pc 'takes over')" == 0 && "$(swc pc .)" == 0 ]] &&
  pass "4. pc ranked first, its claude dead: sat's able claude keeps both roles, pc launches no switch" || fail "4. hub $(hub2) pc switches $(swc pc .): $(cat "$T/pc/spool/dispatch/lease.log")"

# --- 5. hand back to claude ---------------------------------------------------------
reset
both 40000; login_expired sat 200 201 202; login_expired pc 100 101 102
for n in 40060 40120 40180 40240 40300 40360 40420; do both "$n"; done
[[ "$(hub2)" == "g-001@sat g-002@sat" ]] || fail "5. setup: hub $(hub2)"
back_to_claude pc 100 c-001; back_to_claude pc 101 c-002
both 40480 LEASE_HOLDDOWN=120; both 40540 LEASE_HOLDDOWN=120
[[ "$(hub2)" == "g-001@sat g-002@sat" && "$(logc pc 'HOLD orch: pc able 0s < LEASE_HOLDDOWN 120s: g-001@sat keeps it')" == 1 ]] &&
  pass "5. pc's seats back on claude: grok keeps both roles inside LEASE_HOLDDOWN" || fail "5. hold: hub $(hub2) $(cat "$T/pc/spool/dispatch/lease.log")"
both 40600 LEASE_HOLDDOWN=120
[[ "$(hub2)" == "c-001@pc c-002@pc" ]] &&
  pass "5. after LEASE_HOLDDOWN pc's claude (vendor before rank) takes both roles back from sat's grok" || fail "5. handback: hub $(hub2)"
both 40660 LEASE_HOLDDOWN=120; both 40720 LEASE_HOLDDOWN=120
[[ "$(sentc sat 'g-001 :: FLEET LEASE orch: STANDBY')" == 1 && "$(sentc pc 'c-001 :: FLEET LEASE orch: you are now ACTIVE')" == 1 &&
   "$(cut -d' ' -f1 "$T/sat/spool/dispatch/lease.orch")" == c-001@pc ]] &&
  pass "5. g-001 stood down (STANDBY), pc's c-001 told ACTIVE once" || fail "5. sent sat: $(cat "$T/sat/sent") pc: $(cat "$T/pc/sent")"
back_to_claude sat 200 c-001; back_to_claude sat 201 c-002
for n in 40780 40840 40900 40960; do both "$n" LEASE_HOLDDOWN=120; done
[[ "$(hub2)" == "c-001@sat c-002@sat" ]] &&
  pass "5. sat's claude back: the rank handback (unchanged) returns both roles to sat" || fail "5. rank: hub $(hub2)"

# --- 6. a claude seat on another box comes before the holder box's switch ----------------
reset
both 50000
login_expired sat 200 201 202
for n in 50060 50120 50180; do both "$n"; done
[[ "$(hub2)" == "c-001@sat c-002@sat" ]] || fail "6. early: hub $(hub2)"
for n in 50240 50300 50360 50420; do both "$n"; done
[[ "$(hub2)" == "c-001@pc c-002@pc" && "$(logc sat 'VENDOR')" == 0 && "$(swc sat .)" == 0 ]] &&
  pass "6. sat's claude dead, pc's able: pc's claude takes both at 181..240 s, sat never switches" || fail "6. hub $(hub2) switches $(swc sat .) $(cat "$T/sat/spool/dispatch/lease.log")"

# --- 7. agy, the third step -------------------------------------------------------------
reset
both 60000; both 60060
login_expired sat 200 201 202; login_expired pc 100 101 102
for n in 60120 60180 60240 60310; do both "$n" SWITCH_BAD=grok; done
[[ "$(swc sat '^orch c-001 -> g-001 silent=250$')" == 1 && "$(hubh orch)" == c-001@sat ]] &&
  pass "7. silent 250 s: the seat switched to grok, whose new session cannot act either (still c-001@sat)" || fail "7. grok step: hub $(hub2) $(cat "$T/sat/switches" 2>&1)"
both 60350 SWITCH_BAD=grok
[[ "$(swc sat '^orch g-001 -> a-001')" == 0 && "$(hubh orch)" == c-001@sat ]] &&
  pass "7. agy waits past 300 s (silent 290 s, grok cannot act: no g-001 -> a-001 yet)" || fail "7. early agy: $(cat "$T/sat/switches")"
both 60370 SWITCH_BAD=grok
[[ "$(swc sat '^orch g-001 -> a-001 silent=310$')" == 1 ]] &&
  pass "7. silent 310 s > LEASE_STALE + 2 x 60 s: the seat switches g-001 -> a-001 in place" || fail "7. agy switch: $(cat "$T/sat/switches")"
both 60430 SWITCH_BAD=grok
[[ "$(hubh orch)" == a-001@sat ]] &&
  pass "7. claude and grok cannot act anywhere: agy a-001@sat holds orch" || fail "7. hub $(hub2) $(cat "$T/sat/spool/dispatch/lease.log")"

# --- 8. an agy process counts -----------------------------------------------------------
agent pc 120 a-009 agy
got="$(env SRC="$SRC" LEASE_PROC_ROOT="$T/pc/proc" bash -c 'do_log() { :; }; source "$SRC"; spl_lease_agent_pid a-009' 2>&1)"
[[ "$got" == 120 ]] && pass "8. spl_lease_agent_pid finds the agy process" || fail "8. agy pid: '$got'"

# --- 9. the switch off; a failed switch retried after LEASE_SWITCH_RETRY -------------------
reset
both 70000; login_expired sat 200 201 202; login_expired pc 100 101 102
for n in 70060 70120 70180 70240 70300 70360 70420; do both "$n" LEASE_ROLE_SWITCH=0; done
[[ "$(swc sat .)" == 0 && "$(hub2)" == "c-001@sat c-002@sat" ]] &&
  pass "9. LEASE_ROLE_SWITCH=0: no switch launched" || fail "9. off: $(cat "$T/sat/switches" 2>&1)"
reset
both 80000; login_expired sat 200 201 202; login_expired pc 100 101 102
for n in 80060 80120 80180 80240 80300; do both "$n" SWITCH_FAIL=grok; done
[[ "$(swc sat '^orch c-001 -> g-001 silent=300$')" == 1 ]] || fail "9. first try: $(cat "$T/sat/switches" 2>&1)"
both 80360 SWITCH_FAIL=grok
[[ "$(swc sat '^orch c-001 -> g-001')" == 1 ]] && pass "9. a failed switch is not launched again inside LEASE_SWITCH_RETRY (120 s)" || fail "9. retry early: $(cat "$T/sat/switches")"
both 80420 SWITCH_FAIL=grok
[[ "$(swc sat '^orch c-001 -> g-001')" == 2 ]] && pass "9. ... and launched again once it has run" || fail "9. retry: $(cat "$T/sat/switches")"

# --- 10. SPL-2865 (a): a hub outage is no holder silence ----------------------------------
reset
both 90000; both 90060
login_expired sat 200 201 202; login_expired pc 100 101 102
for n in 90120 90180 90240 90300; do both "$n" HUB_DOWN=1; done
[[ "$(logc pc 'HUB-UNREACHABLE orch')" == 1 && "$(swc sat .)" == 0 && "$(swc pc .)" == 0 ]] || fail "10. setup: $(cat "$T/pc/spool/dispatch/lease.log")"
both 90360
[[ "$(swc sat .)" == 0 && "$(swc pc .)" == 0 && "$(hub2)" == "c-001@sat c-002@sat" ]] &&
  pass "10. the first read after the hub outage (holder silent 300 s, the hub down 90120..90300): no switch on either box" ||
  fail "10. switched at the outage's end: sat $(cat "$T/sat/switches" 2>&1) pc $(cat "$T/pc/switches" 2>&1)"
for n in 90420 90480 90540; do both "$n"; done
[[ "$(swc sat .)" == 0 && "$(swc pc .)" == 0 ]] &&
  pass "10. no switch while the silence since the last failed hub call (<= 240 s) is inside the wait" ||
  fail "10. early: sat $(cat "$T/sat/switches" 2>&1) pc $(cat "$T/pc/switches" 2>&1)"
both 90600
[[ "$(swc sat '^orch c-001 -> g-001')" == 1 && "$(swc pc '^orch c-001 -> g-001')" == 1 ]] &&
  pass "10. the holder still silent 300 s after the hub came back: the seats switch as before" ||
  fail "10. late: sat $(cat "$T/sat/switches" 2>&1) pc $(cat "$T/pc/switches" 2>&1)"

# --- 11. SPL-2892: a seat on a far-off limit hands the role over at once -----------------
# on_limit <machine> <now> <reset> <id>...: the watchdog's S2 kind=limit verdict
# (dispatch/wd.<id>) and the reset it read (dispatch/wd/<id>.limit)
on_limit() {
  local m="$1" now="$2" r="$3" id; shift 3
  mkdir -p "$T/$m/spool/dispatch/wd"
  for id in "$@"; do echo "HIT S2 $now" >"$T/$m/spool/dispatch/wd.$id"; echo "$r" >"$T/$m/spool/dispatch/wd/$id.limit"; done
}
reset
both 100000
[[ "$(hub2)" == "c-001@sat c-002@sat" ]] || fail "11. setup: hub $(hub2)"
on_limit sat 100060 $((100060 + 172800)) c-001 c-002 c-003
both 100060 SWITCH_FAIL=grok
[[ "$(hub2)" == "c-001@pc c-002@pc" ]] &&
  pass "11. RED CONTROL: sat's seats on a limit 2 days away, no vendor left: pc's able seats hold orch and dispatch in the same tick (was: the limited seat until stale, 181..240 s)" ||
  fail "11. handover: hub $(hub2) $(cat "$T/sat/spool/dispatch/lease.log")"
[[ "$(logc sat 'HANDOFF orch: c-001 cannot act until')" == 1 && "$(sentc pc 'c-001 :: FLEET LEASE orch: you are now ACTIVE')" == 1 && "$(swc sat .)" == 0 ]] &&
  pass "11. lease.log names the handoff; pc's c-001 is told ACTIVE; sat launched no switch" ||
  fail "11. log/sent: $(cat "$T/sat/spool/dispatch/lease.log") / $(cat "$T/pc/sent" 2>&1)"
reset
both 110000
on_limit sat 110060 $((110060 + 100)) c-001 c-002 c-003
both 110060
[[ "$(hub2)" == "c-001@sat c-002@sat" && "$(logc sat HANDOFF)" == 0 ]] &&
  pass "11. a limit that resets inside LEASE_STALE (100 s) moves nothing" || fail "11. short limit: hub $(hub2) $(cat "$T/sat/spool/dispatch/lease.log")"
reset
both 120000
for n in 120060 120120 120180; do
  on_limit sat "$n" $((120060 + 172800)) c-001 c-002 c-003; on_limit pc "$n" $((120060 + 172800)) c-001 c-002 c-003
  both "$n" SWITCH_FAIL=grok
done
[[ "$(hub2)" == "c-001@pc c-002@pc" && "$(logc sat 'HANDOFF orch')" == 1 && "$(logc pc HANDOFF)" == 0 ]] &&
  pass "11. both boxes on the limit: the row moves one hop (sat -> pc) and pc never hands it back" ||
  fail "11. ping-pong: hub $(hub2) sat $(logc sat HANDOFF) pc $(logc pc HANDOFF)"

# --- 12. SPL-2943: the second claude login is the last vendor step ----------------------
agent pc 130 c-007 claude
agent pc 131 c-008 claude
printf 'SPOOL_AGENT_ID=c-008\0CLAUDE_CONFIG_DIR=/x/.claude-2\0' >"$T/pc/proc/131/environ"
fl12() { env -u LEASE_VENDOR_ORDER -u LEASE_ORCH_FALLBACK SRC="$SRC" LEASE_PROC_ROOT="$T/pc/proc" bash -c 'do_log() { :; }; source "$SRC"; '"$1" 2>&1; }
got="$(fl12 'echo "$(spl_fleet_seat_vendor c-007) $(spl_fleet_seat_vendor c-008) $(spl_fleet_seat_vendor a-009)"')"
[[ "$got" == "claude claude2 agy" ]] && pass "12. the seat's vendor from its process: claude, claude2 (CLAUDE_CONFIG_DIR), agy" || fail "12. seat vendors: '$got'"
got="$(fl12 'echo "[$(spl_fleet_switch_next orch a-009)] [$(spl_fleet_switch_next orch c-008)] [$(spl_fleet_fallback orch)]"')"
[[ "$got" == "[claude2] [] [claude grok agy claude2]" ]] &&
  pass "12. after agy the next step is claude2; after claude2 no vendor is left" || fail "12. switch next: '$got'"

(( fails == 0 )) && { echo "PASS: all fleet-lease-vendor-failover.tst.sh assertions"; exit 0; }
echo "FAIL: $fails fleet-lease-vendor-failover.tst.sh assertion(s)"; exit 1
