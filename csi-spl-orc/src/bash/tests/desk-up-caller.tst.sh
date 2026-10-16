#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a lane never starts a desk that is not its own (SPL-2227). On
#          2026-10-16 a mistral lane with no deploy step in its brief ran
#          AGENT_ID=m-260 ENV=prd TENANT_ID=csitea DESK_AGENT=c-001 DRY_RUN=0
#          do_spl_desk_up six times, rc 0. Rule: unified-fs.md section 6.1.
#   1. RED: that exact call shape is refused before anything starts, naming
#      DESK_AGENT, the caller and what to do instead; the caller also
#      resolves from SPOOL_AGENT_ID and from the $TMUX_PANE window name
#   2. GREEN: a role seat for itself (c-001) and for another seat (c-002), no
#      caller id (the desk cron and do_spl_desk_up_all under it), and a lane
#      seating ITSELF (spool-agent.sh at spawn, spool-mcp.sh --seat) proceed
#   3. a dry run stays open to a lane
# No cloud, tmux or spool call: every seam past the guard is stubbed and
# prints STARTED, so "nothing started" is its absence.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

mkdir -p "$T/bin"
printf '#!/bin/sh\necho "m-260 desk work"\n' >"$T/bin/tmux"; chmod +x "$T/bin/tmux"

# up <env assignments...>: one do_spl_desk_up, the caller ids cleared first
up() {
  env -u AGENT_ID -u SPOOL_AGENT_ID -u MCP_BOT_AGENT_ID -u TMUX_PANE -u CLE_TMUX_PANE -u SPOOL_DESK_BOX \
      PATH="$T/bin:$PATH" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/prd" \
      SPL_ORG_APP="$(basename "$PROJ_ROOT" | sed 's/-orc$//')" \
      SPOOL_ROOT="$T/spool" SPOOL_BOX_USER="$(id -un)" SPOOL_TMUX_SOCKET="$T/nosuch.sock" \
      SPOOL_BOX_ENV="$T/no-box.env" ENV=prd TENANT_ID=csitea DESK_NOTIFY_CMD=off DESK_WAIT_SECS=0 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_box_ws_guard() { return 0; }
    do_spl_desk_cnf() { SPL_HUB_URL=https://hub.example.com SPL_WUI_URL=https://example.com; return 0; }
    spl_host_spool() { echo STARTED host-spool; }
    spl_desk_pin() { echo pub; }
    spl_desk_mute() { :; }
    spl_desk_purge_pokes() { :; }
    spl_desk_sidecar() { echo STARTED sidecar; SPL_DESK_PID=1; }
    spl_desk_wait_roster() { return 0; }
    spl_desk_show_pane() { :; }
    do_spl_desk_up' 2>&1
}

# --- 1. RED: a lane starting another seat's desk is refused --------------------
out=$(up AGENT_ID=m-260 DESK_AGENT=c-001 DRY_RUN=0); rc=$?
[[ $rc -ne 0 && "$out" == *"FATAL DESK_AGENT=c-001 is not you (m-260): a lane never starts a desk; send c-001 the command"* ]] &&
  pass "m-260's exact call (prd, csitea, DESK_AGENT=c-001, DRY_RUN=0) is refused, naming both ids" ||
  fail "m-260 call (rc=$rc): $out"
[[ "$out" != *STARTED* && ! -e "$T/state/prd/desk" ]] &&
  pass "…and nothing started: no spool, no sidecar, no desk state dir" || fail "m-260 started something: $out"
out=$(up SPOOL_AGENT_ID=m-260 DESK_AGENT=c-002 DRY_RUN=0); rc=$?
[[ $rc -ne 0 && "$out" == *"is not you (m-260)"* && "$out" != *STARTED* ]] &&
  pass "the caller resolves from SPOOL_AGENT_ID too" || fail "SPOOL_AGENT_ID (rc=$rc): $out"
out=$(up TMUX_PANE=%9 DESK_AGENT=c-001 DRY_RUN=0); rc=$?
[[ $rc -ne 0 && "$out" == *"is not you (m-260)"* && "$out" != *STARTED* ]] &&
  pass "…and from the \$TMUX_PANE window name" || fail "TMUX_PANE (rc=$rc): $out"
out=$(up AGENT_ID=m-260@sat DESK_AGENT=c-001 DRY_RUN=0); rc=$?
[[ $rc -ne 0 && "$out" == *"is not you (m-260)"* ]] &&
  pass "a qualified id <lane>@<box> is the lane too" || fail "qualified (rc=$rc): $out"

# --- 2. GREEN: seats, the cron and a lane seating itself proceed --------------
for c in "AGENT_ID=c-001 DESK_AGENT=c-001:a role seat for its own desk" \
         "AGENT_ID=c-001 DESK_AGENT=c-002:a role seat for another seat (restore, rotation)" \
         "DESK_AGENT=c-001:no caller id (the desk cron, do_spl_desk_up_all under it)" \
         "AGENT_ID=m-260 DESK_AGENT=m-260:a lane seating itself (spool-agent.sh, spool-mcp.sh --seat)"; do
  read -ra kv <<<"${c%%:*}"
  out=$(up "${kv[@]}" DRY_RUN=0); rc=$?
  [[ $rc -eq 0 && "$out" == *"STARTED sidecar"* && "$out" != *FATAL* ]] &&
    pass "CONTROL ${c#*:} proceeds" || fail "CONTROL ${c#*:} (rc=$rc): $out"
done

# --- 3. a dry run stays open ---------------------------------------------------------
out=$(up AGENT_ID=m-260 DESK_AGENT=c-001); rc=$?
[[ $rc -eq 0 && "$out" == *"OK DRY_RUN nothing was touched"* && "$out" != *STARTED* ]] &&
  pass "a lane's dry run for c-001 stays open and touches nothing" || fail "dry run (rc=$rc): $out"

echo "=== $([[ $fails -eq 0 ]] && echo 'all desk-up-caller.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
