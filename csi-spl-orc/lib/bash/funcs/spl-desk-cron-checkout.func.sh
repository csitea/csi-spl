#!/bin/bash
#------------------------------------------------------------------------------
# @description Shared helper for cron actions: create the self-updating checkout
# @description at $src from $SPL_DESK_CRON_REPO, branch $trunk. Called only when
# @description SPL_DESK_CRON_CREATE=1. Refuses an agent worktree (spl_desk_cron_src).
# @description Never exits; sets no trap. Returns 1 on failure, 0 on success.
# @param src - the checkout path to create
# @param trunk - the branch name to check out
# @example spl_desk_cron_checkout "/opt/csi/csi-spl-desk-cron" "master"
#------------------------------------------------------------------------------

spl_desk_cron_checkout() {
  local src="$1" trunk="$2"
  [[ -n "$src" && -n "$trunk" ]] || { do_log "FATAL spl_desk_cron_checkout: src and trunk are required"; return 1; }
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL spl_desk_cron_checkout: trunk is not a branch name: '$trunk'"; return 1; }

  git -C "$SPL_DESK_CRON_REPO" fetch -q origin "$trunk" &&
    git -C "$SPL_DESK_CRON_REPO" worktree add -q --detach "$src" "origin/$trunk" ||
    { do_log "FATAL could not create the self-updating checkout $src"; return 1; }
  return 0
}

#------------------------------------------------------------------------------
# @description Dry-run version of spl_desk_cron_checkout: prints the git command
# @description that would run, for DRY_RUN=1 logging.
# @param src - the checkout path to create
# @param trunk - the branch name to check out
# @example spl_desk_cron_checkout_dry "/opt/csi/csi-spl-desk-cron" "master"
#------------------------------------------------------------------------------

spl_desk_cron_checkout_dry() {
  local src="$1" trunk="$2"
  [[ -n "$src" && -n "$trunk" ]] || return 1
  do_log "INFO DRY_RUN would: git worktree add --detach $src origin/$trunk (the self-updating checkout)"
}