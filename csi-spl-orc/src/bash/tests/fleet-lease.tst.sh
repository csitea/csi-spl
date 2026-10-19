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
#  22. a box back online renews within LEASE_UNREACHABLE_RETRY (10 s), not a
#      full LEASE_PERIOD (2026-10-09: a box back 14:30:20Z, renewed 14:31:28Z,
#      the standby took over 14:30:50Z): the real loop, a hub failing its first 2 reads
#      per role, sleeps 10 10 then 60; LEASE_UNREACHABLE_RETRY=60 is the control
#  23. t1 3cfc236e, the roles follow beat health: a replay of the 2026-10-11
#      night (the PC box's hub beats per 10 min as measured on prd; the
#      satellite at 60 all night). The PC box ranked first holds both roles
#      until its beats degrade; then the satellite ranks before it and takes
#      both, on the demotion alone (the PC box keeps renewing, never stale);
#      the PC box gets them back only after 30 min (hold_min) of healthy
#      beats. CONTROL: LEASE_HEALTH=0 on the same beats keeps both on the PC
#      box (the old rule). A failed beats read demotes nobody.
#  24. a rank handback names ONE holder (2026-10-11 07:59:55Z, two holders for
#      54 s): the claimant wins the hub row 19 s after the holder renewed but
#      names the old holder for one LEASE_PERIOD; the old box stands down on
#      its next tick, then the claimant is ACTIVE once. A stale take-over waits
#      for nobody. (4 and 7 tick once more for the same wait.)
#  25. t1 3cfc236e, the bench alert: the same night with both loops gives ONE
#      post when the PC box is benched and ONE when it is back, both from the
#      satellite; the ticks in between post nothing; LEASE_ALERT=0 is the control.
#  26. a bench post that never lands is named on the one back line (the
#      2026-10-11 16:12Z outage). CONTROL: a delivered bench keeps the short
#      back line. Still one delivered post per state change.
#  27. a grok seat's own session is its activity (SPL-1696, 2026-10-13 15:52Z:
#      g-001, a live grok in /opt, read "idle 4105s" from a claude transcript
#      of the same cwd). The real spl_lease_transcript_tail on a fake /proc
#      and HOME: a moving grok session is not stuck under an unread > 600 s;
#      an idle one is, unless its pane shows a turn ("[stop]"); a prompt and a
#      hook entry are not activity; a grok pid missing from active_sessions
#      reads its cwd's newest session; the watchdog's progress reads the same
#      tail. CONTROL: a claude pid in that cwd still reads its own transcript.
#  28. one hung dial is not HUB-UNREACHABLE (SPL-2246, 2026-10-16: 21 lines on
#      sat in 86 min, each "failed to send handshake request ... terminated
#      signal received", the next dial answered): every first try failing with
#      the CLI's own text is retried once, 2 s later; both roles held, nothing
#      logged, each try one dial.log line. CONTROL: LEASE_HUB_TRIES=1 logs
#      HUB-UNREACHABLE per role; an error that is no "hub unreachable" is not
#      retried.
#  29. a handback whose wait ends on an unreachable tick still names its own
#      seat (SPL-2246, c-001 repro 2026-10-16 19:15-19:18Z: the claimant won
#      both rows, every next dial hung, it named the old box while the old box
#      read the claimant: both seats STANDBY). Inside LEASE_STALE of its last won write the claimant
#      names itself and tells its seat ACTIVE once; past it, it keeps the old
#      name. CONTROL: inside the wait an unreachable tick keeps the old name.
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
# LEASE_ASKS_RUN: the ./run the lease starts its background actions with; this
# one only records "<args> | DESK_TO=.. DESK_KIND=.. | <body>" (SPL-2584)
printf '#!/bin/sh\nprintf "%%s | DESK_TO=%%s DESK_KIND=%%s | %%s\\n" "$*" "${DESK_TO:-}" "${DESK_KIND:-}" "${DESK_BODY:-}" >>"%s/asksrun.log"\n' "$T" >"$T/bin/asksrun"
chmod +x "$T/bin/asksrun"

