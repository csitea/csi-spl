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
#  6b. LEASE_PRIORITY_ORCH ranks the orch role on its own; unset = LEASE_PRIORITY
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
#  17. a dispatch seat STUCK the same way (t1 865b7a05): pc's master idle with
#      an unread > 600 s is no candidate, pc's failover holds dispatch at once
#  18. the 2026-10-03 satellite (t1 865b7a05): sat ranked first holds both
#      roles, its whole trio sits IDLE on "Usage limit reached · resets
#      10:50am" -> sat stops renewing, pc takes both roles 181 s later; after
#      the reset (banner still shown) sat takes them back on rank
#  19. spec 092, a box losing power is routine, N = 3 boxes: the box ranked
#      first powers off, the next holds both roles at 181 s; back with no desk
#      sidecar it takes nothing (FR-002), a session drop restarts the
#      LEASE_HOLDDOWN clock, each role comes back only after 300 s able; a
#      restarted sidecar with no session up since fails dispatch over; a box in
#      LEASE_INTERMITTENT never hands back by rank, only on stale; CONTROL:
#      LEASE_DESK_GATE=0 LEASE_HOLDDOWN=0 hands back at once (the old rule).
#      The older sections run with LEASE_HOLDDOWN=0 (the tick helper).
#  20. spec 093 FR-000, the 2026-10-05 login-expired orchestrator: its pane
#      ("Login expired · Please run /login", no spinner, no reset) with an
#      API-error last entry is not able on the first tick, the standby box
#      takes orch at 181 s; CONTROLS: the pre-093 spl_lease_stall is able on
#      the same fixture, the same pane after a good turn is able; a usage
#      limit with a reset time is as before; the pokes and their error replies
#      are not activity, so the ask behind them is stuck.
#  21. spec 093 T006: the lease reads the watchdog's dispatch/wd.<id>: a HIT
#      at most 90 s old is not able ("wd <code>"), the standby box takes orch
#      at 181 s; an OK, a stale HIT, a garbled file or no file are as before.
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
    LEASE_FLEET=main LEASE_MACHINE="$m" LEASE_PRIORITY="$PRIO" LEASE_LIMIT_TZ=Etc/GMT-3 LEASE_HOLDDOWN=0 "${ids[@]}" "$@" bash -c '
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

# --- 6b. a per-role ranking (t1 aad0e6cf: the orch prefers the satellite) --------
tick pc 1482 LEASE_PRIORITY_ORCH=sat,pc; tick sat 1484 LEASE_PRIORITY_ORCH=sat,pc
[[ "$(hubh dispatch)" == CLE-002@pc && "$(hubh orch)" == CLE-001@sat && "$(mirror pc orch)" == CLE-001@sat ]] &&
  pass "6b. LEASE_PRIORITY_ORCH=sat,pc: the satellite keeps orch, pc takes dispatch back on LEASE_PRIORITY" ||
  fail "6b. per-role: hub $(hubh dispatch)/$(hubh orch)"
tick pc 1486
[[ "$(hubh dispatch)" == CLE-002@pc && "$(hubh orch)" == CLE-001@pc ]] &&
  pass "6b. control: no per-role key, LEASE_PRIORITY ranks orch too (pc takes it back)" || fail "6b. control: hub $(hubh dispatch)/$(hubh orch)"

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

# --- 17. a stuck dispatch seat is no candidate --------------------------------------------
rm -rf "$T/pc" "$T/sat" "$T/hub" "$T/pane" "$T/act"; mkdir -p "$T/hub" "$T/pc/proc" "$T/sat/proc" "$T/pane" "$T/act"
agent pc 100 CLE-001; agent pc 101 CLE-002; agent pc 102 CLE-003
agent sat 200 CLE-001; agent sat 201 CLE-002; agent sat 202 CLE-003
T17=(LEASE_ACTIVITY_CMD="$T/bin/act" LEASE_OWNER_CMD="$T/bin/owner")
idle 101; idle 102; echo 40000 >"$T/act/101"; echo 40000 >"$T/act/102"
tick pc 40000 "${T17[@]}"
[[ "$(hubh dispatch)" == CLE-002@pc ]] && pass "17. pc's master holds dispatch" || fail "17. setup: hub $(hubh dispatch)"
msg pc CLE-002 40010
tick pc 40611 "${T17[@]}"
[[ "$(hubh dispatch)" == CLE-003@pc && "$(sentc pc 'CLE-003 :: FLEET LEASE dispatch: you are now ACTIVE')" == 1 ]] &&
  pass "17. master idle with an unread 601 s old: pc's failover holds dispatch at once" || fail "17. stuck: hub $(hubh dispatch): $(cat "$T/pc/spool/dispatch/lease.log")"
