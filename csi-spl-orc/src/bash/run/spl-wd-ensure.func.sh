#!/bin/bash
#------------------------------------------------------------------------------
# @description Start this box's watchdog when it is not running (spec 093
# @description section 6, the `* * * * *` keeper). Starts ONLY do_spl_watchdog.
# @description It does not start poll loops, and it runs with or without
# @description <spool root>/peer/seats (P0/P1 have none). A second run while the
# @description loop holds dispatch/wd/run.lock starts nothing. The loop it
# @description starts acts (DRY_RUN=0) and runs forever (WD_TICKS cleared): a
# @description proof tick stays on the caller's own do_spl_watchdog.
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param WD_RUN (optional) - the ./run that starts the loop (tests)
# @param WD_ENSURE_WATCH_DRY (optional) - DRY_RUN handed to the loop, default 0
# @example ./run -a do_spl_wd_ensure
#------------------------------------------------------------------------------
declare -F spl_lease_detach >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-dispatch-lease.func.sh"

# The watchdog dir. Seats are not required and are not read here.
spl_wd_ensure_init() {
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"
  export SPOOL_ROOT
  spl_lease_init || return 1
  WD_DIR="$LEASE_DIR/wd"
  mkdir -p "$WD_DIR" || { do_log "FATAL cannot create $WD_DIR"; return 1; }
  return 0
}

# 0 when a watchdog holds the same lock do_spl_watchdog takes for its life.
spl_wd_ensure_running() {
  [[ -f "$WD_DIR/run.lock" ]] || return 1
  ! flock -n "$WD_DIR/run.lock" true
}

# Start the acting loop, detached. The subshell keeps the DRY_RUN / WD_TICKS
# prefix off the caller (bash keeps a function prefix assignment).
spl_wd_ensure_start() {
  local run="${WD_RUN:-${PROJ_PATH:-}/run}"
  [[ -x "$run" ]] || { do_log "FATAL watchdog runner is missing or not executable: ${run:-<none>}"; return 1; }
  (
    export DRY_RUN="${WD_ENSURE_WATCH_DRY:-0}"
    export WD_TICKS=""
    spl_lease_detach "$WD_DIR/run.out" "$run" -a do_spl_watchdog
  )
  do_log "INFO watchdog started (log $WD_DIR/run.out)"
  return 0
}

do_spl_wd_ensure() {
  spl_wd_ensure_init || return 1
  if spl_wd_ensure_running; then
    do_log "INFO watchdog running (pid $(cat "$WD_DIR/run.pid" 2>/dev/null || echo unknown))"
    return 0
  fi
  if [[ ! -s "$SPOOL_ROOT/peer/seats" ]]; then
    do_log "INFO no seats in $SPOOL_ROOT/peer/seats - starting the watchdog anyway"
  fi
  spl_wd_ensure_start
}
