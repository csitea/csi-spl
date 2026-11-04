#!/bin/bash
#------------------------------------------------------------------------------
# @description Remove the Claude Code scratch dirs of DEAD sessions of the
# @description running user from the shared /tmp tmpfs
# @description (/tmp/claude-<uid>/<project>/<session-uuid>/), which the CI
# @description runners share: a dir goes only when no live session claims it
# @description (a running pid in ~/.claude/sessions/*.json, or its uuid on a
# @description running command line) AND nothing in it changed for
# @description SCRATCH_SWEEP_AGE_H hours (2: lanes rotate hourly). Inode
# @description guard: below SCRATCH_INODE_MIN_FREE_PCT free inodes, the dead
# @description dirs idle SCRATCH_PRESSURE_AGE_M minutes go too, oldest first,
# @description until the projected free inodes reach the threshold (PRESSURE
# @description lines). A dir whose du --inodes count fails stops that pass
# @description (PRESSURE WARN); a df row with a non-numeric inode total or
# @description IFree skips the guard. One PLAN|REMOVE / KEEP line per dir.
# @description Dry run unless DRY_RUN=0. The cron line is
# @description do_tmp_scratch_sweep_install_cron.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SCRATCH_ROOT (optional) - default /tmp/claude-<uid>
# @param SCRATCH_SESSIONS (optional) - default ~/.claude/sessions
# @param SCRATCH_SWEEP_AGE_H (optional) - idle hours before removal, default 2
# @param SCRATCH_INODE_MIN_FREE_PCT (optional) - 0..50, default 10; 0 = no inode guard
# @param SCRATCH_PRESSURE_AGE_M (optional) - idle minutes (>= 10) under inode pressure, default 30
# @param SCRATCH_DF (optional) - the df command, default df (tests)
# @example ./run -a do_tmp_scratch_sweep
# @example SCRATCH_INODE_MIN_FREE_PCT=20 ./run -a do_tmp_scratch_sweep
# @example DRY_RUN=0 ./run -a do_tmp_scratch_sweep
#------------------------------------------------------------------------------
do_tmp_scratch_sweep() {
  DRY_RUN="${DRY_RUN:-1}" bash "$PROJ_PATH/src/bash/scripts/tmp-scratch-sweep.sh"
}