grep -q '^stuck pid=101: oldest unread 601s' "$T/pc/spool/dispatch/able.CLE-002" &&
  pass "17. able.CLE-002 says why" || fail "17. able: $(cat "$T/pc/spool/dispatch/able.CLE-002")"

# --- 18. the 2026-10-03 satellite: every seat idle at its usage limit -----------------------
rm -rf "$T/pc" "$T/sat" "$T/hub" "$T/pane" "$T/act"; mkdir -p "$T/hub" "$T/pc/proc" "$T/sat/proc" "$T/pane" "$T/act"
agent pc 100 CLE-001; agent pc 101 CLE-002; agent pc 102 CLE-003
agent sat 200 CLE-001; agent sat 201 CLE-002; agent sat 202 CLE-003
limited() { printf '❯ [poke] status?\n  ⎿  Usage limit reached · resets 10:50am\n\n────\n❯ \n────\n  ⏵⏵ auto mode on\n' >"$T/pane/$1"; }
N=1791007200
PRIO=sat,pc
tick sat $N; tick pc $N
[[ "$(hubh orch)" == CLE-001@sat && "$(hubh dispatch)" == CLE-002@sat ]] && pass "18. sat ranked first holds both roles" || fail "18. setup: $(hubh orch)/$(hubh dispatch)"
limited 200; limited 201; limited 202
tick sat $((N + 60)); tick pc $((N + 60)); tick sat $((N + 120))
[[ "$(logc sat 'NO-LOCAL-AGENT orch')" == 1 && "$(logc sat 'NO-LOCAL-AGENT dispatch')" == 1 && "$(logc sat 'CLE-002: stalled pid=201: Usage limit reached, resets in')" -ge 1 ]] &&
  pass "18. sat's trio at the limit: sat stops renewing both roles, logged once with why" || fail "18. sat log: $(cat "$T/sat/spool/dispatch/lease.log")"
tick pc $((N + 181))
[[ "$(hubh orch)" == CLE-001@pc && "$(hubh dispatch)" == CLE-002@pc ]] &&
  pass "18. 181 s after sat's last renewal pc takes both roles" || fail "18. takeover: $(hubh orch)/$(hubh dispatch): $(cat "$T/pc/spool/dispatch/lease.log")"
tick sat $((N + 6660)); tick pc $((N + 6670))
[[ "$(hubh orch)" == CLE-001@sat && "$(hubh dispatch)" == CLE-002@sat ]] &&
  pass "18. reset passed (banner still shown): sat takes both back on rank" || fail "18. restore: $(hubh orch)/$(hubh dispatch)"
PRIO=pc,sat

