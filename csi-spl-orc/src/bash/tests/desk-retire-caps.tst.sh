#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 147 R4 (SPL-2676): a desk seat an agent leaves is released at
#          once, so a per-workspace agent cap (spec 147 section 4) frees that
#          seat on the sidecar's next rescan (~10 s), not after the hub's
#          dropDead timeout (up to 60 min on a DESK_RETIRE=0 customer desk).
#   1. do_spl_desk_down DESK_AGENT=c-004 with c-005 on the same sidecar moves
#      c-004's seat to retired/ (inbox kept) and leaves the sidecar running.
#      RED before: FATAL, the seat stayed and kept counting against the cap.
#   2. CONTROL: an orchestrator or dispatcher seat (lease.conf) on a shared
#      sidecar is still refused and nothing moves; a dry run moves nothing.
#   3. the last agent on the box: the sidecar stops AND its seat is released
#      (RED before: the dir stayed, the next desk tick re-announced it).
#   3b. a desk service id (SPL_DESK_AGENT_IDS, the responder c-684): the
#      responder sweep's standby step (DESK_AGENT=c-684 DESK_ALL=1) stops the
#      sidecar and leaves the seat. RED before: the seat moved to retired/ and
#      the hub refused every send as c-684 (sat-rsp + box-rsp, 2026-10-20).
#   4. agent-id-retire.sh run as a user whose $HOME holds no desks (an agent
#      user retiring itself) drops the seat from the BOX user's desk root.
#      RED before: it read the caller's $HOME, found no desk, and the seat
#      stayed announced (g-940 on prd, retired 2026-10-14, still seated 10-20).
# No tmux, no cloud call, no sudo: the box user is the test's own user.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

D="$T/state/dev/desk/example-ws/box-desk"
PIDF="$D/spool/.hub/hub-run.pid"
mkdir -p "$D/spool/.hub" "$T/spool/dispatch"
printf 'LEASE_ORCH=c-001\n' >"$T/spool/dispatch/lease.conf"
seat() { mkdir -p "$D/spool/$1/inbox"; printf 'unread\n' >"$D/spool/$1/inbox/m.json"; }
seats() { (cd "$D/spool" && ls -A | LC_ALL=C sort | tr '\n' ' '); }
released() { compgen -G "$D/retired/$1.*/inbox/m.json" >/dev/null; }

# A fake sidecar: its cmdline carries " hub-run" (spl_desk_alive), and a TERM
# takes its sleep down with it.
SC=""
fake_sidecar() {
  # shellcheck disable=SC2016 # expands in the fake's own shell
  bash -c 'trap "kill \$c 2>/dev/null; exit 0" TERM; sleep 60 & c=$!; wait' hub-run &
  SC=$!; echo "$SC" >"$PIDF"
}
stop_sidecar() { [[ -n "$SC" ]] && kill "$SC" 2>/dev/null; wait "$SC" 2>/dev/null; SC=""; }
trap 'stop_sidecar; rm -rf "$T"' EXIT

# down_orc [VAR=value]...: do_spl_desk_down (or $SNIPPET) in example-ws, the
# desk cnf (cloud env, hub url) stubbed: the action reads the state dir only.
down_orc() {
  SNIPPET="do_spl_desk_cnf() { return 0; }; ${SNIPPET:-do_spl_desk_down}" \
    in_orc SPOOL_ROOT="$T/spool" SPOOL_DESK_BOX= TENANT_ID=example-ws "$@"
}
alive() { SNIPPET="spl_desk_alive '$PIDF'" down_orc >/dev/null 2>&1; }

# --- 1. a co-seated agent: its seat is released, the sidecar stays --------------
seat c-004; seat c-005; seat c-001; fake_sidecar
alive && pass "CONTROL the fake sidecar reads as alive" || fail "CONTROL the fake sidecar is not alive"
before="$(seats)"
out=$(down_orc DESK_AGENT=c-004 2>&1); rc=$?
[[ $rc -eq 0 && "$(seats)" == "$before" && "$out" == *"DRY_RUN would: release the seat of c-004"* ]] &&
  pass "a dry run names the seat it would release and moves nothing" || fail "dry run (rc=$rc): $out"
