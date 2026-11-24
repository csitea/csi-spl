#!/bin/bash
#------------------------------------------------------------------------------
# @description Remove the git worktrees that retired agents left directly
# @description under /tmp (review seats' checkouts and red-control copies,
# @description SPL-6347), only when the agent is PROVEN to have made the tree
# @description (its spl-owner marker, or a message it sent naming the path;
# @description never its name alone), the id is retired here and live on no
# @description box (registry, tmux, the fleet lane map with the hub
# @description answering), no process holds it, nothing is mounted under it
# @description and it is idle TMP_WT_IDLE_H hours. Clean: git worktree
# @description remove; dirty: --force only for a red / parent copy, any other
# @description dirty tree is kept. One PLAN|DO remove / KEEP line per tree. Dry
# @description run unless DRY_RUN=0. By hand only: no cron and no sweep step
# @description runs it.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param TMP_WT_ROOT (optional) - default /tmp
# @param TMP_WT_IDLE_H (optional) - idle hours before removal, default 2
# @param TMP_WT_REPO (optional) - the main checkout, default this one's
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ./run -a do_sweep_tmp_worktrees
# @example DRY_RUN=0 ./run -a do_sweep_tmp_worktrees
#------------------------------------------------------------------------------
do_sweep_tmp_worktrees() {
  local apply=()
  [[ "${DRY_RUN:-1}" == 0 ]] && apply=(--apply)
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" \
    bash "$PROJ_PATH/../csi-spl-orc/src/bash/features/spawn-agents/scripts/tmp-wt-reap.sh" --orphans "${apply[@]}"
}