# --- 19. spec 092: a box losing power is routine (N boxes, desk gate, hold-down) --------
# Three boxes: lap (a laptop, ranked first) and two always-on boxes cl1, cl2.
# The desk of each box is LEASE_DESK_DIR=$T/<box>/desk: hub-run.pid, a fake
# /proc cmdline "spool hub-run", and hub-run.log session lines stamped at <t>.
rm -rf "$T/pc" "$T/sat" "$T/hub" "$T/pane" "$T/act"; mkdir -p "$T/hub" "$T/pane"
PRIO=lap,cl1,cl2
INT=""
trio() { mkdir -p "$T/$1/proc"; agent "$1" "$2"0 CLE-001; agent "$1" "$2"1 CLE-002; agent "$1" "$2"2 CLE-003; }
# desk_start <box> <pid> <t>: a sidecar started at <t>, no session yet
desk_start() {
  local h="$T/$1/desk/spool/.hub"; mkdir -p "$h" "$T/$1/proc/$2"
  printf 'spool\0hub-run\0' >"$T/$1/proc/$2/cmdline"; echo "$2" >"$h/hub-run.pid"; touch -d "@$3" "$h/hub-run.pid"
}
# desk_log <box> <t> <up|down>: one session line, console format with colour
desk_log() {
  printf '\033[90m%s\033[0m \033[32mINF\033[0m \033[1mhub session %s\033[0m box=%s component=hubclient\n' \
    "$(date -u -d "@$2" +%FT%T+00:00)" "$3" "$1" >>"$T/$1/desk/spool/.hub/hub-run.log"
}
t19() { local m="$1" n="$2"; shift 2; tick "$m" "$n" LEASE_DESK_DIR="$T/$m/desk" LEASE_HOLDDOWN=300 LEASE_INTERMITTENT="$INT" "$@"; }
both() { [[ "$(hubh orch)" == "CLE-001@$1" && "$(hubh dispatch)" == "CLE-002@$1" ]]; }
N=1791200000
trio lap 30; trio cl1 31; trio cl2 32
desk_start lap 309 $N; desk_log lap $((N + 1)) up
desk_start cl1 319 $N; desk_log cl1 $((N + 1)) up
desk_start cl2 329 $N; desk_log cl2 $((N + 1)) up
t19 lap $((N + 10)); t19 cl1 $((N + 10)); t19 cl2 $((N + 10))
both lap && pass "19. three boxes, lap ranked first and healthy: lap holds both roles" || fail "19. setup: $(hubh orch)/$(hubh dispatch)"

# lap loses power: nothing of it ticks; cl1 (next by rank) holds both 181 s later, no human step
rm -rf "${T:?}/lap/proc"
t19 cl1 $((N + 60)); t19 cl2 $((N + 60)); t19 cl1 $((N + 191)); t19 cl2 $((N + 191))
both cl1 && pass "19. FR-001: lap powered off, cl1 holds both roles at 181 s, cl2 stands by" || fail "19. failover: $(hubh orch)/$(hubh dispatch)"

# lap boots: agents back, desk sidecar not yet up
trio lap 40
t19 cl1 $((N + 600)); t19 lap $((N + 600))
both cl1 && pass "19. lap back with no desk sidecar: it takes nothing" || fail "19. no desk: $(hubh orch)/$(hubh dispatch)"
grep -q '^desk: no hub-run sidecar' "$T/lap/spool/dispatch/able.CLE-002" &&
  pass "19. FR-002: able.CLE-002 says the desk is why" || fail "19. able: $(cat "$T/lap/spool/dispatch/able.CLE-002" 2>&1)"
[[ "$(logc lap 'HOLD orch: lap able 0s < LEASE_HOLDDOWN 300s')" == 1 ]] &&
  pass "19. the orch hand back is held, logged once" || fail "19. hold log: $(cat "$T/lap/spool/dispatch/lease.log")"

# the sidecar comes up (its session says up), then drops once and comes back: the clock restarts
desk_start lap 409 $((N + 695)); desk_log lap $((N + 700)) up
t19 cl1 $((N + 700)); t19 lap $((N + 700))
desk_log lap $((N + 800)) down
t19 cl1 $((N + 800)); t19 lap $((N + 800))
grep -q '^desk: session not up' "$T/lap/spool/dispatch/able.CLE-002" &&
  pass "19. a session down is no candidate" || fail "19. down: $(cat "$T/lap/spool/dispatch/able.CLE-002")"
desk_log lap $((N + 810)) up
t19 cl1 $((N + 810)); t19 lap $((N + 810))
t19 cl1 $((N + 899)); t19 lap $((N + 899))
both cl1 && pass "19. able 299 s (orch) / 89 s (dispatch): still held" || fail "19. 899: $(hubh orch)/$(hubh dispatch)"
t19 cl1 $((N + 900)); t19 lap $((N + 900))
[[ "$(hubh orch)" == CLE-001@lap && "$(hubh dispatch)" == CLE-002@cl1 ]] &&
  pass "19. FR-001: orch able 300 s -> lap takes it back; dispatch (desk drop restarted its clock) stays" || fail "19. 900: $(hubh orch)/$(hubh dispatch)"