cat >"$T/bin/send" <<'STUB'
#!/bin/sh
to="" body=""
while [ $# -gt 0 ]; do case "$1" in --to) to="$2"; shift 2 ;; --body) body="$2"; shift 2 ;; *) shift ;; esac; done
echo "$to :: $body" >>"$SENT"
STUB
# The hub stub: one file per fleet+role, "holder gen at"; HUB_NOW is its clock.
# HUB_DOWN=1 fails every call, HUB_FAILS=<file> the next <its count> calls; HUB_RACE=<holder> writes that holder first on a
# cas, as another machine winning the race would. A call to another tenant
# (LEASE_HUB_TENANT, the copies of section 16) has its own file
# <tenant>.<fleet>.<role>, is logged to calls, and HUB_DOWN_TENANT=<tenant>
# fails it.
cat >"$T/bin/hub" <<'STUB'
#!/bin/sh
[ "${HUB_DOWN:-0}" = 1 ] && { echo "dial: connection refused" >&2; exit 1; }
[ -s "${HUB_FAILS:-/nonexistent}" ] && n=$(cat "$HUB_FAILS") && [ "$n" -gt 0 ] && { echo $((n - 1)) >"$HUB_FAILS"; echo "dial: lookup hub: no such host" >&2; exit 1; }
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
printf '#!/bin/sh\nf="%s/pane/$1"; [ -e "$f" ] || exit 1; exec cat "$f"\n' "$T" >"$T/bin/pane"
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
    SENT="$T/$m/sent" LEASE_ASKS_RUN="$T/bin/asksrun" LEASE_HUB_CMD="$T/bin/hub" HUB_DIR="$T/hub" HUB_NOW="$now" LEASE_NOW="$now" \
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
# the hub row moves at once; pc names the satellite for one LEASE_PERIOD (section 24)
[[ "$(hubh dispatch)" == CLE-002@pc && "$(hubh orch)" == CLE-001@pc && "$(mirror pc)" == CLE-002@sat ]] &&
  pass "4. pc returns and takes both roles back on priority (the hub row; pc names the satellite until it has read it)" ||
  fail "4. hub $(hubh dispatch)/$(hubh orch) pc $(mirror pc)"
tick sat 1330; tick sat 1390
[[ "$(mirror sat)" == CLE-002@pc && "$(sentc sat 'CLE-002 :: FLEET LEASE dispatch: STANDBY')" == 1 &&
   "$(sentc sat 'CLE-001 :: FLEET LEASE orch: STANDBY')" == 1 && "$(hubh dispatch)" == CLE-002@pc ]] &&
  pass "4. the satellite's agents told STANDBY once and the satellite does not grab it back" || fail "4. sat mirror $(mirror sat) sent: $(cat "$T/sat/sent")"
tick pc 1380
[[ "$(mirror pc)" == CLE-002@pc && "$(mirror pc orch)" == CLE-001@pc && "$(sentc pc 'CLE-002 :: FLEET LEASE dispatch: you are now ACTIVE')" == 2 ]] &&
  pass "4. one LEASE_PERIOD after the handback pc names itself and its master is ACTIVE again" || fail "4. pc mirror $(mirror pc) sent: $(cat "$T/pc/sent")"

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
tick pc 1560  # the handback's one LEASE_PERIOD: pc names itself again

# --- 8. hub unreachable ----------------------------------------------------------
tick pc 1600 HUB_DOWN=1
[[ "$(mirror pc)" == CLE-002@pc && "$(logc pc HUB-UNREACHABLE)" == 2 ]] &&
  pass "8. a short outage keeps the holder; logged once per role" || fail "8. mirror $(mirror pc): $(cat "$T/pc/spool/dispatch/lease.log")"
tick pc 1750 HUB_DOWN=1
[[ "$(mirror pc)" == none@unreachable && "$(sentc pc 'CLE-002 :: FLEET LEASE dispatch: STANDBY')" -ge 1 && "$(logc pc HUB-UNREACHABLE)" == 2 ]] &&
  pass "8. past LEASE_STALE without a renewal pc demotes itself (no double acting)" || fail "8. mirror $(mirror pc)"
tick pc 1760
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
printf '#!/bin/sh\nexit "$SEND_RC"\n' >"$T/bin/send-rc"; chmod +x "$T/bin/send-rc"
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
printf '#!/bin/sh\nf="%s/act/$1"; [ -e "$f" ] || exit 1; exec cat "$f"\n' "$T" >"$T/bin/act"
printf '#!/bin/sh\nexec cat >>"%s/owner-dm"\n' "$T" >"$T/bin/owner"
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
[[ "$(dms)" == 1 && "$(grep -c 'CLE-001@sat took over from CLE-001@pc, silent 181s' "$T/owner-dm")" == 1 && "$(logc sat 'OPS-NOTICE orch take-over')" == 1 ]] &&
  pass "15. ONE ops notice for the take-over" || fail "15. dm: $(cat "$T/owner-dm" 2>&1)"
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
# the real leg (no LEASE_OWNER_CMD): the notice is do_spl_fleet_notice, a post
# into the ops channel, never a DM to the owner (SPL-2584, t1 4b49e47d; red on
# the old code, which ran do_spl_desk_reply with DESK_TO=<owner>)
rm -rf "$T/hub"/*; rm -f "$T/asksrun.log"; agent pc 100 CLE-001; echo 31700 >"$T/act/100"
tick pc 31700 LEASE_ACTIVITY_CMD="$T/bin/act"; kill_agent pc 100
tick sat 31900 LEASE_ACTIVITY_CMD="$T/bin/act" LEASE_OWNER=HUM-10 ASKS_OWNER=HUM-10
for _ in $(seq 1 50); do grep -q failover "$T/asksrun.log" 2>/dev/null && break; sleep 0.1; done
[[ "$(hubh orch)" == CLE-001@sat && "$(grep -c '^-a do_spl_fleet_notice | DESK_TO= DESK_KIND=note | Orchestrator failover: CLE-001@sat took over' "$T/asksrun.log" 2>/dev/null)" == 1 &&
   "$(grep -c 'DESK_TO=HUM' "$T/asksrun.log" 2>/dev/null)" == 0 && "$(dms)" == 2 ]] &&
  pass "15. the take-over notice goes to the ops channel (do_spl_fleet_notice), no DM to the owner" ||
  fail "15. ops notice: $(cat "$T/asksrun.log" 2>&1) $(tail -3 "$T/sat/spool/dispatch/lease.log")"

# --- 16. the lease in every served tenant ------------------------------------------------
rm -rf "$T/pc" "$T/sat" "$T/hub" "$T/pane"; mkdir -p "$T/hub" "$T/pc/proc" "$T/sat/proc" "$T/pane"
agent pc 100 CLE-001; agent pc 101 CLE-002; agent pc 102 CLE-003
agent sat 200 CLE-001; agent sat 201 CLE-002; agent sat 202 CLE-003
T16=(LEASE_MIRROR_TENANTS="csitea ws-a")
copy() { cut -d' ' -f"${3:-1}" "$T/hub/$1.main.$2" 2>/dev/null; }
tick pc 40000 "${T16[@]}"; tick sat 40000 "${T16[@]}"
[[ "$(hubh dispatch)" == CLE-002@pc && "$(copy csitea dispatch)" == CLE-002@pc && "$(copy ws-a dispatch)" == CLE-002@pc &&
   "$(copy csitea orch)" == CLE-001@pc && "$(copy ws-a orch)" == CLE-001@pc ]] &&
  pass "16. the holder copies both roles into every served tenant (csitea, ws-a)" ||
  fail "16. copies csitea $(copy csitea dispatch)/$(copy csitea orch) ws-a $(copy ws-a dispatch)/$(copy ws-a orch): $(tail -5 "$T/out")"
[[ "$(copy csitea dispatch 2)" == 1 ]] && pass "16. the standby machine copies nothing (gen 1 after both ticks)" || fail "16. standby wrote: gen $(copy csitea dispatch 2)"
tick pc 40060 "${T16[@]}"
[[ "$(copy csitea dispatch 2)" == 2 && "$(copy csitea dispatch 3)" == 40060 && "$(copy ws-a orch 3)" == 40060 ]] &&
  pass "16. every renewal renews the copies (they go stale only with the holder)" || fail "16. renewal: $(cat "$T/hub/csitea.main.dispatch")"
tick sat 40241 "${T16[@]}"
[[ "$(hubh dispatch)" == CLE-002@sat && "$(copy csitea dispatch)" == CLE-002@sat && "$(copy ws-a dispatch)" == CLE-002@sat &&
   "$(copy csitea orch)" == CLE-001@sat ]] &&
  pass "16. a take-over moves the copies to the new holder" || fail "16. take-over: csitea $(copy csitea dispatch) ws-a $(copy ws-a dispatch)"
: >"$T/hub/calls"
tick sat 40300 "${T16[@]}" HUB_DOWN_TENANT=csitea; tick sat 40360 "${T16[@]}" HUB_DOWN_TENANT=csitea
[[ "$(hubh dispatch)" == CLE-002@sat && "$(hubh dispatch | wc -l)" == 1 && "$(cut -d' ' -f3 "$T/hub/main.dispatch")" == 40360 &&
   "$(logc sat 'COPY-FAILED dispatch in csitea: dial: i/o timeout')" == 1 && "$(grep -c ws-a "$T/hub/calls")" == 0 ]] &&
  pass "16. a failing tenant: logged once, ends the tick's copies, the lease itself still renews" ||
  fail "16. down: calls $(tr '\n' ' ' <"$T/hub/calls") log: $(grep COPY "$T/sat/spool/dispatch/lease.log")"
tick sat 40420 "${T16[@]}"
[[ "$(copy csitea dispatch 3)" == 40420 && "$(copy ws-a dispatch 3)" == 40420 && "$(logc sat 'COPY dispatch in csitea: written again')" == 1 ]] &&
  pass "16. the tenant back: the copies are written again, logged once" || fail "16. back: $(grep COPY "$T/sat/spool/dispatch/lease.log")"
S="$T/state"
for p in t1/box-desk csitea/box-desk e2e/box-desk ws-a/box-desk ws-c/box-rsp acme-proof/box-desk; do mkdir -p "$S/desk/$p"; echo pinned >"$S/desk/$p/pinned"; done
: >"$S/desk/ws-a/box-desk/pinned"
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
printf '#!/bin/sh\nf="%s/tr/$1"; [ -e "$f" ] || exit 1; exec cat "$f"\n' "$T" >"$T/bin/tr"; chmod +x "$T/bin/tr"
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

hubh22() { cut -d' ' -f1 "$T/$1/hub/main.$2" 2>/dev/null; }
# --- 22. fast retry after an unreachable tick (the real loop, sleep recorded) ----
# loop22 <dir> [env...]: 4 ticks of spl_lease_loop fleet on pc, its hub failing
# the first 4 calls (2 reads per role); prints the pauses it slept
loop22() {
  local d="$T/$1"; shift
  mkdir -p "$d/hub" "$d/spool/dispatch"; agent "${d#"$T"/}" 300 CLE-001; agent "${d#"$T"/}" 301 CLE-002
  echo 4 >"$d/fails"
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$d/spool" LEASE_PROC_ROOT="$d/proc" LEASE_SEND="$T/bin/send" LEASE_PANE_CMD="$T/bin/pane" \
    SENT="$d/sent" LEASE_HUB_CMD="$T/bin/hub" HUB_DIR="$d/hub" HUB_FAILS="$d/fails" HUB_NOW=5000 LEASE_NOW=5000 \
    LEASE_FLEET=main LEASE_MACHINE=pc LEASE_PRIORITY=pc,sat LEASE_HOLDDOWN=0 LEASE_ASKS=0 LEASE_AGENT_RUN=0 LEASE_TICKS=4 \
    LEASE_ORCH=CLE-001 LEASE_MASTER=CLE-002 LEASE_FAILOVER=CLE-003 "$@" bash -c '
    set -uo pipefail
    do_log() { :; }
    sleep() { echo "$1" >>"$SPOOL_ROOT/slept"; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    spl_lease_init && spl_lease_ids master failover orch && spl_fleet_ids && spl_fleet_hub_init && spl_lease_loop fleet' >>"$T/out" 2>&1
  tr '\n' ' ' <"$d/spool/slept"
}
got="$(loop22 l22)"
[[ "$got" == "10 10 60 " && "$(hubh22 l22 orch)" == CLE-001@pc && "$(hubh22 l22 dispatch)" == CLE-002@pc &&
   "$(grep -c HUB-UNREACHABLE "$T/l22/spool/dispatch/lease.log")" == 2 && ! -e "$T/l22/spool/dispatch/fleet.orch.unreachable" ]] &&
  pass "22. after an unreachable tick the loop retries in 10 s, then back to LEASE_PERIOD once the hub answers (logged once per role)" ||
  fail "22. slept '$got': $(cat "$T/l22/spool/dispatch/lease.log" 2>&1)"
got="$(loop22 l22c LEASE_UNREACHABLE_RETRY=60)"
[[ "$got" == "60 60 60 " ]] && pass "22. control: LEASE_UNREACHABLE_RETRY=60 (the old pause) waits a full period" || fail "22. control slept '$got'"
got="$(loop22 l22p LEASE_PERIOD=5)"
[[ "$got" == "5 5 5 " ]] && pass "22. the retry is never longer than LEASE_PERIOD" || fail "22. cap slept '$got'"

# --- 23. the roles follow beat health (t1 3cfc236e) ------------------------------
# The beats stub (LEASE_BEATS_CMD) answers `box-beat list --since <n>m` from
# $BEATS: the rows of the last <n> minutes on the hub's clock HUB_NOW.
cat >"$T/bin/beats" <<'STUB'
#!/bin/sh
[ "${BEATS_DOWN:-0}" = 1 ] && { echo "dial: i/o timeout" >&2; exit 1; }
jq -c --argjson now "$HUB_NOW" --argjson s "$(( ${4%m} * 60 ))" \
  '{rows: [.[] | select(.e <= $now and .e > $now - $s) | {box, beat_at: (.e | todate)}]}' "$BEATS"
STUB
chmod +x "$T/bin/beats"
beats() { jq -nc --arg b "$1" --argjson s "$2" --argjson c "[$3]" \
  '[range(0; $c | length) as $i | range(0; $c[$i]) as $k | {box: $b, e: ($s + $i * 600 + (($k + 0.5) * 600 / $c[$i] | floor))}]'; }
B0=1791678600  # 2026-10-11T00:30:00Z
# hp: the PC box's beats per 10 min from 00:30Z (prd box_beats, 01:00..05:30Z measured), hs: the satellite
NIGHT=60,60,60,61,60,61,60,62,23,16,10,15,11,16,3,4,9,2,5,5,8,8,2,1,2,2,0,1,0,16,60,60,60,60,60,60,60,60,60
jq -s add <(beats hp $B0 "$NIGHT") <(beats hs $B0 "$(printf '60,%.0s' {1..38})60") >"$T/beats23.json"
trio hp 50; trio hs 51
# LEASE_ALERT=0: the bench alert (section 25) is not what 23 measures, and its beats read on every tick doubles 23's cost
t23() { tick "$1" "$2" LEASE_PRIORITY=hp,hs LEASE_BEATS_CMD="$T/bin/beats" BEATS="$T/beats23.json" LEASE_HEALTH_TTL=0 LEASE_ALERT=0 "${@:3}"; }
hm23() { local o d; o="$(hubh orch)" d="$(hubh dispatch)"; [[ "${o##*@}" == "${d##*@}" ]] && echo "${o##*@}" || echo "split:$o/$d"; }
rm -f "$T"/hub/main.*
# one tick per box on the 170 s grid 01:36..06:59Z (k = 0..114): every step where the
# roles move (k 4..12, 01:47..02:10Z, the demotion; k 86..98, 05:39..06:13Z, the
# handback), every 6th step between (1020 s, under hold_min 30: each tick judges the
# last 30 min of beats, so every minute of the outage is judged by some tick) - 38
# steps, not 115 (r01-02, SPL-2082). LEASE_STALE 1200 > the widest gap: nobody goes stale.
s23() { local k; for k in $(seq 0 114); do
  (( (k >= 4 && k <= 12) || (k >= 86 && k <= 98) || k % 6 == 0 )) && echo $((B0 + 3960 + k * 170)); done; }
first_hs="" back_hp="" hp_in_outage=0 split=0 n23=0 n_out=0
for now in $(s23); do
  t23 hp $now LEASE_STALE=1200; t23 hs $((now + 1)) LEASE_STALE=1200; n23=$((n23 + 1))
  h="$(hm23)"; [[ "$h" == split:* ]] && split=$((split + 1))
  [[ "$h" == hs && -z "$first_hs" ]] && first_hs=$now
  [[ -n "$first_hs" && "$h" == hp && -z "$back_hp" ]] && back_hp=$now
  # 02:10..05:40Z: every 10-min window of the PC box held under 30 beats
  (( now >= B0 + 6000 && now <= B0 + 18600 )) && { n_out=$((n_out + 1)); [[ "$h" != hs ]] && hp_in_outage=$((hp_in_outage + 1)); }
done
utc() { date -u -d "@$1" +%H:%MZ; }
(( first_hs >= B0 + 4800 && first_hs <= B0 + 5580 )) &&
  pass "23. the PC box degrades from 01:50Z: the satellite holds both roles at $(utc "$first_hs")" || fail "23. first satellite hold: ${first_hs:+$(utc "$first_hs")}"
[[ $hp_in_outage == 0 && $split == 0 ]] &&
  pass "23. 02:10..05:40Z ($n_out of $n23 steps): the satellite holds both roles all through, the PC box never takes one back" ||
  fail "23. outage: $hp_in_outage step(s) not on the satellite, $split split"
# its beats are healthy again from ~05:33Z (the window under 30 last at 05:3xZ): back only after 30 min
(( back_hp >= B0 + 19800 && back_hp <= B0 + 20400 )) &&
  pass "23. the PC box gets both roles back at $(utc "$back_hp"), after hold_min 30 of healthy beats (none before 06:00Z)" ||
  fail "23. back: ${back_hp:+$(utc "$back_hp")}"
[[ "$(hm23)" == hp ]] && pass "23. at 06:59Z the configured order holds again (PC box first)" || fail "23. end: $(hm23)"
[[ "$(logc hs 'DEMOTED dispatch: hp ranks last (degraded:')" == 1 && "$(logc hs 'takes over from CLE-002@hp (silent 1s')" == 1 ]] &&
  pass "23. the satellite logs the demotion once and takes over from a holder silent 1 s (never stale)" ||
  fail "23. log: $(grep -E 'DEMOTED|takes over' "$T/hs/spool/dispatch/lease.log")"
grep -q '"hp":{"n":[0-9]*,"need":30' "$T/hs/spool/dispatch/fleet.health" &&
  pass "23. the verdicts are cached in <dir>/fleet.health" || fail "23. cache: $(cat "$T/hs/spool/dispatch/fleet.health" 2>&1)"
# CONTROL: the same beats with LEASE_HEALTH=0 (the old rule): the PC box keeps both
rm -f "$T"/hub/main.*; ctl=0
for i in $(seq 50 59); do now=$((B0 + i * 120)); t23 hp $now LEASE_HEALTH=0; t23 hs $((now + 1)) LEASE_HEALTH=0; [[ "$(hm23)" == hp ]] || ctl=$((ctl + 1)); done
[[ $ctl == 0 ]] && pass "23. CONTROL: LEASE_HEALTH=0, 02:10..02:28Z (10 steps): the PC box keeps both roles (the old rule)" || fail "23. control: $ctl step(s) moved"
# a failed beats read with no good read before demotes nobody (rc 0, a HEALTH-UNREAD line once)
rm -f "$T"/hub/main.* "$T"/hs/spool/dispatch/fleet.health*; ctl=0
for i in 60 61 62; do now=$((B0 + i * 120)); t23 hp $now BEATS_DOWN=1; t23 hs $((now + 1)) BEATS_DOWN=1; [[ "$(hm23)" == hp ]] || ctl=$((ctl + 1)); done
[[ $ctl == 0 && "$(logc hs 'HEALTH-UNREAD')" == 1 ]] &&
  pass "23. beats read failing: nobody demoted, the configured order; HEALTH-UNREAD logged once" || fail "23. unread: $ctl $(logc hs HEALTH-UNREAD)"

# --- 24. a rank handback never names two holders (2026-10-11 07:59:55Z) ----------
# Replay: st holds dispatch, renewing every 60 s; tk (ranked first) takes it
# back 19 s after st's last renewal. Each box reads the hub once per tick, so
# the old holder saw the new one only on its next tick (54 s later that
# morning). Before the fix tk named itself at once and told its seat ACTIVE
# while st's seat was still ACTIVE: two holders. Now the claimant names the
# old holder for one LEASE_PERIOD, the old box stands down on its next tick,
# then the claimant goes ACTIVE.
rm -rf "$T/tk" "$T/st"; rm -f "$T"/hub/main.*
trio st 61
t24() { tick "$1" "$2" LEASE_PRIORITY=tk,st LEASE_PRIORITY_DISPATCH=tk,st; }
# selfc: how many boxes name one of their own seats as the dispatch holder
selfc() { local n=0 m; for m in tk st; do [[ "$(mirror "$m")" == *"@$m" ]] && n=$((n + 1)); done; echo "$n"; }
t24 st 2000
mkdir -p "$T/tk/proc"; t24 tk 2001
[[ "$(hubh dispatch)" == CLE-002@st && "$(mirror tk)" == CLE-002@st ]] && pass "24. setup: st holds, tk has no seat" || fail "24. setup: $(hubh dispatch) tk=$(mirror tk)"
trio tk 60
t24 st 2060; t24 tk 2079
two=0; [[ "$(selfc)" -gt 1 ]] && two=1
[[ "$(hubh dispatch)" == CLE-002@tk && "$(mirror tk)" == CLE-002@st && "$(sentc tk 'CLE-002 :: FLEET LEASE dispatch: you are now ACTIVE')" == 0 && $two == 0 ]] &&
  pass "24. tk takes it back on the hub 19 s after st renewed, but names st and keeps its seat STANDBY: one holder" ||
  fail "24. split: hub $(hubh dispatch) tk=$(mirror tk) st=$(mirror st), tk ACTIVE sent $(sentc tk 'dispatch: you are now ACTIVE')"
t24 st 2120
[[ "$(mirror st)" == CLE-002@tk && "$(sentc st 'CLE-002 :: FLEET LEASE dispatch: STANDBY')" == 1 && "$(selfc)" == 0 ]] &&
  pass "24. st's next tick stands its seat down (STANDBY once)" || fail "24. st: $(mirror st) $(cat "$T/st/sent" 2>&1)"
t24 tk 2138
[[ "$(mirror tk)" == CLE-002@st && "$(sentc tk 'CLE-002 :: FLEET LEASE dispatch: you are now ACTIVE')" == 0 && "$(hubh dispatch)" == CLE-002@tk ]] &&
  pass "24. 59 s after the take-back tk still waits (LEASE_PERIOD 60 s) and renews" || fail "24. early: tk=$(mirror tk) sent $(cat "$T/tk/sent" 2>&1)"
t24 tk 2139
[[ "$(mirror tk)" == CLE-002@tk && "$(sentc tk 'CLE-002 :: FLEET LEASE dispatch: you are now ACTIVE')" == 1 && "$(selfc)" == 1 &&
   "$(logc tk 'HANDBACK dispatch: CLE-002@tk')" == 1 && "$(logc tk 'takes over from CLE-002@st (silent 19s')" == 1 ]] &&
  pass "24. one LEASE_PERIOD later tk is ACTIVE once; the handback and its wait are logged once" ||
  fail "24. active: tk=$(mirror tk) sent $(cat "$T/tk/sent" 2>&1) log $(grep -E 'HANDBACK|takes over' "$T/tk/spool/dispatch/lease.log")"
# a stale take-over (the holder silent > LEASE_STALE) waits for nobody: st takes it at once
kill_agent tk 600; kill_agent tk 601; kill_agent tk 602
t24 st 2320
[[ "$(mirror st)" == CLE-002@st && "$(sentc st 'CLE-002 :: FLEET LEASE dispatch: you are now ACTIVE')" == 2 && "$(logc st HANDBACK)" == 0 ]] &&
  pass "24. a stale holder (181 s silent) is taken over at once, no wait" || fail "24. stale: st=$(mirror st) $(cat "$T/st/sent" 2>&1)"

# --- 25. the bench alert (t1 3cfc236e, HUM-10 "yes" 0c2817c5) --------------------
# The 2026-10-11 night of section 23, both loops running: ONE line in #alerts
# when the PC box is benched and ONE when it is back, both from the
# satellite (the first healthy box of the orch order that is not the PC box);
# the PC box posts nothing about itself. The post is the LEASE_ALERT_CMD stub.
cat >"$T/bin/alert" <<'STUB'
#!/bin/sh
echo "$LEASE_MACHINE $HUB_NOW :: $(cat)" >>"$ALERTS"
STUB
chmod +x "$T/bin/alert"
t25() { t23 "$1" "$2" LEASE_ALERT=1 LEASE_ALERT_CMD="$T/bin/alert" ALERTS="$T/alerts25" "${@:3}"; }
# b25 <machine> <from>: 100 bench ticks in ONE process (sourced once), the clock +60 s each,
# the beats read every 10 ticks (LEASE_HEALTH_TTL 600, the loop's cache)
b25() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$T/$1/spool" LEASE_FLEET=main LEASE_MACHINE="$1" LEASE_PRIORITY=hp,hs \
    LEASE_HUB_CMD="$T/bin/hub" LEASE_BEATS_CMD="$T/bin/beats" BEATS="$T/beats23.json" LEASE_HEALTH_TTL=600 \
    LEASE_ALERT_CMD="$T/bin/alert" ALERTS="$T/alerts25" FROM="$2" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    spl_lease_init || exit 1
    for i in $(seq 1 100); do export HUB_NOW=$((FROM + i * 60)) LEASE_NOW=$((FROM + i * 60)); spl_fleet_bench_tick; done' >>"$T/out" 2>&1
}
rm -f "$T"/hub/main.* "$T"/h[ps]/spool/dispatch/fleet.* "$T/alerts25"
for now in $(seq $((B0 + 3000)) 340 $((B0 + 3600))); do t25 hp $now; t25 hs $((now + 1)); done
[[ ! -s "$T/alerts25" ]] && pass "25. healthy beats, both loops: no post (a box seen first is recorded, not posted)" ||
  fail "25. healthy: $(cat "$T/alerts25")"
nt=0
# 01:36..06:20Z on the 680 s grid (k = 0..25): every step to 02:10Z (the bench) and from
# 05:45Z (the recovery), every 3rd between: 14 steps, not 26 (r01-02, SPL-2082); the
# benched ticks in between are the 200 below
for k in $(seq 0 25); do
  (( k <= 3 || k >= 22 || k % 3 == 0 )) || continue
  now=$((B0 + 3960 + k * 680)); t25 hp $now; t25 hs $((now + 1)); nt=$((nt + 2))
done
a25() { sed -n "${1}p" "$T/alerts25" 2>/dev/null; }
[[ "$(wc -l <"$T/alerts25" 2>/dev/null)" == 2 ]] &&
  pass "25. a bench, then a recovery: exactly 2 posts over the night ($nt ticks, 2 loops)" ||
  fail "25. posts: $(cat "$T/alerts25" 2>&1)"
[[ "$(a25 1)" =~ ^hs\ [0-9]+\ ::\ Box\ hp\ benched\ \(degraded:\ .*\;\ [0-9]+\ of\ 60\ heartbeats\ in\ 10\ min,\ last\ .*\)\ \(no\ new\ lanes,\ last\ for\ the\ roles\)$ &&
   "$(a25 2)" =~ ^hs\ [0-9]+\ ::\ Box\ hp\ back\ after\ 30\ healthy\ min$ ]] &&
  pass "25. both posts come from the satellite, none from the PC box: '$(a25 1 | cut -d: -f3-)'" || fail "25. lines: $(cat "$T/alerts25" 2>&1)"
t1="$(a25 1 | cut -d' ' -f2)" t2="$(a25 2 | cut -d' ' -f2)"
(( t1 >= B0 + 4800 && t1 <= B0 + 5580 && t2 >= B0 + 19800 && t2 <= B0 + 20400 )) &&
  pass "25. benched at $(utc "$t1"), back at $(utc "$t2"), with the role demotion of section 23" || fail "25. times: $t1 $t2"
[[ "$(logc hs 'ALERT #alerts: Box hp')" == 2 && "$(logc hp 'ALERT #alerts')" == 0 ]] &&
  pass "25. lease.log: the satellite logs both posts, the PC box none" || fail "25. log: $(grep -h ALERT "$T"/h[ps]/spool/dispatch/lease.log)"
# 100 ticks on each box while benched (02:10..03:50Z, every 10-min window under 30 beats): no more posts
rm -f "$T"/h[ps]/spool/dispatch/fleet.* "$T/alerts25"
t25 hp $((B0 + 5940)); t25 hs $((B0 + 5941))
b25 hp $((B0 + 5940)); b25 hs $((B0 + 5941))
[[ "$(jq -r .hp "$T/hs/spool/dispatch/fleet.bench" 2>/dev/null)" == benched && ! -s "$T/alerts25" ]] &&
  pass "25. 200 ticks (100 per box) while benched: 0 more posts" || fail "25. benched ticks: $(jq -c . "$T/hs/spool/dispatch/fleet.bench" 2>&1) $(cat "$T/alerts25" 2>&1)"
# CONTROL: LEASE_ALERT=0 across the bench edge (01:41..02:13Z) posts nothing
rm -f "$T"/hub/main.* "$T"/h[ps]/spool/dispatch/fleet.* "$T/alerts25"
for now in $(seq $((B0 + 4260)) 680 $((B0 + 6300))); do t25 hp $now LEASE_ALERT=0; t25 hs $((now + 1)) LEASE_ALERT=0; done
[[ ! -s "$T/alerts25" ]] && pass "25. CONTROL: LEASE_ALERT=0 across the bench edge: no post" || fail "25. control: $(cat "$T/alerts25")"

# --- 26. an undelivered bench is named on the one back line -------------------
# Red without this change: the back line is "Box hp back after 30 healthy min"
# and does not name the bench time. Verdicts are injected through the health
# cache, so this does not replay the night.
cat >"$T/bin/alert26" <<'STUB'
#!/usr/bin/env bash
line=$(cat)
if [[ "$line" == *' benched ('* && "${ALERT_FAIL:-0}" == 1 ]]; then
  echo "FAIL :: $line" >>"$ALERTS.tried"
  exit 1
fi
echo "$LEASE_MACHINE :: $line" >>"$ALERTS"
STUB
chmod +x "$T/bin/alert26"
VOK='{"hp":{"state":"healthy","n":60,"age":5},"hs":{"state":"healthy","n":60,"age":5}}'
VBAD='{"hp":{"state":"degraded","n":3,"age":90},"hs":{"state":"healthy","n":60,"age":5}}'
VBACK='{"hp":{"state":"healthy","n":60,"age":4},"hs":{"state":"healthy","n":60,"age":4}}'
VBOTH='{"hp":{"state":"degraded","n":1,"age":80},"hs":{"state":"degraded","n":2,"age":70}}'
VHS='{"hp":{"state":"degraded","n":1,"age":80},"hs":{"state":"healthy","n":60,"age":3}}'
tick26() {
  local m="$1" now="$2" json="$3"; shift 3
  mkdir -p "$T/$m/spool/dispatch"
  printf '%s %s\n' "$now" "$json" > "$T/$m/spool/dispatch/fleet.health"
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$T/$m/spool" LEASE_MACHINE="$m" \
    LEASE_PRIORITY=hp,hs LEASE_NOW="$now" HUB_NOW="$now" \
    LEASE_HEALTH_TTL=99999 LEASE_BEATS_CMD=/bin/true \
    LEASE_ALERT=1 LEASE_ALERT_CMD="$T/bin/alert26" ALERTS="$T/alerts26" \
    "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    spl_lease_init || exit 1
    spl_fleet_bench_tick' >>"$T/out" 2>&1
}
rm -rf "$T/hs" "$T/hp"; rm -f "$T/alerts26" "$T/alerts26.tried"
tick26 hs 1000 "$VOK"
tick26 hs 2000 "$VBAD" ALERT_FAIL=1
tick26 hs 3800 "$VBACK"
since26=$(date -u -d @2000 +%Y-%m-%dT%H:%M:%SZ)
[[ "$(wc -l <"$T/alerts26" 2>/dev/null)" == 1 && "$(wc -l <"$T/alerts26.tried" 2>/dev/null)" == 1 ]] &&
  pass "26. a failed bench post is one attempt and one delivered post (the back line)" ||
  fail "26. counts: alerts $(wc -l <"$T/alerts26" 2>/dev/null) tried $(wc -l <"$T/alerts26.tried" 2>/dev/null) $(cat "$T/alerts26" 2>&1)"
[[ "$(sed -n 1p "$T/alerts26")" == "hs :: Box hp back after 30 healthy min (benched since ${since26}; the benched alert could not be delivered)" ]] &&
  pass "26. a failed bench post: the one back line names the bench time" ||
  fail "26. back line: $(cat "$T/alerts26" 2>&1)"
# CONTROL: the same edges with the bench post delivered keep the short back line
rm -rf "$T/hs" "$T/hp"; rm -f "$T/alerts26" "$T/alerts26.tried"
tick26 hs 1000 "$VOK"
tick26 hs 2000 "$VBAD"
tick26 hs 3800 "$VBACK"
[[ "$(wc -l <"$T/alerts26" 2>/dev/null)" == 2 && "$(sed -n 2p "$T/alerts26")" == "hs :: Box hp back after 30 healthy min" &&
   "$(sed -n 1p "$T/alerts26")" == "hs :: Box hp benched (degraded; 3 of 60 heartbeats in 10 min, last 90 s ago) (no new lanes, last for the roles)" ]] &&
  pass "26. CONTROL: a delivered bench keeps the short back line, one post per change" ||
  fail "26. control: $(cat "$T/alerts26" 2>&1)"
# the benched line names the verdict and its why (SPL-2021): on 2026-10-15
# 07:56Z a box whose fleet.bench.v read {n 61, need 30, age 0, state
# recovering, why "healthy for 1260s < hold 1800s"} was posted as "Box <box>
# benched: 61 of 60 heartbeats in 10 min, last 0 s ago", a healthy-looking box benched.
VREC='{"hp":{"state":"recovering","n":61,"need":30,"age":0,"why":"healthy for 1260s < hold 1800s"},"hs":{"state":"healthy","n":60,"age":5}}'
VDEG='{"hp":{"state":"degraded","n":3,"need":30,"age":90,"why":"3 beats in 10m < 30, last beat 90s ago (max 120s)"},"hs":{"state":"healthy","n":60,"age":5}}'
want_rec="hs :: Box hp benched (recovering: healthy for 1260s < hold 1800s; 61 of 60 heartbeats in 10 min, last 0 s ago) (no new lanes, last for the roles)"
want_deg="hs :: Box hp benched (degraded: 3 beats in 10m < 30, last beat 90s ago (max 120s); 3 of 60 heartbeats in 10 min, last 90 s ago) (no new lanes, last for the roles)"
# names_why LINE STATE: the line states the verdict and the why it carries
names_why() { [[ "$1" == *"benched ($2: "*"; "*" heartbeats in "*") (no new lanes, last for the roles)" ]]; }
rm -rf "$T/hs" "$T/hp"; rm -f "$T/alerts26" "$T/alerts26.tried"
tick26 hs 1000 "$VOK"
tick26 hs 2000 "$VREC"
got26="$(sed -n 1p "$T/alerts26" 2>/dev/null)"
[[ "$(wc -l <"$T/alerts26" 2>/dev/null)" == 1 && "$got26" == "$want_rec" ]] && names_why "$got26" recovering &&
  pass "26. a recovering box's benched line says recovering and its why" ||
  fail "26. recovering: $(cat "$T/alerts26" 2>&1)"
rm -rf "$T/hs" "$T/hp"; rm -f "$T/alerts26" "$T/alerts26.tried"
tick26 hs 1000 "$VOK"
tick26 hs 2000 "$VDEG"
got26="$(sed -n 1p "$T/alerts26" 2>/dev/null)"
[[ "$(wc -l <"$T/alerts26" 2>/dev/null)" == 1 && "$got26" == "$want_deg" ]] && names_why "$got26" degraded &&
  pass "26. a degraded box's benched line says degraded and its why" ||
  fail "26. degraded: $(cat "$T/alerts26" 2>&1)"
# CONTROL: the old line (before SPL-2021) fails the same check
! names_why "hs :: Box hp benched: 61 of 60 heartbeats in 10 min, last 0 s ago (no new lanes, last for the roles)" recovering &&
  pass "26. CONTROL: the old benched line (no verdict, no why) fails the check" ||
  fail "26. control: the old line passes names_why"
# both boxes benched: nobody is healthy, so no bench post is attempted (the outage)
rm -rf "$T/hs" "$T/hp"; rm -f "$T/alerts26" "$T/alerts26.tried"
tick26 hs 5000 "$VOK"
tick26 hs 6000 "$VBOTH"
tick26 hs 7000 "$VHS"
since26=$(date -u -d @6000 +%Y-%m-%dT%H:%M:%SZ)
[[ ! -s "$T/alerts26.tried" && "$(wc -l <"$T/alerts26" 2>/dev/null)" == 1 &&
   "$(sed -n 1p "$T/alerts26")" == "hs :: Box hs back after 30 healthy min (benched since ${since26}; the benched alert could not be delivered)" ]] &&
  pass "26. no healthy poster: the one back line names the bench time, and the bench line was not sent" ||
  fail "26. no poster: $(cat "$T/alerts26" 2>&1) tried $(cat "$T/alerts26.tried" 2>&1)"

# --- 27. a grok seat's own session is its activity (SPL-1696) --------------------
G="$T/g"; N=1791900000
rm -rf "$G"; mkdir -p "$G/proc" "$G/home" "$G/wt" "$T/pane"
[[ "$G" != /var/spool-hub* ]] || { echo "FAIL: 27. a fixture root is the live spool"; exit 1; }
# seat <pid> <comm>: a live agent in $G/wt whose HOME is $G/home
seat() { mkdir -p "$G/proc/$1"; echo "$2" >"$G/proc/$1/comm"; ln -sfn "$G/wt" "$G/proc/$1/cwd"
  printf 'HOME=%s\0SPOOL_AGENT_ID=g-001\0' "$G/home" >"$G/proc/$1/environ"; }
seat 300 grok; seat 301 grok; seat 302 claude
# the grok session of pid 300 (active_sessions.json), and a stale claude transcript of the same cwd
gdir="$G/home/.grok/sessions/$(jq -rn --arg c "$G/wt" '$c | @uri')"
cdir="$G/home/.claude/projects/$(printf '%s' "$G/wt" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$gdir/s300" "$cdir"
jq -n --arg c "$G/wt" '[{session_id: "s300", pid: 300, cwd: $c}]' >"$G/home/.grok/active_sessions.json"
printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"text","text":"x"}]}}\n' \
  "$(date -ud @$((N - 4105)) +%Y-%m-%dT%H:%M:%S.000Z)" >"$cdir/old.jsonl"
# gup <ts> <sessionUpdate> [status]: one updates.jsonl line of a grok session
gup() { jq -cn --argjson t "$1" --arg k "$2" --arg s "${3:-}" \
  '{timestamp: $t, method: "session/update", params: {sessionId: "s", update: ({sessionUpdate: $k, toolCallId: "c1"} + (if $s == "" then {} else {status: $s} end))}}'; }
{ gup $((N - 900)) user_message_chunk; gup $((N - 890)) tool_call; gup $((N - 60)) tool_call_update completed
  gup $((N - 30)) hook_execution; } >"$gdir/s300/updates.jsonl"
G27=(LEASE_TRANSCRIPT_CMD= LEASE_PROC_ROOT="$G/proc" SPOOL_ROOT="$G/spool" LEASE_NOW="$N")
printf '   ⠙ Waiting for response… 2.4s      33s ⇣109k\n  ╭──\n  │ ❯\n  ╰──\n  Enter:send now  │  Ctrl+x:shortcuts\n' >"$T/pane/300"
cp "$T/pane/300" "$T/pane/301"; cp "$T/pane/300" "$T/pane/302"
msg g g-001 $((N - 700))
got="$(unit spl_lease_activity 300 "${G27[@]}")"
[[ "$got" == $((N - 60)) ]] && pass "27. grok activity = its session's last tool result, not the cwd's claude transcript" || fail "27. activity: '$got' want $((N - 60))"
got="$(unit spl_fleet_stuck "g-001 300" "${G27[@]}")"
[[ -z "$got" ]] && pass "27. a moving grok session is not stuck under an unread 700 s old" || fail "27. moving: '$got'"
# idle: the last reply before the unread, nothing since but a hook and a prompt
{ gup $((N - 2000)) user_message_chunk; gup $((N - 1990)) agent_message_chunk; gup $((N - 30)) hook_execution
  gup $((N - 20)) user_message_chunk; } >"$gdir/s300/updates.jsonl"
got="$(unit spl_lease_activity 300 "${G27[@]}")"
[[ "$got" == $((N - 1990)) ]] && pass "27. a prompt and a hook entry are not grok activity" || fail "27. idle activity: '$got' want $((N - 1990))"
got="$(unit spl_fleet_stuck "g-001 300" "${G27[@]}")"
[[ "$got" == "oldest unread 700s > 600s, idle 1990s" ]] && pass "27. an idle grok seat with an unread 700 s old is stuck ($got)" || fail "27. idle: '$got'"
printf '   ⠙ Waiting for response… 2.4s      33s ⇣109k [stop]\n  ╭──\n  │ ❯\n  ╰──\n  Ctrl+c:cancel  │  Ctrl+x:shortcuts\n' >"$T/pane/300"
got="$(unit spl_fleet_stuck "g-001 300" "${G27[@]}")"
[[ -z "$got" ]] && pass "27. the same idle session under a grok turn in progress ([stop]) is not stuck" || fail "27. turn: '$got'"
# pid 301: not in active_sessions -> the newest session of its cwd
mkdir -p "$gdir/s301"; gup $((N - 120)) agent_thought_chunk >"$gdir/s301/updates.jsonl"; touch -d @$((N - 10)) "$gdir/s300/updates.jsonl"
got="$(unit spl_lease_activity 301 "${G27[@]}")"
[[ "$got" == $((N - 120)) ]] && pass "27. a grok pid missing from active_sessions reads its cwd's newest session" || fail "27. fallback: '$got' want $((N - 120))"
# the watchdog reads the same tail (spl_wd_transcript -> wd_transcript_progress)
mkdir -p "$G/wd"; unit spl_lease_transcript_tail 300 "${G27[@]}" >"$G/wd/transcript"
got="$(WD_CTX="$G/wd" bash -c 'source "$1/src/bash/features/watchdog/situations/lib.inc.sh" g-001 300 -; wd_transcript_progress' _ "$PROJ_ROOT")"
[[ "$got" == $((N - 1990)) ]] && pass "27. watchdog S8 progress reads the grok session" || fail "27. wd: '$got' want $((N - 1990))"
# a grok session has no API-error entry: its last turn stays unknown, so a banner is judged as before
got="$(unit spl_lease_last_turn 300 "${G27[@]}")"
[[ -z "$got" ]] && pass "27. a grok session's last turn is unknown (login banners as before)" || fail "27. last turn: '$got'"
# CONTROL: a claude pid in the same cwd keeps its own transcript
got="$(unit spl_lease_activity 302 "${G27[@]}")"
[[ "$got" == $((N - 4105)) ]] && pass "27. CONTROL: a claude pid in that cwd still reads its claude transcript" || fail "27. claude: '$got' want $((N - 4105))"
rm -f "$T/pane/300" "$T/pane/301" "$T/pane/302"

# --- 28. one hung dial is retried, not logged HUB-UNREACHABLE (SPL-2246) ----------
# The hubhang stub fails the odd calls (every first try) with the spool CLI's
# own text for a /v1/ws upgrade the 30 s timeout killed, the even ones go to hub.
cat >"$T/bin/hubhang" <<'STUB'
#!/bin/sh
n=$(( $(cat "$HANG_N" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$HANG_N"
[ $((n % 2)) = 1 ] && [ "${HANG_ON:-1}" = 1 ] && { echo 'spool: hub unreachable: failed to WebSocket dial: failed to send handshake request: Get "https://hub.example/v1/ws": terminated signal received' >&2; exit 1; }
exec "$HUB_BIN" "$@"
STUB
chmod +x "$T/bin/hubhang"
# tick28 <dir> [env...]: one fleet tick on pc through hubhang; prints the pauses slept
tick28() {
  local d="$T/$1"; shift
  mkdir -p "$d/hub" "$d/spool/dispatch"; agent "${d#"$T"/}" 300 CLE-001; agent "${d#"$T"/}" 301 CLE-002
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$d/spool" LEASE_PROC_ROOT="$d/proc" LEASE_SEND="$T/bin/send" LEASE_PANE_CMD="$T/bin/pane" \
    SENT="$d/sent" LEASE_HUB_CMD="$T/bin/hubhang" HUB_BIN="$T/bin/hub" HANG_N="$d/calls" HUB_DIR="$d/hub" HUB_NOW=7000 LEASE_NOW=7000 \
    LEASE_FLEET=main LEASE_MACHINE=pc LEASE_PRIORITY=pc,sat LEASE_HOLDDOWN=0 LEASE_ASKS=0 LEASE_AGENT_RUN=0 \
    LEASE_ORCH=CLE-001 LEASE_MASTER=CLE-002 LEASE_FAILOVER=CLE-003 "$@" bash -c '
    set -uo pipefail
    do_log() { :; }
    sleep() { echo "$1" >>"$SPOOL_ROOT/slept"; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    spl_lease_init && spl_lease_ids master failover orch && spl_fleet_ids && spl_fleet_hub_init && spl_lease_fleet_tick' >>"$T/out" 2>&1
  tr '\n' ' ' <"$d/spool/slept" 2>/dev/null
}
dl28() { grep -c -- "$2" "$T/$1/spool/dispatch/dial.log" 2>/dev/null || true; }
got="$(tick28 l28)"
[[ "$(hubh22 l28 orch)" == CLE-001@pc && "$(hubh22 l28 dispatch)" == CLE-002@pc && "$(grep -c HUB-UNREACHABLE "$T/l28/spool/dispatch/lease.log")" == 0 &&
   "$got" == "2 2 2 2 " ]] &&
  pass "28. every first try hung: each call retried once 2 s later, both roles held, no HUB-UNREACHABLE" ||
  fail "28. slept '$got' hub $(hubh22 l28 orch)/$(hubh22 l28 dispatch): $(cat "$T/l28/spool/dispatch/lease.log" 2>&1)"
[[ "$(dl28 l28 'rc=1 try=1 .*--role orch.*terminated signal received')" == 2 && "$(dl28 l28 'rc=1 try=1 .*--role dispatch')" == 2 &&
   "$(dl28 l28 'rc=0 try=2 .* :: ok$')" == 4 && "$(wc -l <"$T/l28/spool/dispatch/dial.log")" == 8 ]] &&
  pass "28. dial.log: one line per try, the failed ones with the CLI's error, the retries ok" ||
  fail "28. dial.log: $(cat "$T/l28/spool/dispatch/dial.log" 2>&1)"
tick28 l28c LEASE_HUB_TRIES=1 >/dev/null
[[ "$(grep -c HUB-UNREACHABLE "$T/l28c/spool/dispatch/lease.log")" == 2 && "$(dl28 l28c 'try=2')" == 0 ]] &&
  pass "28. CONTROL: LEASE_HUB_TRIES=1 (the old single try) logs HUB-UNREACHABLE per role" ||
  fail "28. control: $(cat "$T/l28c/spool/dispatch/lease.log" 2>&1)"
got="$(tick28 l28d HANG_ON=0 HUB_DOWN=1)"
[[ -z "$got" && "$(dl28 l28d 'try=2')" == 0 && "$(dl28 l28d 'rc=1 try=1 .*connection refused')" == 2 ]] &&
  pass "28. an error that is no \"hub unreachable\" is not retried" || fail "28. refused slept '$got': $(cat "$T/l28d/spool/dispatch/dial.log" 2>&1)"

# --- 29. a handback finishes on an unreachable tick (SPL-2246) --------------------
# The section 24 replay: st holds dispatch, tk (ranked first) takes it back at
# 3079, 19 s after st renewed; st stands down at 3120; then every tk dial fails.
rm -rf "$T/tk" "$T/st"; rm -f "$T"/hub/main.*
trio st 71
t29() { tick "$1" "$2" LEASE_PRIORITY=tk,st LEASE_PRIORITY_DISPATCH=tk,st "${@:3}"; }
t29 st 3000; trio tk 70; t29 st 3060; t29 tk 3079; t29 st 3120
[[ "$(hubh dispatch)" == CLE-002@tk && "$(mirror tk)" == CLE-002@st && "$(mirror st)" == CLE-002@tk ]] &&
  pass "29. setup: tk won the hub row and waits naming st; st stood down" || fail "29. setup: hub $(hubh dispatch) tk=$(mirror tk) st=$(mirror st)"
t29 tk 3130 HUB_DOWN=1
[[ "$(mirror tk)" == CLE-002@st && "$(sentc tk 'CLE-002 :: FLEET LEASE dispatch: you are now ACTIVE')" == 0 ]] &&
  pass "29. CONTROL: inside the wait (51 s) an unreachable tick still names st" || fail "29. early: tk=$(mirror tk) $(cat "$T/tk/sent" 2>&1)"
t29 tk 3139 HUB_DOWN=1
[[ "$(mirror tk)" == CLE-002@tk && "$(sentc tk 'CLE-002 :: FLEET LEASE dispatch: you are now ACTIVE')" == 1 && ! -e "$T/tk/spool/dispatch/fleet.dispatch.handback" ]] &&
  pass "29. the wait over and the hub unreachable: tk names itself and tells its seat ACTIVE once (no split brain)" ||
  fail "29. stuck: tk=$(mirror tk) st=$(mirror st) sent $(cat "$T/tk/sent" 2>&1)"
t29 tk 3200 HUB_DOWN=1
[[ "$(mirror tk)" == CLE-002@tk && "$(sentc tk 'CLE-002 :: FLEET LEASE dispatch: you are now ACTIVE')" == 1 ]] &&
  pass "29. still inside LEASE_STALE of its last renewal: tk keeps it, nothing told twice" || fail "29. hold: tk=$(mirror tk)"
t29 tk 3270 HUB_DOWN=1
[[ "$(mirror tk)" == none@unreachable ]] &&
  pass "29. past LEASE_STALE without a renewal tk demotes itself as before" || fail "29. demote: tk=$(mirror tk)"
# a wait that ends past LEASE_STALE: the row may be st's again, tk keeps the old name
rm -rf "$T/tk" "$T/st"; rm -f "$T"/hub/main.*
trio st 71; t29 st 4000; trio tk 70; t29 st 4060; t29 tk 4079
t29 tk 4300 HUB_DOWN=1
[[ "$(mirror tk)" == CLE-002@st && "$(sentc tk 'CLE-002 :: FLEET LEASE dispatch: you are now ACTIVE')" == 0 ]] &&
  pass "29. a wait that ends past LEASE_STALE keeps naming st" || fail "29. stale: tk=$(mirror tk)"

echo
(( fails == 0 )) && { echo "PASS: all fleet-lease.tst.sh assertions"; exit 0; }
echo "FAIL: $fails fleet-lease.tst.sh assertion(s)"; exit 1
