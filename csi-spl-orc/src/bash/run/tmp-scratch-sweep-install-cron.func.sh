#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove) the /tmp scratch sweep's cron line: ONE
# @description line in the AGENT user's crontab (SPOOL_AGENT_USER, else the
# @description box config's SPOOL_AGENT_USER= line, else the running user;
# @description another user's is written with sudo -n crontab -u, SPL-4463),
# @description at minute SCRATCH_CRON_MINUTE of every hour, running
# @description tmp-scratch-sweep.sh with DRY_RUN=SCRATCH_CRON_DRY_RUN and
# @description appending to <agent home>/.cache/csi-spl/tmp-scratch-sweep.log. Tagged
# @description `# csi-spl:tmp-scratch-sweep`, matched only as the whole END of
# @description a line, so no other job is touched; idempotent (the line is
# @description replaced in place). From a linked worktree the install is
# @description refused (its path vanishes with it).
# @description Dry run unless DRY_RUN=0 (prints the crontab diff).
# @param SCRATCH_CRON_ACTION (optional) - install (default) | remove
# @param SCRATCH_CRON_MINUTE (optional) - 0..59, default 17
# @param SCRATCH_CRON_DRY_RUN (optional) - the line's DRY_RUN: 0 (default) or 1
# @param SPOOL_AGENT_USER (optional) - whose crontab; default as above
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_tmp_scratch_sweep_install_cron
# @example DRY_RUN=0 ./run -a do_tmp_scratch_sweep_install_cron
# @example DRY_RUN=0 SCRATCH_CRON_ACTION=remove ./run -a do_tmp_scratch_sweep_install_cron
#------------------------------------------------------------------------------
do_tmp_scratch_sweep_install_cron() {
  local dry="${DRY_RUN:-1}" act="${SCRATCH_CRON_ACTION:-install}" min="${SCRATCH_CRON_MINUTE:-17}"
  local live="${SCRATCH_CRON_DRY_RUN:-0}" box_env="${SPOOL_BOX_ENV-${SPOOL_ROOT:-/var/spool-hub}/box.env}"
  local agent="${SPOOL_AGENT_USER:-}" sudo_="${SCRATCH_SUDO:-sudo -n}" ct logdir
  local tag="csi-spl:tmp-scratch-sweep" script want gd cd
  [[ -n "$agent" || -z "$box_env" || ! -r "$box_env" ]] \
    || agent="$(sed -n 's/^SPOOL_AGENT_USER=//p' "$box_env" | tail -1 | tr -d "\"'\r")"
  agent="${agent:-$(id -un)}"
  id -u "$agent" >/dev/null 2>&1 || { do_log "FATAL no such agent user '$agent'"; return 1; }
  ct="${SCRATCH_CRONTAB:-crontab}"
  [[ -n "${SCRATCH_CRONTAB:-}" || "$agent" == "$(id -un)" ]] || ct="$sudo_ crontab -u $agent"
  logdir="${SCRATCH_CRON_LOG_DIR:-$(getent passwd "$agent" | cut -d: -f6)/.cache/csi-spl}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ "$live" == 0 || "$live" == 1 ]] || { do_log "FATAL SCRATCH_CRON_DRY_RUN must be 0 or 1, got: '$live'"; return 1; }
  case "$act" in install|remove) ;; *) do_log "FATAL SCRATCH_CRON_ACTION must be install or remove, got: '$act'"; return 1 ;; esac
  [[ "$min" =~ ^[0-9]+$ ]] && (( min <= 59 )) || { do_log "FATAL SCRATCH_CRON_MINUTE must be 0..59, got: '$min'"; return 1; }
  script="$PROJ_PATH/src/bash/scripts/tmp-scratch-sweep.sh"
  gd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-dir 2>/dev/null)"
  cd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [[ "$act" == install && -n "$gd" && "$gd" != "$cd" && "${SCRATCH_ALLOW_WORKTREE:-0}" != 1 ]]; then
    [[ "$dry" == 0 ]] && { do_log "FATAL $PROJ_PATH is a linked worktree: install from the main checkout - nothing changed"; return 1; }
    echo "WARN $PROJ_PATH is a linked worktree: the path below would vanish with it; install from the main checkout"
  fi
  want="$min * * * * DRY_RUN=$live bash $script >> $logdir/tmp-scratch-sweep.log 2>&1 # $tag"
  [[ "$act" == install ]] || want=""
  echo "INFO the crontab of the agent user $agent"
  if [[ "$dry" == 0 && "$act" == install && "$agent" != "$(id -un)" && ! -d "$logdir" ]]; then
    $sudo_ -u "$agent" -- mkdir -p "$logdir" || { do_log "FATAL cannot create $logdir as $agent"; return 1; }
  fi
  cron_drop_tagged_line "$ct" "$tag" "$dry" "$logdir" "$want" || return $(( $? == 2 ? 0 : 1 ))
  do_log "OK the scratch sweep cron is $([[ "$act" == install ]] && echo "installed (DRY_RUN=$live, hourly at :$min)" || echo removed)"
}