t19 cl1 $((N + 1000)); t19 lap $((N + 1000)); t19 cl1 $((N + 1100)); t19 lap $((N + 1100))
[[ "$(hubh dispatch)" == CLE-002@cl1 ]] && pass "19. dispatch able 290 s since the drop: held" || fail "19. 1100: $(hubh dispatch)"
t19 cl1 $((N + 1110)); t19 lap $((N + 1110))
both lap && pass "19. dispatch able 300 s since the drop: lap takes it back" || fail "19. 1110: $(hubh orch)/$(hubh dispatch)"

# a holder whose sidecar restarts with no session since stops renewing; cl1 takes dispatch on stale
desk_start lap 509 $((N + 1200))
t19 lap $((N + 1200)); t19 cl1 $((N + 1200))
[[ "$(logc lap 'NO-LOCAL-AGENT dispatch: .*desk: sidecar pid=509 (re)started, no session up since')" == 1 ]] &&
  pass "19. FR-002: a restarted sidecar with no session up since is not able, logged once" || fail "19. restart: $(cat "$T/lap/spool/dispatch/able.CLE-002") / $(cat "$T/lap/spool/dispatch/lease.log")"
t19 lap $((N + 1260)); t19 cl1 $((N + 1381))
[[ "$(hubh orch)" == CLE-001@lap && "$(hubh dispatch)" == CLE-002@cl1 ]] &&
  pass "19. lap's desk cannot post: dispatch fails over to cl1 at 181 s, orch stays" || fail "19. desk failover: $(hubh orch)/$(hubh dispatch)"

# an intermittent lap never takes a role back by rank, only on stale
rm -rf "$T/hub" "$T/lap/spool" "$T/cl1/spool" "$T/cl2/spool"; mkdir -p "$T/hub"
INT=lap
rm -rf "${T:?}/lap/proc"; t19 cl1 $N
trio lap 30; desk_start lap 309 $N; desk_log lap $((N + 1)) up
for k in 10 400 1000; do t19 cl1 $((N + k)); t19 lap $((N + k)); done
both cl1 && [[ "$(logc lap 'HOLD orch: lap is intermittent')" == 1 && "$(logc lap 'HOLD dispatch: lap is intermittent')" == 1 ]] &&
  pass "19. FR-001: LEASE_INTERMITTENT=lap healthy 1000 s: takes nothing back, logged once per role" || fail "19. intermittent: $(hubh orch)/$(hubh dispatch): $(cat "$T/lap/spool/dispatch/lease.log")"
t19 lap $((N + 1181))
both lap && pass "19. the intermittent lap still takes both when cl1 goes stale" || fail "19. intermittent stale: $(hubh orch)/$(hubh dispatch)"

# CONTROL: gate off, no hold-down, not intermittent = the old rule - lap with NO desk takes both at once
rm -rf "$T/hub" "$T/lap/spool" "$T/cl1/spool"; mkdir -p "$T/hub"
INT=""
rm -rf "${T:?}/lap/proc"; t19 cl1 $N
trio lap 30
t19 lap $((N + 10)) LEASE_DESK_GATE=0 LEASE_HOLDDOWN=0
both lap && pass "19. CONTROL: LEASE_DESK_GATE=0 LEASE_HOLDDOWN=0 hands back at once with no desk (the old rule)" || fail "19. control: $(hubh orch)/$(hubh dispatch)"
PRIO=pc,sat

