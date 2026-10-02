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
#  14. a STALLED agent (CLE-77935: alive, "Usage limit reached" under a turn
#      frozen >= 45 s) is no candidate: pc's stalled master hands to pc's
#      failover; pc's whole trio stalled lets the lease go stale and the
#      satellite takes over; the banner under an idle line is able
#  15. take-over condition 2 (27f01e16): an orchestrator alive but STUCK (idle,
#      an inbox message newer than its last transcript write and > 600 s old)
#      is no candidate - the satellite takes the orch role 181 s later and the
#      owner gets ONE DM; a busy holder (fresh unread, or a turn in progress)
#      keeps it; LEASE_UNREAD_MAX=0 (the old rule) is the control; a dead
#      holder still fails over at 181 s (and DMs once); a handback DMs nobody
#  16. the lease in every served tenant (spec 059 S5 gap, c-043): the holder
#      copies each won write into every other tenant it serves (the hub
#      routes a post from its OWN tenant's row: csitea had none and fanned
#      out to both dispatcher boxes); the standby machine copies nothing; a
#      take-over moves the copies; a failing tenant is logged once and ends
#      that tick's copies; the tenant list is the desk pins minus the lease
#      tenant and the test workspaces
#  Fixtures only in a mktemp root: the test refuses to run where its roots
#  could reach the live /var/spool-hub.
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
mkdir -p "$T/bin" "$T/hub" "$T/pc/proc" "$T/sat/proc"

