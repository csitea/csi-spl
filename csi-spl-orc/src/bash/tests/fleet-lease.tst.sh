#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_dispatch_lease FLEET MODE (CLE-77911, SPEC-spool-fleet-roles.md
#          section 4.2): ONE orchestrator and ONE master dispatcher across two
#          machines. Two machines are simulated (two spool roots, two fake
#          /proc trees); the hub is a stub with the real contract (`spool
#          lease`: read, compare-and-set on gen, age on the HUB's clock).
#   1. the preferred machine (pc) takes both roles; the satellite stands by
#   2. renewals change nothing and log nothing
#   3. pc silent: 180 s is not stale, 181 s is - the satellite takes over,
#      its agents are told ACTIVE once
#   4. pc returns: priority handback; the satellite's agents told STANDBY once
#   5. local order: pc's master dies -> pc's failover holds at once
#   6. priority flip is one config change (LEASE_PRIORITY=sat,pc)
#   7. a lost compare-and-set mirrors the real holder, never its own wish
#   8. hub unreachable past LEASE_STALE: the holder demotes itself locally
#   9. a machine with no live candidate never writes
#  10. the age is the hub's clock: a machine whose clock runs ahead does not
#      take over
#  11. ensure in fleet mode runs the fleet loop instead of renew + watch;
#      a machine missing from LEASE_PRIORITY is refused
#  11b. a lease.conf or desk-box-name change changes the loop version, so
#      ensure replaces a loop still running on the old settings
#  13. a note delivered without a poke (spool-send exit 1-9) is no WARN;
#      exit 10+ (nothing delivered) is
#  Both machines run CLE-001/002/003 (reserved on every box), so every holder
#  is <ID>@<box>; 12 checks a same-id holder on the other box is never read as
#  this machine's own.
#  12. a remote holder silences this machine's unanswered sweep and sends its
#      gap notes to its own orchestrator
#  14. a STALLED agent (CLE-77935: alive, pane on "Usage limit reached") is
#      no candidate: pc's stalled master hands to pc's failover; pc's whole
#      trio stalled lets the lease go stale and the satellite takes over
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
mkdir -p "$T/bin" "$T/hub" "$T/pc/proc" "$T/sat/proc"

