#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove) the OD pool supervisor's cron lines (spec
# @description 134 section 4.2, step P3): every 30 s = TWO lines in the
# @description running user's crontab, `* * * * *` (tag
# @description `# csi-spl:od-pool-supervise`) and the same after `sleep 30`
# @description (tag `# csi-spl:od-pool-supervise-30`), each running
# @description do_spl_od_pool_supervise with OD_POOL_SUPERVISE=<OD_CRON_SUPERVISE>
# @description and appending to <spool root>/od/supervise.log. The lines are
# @description installed OFF (OD_CRON_SUPERVISE=0, the default): off, the
# @description supervisor only retires the seats it spawned. Turning it on is
# @description the P5 dev drill's call. Tags are matched only as the whole END
# @description of a line, so no other job is touched; idempotent (a line is
# @description replaced in place). From a linked worktree the install is
# @description refused (its path vanishes with it). Dry run unless DRY_RUN=0
# @description (prints the crontab diff).
# @param OD_CRON_ACTION (optional) - install (default) | remove
# @param OD_CRON_SUPERVISE (optional) - the lines' OD_POOL_SUPERVISE: 0 (default) or 1
# @param OD_CRONTAB (optional, tests) - the crontab command, default crontab
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ./run -a do_spl_od_pool_supervise_install_cron
# @example DRY_RUN=0 ./run -a do_spl_od_pool_supervise_install_cron
# @example DRY_RUN=0 OD_CRON_ACTION=remove ./run -a do_spl_od_pool_supervise_install_cron
#------------------------------------------------------------------------------
do_spl_od_pool_supervise_install_cron() {
  local dry="${DRY_RUN:-1}" act="${OD_CRON_ACTION:-install}" on="${OD_CRON_SUPERVISE:-0}"
  local root="${SPOOL_ROOT:-/var/spool-hub}" ct="${OD_CRONTAB:-crontab}" tag="csi-spl:od-pool-supervise"
  local cmd gd cd want="" want30="" rc=0
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ "$on" == 0 || "$on" == 1 ]] || { do_log "FATAL OD_CRON_SUPERVISE must be 0 or 1, got: '$on'"; return 1; }
  case "$act" in install|remove) ;; *) do_log "FATAL OD_CRON_ACTION must be install or remove, got: '$act'"; return 1 ;; esac
  gd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-dir 2>/dev/null)"
  cd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [[ "$act" == install && -n "$gd" && "$gd" != "$cd" && "${OD_CRON_ALLOW_WORKTREE:-0}" != 1 ]]; then
    [[ "$dry" == 0 ]] && { do_log "FATAL $PROJ_PATH is a linked worktree: install from the main checkout - nothing changed"; return 1; }
    echo "WARN $PROJ_PATH is a linked worktree: the path below would vanish with it; install from the main checkout"
  fi
  cmd="cd $PROJ_PATH && OD_POOL_SUPERVISE=$on SPOOL_ROOT=$root ./run -a do_spl_od_pool_supervise >> $root/od/supervise.log 2>&1"
  if [[ "$act" == install ]]; then
    want="* * * * * $cmd # $tag"
    want30="* * * * * sleep 30; $cmd # $tag-30"
  fi
  cron_drop_tagged_line "$ct" "$tag" "$dry" "$root/od" "$want" || rc=$?
  (( rc == 0 || rc == 2 )) || return 1
  rc=0
  cron_drop_tagged_line "$ct" "$tag-30" "$dry" "$root/od" "$want30" || rc=$?
  (( rc == 0 || rc == 2 )) || return 1
  do_log "OK the od pool supervisor cron is $([[ "$act" == install ]] && echo "installed (OD_POOL_SUPERVISE=$on, every 30 s)" || echo removed)"
}
