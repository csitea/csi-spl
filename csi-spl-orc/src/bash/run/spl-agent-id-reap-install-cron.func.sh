#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove) the dead-agent reaper's cron line
# @description (specs/061 section 3.6): ONE line in the running user's
# @description crontab, every REAP_CRON_EVERY minutes, running
# @description agent-id-reap.sh with DRY_RUN=REAP_DRY_RUN and appending to
# @description $SPOOL_ROOT/.reap/reap.log. Tagged `# csi-spl:agent-id-reap`,
# @description matched only as the whole END of a line, so no other job is
# @description touched; idempotent (the line is replaced in place). The line
# @description is installed reporting only (REAP_DRY_RUN=1, the default):
# @description turning it live is the orchestrator's call. From a linked
# @description worktree the install is refused (its path vanishes with it).
# @description Dry run unless DRY_RUN=0 (prints the crontab diff).
# @param REAP_CRON_ACTION (optional) - install (default) | remove
# @param REAP_CRON_EVERY (optional) - minutes between ticks, 1..59, default 15
# @param REAP_DRY_RUN (optional) - the line's DRY_RUN: 1 (default) or 0
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ./run -a do_spl_agent_id_reap_install_cron
# @example DRY_RUN=0 ./run -a do_spl_agent_id_reap_install_cron
# @example DRY_RUN=0 REAP_CRON_ACTION=remove ./run -a do_spl_agent_id_reap_install_cron
#------------------------------------------------------------------------------
do_spl_agent_id_reap_install_cron() {
  local dry="${DRY_RUN:-1}" act="${REAP_CRON_ACTION:-install}" every="${REAP_CRON_EVERY:-15}"
  local live="${REAP_DRY_RUN:-1}" root="${SPOOL_ROOT:-/var/spool-hub}" ct="${REAP_CRONTAB:-crontab}"
  local tag="csi-spl:agent-id-reap" script want gd cd
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ "$live" == 0 || "$live" == 1 ]] || { do_log "FATAL REAP_DRY_RUN must be 0 or 1, got: '$live'"; return 1; }
  case "$act" in install|remove) ;; *) do_log "FATAL REAP_CRON_ACTION must be install or remove, got: '$act'"; return 1 ;; esac
  [[ "$every" =~ ^[0-9]+$ ]] && (( every >= 1 && every <= 59 )) || { do_log "FATAL REAP_CRON_EVERY must be 1..59 minutes, got: '$every'"; return 1; }
  script="$PROJ_PATH/src/bash/features/spawn-agents/scripts/agent-id-reap.sh"
  gd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-dir 2>/dev/null)"
  cd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [[ "$act" == install && -n "$gd" && "$gd" != "$cd" && "${REAP_ALLOW_WORKTREE:-0}" != 1 ]]; then
    [[ "$dry" == 0 ]] && { do_log "FATAL $PROJ_PATH is a linked worktree: install from the main checkout - nothing changed"; return 1; }
    echo "WARN $PROJ_PATH is a linked worktree: the path below would vanish with it; install from the main checkout"
  fi
  want="*/$every * * * * DRY_RUN=$live bash $script >> $root/.reap/reap.log 2>&1 # $tag"
  [[ "$act" == install ]] || want=""
  cron_drop_tagged_line "$ct" "$tag" "$dry" "$root/.reap" "$want" || return $(( $? == 2 ? 0 : 1 ))
  do_log "OK the reaper cron is $([[ "$act" == install ]] && echo "installed (DRY_RUN=$live, every ${every}m)" || echo removed)"
}