cat >"$T/bin/send" <<'STUB'
#!/usr/bin/env bash
to="" body=""
while [ $# -gt 0 ]; do case "$1" in --to) to="$2"; shift 2 ;; --body) body="$2"; shift 2 ;; *) shift ;; esac; done
echo "$to :: $body" >>"$SENT"
STUB
# The hub stub: one file per fleet+role, "holder gen at"; HUB_NOW is its clock.
# HUB_DOWN=1 fails every call; HUB_RACE=<holder> writes that holder first on a
# cas, as another machine winning the race would.
cat >"$T/bin/hub" <<'STUB'
#!/usr/bin/env bash
[ "${HUB_DOWN:-0}" = 1 ] && { echo "dial: connection refused" >&2; exit 1; }
shift
fleet="" role="" holder="" ifgen=""
while [ $# -gt 0 ]; do case "$1" in --fleet) fleet="$2";; --role) role="$2";; --holder) holder="$2";; --if-gen) ifgen="$2";; esac; shift 2; done
f="$HUB_DIR/$fleet.$role"; h="" g=0 at=0
[ -s "$f" ] && read -r h g at <"$f"
if [ -n "$holder" ] && [ -n "${HUB_RACE:-}" ]; then g=$((g + 1)); h="$HUB_RACE"; at="$HUB_NOW"; echo "$h $g $at" >"$f"; fi
won=false
if [ -n "$holder" ] && [ "$ifgen" = "$g" ]; then g=$((g + 1)); h="$holder"; at="$HUB_NOW"; echo "$h $g $at" >"$f"; won=true; fi
age=-1; [ "$g" -gt 0 ] && age=$((HUB_NOW - at))
printf '{"fleet":"%s","role":"%s","holder":"%s","box":"b","gen":%s,"age_s":%s,"won":%s}\n' "$fleet" "$role" "$h" "$g" "$age" "$won"
STUB
# The pane stub (LEASE_PANE_CMD): the screen of pid N is $T/pane/N; none = able.
mkdir -p "$T/pane"
printf '#!/usr/bin/env bash\ncat "%s/pane/$1" 2>/dev/null\n' "$T" >"$T/bin/pane"
chmod +x "$T/bin/send" "$T/bin/hub" "$T/bin/pane"

# agent <machine> <pid> <id> / kill_agent <machine> <pid>
agent() { mkdir -p "$T/$1/proc/$2"; echo claude >"$T/$1/proc/$2/comm"; printf 'SPOOL_AGENT_ID=%s\0' "$3" >"$T/$1/proc/$2/environ"; }
kill_agent() { rm -rf "${T:?}/$1/proc/$2"; }

PRIO=pc,sat
# tick <machine> <hub-now> [env...]: one fleet tick on that machine
tick() {
  local m="$1" now="$2"; shift 2
  local ids=(LEASE_ORCH=CLE-001 LEASE_MASTER=CLE-002 LEASE_FAILOVER=CLE-003)
  [[ "$m" == sat ]] && ids=(LEASE_ORCH=CLE-001 LEASE_MASTER=CLE-002 LEASE_FAILOVER=CLE-003)
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$T/$m/spool" LEASE_PROC_ROOT="$T/$m/proc" LEASE_SEND="$T/bin/send" LEASE_PANE_CMD="$T/bin/pane" \
    SENT="$T/$m/sent" LEASE_HUB_CMD="$T/bin/hub" HUB_DIR="$T/hub" HUB_NOW="$now" LEASE_NOW="$now" \
    LEASE_FLEET=main LEASE_MACHINE="$m" LEASE_PRIORITY="$PRIO" "${ids[@]}" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    spl_lease_init && spl_lease_ids master failover orch && spl_fleet_ids && spl_fleet_hub_init && spl_lease_fleet_tick' >>"$T/out" 2>&1
}
mirror() { cut -d' ' -f1 "$T/$1/spool/dispatch/lease${2:+.$2}" 2>/dev/null; }
hubh() { cut -d' ' -f1 "$T/hub/main.$1" 2>/dev/null; }
sentc() { grep -c -- "$2" "$T/$1/sent" 2>/dev/null || true; }
logc() { grep -c -- "$2" "$T/$1/spool/dispatch/lease.log" 2>/dev/null || true; }

agent pc 100 CLE-001; agent pc 101 CLE-002; agent pc 102 CLE-003
agent sat 200 CLE-001; agent sat 201 CLE-002; agent sat 202 CLE-003

# --- 1. pc first ---------------------------------------------------------------
tick pc 1000; tick sat 1000
[[ "$(hubh dispatch)" == CLE-002@pc && "$(hubh orch)" == CLE-001@pc && "$(mirror pc)" == CLE-002@pc && "$(mirror pc orch)" == CLE-001@pc &&
   "$(mirror sat)" == CLE-002@pc && "$(mirror sat orch)" == CLE-001@pc ]] &&
  pass "1. pc holds both roles; the satellite mirrors pc as the holder" ||
  fail "1. hub $(hubh dispatch)/$(hubh orch) pc $(mirror pc)/$(mirror pc orch) sat $(mirror sat)/$(mirror sat orch): $(cat "$T/out")"
[[ "$(sentc pc 'CLE-002 :: FLEET LEASE dispatch: you are now ACTIVE')" == 1 && "$(sentc pc 'CLE-001 :: FLEET LEASE orch: you are now ACTIVE')" == 1 &&
   "$(sentc sat ACTIVE)" == 0 ]] &&
  pass "1. pc's agents told ACTIVE once; nobody on the satellite is" || fail "1. sent pc: $(cat "$T/pc/sent" 2>&1) sat: $(cat "$T/sat/sent" 2>&1)"
# CLE-001 50434b38: the asks to the orchestrator are the orchestrator's; the
# dispatcher's ACTIVE notice must not tell it to ack/close them
[[ "$(sentc pc 'CLE-002 :: FLEET LEASE dispatch: you are now ACTIVE.*do_spl_orch_inbox')" == 0 &&
   "$(sentc pc 'CLE-001 :: FLEET LEASE orch: you are now ACTIVE.*do_spl_orch_inbox: ack, then close each')" == 1 ]] &&
  pass "1. only the orchestrator's ACTIVE notice names the orchestrator's asks" || fail "1. asks line: $(cat "$T/pc/sent" 2>&1)"

# --- 2. renewals ----------------------------------------------------------------
n_pc=$(wc -l <"$T/pc/spool/dispatch/lease.log"); n_sat=$(wc -l <"$T/sat/spool/dispatch/lease.log")
tick pc 1060; tick sat 1060
[[ "$(wc -l <"$T/pc/spool/dispatch/lease.log")" == "$n_pc" && "$(wc -l <"$T/sat/spool/dispatch/lease.log")" == "$n_sat" &&
   "$(cut -d' ' -f2 "$T/hub/main.dispatch")" == 2 ]] &&
  pass "2. a renewal bumps gen and logs nothing on either machine" || fail "2. logs grew or gen wrong: $(cat "$T/hub/main.dispatch")"

# --- 3. pc silent: the satellite takes over after 180 s ------------------------------
tick sat 1240
[[ "$(hubh dispatch)" == CLE-002@pc ]] && pass "3. 180 s of silence is not stale" || fail "3. took over at 180 s: $(hubh dispatch)"
tick sat 1241
[[ "$(hubh dispatch)" == CLE-002@sat && "$(hubh orch)" == CLE-001@sat && "$(mirror sat)" == CLE-002@sat && "$(mirror sat orch)" == CLE-001@sat ]] &&
  pass "3. at 181 s the satellite's master and orchestrator take over" || fail "3. hub $(hubh dispatch)/$(hubh orch): $(cat "$T/sat/spool/dispatch/lease.log")"
tick sat 1300
[[ "$(sentc sat 'CLE-002 :: FLEET LEASE dispatch: you are now ACTIVE')" == 1 && "$(sentc sat 'CLE-001 :: FLEET LEASE orch: you are now ACTIVE')" == 1 &&
   "$(logc sat 'takes over from CLE-002@pc')" == 1 ]] &&
  pass "3. ACTIVE told once, the takeover logged once" || fail "3. sent: $(cat "$T/sat/sent")"

# --- 4. pc returns: handback ------------------------------------------------------
tick pc 1320
[[ "$(hubh dispatch)" == CLE-002@pc && "$(hubh orch)" == CLE-001@pc && "$(mirror pc)" == CLE-002@pc ]] &&
  pass "4. pc returns and takes both roles back on priority" || fail "4. hub $(hubh dispatch)/$(hubh orch)"
tick sat 1330; tick sat 1390
[[ "$(mirror sat)" == CLE-002@pc && "$(sentc sat 'CLE-002 :: FLEET LEASE dispatch: STANDBY')" == 1 &&
   "$(sentc sat 'CLE-001 :: FLEET LEASE orch: STANDBY')" == 1 && "$(hubh dispatch)" == CLE-002@pc ]] &&
  pass "4. the satellite's agents told STANDBY once and the satellite does not grab it back" || fail "4. sat mirror $(mirror sat) sent: $(cat "$T/sat/sent")"

# --- 5. local order ---------------------------------------------------------------
kill_agent pc 101
tick pc 1400
[[ "$(hubh dispatch)" == CLE-003@pc && "$(mirror pc)" == CLE-003@pc && "$(sentc pc 'CLE-003 :: FLEET LEASE dispatch: you are now ACTIVE')" == 1 ]] &&
  pass "5. pc's master gone: pc's failover holds at once, the fleet lease stays on pc" || fail "5. hub $(hubh dispatch)"
agent pc 111 CLE-002
tick pc 1460
[[ "$(hubh dispatch)" == CLE-002@pc && "$(sentc pc 'CLE-003 :: FLEET LEASE dispatch: STANDBY')" == 1 ]] &&
  pass "5. pc's master back: it holds again, the failover is told STANDBY" || fail "5. hub $(hubh dispatch)"

# --- 6. priority flip ------------------------------------------------------------
PRIO=sat,pc
tick sat 1470; tick pc 1480
[[ "$(hubh dispatch)" == CLE-002@sat && "$(hubh orch)" == CLE-001@sat && "$(mirror pc)" == CLE-002@sat ]] &&
  pass "6. LEASE_PRIORITY=sat,pc moves both roles to the satellite, pc stands by" || fail "6. hub $(hubh dispatch)/$(hubh orch)"
PRIO=pc,sat

# --- 7. a lost compare-and-set ---------------------------------------------------
tick pc 1490 HUB_RACE=CLE-003@sat
[[ "$(hubh dispatch)" == CLE-003@sat && "$(mirror pc)" == CLE-003@sat ]] &&
  pass "7. pc lost the race: it mirrors the real holder (CLE-003@sat), not its own wish" || fail "7. hub $(hubh dispatch) mirror $(mirror pc)"
tick pc 1500
[[ "$(hubh dispatch)" == CLE-002@pc ]] && pass "7. the next tick takes it on priority" || fail "7. hub $(hubh dispatch)"

# --- 8. hub unreachable ----------------------------------------------------------
tick pc 1600 HUB_DOWN=1
[[ "$(mirror pc)" == CLE-002@pc && "$(logc pc HUB-UNREACHABLE)" == 2 ]] &&
  pass "8. a short outage keeps the holder; logged once per role" || fail "8. mirror $(mirror pc): $(cat "$T/pc/spool/dispatch/lease.log")"
tick pc 1700 HUB_DOWN=1
[[ "$(mirror pc)" == none@unreachable && "$(sentc pc 'CLE-002 :: FLEET LEASE dispatch: STANDBY')" -ge 1 && "$(logc pc HUB-UNREACHABLE)" == 2 ]] &&
  pass "8. past LEASE_STALE without a renewal pc demotes itself (no double acting)" || fail "8. mirror $(mirror pc)"
tick pc 1710
[[ "$(mirror pc)" == CLE-002@pc && "$(hubh dispatch)" == CLE-002@pc ]] && pass "8. hub back: pc holds again" || fail "8. mirror $(mirror pc)"

# --- 9. no live candidate --------------------------------------------------------
kill_agent sat 200; kill_agent sat 201; kill_agent sat 202
g0=$(cut -d' ' -f2 "$T/hub/main.dispatch")
tick sat 9999
[[ "$(cut -d' ' -f2 "$T/hub/main.dispatch")" == "$g0" && "$(hubh dispatch)" == CLE-002@pc ]] &&
  pass "9. a machine with no live agent never writes, even over a stale lease" || fail "9. hub $(cat "$T/hub/main.dispatch")"

# --- 10. the hub's clock -----------------------------------------------------------
agent sat 201 CLE-002
tick sat 1720 LEASE_NOW=999999
[[ "$(hubh dispatch)" == CLE-002@pc ]] && pass "10. a satellite clock far ahead does not make pc stale (hub age decides)" || fail "10. hub $(hubh dispatch)"

# --- 11. ensure in fleet mode -------------------------------------------------------
E="$T/e"; mkdir -p "$E/spool/dispatch"
printf 'LEASE_MASTER=CLE-002\nLEASE_FAILOVER=CLE-003\nLEASE_ORCH=CLE-001\nLEASE_FLEET=main\nLEASE_MACHINE=pc\nLEASE_PRIORITY=pc,sat\n' >"$E/spool/dispatch/lease.conf"
cat >"$T/bin/run" <<'STUB'
#!/usr/bin/env bash
echo "$LEASE_CMD $LEASE_FLEET $LEASE_MACHINE $LEASE_PRIORITY" >>"$RUNLOG"; exec 8>"$SPOOL_ROOT/dispatch/$LEASE_CMD.run"; flock -n 8 || exit 0
echo $$ >"$SPOOL_ROOT/dispatch/$LEASE_CMD.pid"; sleep 30
STUB
chmod +x "$T/bin/run"
ens() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$E/spool" LEASE_RUN="$T/bin/run" RUNLOG="$E/runlog" LEASE_ALLOW_STALE=1 "$@" bash -c '
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    spl_lease_init && LEASE_CMD=ensure do_spl_dispatch_lease' >>"$T/out" 2>&1
}
ens; sleep 1
[[ "$(cat "$E/runlog" 2>/dev/null)" == "fleet main pc pc,sat" ]] &&
  pass "11. ensure starts ONE fleet loop with the conf's fleet settings (no renew, no watch)" || fail "11. runlog: $(cat "$E/runlog" 2>&1)"
env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$E/spool" bash -c 'do_log() { :; }; source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"; spl_lease_init; LEASE_CMD=stop do_spl_dispatch_lease' >/dev/null 2>&1
out=$(env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$E/spool" LEASE_MACHINE=other LEASE_HUB_CMD="$T/bin/hub" bash -c '
  do_log() { echo "$*"; }; source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"; spl_lease_init; LEASE_CMD=fleet do_spl_dispatch_lease' 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"not in LEASE_PRIORITY"* ]] &&
  pass "11. a machine missing from LEASE_PRIORITY is refused" || fail "11. rc=$rc out=$out"

# --- 11b. a lease.conf or box-name change makes ensure replace the loop ----------------
ver() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$E/spool" SPOOL_BOX_ENV=/nonexistent "$@" bash -c '
    do_log() { :; }; source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"; spl_lease_init ro; spl_lease_code_ver'
}
v1=$(ver SPOOL_DESK_BOX=box-desk)
sed -i 's/^LEASE_PRIORITY=.*/LEASE_PRIORITY=hom,box-desk,sat/' "$E/spool/dispatch/lease.conf"
v2=$(ver SPOOL_DESK_BOX=box-desk); v3=$(ver SPOOL_DESK_BOX=hom)
[[ -n "$v1" && "$v1" != "$v2" && "$v2" != "$v3" && "$(ver SPOOL_DESK_BOX=box-desk)" == "$v2" ]] &&
  pass "11b. the loop version changes with lease.conf and with the desk box name (ensure then replaces it)" || fail "11b. versions $v1 / $v2 / $v3"

# --- 13. a delivered note whose poke did not ring is not a WARN ----------------------
printf '#!/usr/bin/env bash\nexit "$SEND_RC"\n' >"$T/bin/send-rc"; chmod +x "$T/bin/send-rc"
tellrc() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$T/w/spool" LEASE_SEND="$T/bin/send-rc" SEND_RC="$1" LEASE_ORCH=CLE-001 bash -c '
    do_log() { :; }; source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"; spl_lease_init; spl_lease_tell CLE-002 hi'
  cat "$T/w/spool/dispatch/lease.log" 2>/dev/null | grep -c WARN
}
mkdir -p "$T/w/spool"
[[ "$(tellrc 6)" == 0 ]] && pass "13. exit 6 (delivered, pane busy) logs no WARN" || fail "13. exit 6 warned"
[[ "$(tellrc 11)" == 1 ]] && pass "13. exit 11 (nothing delivered) logs a WARN" || fail "13. exit 11 not warned"

