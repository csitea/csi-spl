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
# @description runs it. TMP_WT_MODE=unproven (SPL-6431) sweeps instead the
# @description trees with NO proof: <prefix><id>-* git trees of an id live on
# @description no box, and r<N>-* / rc<N>-* round scratch no live lane names,
# @description idle 24 h, with no commit missing from origin; one line per
# @description tree with its class, inodes and the reason kept or removed.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param TMP_WT_MODE (optional) - orphans (default) or unproven
# @param TMP_WT_ROOT (optional) - default /tmp
# @param TMP_WT_IDLE_H (optional) - idle hours before removal, default 2 (unproven: 24)
# @param TMP_WT_REPO (optional) - the main checkout, default this one's
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ./run -a do_sweep_tmp_worktrees
# @example DRY_RUN=0 ./run -a do_sweep_tmp_worktrees
# @example TMP_WT_MODE=unproven ./run -a do_sweep_tmp_worktrees
#------------------------------------------------------------------------------
do_sweep_tmp_worktrees() {
  local apply=() mode="${TMP_WT_MODE:-orphans}"
  [[ "${DRY_RUN:-1}" == 0 ]] && apply=(--apply)
  [[ "$mode" == orphans || "$mode" == unproven ]] || { echo "TMP_WT_MODE must be orphans or unproven, got '$mode'" >&2; return 2; }
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" \
    bash "$PROJ_PATH/../csi-spl-orc/src/bash/features/spawn-agents/scripts/tmp-wt-reap.sh" "--$mode" "${apply[@]}"
}