out=$(down_orc DESK_AGENT=c-004 DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && ! -e "$D/spool/c-004" ]] && released c-004 &&
  pass "desk_down DESK_AGENT=c-004 releases its seat at once, inbox kept in retired/" ||
  fail "c-004 seat not released (rc=$rc): $out"
alive && [[ -d "$D/spool/c-005" && -d "$D/spool/c-001" ]] &&
  pass "CONTROL the shared sidecar and the other seats keep running (SPL-1004)" ||
  fail "the sidecar or another seat went down: $(seats)"
[[ "$out" == *'"released": true'* && "$out" == *'"was_running": true'* && "$out" == *'"stopped_pid": null'* ]] &&
  pass "its JSON line says released, sidecar not stopped" || fail "JSON line: $out"

# --- 2. CONTROL: an orchestrator seat on a shared sidecar is refused ---------------
before="$(seats)"
out=$(down_orc DESK_AGENT=c-001 DRY_RUN=0 2>&1); rc=$?
[[ $rc -ne 0 && "$(seats)" == "$before" ]] && alive &&
  pass "CONTROL an orchestrator seat on a shared sidecar is refused, nothing moves" ||
  fail "od seat (rc=$rc): $out"

# --- 3. the last agent: sidecar stops and the seat is released ---------------------
rm -rf "$D/spool/c-001"
out=$(down_orc DESK_AGENT=c-005 DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *'"was_running": true'* && ! -e "$D/spool/c-005" ]] && released c-005 && ! alive &&
  pass "the last agent stops the sidecar and releases its seat" || fail "last agent (rc=$rc): $out"
stop_sidecar

# --- 3b. a desk service id: the sidecar stops, the seat stays ---------------------
. "$PROJ_ROOT/lib/bash/funcs/spl-desk-agents.func.sh"
for sid in $SPL_DESK_AGENT_IDS; do
  seat "$sid"; seat c-006; fake_sidecar
  out=$(down_orc DESK_AGENT="$sid" DESK_ALL=1 DRY_RUN=0 2>&1); rc=$?
  [[ $rc -eq 0 && -d "$D/spool/$sid/inbox" ]] && ! released "$sid" && ! alive &&
    pass "desk service id $sid: DESK_ALL stops the sidecar and keeps its seat" ||
    fail "desk service id $sid (rc=$rc, seats: $(seats)): $out"
  [[ "$out" == *'"released": false'* ]] && pass "...its JSON line says not released" || fail "JSON line: $out"
  fake_sidecar
  out=$(down_orc DESK_AGENT="$sid" DRY_RUN=0 2>&1); rc=$?
  [[ $rc -ne 0 && -d "$D/spool/$sid/inbox" ]] && alive &&
    pass "CONTROL desk service id $sid on a shared sidecar is refused, nothing moves" ||
    fail "desk service id $sid shared (rc=$rc): $out"
  stop_sidecar; rm -rf "${D:?}/spool/$sid" "$D/spool/c-006"
done

# --- 4. agent-id-retire.sh as an agent user: the box user's desk root --------------
RET="$PROJ_ROOT/src/bash/features/spawn-agents/scripts/agent-id-retire.sh"
BH="$T/box-home"; CH="$T/agent-home"
RD="$BH/.local/share/csi-spl/cloud/prd/desk/example-ws/tb/spool"
mkdir -p "$RD/c-004/inbox" "$RD/c-005/inbox" "$CH" "$T/rspool/c-004/inbox"
printf 'unread\n' >"$RD/c-004/inbox/m.json"
out=$(env -u DESK_STATE_ROOT HOME="$CH" SPOOL_BOX_HOME="$BH" SPOOL_BOX_USER="$(id -un)" \
  SPOOL_ROOT="$T/rspool" SPOOL_DESK_BOX=tb SPOOL_TMUX_SOCKET="$T/no-tmux" \
  RETIRE_DESKS=1 bash "$RET" --apply c-004 2>&1); rc=$?
[[ $rc -eq 0 && ! -e "$RD/c-004" ]] && compgen -G "$RD/.retired/c-004.*/inbox/m.json" >/dev/null &&
  pass "retire as the agent user drops the seat from the box user's desk root" ||
  fail "retire left the seat (rc=$rc): $out"
[[ -d "$RD/c-005" ]] && pass "CONTROL the other seat stays" || fail "CONTROL c-005 moved"

echo "=== $([[ $fails -eq 0 ]] && echo 'all desk-retire-caps.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