# --- 12. remote holder: the standby machine's sweep, tick and check --------------
R="$T/r"; mkdir -p "$R/spool/dispatch"
printf 'LEASE_MASTER=CLE-002\nLEASE_FAILOVER=CLE-003\nLEASE_ORCH=CLE-001\nLEASE_FLEET=main\nLEASE_MACHINE=pc\n' >"$R/spool/dispatch/lease.conf"
rem() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$R/spool" LEASE_NOW=5000 "$@" bash -c '
    do_log() { echo "$*"; }
    for f in spl-dispatch-lease spl-unanswered-sweep spl-dispatch-tick spl-dispatch-check; do source "$PROJ_PATH/src/bash/run/$f.func.sh"; done
    spl_sweep_rows() { echo "SWEEP-READ-ROWS"; return 1; }
    spl_lease_init ro; spl_lease_conf; eval "$CALL"' 2>&1
}
echo "CLE-002@sat 4990" >"$R/spool/dispatch/lease"
out=$(rem ENV=prd DELIVER=1 CALL=do_spl_unanswered_sweep); rc=$?
[[ $rc -eq 0 && "$out" == *"held by CLE-002@sat"* && "$out" != *SWEEP-READ-ROWS* ]] &&
  pass "12. remote holder: DELIVER=1 sweep sends nothing (no double delivery)" || fail "12. sweep rc=$rc: $out"
