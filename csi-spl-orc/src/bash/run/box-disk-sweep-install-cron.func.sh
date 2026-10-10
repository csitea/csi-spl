#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove) the box disk sweep's cron line: ONE line in
# @description the running user's crontab (the box user, <DEV_USER>: its steps
# @description reach the other agent users through sudo -n), every 15 minutes
# @description from minute BOX_SWEEP_CRON_MINUTE (mod 15), running
# @description box-disk-sweep.sh with BOX_SWEEP_GATE=1 (a tick with enough free
# @description space runs only every 4 h; a low-space tick always runs, with
# @description shorter age limits) and DRY_RUN=BOX_SWEEP_CRON_DRY_RUN, appending to
# @description <log dir>/box-disk-sweep.log. Tagged `# csi-spl:box-disk-sweep`,
# @description matched only as the whole END of a line, so no other job is
# @description touched; idempotent (the line is replaced in place). From a
# @description linked worktree the install is refused (its path vanishes).
# @description Dry run unless DRY_RUN=0 (prints the crontab diff).
# @param BOX_SWEEP_CRON_ACTION (optional) - install (default) | remove
# @param BOX_SWEEP_CRON_MINUTE (optional) - 0..59, default 41
# @param BOX_SWEEP_CRON_DRY_RUN (optional) - the line's DRY_RUN: 0 (default) or 1
# @param BOX_SWEEP_CRON_LOG_DIR (optional) - default /var/<org>/<app>/box-disk-sweep
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_box_disk_sweep_install_cron
# @example DRY_RUN=0 ./run -a do_box_disk_sweep_install_cron
# @example DRY_RUN=0 BOX_SWEEP_CRON_ACTION=remove ./run -a do_box_disk_sweep_install_cron
#------------------------------------------------------------------------------
do_box_disk_sweep_install_cron() {
  local dry="${DRY_RUN:-1}" act="${BOX_SWEEP_CRON_ACTION:-install}" min="${BOX_SWEEP_CRON_MINUTE:-41}"
  local live="${BOX_SWEEP_CRON_DRY_RUN:-0}" ct="${BOX_SWEEP_CRONTAB:-crontab}"
  local app org logdir tag="csi-spl:box-disk-sweep" script want gd cd
  app="$(basename "$PROJ_PATH")"; app="${app%-orc}"; org="${app%%-*}"
  logdir="${BOX_SWEEP_CRON_LOG_DIR:-/var/${org}/${app}/box-disk-sweep}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ "$live" == 0 || "$live" == 1 ]] || { do_log "FATAL BOX_SWEEP_CRON_DRY_RUN must be 0 or 1, got: '$live'"; return 1; }
  case "$act" in install|remove) ;; *) do_log "FATAL BOX_SWEEP_CRON_ACTION must be install or remove, got: '$act'"; return 1 ;; esac
  [[ "$min" =~ ^[0-9]+$ ]] && (( min <= 59 )) || { do_log "FATAL BOX_SWEEP_CRON_MINUTE must be 0..59, got: '$min'"; return 1; }
  script="$PROJ_PATH/src/bash/scripts/box-disk-sweep.sh"
  gd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-dir 2>/dev/null)"
  cd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [[ "$act" == install && -n "$gd" && "$gd" != "$cd" && "${BOX_SWEEP_ALLOW_WORKTREE:-0}" != 1 ]]; then
    [[ "$dry" == 0 ]] && { do_log "FATAL $PROJ_PATH is a linked worktree: install from the main checkout - nothing changed"; return 1; }
    echo "WARN $PROJ_PATH is a linked worktree: the path below would vanish with it; install from the main checkout"
  fi
  want="$((min % 15))-59/15 * * * * DRY_RUN=$live BOX_SWEEP_GATE=1 BOX_SWEEP_LOCK=$logdir/box-disk-sweep.lock bash $script >> $logdir/box-disk-sweep.log 2>&1 # $tag"
  [[ "$act" == install ]] || want=""
  cron_drop_tagged_line "$ct" "$tag" "$dry" "$logdir" "$want" || return $(( $? == 2 ? 0 : 1 ))
  do_log "OK the box disk sweep cron is $([[ "$act" == install ]] && echo "installed (DRY_RUN=$live, every 15 min from :$((min % 15)), gated)" || echo removed)"
}
