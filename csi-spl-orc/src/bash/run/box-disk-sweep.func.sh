#!/bin/bash
#------------------------------------------------------------------------------
# @description Free this box's disk of data that is safe to remove, one guarded
# @description step after the other: old dead session transcripts
# @description (do_spl_session_prune), idle /tmp build leftovers
# @description (do_tmp_stale_sweep), dead landed worktrees (do_wt_dead_sweep),
# @description the finished lanes' listed workdirs older than 24 h, 6 h at <= 8%
# @description free (csi-spl-utl do_sweep_workdirs, $SPOOL_ROOT/workdirs.tsv),
# @description the Go build cache (do_prune_go_build_cache), docker images +
# @description build cache older than BOX_SWEEP_DOCKER_UNTIL
# @description (do_prune_docker_images), the systemd journal down to
# @description BOX_SWEEP_JOURNAL_MAX (journal-sweep.sh) and idle runner
# @description scratch older than BOX_SWEEP_RUNNER_AGE (runner-sweep.sh:
# @description _work/_temp and _diag/*.log only); under disk pressure only (low /
# @description crit) also idle lane leftovers in /var/tmp (tmp-stale-sweep.sh
# @description TMP_STALE_ANY=1, a live lane's kept; idle 72 h / 24 h) and the
# @description logs (log-sweep.sh: forced rsyslog rotation of a log over
# @description BOX_SWEEP_LOG_MAX, apt-get clean). Free space per mount before, after
# @description each step and at the end. The lowest free % picks the level:
# @description under BOX_SWEEP_LOW_FREE_PCT (15) / _CRIT_FREE_PCT (7) the docker
# @description and go age limits shrink (12h / 360 min, 2h / 60 min), and a crit
# @description sweep that leaves the disk under 7% sends a note to the
# @description orchestrator. Dry run unless DRY_RUN=0. The cron line (every
# @description 15 min, gated) is do_box_disk_sweep_install_cron.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param BOX_SWEEP_STEPS (optional) - default "sessions tmp worktrees workdirs go docker journal runners vartmp logs"
# @param BOX_SWEEP_JOURNAL_MAX (optional) - default 500M
# @param BOX_SWEEP_RUNNER_ROOT (optional) - default /srv/gh-runner
# @param BOX_SWEEP_RUNNER_AGE (optional) - default 2 (days)
# @param BOX_SWEEP_DOCKER_UNTIL (optional) - default 72h
# @param BOX_SWEEP_LOW_VARTMP_AGE_H / BOX_SWEEP_CRIT_VARTMP_AGE_H (optional) - 72 / 24
# @param BOX_SWEEP_LOG_MAX (optional) - default 256M
# @param BOX_SWEEP_LOW_FREE_PCT / BOX_SWEEP_CRIT_FREE_PCT (optional) - 15 / 7
# @example ./run -a do_box_disk_sweep
# @example DRY_RUN=0 ./run -a do_box_disk_sweep
#------------------------------------------------------------------------------
do_box_disk_sweep() {
  DRY_RUN="${DRY_RUN:-1}" bash "$PROJ_PATH/src/bash/scripts/box-disk-sweep.sh"
}
