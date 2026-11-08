#!/bin/bash
#------------------------------------------------------------------------------
# @description Size the top dirs of one mount, niced and bounded in time, so the
# @description job swinging a disk across its headroom limit gets a name
# @description (SPL-4629). A dir that du cannot finish in its share of the budget
# @description is recorded as partial, never as a full size. With DRY_RUN=0 it
# @description appends the rows to the record; check-disk-headroom.sh runs it so
# @description at each new blocks crossing.
# @param DISK_CROSSING_MOUNT (required) - the mount to size
# @param DRY_RUN (optional) - 1 (default): print only; 0: also append to the record
# @param DISK_CROSSING_BUDGET_S (optional) - the whole run's budget in seconds, default 60
# @param DISK_CROSSING_CHILDREN (optional) - biggest children recorded per top dir, default 10
# @param DISK_CROSSING_TRIGGER (optional) - what asked for it, default manual
# @param DISK_CROSSING_TSV (optional) - default /var/<org>/<org>-<app>/disk-crossing-sizes/sizes.tsv
# @example DISK_CROSSING_MOUNT=/ ./run -a do_disk_crossing_sizes
# @example DISK_CROSSING_MOUNT=/ DISK_CROSSING_BUDGET_S=30 DRY_RUN=0 ./run -a do_disk_crossing_sizes
#------------------------------------------------------------------------------
do_disk_crossing_sizes() {
  : "${DISK_CROSSING_MOUNT:?DISK_CROSSING_MOUNT must be set (the mount to size)}"
  bash "$PROJ_PATH/src/bash/scripts/disk-crossing-sizes.sh"
}
