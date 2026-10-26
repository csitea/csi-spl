#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove) the hourly merged-branch prune's cron line
# @description (SPL-3609): ONE line in the running user's crontab, at minute
# @description GIT_PRUNE_CRON_MINUTE of every hour, running
# @description src/bash/scripts/git-prune-merged-cron.sh (PRUNE_ALL_MERGED=1
# @description DRY_RUN=0 do_git_prune_round_branches) and appending to
# @description /var/<org>/<app>/git-prune-merged/cron.out. Install it on the
# @description ONE box whose git pushes to the remote, from the main checkout.
# @description Tagged `# <org>-<app>:git-prune-merged`, matched only as the
# @description whole END of a line, so no other job is touched; idempotent.
# @description From a linked worktree the install is refused (its path
# @description vanishes with it). Dry run unless DRY_RUN=0 (prints the diff).
# @param GIT_PRUNE_CRON_ACTION (optional) - install (default) | remove
# @param GIT_PRUNE_CRON_MINUTE (optional) - 0..59, default 47
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_git_prune_merged_install_cron
# @example DRY_RUN=0 ./run -a do_git_prune_merged_install_cron
# @example DRY_RUN=0 GIT_PRUNE_CRON_ACTION=remove ./run -a do_git_prune_merged_install_cron
#------------------------------------------------------------------------------
do_git_prune_merged_install_cron() {
  local dry="${DRY_RUN:-1}" act="${GIT_PRUNE_CRON_ACTION:-install}" min="${GIT_PRUNE_CRON_MINUTE:-47}"
  local ct="${GIT_PRUNE_CRONTAB:-crontab}" app org logdir tag script want gd cd
  app="$(basename "$PROJ_PATH")"; app="${app%-orc}"; org="${app%%-*}"
  logdir="${GIT_PRUNE_CRON_LOG_DIR:-/var/$org/$app/git-prune-merged}" tag="$app:git-prune-merged"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  case "$act" in install|remove) ;; *) do_log "FATAL GIT_PRUNE_CRON_ACTION must be install or remove, got: '$act'"; return 1 ;; esac
  [[ "$min" =~ ^[0-9]+$ ]] && (( min <= 59 )) || { do_log "FATAL GIT_PRUNE_CRON_MINUTE must be 0..59, got: '$min'"; return 1; }
  script="$PROJ_PATH/src/bash/scripts/git-prune-merged-cron.sh"
  gd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
  cd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ "$act" == install && -n "$gd" && "$gd" != "$cd" && "${GIT_PRUNE_ALLOW_WORKTREE:-0}" != 1 ]]; then
    [[ "$dry" == 0 ]] && { do_log "FATAL $PROJ_PATH is a linked worktree: install from the main checkout - nothing changed"; return 1; }
    echo "WARN $PROJ_PATH is a linked worktree: the path below would vanish with it; install from the main checkout"
  fi
  want="$min * * * * bash $script >> $logdir/cron.out 2>&1 # $tag"
  [[ "$act" == install ]] || want=""
  cron_drop_tagged_line "$ct" "$tag" "$dry" "$logdir" "$want" || return $(( $? == 2 ? 0 : 1 ))
  do_log "OK the merged-branch prune cron is $([[ "$act" == install ]] && echo "installed (minute $min of every hour)" || echo removed)"
}
