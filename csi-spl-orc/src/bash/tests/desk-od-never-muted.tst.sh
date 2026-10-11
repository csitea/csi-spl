#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: an orchestrator or dispatcher seat (LEASE_ORCH / LEASE_MASTER /
#          LEASE_FAILOVER of <spool root>/dispatch/lease.conf) is never muted
#          on any desk. prd 2026-10-10: a hand DESK_POKE=0 left .no-poke on
#          c-001..003 in sienna and aleko-gik, the seated-only reconcile kept
#          it on every tick, and on 2026-10-11 six human posts in sienna
#          reached no dispatcher prompt.
#   1. do_spl_desk_up refuses DESK_POKE=0 for such a seat, naming the rule.
#      CONTROL: DESK_POKE=0 for any other seat is accepted
#   2. one do_spl_desk_up_tenants pass removes a planted .no-poke of c-002,
#      logs it and seats it with the poke on. CONTROL: the hand mute of a
#      non-dispatcher seat stays, and without lease.conf c-002's stays too
#   3. the sidecar restart of do_spl_desk_up_boxes un-mutes it as well
# No cloud, tmux or spool call: do_spl_desk_up is stubbed where it would seat.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

in_orc() {
  env -u SPOOL_DESK_BOX PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" \
      SPL_ORG_APP="$(basename "$PROJ_ROOT" | sed 's/-orc$//')" \
      SPOOL_ROOT="$T/spool" SPOOL_BOX_USER="$(id -un)" SPOOL_TMUX_SOCKET="$T/nosuch.sock" \
      SPOOL_BOX_ENV="$T/no-box.env" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}
lease() {
  mkdir -p "$T/spool/dispatch"
  printf 'LEASE_MASTER=c-002\nLEASE_FAILOVER=c-003\nLEASE_ORCH=c-001\n' >"$T/spool/dispatch/lease.conf"
}
lease

# --- 1. do_spl_desk_up refuses to mute a dispatcher seat ---------------------------
out=$(SNIPPET=do_spl_desk_up in_orc TENANT_ID=t1 DESK_AGENT=c-002 DESK_POKE=0 DESK_NOTIFY_CMD=off 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"FATAL c-002 is an orchestrator or dispatcher seat"*"never muted"* ]] &&
  pass "DESK_POKE=0 for the master dispatcher c-002 is refused, naming the rule" || fail "c-002 mute (rc=$rc): $out"
out=$(SNIPPET=do_spl_desk_up in_orc TENANT_ID=t1 DESK_AGENT=c-001 DESK_POKE=0 DESK_NOTIFY_CMD=off 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"FATAL c-001 is an orchestrator"* ]] &&
  pass "DESK_POKE=0 for the orchestrator c-001 is refused" || fail "c-001 mute (rc=$rc): $out"
out=$(SNIPPET=do_spl_desk_up in_orc TENANT_ID=t1 DESK_AGENT=c-842 DESK_POKE=0 DESK_NOTIFY_CMD=off 2>&1); rc=$?
[[ $rc -eq 0 && "$out" != *FATAL* ]] &&
  pass "CONTROL DESK_POKE=0 for a lane seat (c-842) is accepted" || fail "CONTROL c-842 mute (rc=$rc): $out"

# --- 2. one up_tenants pass un-mutes the dispatcher seat ---------------------------
D="$T/state/dev/desk/sienna-x/box-desk"
plant() {
  mkdir -p "$D/spool/c-002/inbox" "$D/spool/c-842/inbox" "$D/spool/.hub"
  touch "$D/spool/c-002/.no-poke" "$D/spool/c-842/.no-poke"
}
STUB='spl_desk_live_agents() { printf "%s\n" c-002 c-842; }
      do_spl_desk_up() { echo "CALL up $TENANT_ID $DESK_AGENT poke=$DESK_POKE"; }'
plant
out=$(SNIPPET="$STUB; do_spl_desk_up_tenants" in_orc DRY_RUN=0 2>&1); rc=$?
[[ ! -e "$D/spool/c-002/.no-poke" ]] &&
  pass "after one up_tenants pass the planted .no-poke of c-002 is gone" || fail "c-002 still muted: $out"
[[ "$out" == *"WARN removed the mute of c-002"* && "$out" == *"CALL up sienna-x c-002 poke=1"* ]] &&
  pass "…logged, and c-002 is seated with its prompt poked" || fail "c-002 log/seat: $out"
[[ -e "$D/spool/c-842/.no-poke" && "$out" == *"CALL up sienna-x c-842 poke=0"* ]] &&
  pass "CONTROL the hand mute of a non-dispatcher seat (c-842) stays" || fail "CONTROL c-842 un-muted: $out"
rm -f "$T/spool/dispatch/lease.conf"; plant
out=$(SNIPPET="$STUB; do_spl_desk_up_tenants" in_orc DRY_RUN=0 2>&1)
[[ -e "$D/spool/c-002/.no-poke" && "$out" == *"CALL up sienna-x c-002 poke=0"* ]] &&
  pass "CONTROL with no lease.conf c-002 is an ordinary seat: its mute stays" || fail "CONTROL no lease: $out"
lease

# --- 3. the other desk boxes' sidecar restart un-mutes it too ----------------------
B="$T/state/dev/desk/sienna-x/box-rsp"
mkdir -p "$B/spool/c-003/inbox" "$B/spool/.hub"; touch "$B/spool/c-003/.no-poke"
bash -c 'exit 0' & DEAD=$!; wait "$DEAD"; echo "$DEAD" >"$B/spool/.hub/hub-run.pid"
out=$(SNIPPET='do_spl_desk_up() { echo "CALL up $TENANT_ID $DESK_BOX $DESK_AGENT poke=$DESK_POKE"; }; do_spl_desk_up_boxes' \
  in_orc DRY_RUN=0 2>&1)
[[ ! -e "$B/spool/c-003/.no-poke" && "$out" == *"CALL up sienna-x box-rsp c-003 poke=1"* ]] &&
  pass "do_spl_desk_up_boxes restarts the failover c-003 un-muted" || fail "up_boxes c-003: $out"

echo "=== $([[ $fails -eq 0 ]] && echo 'all desk-od-never-muted.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