cat >"$T/bin/send" <<'STUB'
#!/usr/bin/env bash
to="" body=""
while [ $# -gt 0 ]; do case "$1" in --to) to="$2"; shift 2 ;; --body) body="$2"; shift 2 ;; *) shift ;; esac; done
echo "$to :: $body" >>"$SENT"
STUB
# The hub stub: one file per fleet+role, "holder gen at"; HUB_NOW is its clock.
# HUB_DOWN=1 fails every call; HUB_RACE=<holder> writes that holder first on a
# cas, as another machine winning the race would. A call to another tenant
# (LEASE_HUB_TENANT, the copies of section 16) has its own file
# <tenant>.<fleet>.<role>, is logged to calls, and HUB_DOWN_TENANT=<tenant>
# fails it.
cat >"$T/bin/hub" <<'STUB'
#!/usr/bin/env bash
[ "${HUB_DOWN:-0}" = 1 ] && { echo "dial: connection refused" >&2; exit 1; }
[ -n "${LEASE_HUB_TENANT:-}" ] && [ "$LEASE_HUB_TENANT" = "${HUB_DOWN_TENANT:-}" ] && { echo "dial: i/o timeout" >&2; exit 1; }
[ -n "${LEASE_HUB_TENANT:-}" ] && echo "$LEASE_HUB_TENANT" >>"$HUB_DIR/calls"
shift
fleet="" role="" holder="" ifgen=""
while [ $# -gt 0 ]; do case "$1" in --fleet) fleet="$2";; --role) role="$2";; --holder) holder="$2";; --if-gen) ifgen="$2";; esac; shift 2; done
f="$HUB_DIR/${LEASE_HUB_TENANT:+$LEASE_HUB_TENANT.}$fleet.$role"; h="" g=0 at=0
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
stall() { printf '%s\n❯ a\n────\n  ⚠ Usage limit reached · limit resets 7:20am\n  ⏵⏵ auto mode on\n' "${2:-✢ Cogitating… (12s · ↓ 214 tokens)}" >"$T/pane/$1"; }
tick pc 20000; tick sat 20000
stall 101; tick pc 20010
[[ "$(hubh dispatch)" == CLE-002@pc ]] && pass "14. a first sighting of the banner keeps the master" || fail "14. first: hub $(hubh dispatch)"
tick pc 20060
[[ "$(hubh dispatch)" == CLE-003@pc && "$(sentc pc 'CLE-003 :: FLEET LEASE dispatch: you are now ACTIVE')" == 1 ]] &&
  pass "14. pc's master stalled: pc's failover holds at once" || fail "14. hub $(hubh dispatch): $(cat "$T/pc/spool/dispatch/lease.log")"
stall 100; stall 102
tick pc 20070; tick pc 20120; tick pc 20180
[[ "$(logc pc 'NO-LOCAL-AGENT dispatch')" == 1 && "$(logc pc 'CLE-002: stalled pid=101: Usage limit reached')" -ge 1 ]] &&
  pass "14. pc's trio stalled: no local candidate, logged once with why" || fail "14. log: $(cat "$T/pc/spool/dispatch/lease.log")"
tick sat 20251
[[ "$(hubh dispatch)" == CLE-002@sat && "$(hubh orch)" == CLE-001@sat ]] &&
  pass "14. 181 s after the last renewal the satellite takes both roles" || fail "14. hub $(hubh dispatch)/$(hubh orch)"
stall 100 '✻ Brewed for 16s · done'; stall 101 '✻ Brewed for 16s · done'; rm -f "$T/pane/102"
tick pc 20300
[[ "$(hubh dispatch)" == CLE-002@pc && "$(hubh orch)" == CLE-001@pc ]] &&
  pass "14. turns done (banner still shown), pc takes both back on priority" || fail "14. hub $(hubh dispatch)/$(hubh orch)"

# --- 15. take-over condition 2: a stuck-but-alive orchestrator -------------------------
rm -rf "$T/pc" "$T/sat" "$T/hub" "$T/pane"; mkdir -p "$T/hub" "$T/pc/proc" "$T/sat/proc" "$T/pane" "$T/act"
agent pc 100 CLE-001; agent pc 101 CLE-002; agent pc 102 CLE-003
agent sat 200 CLE-001; agent sat 201 CLE-002; agent sat 202 CLE-003
# the last transcript write of pid N is $T/act/N (none = unknown, fails open)
printf '#!/usr/bin/env bash\ncat "%s/act/$1" 2>/dev/null\n' "$T" >"$T/bin/act"
printf '#!/usr/bin/env bash\ncat >>"%s/owner-dm"\n' "$T" >"$T/bin/owner"
chmod +x "$T/bin/act" "$T/bin/owner"
T15=(LEASE_ACTIVITY_CMD="$T/bin/act" LEASE_OWNER_CMD="$T/bin/owner")
idle() { printf '✻ Brewed for 16s\n❯ x\n────\n  ⏵⏵ auto mode on\n' >"$T/pane/$1"; }
busy() { printf '✢ Compiling… (%ss · ↓ 214 tokens)\n❯ \n────\n  ⏵⏵ auto mode on\n' "${2:-40}" >"$T/pane/$1"; }
msg() { mkdir -p "$T/$1/spool/$2/inbox"; touch -d "@$3" "$T/$1/spool/$2/inbox/$3--$2--m.json"; }
dms() { grep -c '^Orchestrator failover' "$T/owner-dm" 2>/dev/null || true; }
[[ "$T/pc/spool" != /var/spool-hub* && "$T/sat/spool" != /var/spool-hub* ]] || { echo "FAIL: 15. a fixture root is the live spool"; exit 1; }
idle 100; echo 30000 >"$T/act/100"
tick pc 30000 "${T15[@]}"; tick sat 30000 "${T15[@]}"
[[ "$(hubh orch)" == CLE-001@pc ]] && pass "15. pc's orchestrator holds orch (idle, inbox empty)" || fail "15. setup: hub $(hubh orch)"
# busy holder: a fresh unread (60 s) while it works, and an old one under a running turn
echo 30595 >"$T/act/100"; msg pc CLE-001 30540
tick pc 30600 "${T15[@]}"
[[ "$(hubh orch)" == CLE-001@pc && "$(logc pc 'NO-LOCAL-AGENT orch')" == 0 ]] &&
  pass "15. busy holder: a message read before its last activity keeps the lease" || fail "15. busy: $(cat "$T/pc/spool/dispatch/lease.log")"
msg pc CLE-001 30610; busy 100
tick pc 31300 "${T15[@]}"
[[ "$(hubh orch)" == CLE-001@pc && "$(logc pc 'NO-LOCAL-AGENT orch')" == 0 ]] &&
  pass "15. busy holder: a turn in progress (long tool call) keeps it despite an unread 690 s old" || fail "15. spinner: $(cat "$T/pc/spool/dispatch/lease.log")"
# stuck: idle, the unread from 30610 waits > 600 s
idle 100
tick pc 31200 "${T15[@]}" LEASE_UNREAD_MAX=600
[[ "$(hubh orch)" == CLE-001@pc ]] && pass "15. an unread 590 s old is not stuck yet" || fail "15. early: hub $(hubh orch)"
tick pc 31211 "${T15[@]}" LEASE_UNREAD_MAX=0
[[ "$(hubh orch)" == CLE-001@pc && "$(logc pc 'NO-LOCAL-AGENT orch')" == 0 ]] &&
  pass "15. control: LEASE_UNREAD_MAX=0 (the old, process-only rule) renews the stuck holder" || fail "15. control: $(cat "$T/pc/spool/dispatch/lease.log")"
tick pc 31212 "${T15[@]}"; tick pc 31272 "${T15[@]}"
[[ "$(logc pc 'NO-LOCAL-AGENT orch.*CLE-001: stuck pid=100: oldest unread 602s')" == 1 && "$(hubh dispatch)" == CLE-002@pc ]] &&
  pass "15. stuck holder: pc stops renewing orch (logged once, with why) and keeps dispatch" || fail "15. stuck: $(cat "$T/pc/spool/dispatch/lease.log")"
tick sat 31391 "${T15[@]}"
[[ "$(hubh orch)" == CLE-001@pc ]] && pass "15. the satellite waits the 180 s" || fail "15. sat early: hub $(hubh orch)"
tick sat 31392 "${T15[@]}"; tick sat 31450 "${T15[@]}"
[[ "$(hubh orch)" == CLE-001@sat && "$(hubh dispatch)" == CLE-002@pc && "$(sentc sat 'CLE-001 :: FLEET LEASE orch: you are now ACTIVE')" == 1 ]] &&
  pass "15. 181 s later the satellite's orchestrator takes orch over; dispatch stays on pc" || fail "15. takeover: hub $(hubh orch)/$(hubh dispatch): $(cat "$T/sat/spool/dispatch/lease.log")"
[[ "$(dms)" == 1 && "$(grep -c 'CLE-001@sat took over from CLE-001@pc, silent 181s' "$T/owner-dm")" == 1 && "$(logc sat 'OWNER-DM orch take-over')" == 1 ]] &&
  pass "15. the owner gets ONE DM for the take-over" || fail "15. dm: $(cat "$T/owner-dm" 2>&1)"
tick pc 31460 "${T15[@]}"
[[ "$(hubh orch)" == CLE-001@sat && "$(mirror pc orch)" == CLE-001@sat ]] &&
  pass "15. still stuck: pc does not take it back on priority" || fail "15. stuck handback: hub $(hubh orch)"
# it works again (the poke landed): its transcript grows past the unread -> handback, no DM
echo 31500 >"$T/act/100"
tick pc 31510 "${T15[@]}"; tick sat 31520 "${T15[@]}"
[[ "$(hubh orch)" == CLE-001@pc && "$(dms)" == 1 && "$(sentc sat 'CLE-001 :: FLEET LEASE orch: STANDBY')" == 1 ]] &&
  pass "15. active again: priority handback to pc, the owner is not DMed for a handback" || fail "15. handback: hub $(hubh orch) dms $(dms)"
# dead holder (rule 1, the control): still fails over at 181 s, one more DM
kill_agent pc 100
tick pc 31570 "${T15[@]}"; tick sat 31690 "${T15[@]}"
[[ "$(hubh orch)" == CLE-001@pc ]] && pass "15. dead holder: 180 s is not stale" || fail "15. dead early: hub $(hubh orch)"
tick sat 31691 "${T15[@]}"
[[ "$(hubh orch)" == CLE-001@sat && "$(dms)" == 2 ]] &&
  pass "15. dead holder: the satellite takes over at 181 s, one DM" || fail "15. dead: hub $(hubh orch) dms $(dms)"
# no owner leg: the take-over is logged with a WARN, nothing sent
rm -rf "$T/hub"/*; agent pc 100 CLE-001; echo 31700 >"$T/act/100"
tick pc 31700 LEASE_ACTIVITY_CMD="$T/bin/act"; kill_agent pc 100
tick sat 31900 LEASE_ACTIVITY_CMD="$T/bin/act" LEASE_OWNER= ASKS_OWNER=
[[ "$(hubh orch)" == CLE-001@sat && "$(logc sat 'WARN orch take-over by CLE-001@sat: no owner to tell')" == 1 && "$(dms)" == 2 ]] &&
  pass "15. no owner configured: one WARN, nothing sent" || fail "15. no owner: $(tail -3 "$T/sat/spool/dispatch/lease.log")"

# --- 16. the lease in every served tenant ------------------------------------------------
rm -rf "$T/pc" "$T/sat" "$T/hub" "$T/pane"; mkdir -p "$T/hub" "$T/pc/proc" "$T/sat/proc" "$T/pane"
agent pc 100 CLE-001; agent pc 101 CLE-002; agent pc 102 CLE-003
agent sat 200 CLE-001; agent sat 201 CLE-002; agent sat 202 CLE-003
T16=(LEASE_MIRROR_TENANTS="csitea leiden")
copy() { cut -d' ' -f"${3:-1}" "$T/hub/$1.main.$2" 2>/dev/null; }
tick pc 40000 "${T16[@]}"; tick sat 40000 "${T16[@]}"
[[ "$(hubh dispatch)" == CLE-002@pc && "$(copy csitea dispatch)" == CLE-002@pc && "$(copy leiden dispatch)" == CLE-002@pc &&
   "$(copy csitea orch)" == CLE-001@pc && "$(copy leiden orch)" == CLE-001@pc ]] &&
  pass "16. the holder copies both roles into every served tenant (csitea, leiden)" ||
  fail "16. copies csitea $(copy csitea dispatch)/$(copy csitea orch) leiden $(copy leiden dispatch)/$(copy leiden orch): $(tail -5 "$T/out")"
[[ "$(copy csitea dispatch 2)" == 1 ]] && pass "16. the standby machine copies nothing (gen 1 after both ticks)" || fail "16. standby wrote: gen $(copy csitea dispatch 2)"
tick pc 40060 "${T16[@]}"
[[ "$(copy csitea dispatch 2)" == 2 && "$(copy csitea dispatch 3)" == 40060 && "$(copy leiden orch 3)" == 40060 ]] &&
  pass "16. every renewal renews the copies (they go stale only with the holder)" || fail "16. renewal: $(cat "$T/hub/csitea.main.dispatch")"
tick sat 40241 "${T16[@]}"
[[ "$(hubh dispatch)" == CLE-002@sat && "$(copy csitea dispatch)" == CLE-002@sat && "$(copy leiden dispatch)" == CLE-002@sat &&
   "$(copy csitea orch)" == CLE-001@sat ]] &&
  pass "16. a take-over moves the copies to the new holder" || fail "16. take-over: csitea $(copy csitea dispatch) leiden $(copy leiden dispatch)"
: >"$T/hub/calls"
tick sat 40300 "${T16[@]}" HUB_DOWN_TENANT=csitea; tick sat 40360 "${T16[@]}" HUB_DOWN_TENANT=csitea
[[ "$(hubh dispatch)" == CLE-002@sat && "$(hubh dispatch | wc -l)" == 1 && "$(cut -d' ' -f3 "$T/hub/main.dispatch")" == 40360 &&
   "$(logc sat 'COPY-FAILED dispatch in csitea: dial: i/o timeout')" == 1 && "$(grep -c leiden "$T/hub/calls")" == 0 ]] &&
  pass "16. a failing tenant: logged once, ends the tick's copies, the lease itself still renews" ||
  fail "16. down: calls $(tr '\n' ' ' <"$T/hub/calls") log: $(grep COPY "$T/sat/spool/dispatch/lease.log")"
tick sat 40420 "${T16[@]}"
[[ "$(copy csitea dispatch 3)" == 40420 && "$(copy leiden dispatch 3)" == 40420 && "$(logc sat 'COPY dispatch in csitea: written again')" == 1 ]] &&
  pass "16. the tenant back: the copies are written again, logged once" || fail "16. back: $(grep COPY "$T/sat/spool/dispatch/lease.log")"
S="$T/state"
for p in t1/box-desk csitea/box-desk e2e/box-desk leiden/box-desk niba-consult/box-rsp acme-proof/box-desk; do mkdir -p "$S/desk/$p"; echo pinned >"$S/desk/$p/pinned"; done
: >"$S/desk/leiden/box-desk/pinned"
got=$(env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$T/pc/spool" SPL_STATE_DIR="$S" LEASE_DESK_BOX=box-desk LEASE_TENANT=t1 bash -c '
  do_log() { :; }; source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"; spl_lease_init; spl_fleet_mirror_tenants')
[[ "$got" == "csitea " ]] &&
  pass "16. served tenants = this box's desk pins, minus the lease tenant, test workspaces and empty pins" || fail "16. tenants: '$got'"

echo
(( fails == 0 )) && { echo "PASS: all fleet-lease.tst.sh assertions"; exit 0; }
echo "FAIL: $fails fleet-lease.tst.sh assertion(s)"; exit 1
