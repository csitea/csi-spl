#!/bin/bash
#------------------------------------------------------------------------------
# @description Create the self-updating checkout an install-cron action points
# @description its line at, when spl_desk_cron_src found none
# @description (SPL_DESK_CRON_CREATE=1): fetch <trunk> in SPL_DESK_CRON_REPO,
# @description then add a detached worktree at <src> on origin/<trunk>.
# @description With SPL_DESK_CRON_CREATE other than 1 it calls no git, rc 0.
# @description It never exits and sets no trap; each caller keeps its rc.
# @param src (required) - the checkout path (SPL_DESK_CRON_SRC)
# @param trunk (required) - the trunk branch (DESK_CRON_TRUNK, default master)
# @return 0 created, or nothing to create; 1 FATAL (logged)
# @example spl_desk_cron_checkout "$src" "$trunk" || return 1
#------------------------------------------------------------------------------
spl_desk_cron_checkout() {
  local src="$1" trunk="$2"
  [[ "${SPL_DESK_CRON_CREATE:-0}" == 1 ]] || return 0
  git -C "$SPL_DESK_CRON_REPO" fetch -q origin "$trunk" &&
    git -C "$SPL_DESK_CRON_REPO" worktree add -q --detach "$src" "origin/$trunk" ||
    { do_log "FATAL could not create the self-updating checkout $src"; return 1; }
}

#------------------------------------------------------------------------------
# @description The dry-run twin of spl_desk_cron_checkout: log the worktree add
# @description it would run when SPL_DESK_CRON_CREATE=1, else print nothing.
# @param src (required) - the checkout path (SPL_DESK_CRON_SRC)
# @param trunk (required) - the trunk branch
# @return 0 always
# @example [[ "$act" == install ]] && spl_desk_cron_checkout_dry "$src" "$trunk"
#------------------------------------------------------------------------------
spl_desk_cron_checkout_dry() {
  local src="$1" trunk="$2"
  [[ "${SPL_DESK_CRON_CREATE:-0}" == 1 ]] || return 0
  do_log "INFO DRY_RUN would: git worktree add --detach $src origin/$trunk (the self-updating checkout)"
}
