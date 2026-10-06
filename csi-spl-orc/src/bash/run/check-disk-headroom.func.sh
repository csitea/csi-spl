#!/bin/bash
#------------------------------------------------------------------------------
# @description Disk + inode headroom check of THIS box: every real mount (not
# @description tmpfs/overlay/squashfs and other pseudo filesystems, but /tmp
# @description whenever it is its own filesystem) at blocks >=
# @description DISK_HEADROOM_BLOCK_PCT or inodes >= DISK_HEADROOM_INODE_PCT
# @description is a WARN line plus ONE spool note to the orchestrator per
# @description crossing (a state file under the cnf state dir keeps it quiet
# @description while the mount stays high). A failure or a skip is a WARN and
# @description a note too, never silent. One CHECK line per run. Dry run (no
# @description note, no state) unless DRY_RUN=0. The cron line is
# @description do_check_disk_headroom_install_cron (every 15 min).
# @param DRY_RUN (optional) - 1 (default) or 0
# @param DISK_HEADROOM_BLOCK_PCT (optional) - default 85
# @param DISK_HEADROOM_INODE_PCT (optional) - default 80
# @param DISK_HEADROOM_SKIP_TYPES (optional) - fs types not checked
# @param DISK_HEADROOM_STATE_DIR (optional) - default $SPL_STATE_DIR/disk-headroom
# @param DISK_HEADROOM_TO / DISK_HEADROOM_FROM (optional) - default orchestrator / c-001
# @example ./run -a do_check_disk_headroom
# @example DRY_RUN=0 ./run -a do_check_disk_headroom
# @example DISK_HEADROOM_BLOCK_PCT=50 ./run -a do_check_disk_headroom
#------------------------------------------------------------------------------
do_check_disk_headroom() {
  DRY_RUN="${DRY_RUN:-1}" bash "$PROJ_PATH/src/bash/scripts/check-disk-headroom.sh"
}
