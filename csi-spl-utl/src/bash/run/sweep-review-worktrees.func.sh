#!/bin/bash
#------------------------------------------------------------------------------
# @description Remove the finished review worktrees of this repo (SPL-5225,
# @description row 5 of the sat disk table). A linked worktree goes only when
# @description it is on a review/* branch (or detached at a commit an origin
# @description review/* branch holds that is not on origin/master), every
# @description commit of it is on origin or has a patch-id twin on
# @description origin/master, it is clean, not locked, and no live agent owns
# @description it (lane map with the hub answering, registry.tsv, no process
# @description cwd or open file in it). Through git worktree remove, as its
# @description owner; the branch stays. One PLAN|REMOVE / KEEP line per
# @description worktree with its reason and MB. Dry run unless DRY_RUN=0. By
# @description hand only: no cron and no sweep step runs it.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param REVIEW_WT_REPO (optional) - a checkout of the repo, default this one
# @param REVIEW_WT_SUDO (optional) - 1 (default) or 0: only this user's worktrees
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ./run -a do_sweep_review_worktrees
# @example DRY_RUN=0 ./run -a do_sweep_review_worktrees
#------------------------------------------------------------------------------
do_sweep_review_worktrees() {
  DRY_RUN="${DRY_RUN:-1}" REVIEW_WT_REPO="${REVIEW_WT_REPO:-$PROJ_PATH}" bash "$PROJ_PATH/src/bash/scripts/review-worktree-sweep.sh"
}
