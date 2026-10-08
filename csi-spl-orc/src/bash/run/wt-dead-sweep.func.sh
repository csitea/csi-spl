#!/bin/bash
#------------------------------------------------------------------------------
# @description Remove the linked worktrees of agents that are gone: never a
# @description role seat, an alive agent record, a worktree a process works in,
# @description a dirty one, one whose HEAD is not on origin/master, or one
# @description changed in the last WT_SWEEP_AGE_H hours. `git worktree remove`
# @description (no --force) and `git branch -d`. One PLAN|REMOVE / KEEP line per
# @description worktree. Dry run unless DRY_RUN=0. Runs every 4 h inside
# @description do_box_disk_sweep.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param WT_SWEEP_AGE_H (optional) - idle hours before removal, default 72
# @param WT_SWEEP_KEEP_RE (optional) - ids never removed, default the role seats
# @example ./run -a do_wt_dead_sweep
# @example DRY_RUN=0 ./run -a do_wt_dead_sweep
#------------------------------------------------------------------------------
do_wt_dead_sweep() {
  DRY_RUN="${DRY_RUN:-1}" bash "$PROJ_PATH/src/bash/scripts/wt-dead-sweep.sh"
}