[[ "$(rem CALL=_spl_dispatch_tick_holder)" == CLE-001 ]] &&
  pass "12. remote holder: this machine's gap notes go to its own orchestrator" || fail "12. tick holder: $(rem CALL=_spl_dispatch_tick_holder)"
echo "CLE-002@pc 4990" >"$R/spool/dispatch/lease"
[[ "$(rem CALL=_spl_dispatch_tick_holder)" == CLE-002 ]] &&
  pass "12. local holder: gap notes go to it as before" || fail "12. local tick holder"
# --- 14. a stalled agent is no candidate ----------------------------------------------
rm -rf "$T/pc" "$T/sat" "$T/hub"; mkdir -p "$T/hub" "$T/pc/proc" "$T/sat/proc"
agent pc 100 CLE-001; agent pc 101 CLE-002; agent pc 102 CLE-003
agent sat 200 CLE-001; agent sat 201 CLE-002; agent sat 202 CLE-003
stall() { printf '❯ a\n────\n  ⚠ Usage limit reached · limit resets 7:20am\n  ⏵⏵ auto mode on\n' >"$T/pane/$1"; }
tick pc 20000; tick sat 20000
stall 101
tick pc 20060
[[ "$(hubh dispatch)" == CLE-003@pc && "$(sentc pc 'CLE-003 :: FLEET LEASE dispatch: you are now ACTIVE')" == 1 ]] &&
  pass "14. pc's master stalled: pc's failover holds at once" || fail "14. hub $(hubh dispatch): $(cat "$T/pc/spool/dispatch/lease.log")"
stall 100; stall 102
tick pc 20120; tick pc 20180
[[ "$(logc pc 'NO-LOCAL-AGENT dispatch')" == 1 && "$(logc pc 'CLE-002: stalled pid=101: Usage limit reached')" -ge 1 ]] &&
  pass "14. pc's trio stalled: no local candidate, logged once with why" || fail "14. log: $(cat "$T/pc/spool/dispatch/lease.log")"
tick sat 20241
[[ "$(hubh dispatch)" == CLE-002@sat && "$(hubh orch)" == CLE-001@sat ]] &&
  pass "14. 181 s later the satellite takes both roles" || fail "14. hub $(hubh dispatch)/$(hubh orch)"
rm -f "$T/pane/100" "$T/pane/101" "$T/pane/102"
tick pc 20300
[[ "$(hubh dispatch)" == CLE-002@pc && "$(hubh orch)" == CLE-001@pc ]] &&
  pass "14. the notices gone, pc takes both back on priority" || fail "14. hub $(hubh dispatch)/$(hubh orch)"

echo
(( fails == 0 )) && { echo "PASS: all fleet-lease.tst.sh assertions"; exit 0; }
echo "FAIL: $fails fleet-lease.tst.sh assertion(s)"; exit 1
