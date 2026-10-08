#!/bin/bash
#------------------------------------------------------------------------------
# @description Free this box's disk of data that is safe to remove, one guarded
# @description step after the other: old dead session transcripts
# @description (do_spl_session_prune), idle /tmp build leftovers
# @description (do_tmp_stale_sweep), dead landed worktrees (do_wt_dead_sweep),
# @description the Go build cache (do_prune_go_build_cache) and docker images +
# @description build cache older than BOX_SWEEP_DOCKER_UNTIL
# @description (do_prune_docker_images). Free space per mount before, after
# @description each step and at the end. Dry run unless DRY_RUN=0. The cron
# @description line (every 4 h) is do_box_disk_sweep_install_cron.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param BOX_SWEEP_STEPS (optional) - default "sessions tmp worktrees go docker"
# @param BOX_SWEEP_DOCKER_UNTIL (optional) - default 72h
# @example ./run -a do_box_disk_sweep
# @example DRY_RUN=0 ./run -a do_box_disk_sweep
#------------------------------------------------------------------------------
do_box_disk_sweep() {
  DRY_RUN="${DRY_RUN:-1}" bash "$PROJ_PATH/src/bash/scripts/box-disk-sweep.sh"
}
