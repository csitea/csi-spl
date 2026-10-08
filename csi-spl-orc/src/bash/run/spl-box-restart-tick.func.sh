#!/bin/bash
#------------------------------------------------------------------------------
# @description do_spl_box_restart_tick - the cron entry (one line per box,
# @description do_spl_box_restart_install_cron): the after-boot pass
# @description (do_spl_box_restart_after) when a pending restart has booted,
# @description else the restart (do_spl_box_restart_run) when the slot is due,
# @description else nothing (and prints nothing).
# @param BOX_RESTART_AT (required) - "<cron weekday> <HH:MM> <tz>": the slot
# @param BOX_RESTART_WINDOW_MIN (optional) - minutes after the slot a deferred restart retries, default 180
# @example BOX_RESTART_AT='0 03:30 Europe/Helsinki' ./run -a do_spl_box_restart_tick
#------------------------------------------------------------------------------
declare -F spl_brx_slot_parse >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-box-restart-run.func.sh"
declare -F do_spl_box_restart_after >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-box-restart-after.func.sh"

do_spl_box_restart_tick() {
  local root dir rc=0 bt0 since
  root="${SPOOL_ROOT:-/var/spool-hub}"; dir="$root/dispatch/box-restart"
  spl_brx_slot_parse || return 1
  mkdir -p "$dir" || return 1
  exec 8>"$dir/.lock"
  flock -n 8 || { exec 8>&-; return 0; }
  if [[ -f "$dir/pending" ]]; then
    bt0="$(spl_brx_pending_get "$dir/pending" btime)"
    if [[ "$(spl_brs_btime)" != "$bt0" ]]; then
      do_spl_box_restart_after || rc=1
    else
      since="$(date -d "$(spl_brx_pending_get "$dir/pending" since)" +%s 2>/dev/null || echo 0)"
      if (( $(spl_brx_now) - since > 900 )); then
        do_log "ERROR $dir/pending is 15 min old and the box has not rebooted: dropped; start the runners by hand if the drain stopped them (systemctl start 'actions.runner.*')"
        mv "$dir/pending" "$dir/$(spl_brx_pending_get "$dir/pending" utc).noboot"; rc=1
      fi
    fi
  elif spl_brx_slot_due "$dir"; then
    do_log "INFO the slot ${BOX_RESTART_AT} is due: the scheduled restart"
    DRY_RUN=0 do_spl_box_restart_run || rc=1
  fi
  exec 8>&-
  return "$rc"
}