# --- 20. spec 093 FR-000: the 2026-10-05 login-expired orchestrator ------------------------
# c-001@sat answered every poke with "Login expired · Please run /login" for ~6 h:
# idle, no spinner, no reset time, and each poke wrote a prompt + an API-error
# reply to its transcript. Fixtures: that pane, that transcript, and the same
# session after a good turn; the pre-093 spl_lease_stall is the control.
FX="$TEST_DIR/fixtures/fleet-lease"
rm -rf "$T/pc" "$T/sat" "$T/hub" "$T/pane" "$T/tr"; mkdir -p "$T/hub" "$T/pc/proc" "$T/sat/proc" "$T/pane" "$T/tr"
agent pc 100 CLE-001; agent pc 101 CLE-002; agent pc 102 CLE-003
agent sat 200 CLE-001; agent sat 201 CLE-002; agent sat 202 CLE-003
# the transcript of pid N is $T/tr/N (LEASE_TRANSCRIPT_CMD; none = unknown)
printf '#!/usr/bin/env bash\ncat "%s/tr/$1" 2>/dev/null\n' "$T" >"$T/bin/tr"; chmod +x "$T/bin/tr"
T20=(LEASE_TRANSCRIPT_CMD="$T/bin/tr")
# unit <fn> "<args>" [env...]: one call of a lease function on pc's fixtures
unit() {
  local fn="$1" args="$2"; shift 2
  env PROJ_PATH="$PROJ_ROOT" FX="$FX" SPOOL_ROOT="$T/pc/spool" LEASE_PROC_ROOT="$T/pc/proc" LEASE_PANE_CMD="$T/bin/pane" \
    LEASE_TRANSCRIPT_CMD="$T/bin/tr" LEASE_LIMIT_TZ=Etc/GMT-3 "$@" bash -c '
    do_log() { :; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"; source "$FX/spl-lease-stall-pre-093.sh"
    # shellcheck disable=SC2086 # the args, split on purpose
    spl_lease_init && "$0" $1' "$fn" "$args" 2>&1
}
login() { cp "$FX/login-expired-2026-10-05.pane" "$T/pane/$1"; cp "$FX/${2:-login-expired}.jsonl" "$T/tr/$1"; }
login 100
got="$(unit spl_lease_stall 100)"
[[ "$got" == "Please run /login, no spinner" ]] &&
  pass "20. login expired, no spinner, last entry an API error: stalled ($got)" || fail "20. login: '$got'"
got="$(unit spl_lease_stall_pre093 100)"
[[ -z "$got" ]] && pass "20. CONTROL: the pre-093 spl_lease_stall returns able on the same fixture" || fail "20. control pre-093: '$got'"
login 100 good-turn
got="$(unit spl_lease_stall 100)"
[[ -z "$got" ]] && pass "20. CONTROL: the same pane after a good turn (a stale banner) is able" || fail "20. good turn: '$got'"
rm -f "$T/tr/100"
got="$(unit spl_lease_stall 100)"
[[ "$got" == "Please run /login, no spinner" ]] && pass "20. the banner with no readable transcript is a stall" || fail "20. no transcript: '$got'"
# a usage-limit banner WITH a reset time behaves as before 093, whatever the transcript says
N=1791007200
printf '❯ [poke] status?\n  ⎿  Usage limit reached · resets 10:50am\n\n────\n❯ \n────\n  ⏵⏵ auto mode on\n' >"$T/pane/100"
cp "$FX/login-expired.jsonl" "$T/tr/100"
a="$(unit spl_lease_stall 100 LEASE_NOW=$((N + 60)))"; b="$(unit spl_lease_stall_pre093 100 LEASE_NOW=$((N + 60)))"
[[ "$a" == "Usage limit reached, resets in"* && "$a" == "$b" ]] &&
  pass "20. usage limit, reset ahead: stalled, same as pre-093 ($a)" || fail "20. limit ahead: new '$a' pre-093 '$b'"
a="$(unit spl_lease_stall 100 LEASE_NOW=$((N + 6660)))"; b="$(unit spl_lease_stall_pre093 100 LEASE_NOW=$((N + 6660)))"
[[ -z "$a" && -z "$b" ]] && pass "20. usage limit, reset passed (stale banner): able, same as pre-093" || fail "20. limit passed: new '$a' pre-093 '$b'"
# activity: the pokes' prompts and their API-error replies are not activity
t_good=$(date -ud 2026-10-05T12:38:20Z +%s); t_after=$(date -ud 2026-10-05T18:41:09Z +%s); t_first=$(date -ud 2026-10-05T12:38:20Z +%s)
login 100
got="$(unit spl_lease_activity 100)"
[[ "$got" == "$t_good" ]] && pass "20. activity = the last good reply (12:38:20Z), not the 18:31Z poke" || fail "20. activity: '$got' want $t_good"
login 100 good-turn
got="$(unit spl_lease_activity 100)"
[[ "$got" == "$t_after" ]] && pass "20. CONTROL: a good turn after /login moves the activity (18:41:09Z)" || fail "20. activity good: '$got' want $t_after"
grep -v -e '"tool_result"' -e '"claude-opus"' "$FX/login-expired.jsonl" >"$T/tr/100"
got="$(unit spl_lease_activity 100)"
[[ "$got" == "$t_first" ]] && pass "20. only pokes, errors and system entries in the window: activity = its oldest entry (12:38:20Z)" || fail "20. activity window: '$got' want $t_first"
# the stuck rule on that activity: an ask at 12:44Z, unread at 18:32Z
cp "$FX/login-expired.jsonl" "$T/tr/100"
printf '✻ Brewed for 16s\n❯ x\n────\n  ⏵⏵ auto mode on\n' >"$T/pane/100"
msg pc CLE-001 "$(date -ud 2026-10-05T12:44:00Z +%s)"
got="$(unit spl_fleet_stuck "CLE-001 100" LEASE_NOW="$(date -ud 2026-10-05T18:32:00Z +%s)")"
[[ "$got" == "oldest unread "*"idle "* ]] && pass "20. the ask behind the pokes is stuck ($got)" || fail "20. stuck: '$got'"
cp "$FX/good-turn.jsonl" "$T/tr/100"
got="$(unit spl_fleet_stuck "CLE-001 100" LEASE_NOW="$(date -ud 2026-10-05T18:42:00Z +%s)")"
[[ -z "$got" ]] && pass "20. CONTROL: after the good turn the same ask is read, not stuck" || fail "20. stuck good: '$got'"
rm -rf "$T/pc/spool/CLE-001"; rm -f "$T/pane/100" "$T/tr/100"
# the fleet: sat ranked first holds orch; its orchestrator's login expires
PRIO=sat,pc
tick sat $N "${T20[@]}"; tick pc $N "${T20[@]}"
[[ "$(hubh orch)" == CLE-001@sat ]] && pass "20. sat's orchestrator holds orch" || fail "20. setup: $(hubh orch)"
login 200
tick sat $((N + 60)) "${T20[@]}"
[[ "$(logc sat 'NO-LOCAL-AGENT orch.*CLE-001: stalled pid=200: Please run /login, no spinner')" == 1 && "$(hubh dispatch)" == CLE-002@sat ]] &&
  pass "20. first tick after the poke: sat stops renewing orch (logged with why), keeps dispatch" || fail "20. sat: $(cat "$T/sat/spool/dispatch/lease.log")"
grep -q '^stalled pid=200: Please run /login, no spinner' "$T/sat/spool/dispatch/able.CLE-001" &&
  pass "20. able.CLE-001 names the login" || fail "20. able: $(cat "$T/sat/spool/dispatch/able.CLE-001")"
tick pc $((N + 180)) "${T20[@]}"
[[ "$(hubh orch)" == CLE-001@sat ]] && pass "20. 180 s is not stale yet" || fail "20. early: $(hubh orch)"
tick pc $((N + 181)) "${T20[@]}"
[[ "$(hubh orch)" == CLE-001@pc && "$(hubh dispatch)" == CLE-002@sat ]] &&
  pass "20. 181 s after sat's last orch renewal pc takes orch; dispatch stays on sat" || fail "20. takeover: $(hubh orch)/$(hubh dispatch)"
login 200 good-turn
tick sat $((N + 240)) "${T20[@]}"
[[ "$(hubh orch)" == CLE-001@sat ]] && pass "20. CONTROL: logged in again (a good turn), sat takes orch back on rank" || fail "20. back: $(hubh orch)"
rm -f "$T/pane/200" "$T/tr/200"
PRIO=pc,sat

# --- 21. spec 093 T006: the lease reads the watchdog's verdict ---------------------------
# dispatch/wd.<id> is "HIT <code> <epoch>" or "OK <epoch>" (spl-watchdog.func.sh).
# A HIT at most 90 s old makes the agent not able ("wd <code>"); an older HIT,
# an OK, a garbled file or none changes nothing.
rm -rf "$T/pc" "$T/sat" "$T/hub" "$T/pane" "$T/tr"; mkdir -p "$T/hub" "$T/pc/proc" "$T/sat/proc" "$T/pane" "$T/tr"
agent pc 100 CLE-001; agent pc 101 CLE-002; agent pc 102 CLE-003
agent sat 200 CLE-001; agent sat 201 CLE-002; agent sat 202 CLE-003
N=1791007200; WD="$T/pc/spool/dispatch/wd.CLE-001"; mkdir -p "$T/pc/spool/dispatch"
got="$(unit spl_lease_agent_able CLE-001 LEASE_NOW=$N)"
[[ "$got" == 100 && ! -e "$WD" ]] && pass "21. no wd file: able as before" || fail "21. no file: '$got'"
for v in "OK $N" "HIT S3 $((N - 91))" "HIT S3" "garbage"; do
  echo "$v" >"$WD"
  got="$(unit spl_lease_agent_able CLE-001 LEASE_NOW=$N)"
  [[ "$got" == 100 && "$(cat "$T/pc/spool/dispatch/able.CLE-001")" == able ]] && pass "21. wd '$v': able" || fail "21. wd '$v': '$got'"
done
echo "HIT S3 $((N - 90))" >"$WD"
got="$(unit spl_lease_agent_able CLE-001 LEASE_NOW=$N)"
[[ -z "$got" && "$(cat "$T/pc/spool/dispatch/able.CLE-001")" == "wd S3: HIT 90s ago" ]] &&
  pass "21. a HIT 90 s old: not able (wd S3)" || fail "21. 90 s: '$got' $(cat "$T/pc/spool/dispatch/able.CLE-001")"
printf 'HIT S2 %s' "$N" >"$WD"
got="$(unit spl_lease_agent_able CLE-001 LEASE_NOW=$N)"
[[ -z "$got" && "$(cat "$T/pc/spool/dispatch/able.CLE-001")" == "wd S2: HIT 0s ago" ]] &&
  pass "21. a HIT with no trailing newline is read" || fail "21. no newline: '$got'"
echo "HIT S3 $((N - 30))" >"$WD"
got="$(unit spl_lease_agent_able CLE-001 LEASE_NOW=$N WD_FRESH=20)"
[[ "$got" == 100 ]] && pass "21. WD_FRESH bounds the window" || fail "21. WD_FRESH: '$got'"
rm -f "$WD"
# the fleet: sat ranked first holds orch; its orchestrator's watchdog verdict turns HIT S3
PRIO=sat,pc
tick sat $N; tick pc $N
[[ "$(hubh orch)" == CLE-001@sat ]] && pass "21. sat's orchestrator holds orch" || fail "21. setup: $(hubh orch)"
echo "HIT S3 $((N + 50))" >"$T/sat/spool/dispatch/wd.CLE-001"
tick sat $((N + 60))
[[ "$(logc sat 'NO-LOCAL-AGENT orch.*CLE-001: wd S3: HIT 10s ago')" == 1 && "$(hubh dispatch)" == CLE-002@sat ]] &&
  pass "21. a fresh HIT S3: sat stops renewing orch (logged with why), keeps dispatch" || fail "21. sat: $(cat "$T/sat/spool/dispatch/lease.log")"
tick pc $((N + 180))
[[ "$(hubh orch)" == CLE-001@sat ]] && pass "21. 180 s is not stale yet" || fail "21. early: $(hubh orch)"
tick pc $((N + 181))
[[ "$(hubh orch)" == CLE-001@pc && "$(hubh dispatch)" == CLE-002@sat ]] &&
  pass "21. 181 s after sat's last orch renewal pc takes orch; dispatch stays on sat" || fail "21. takeover: $(hubh orch)/$(hubh dispatch)"
tick sat $((N + 141))
[[ "$(hubh orch)" == CLE-001@sat && "$(cat "$T/sat/spool/dispatch/able.CLE-001")" == able ]] &&
  pass "21. the HIT now 91 s old is stale and ignored: sat takes orch back on rank" || fail "21. back: $(hubh orch) $(cat "$T/sat/spool/dispatch/able.CLE-001")"
rm -f "$T/sat/spool/dispatch/wd.CLE-001"
PRIO=pc,sat

echo
(( fails == 0 )) && { echo "PASS: all fleet-lease.tst.sh assertions"; exit 0; }
echo "FAIL: $fails fleet-lease.tst.sh assertion(s)"; exit 1
