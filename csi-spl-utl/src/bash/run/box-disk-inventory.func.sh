#!/bin/bash
#------------------------------------------------------------------------------
# @description Print what fills this box's disk OUTSIDE the repos, one markdown
# @description table (row, size, files, oldest): journald, /var/log, docker
# @description (images, containers, volumes, build cache), snapshots of every
# @description kind found, /var/tmp, /tmp, lane worktrees, caches, core dumps,
# @description the agents' transcripts and logs, CI runner work dirs and the
# @description human users' Downloads / screenshots / Trash / browser and editor
# @description caches (sizes per directory only, never a file name). The rows
# @description are cnf/disk-inventory.rows. With DRY_RUN=0 it also appends
# @description today's sizes to the growth record (once per day per box) and
# @description prints the top growers of the last 7 days. The daily cron line
# @description of do_box_disk_guard_install runs it.
# @param DRY_RUN (optional) - 1 (default): print only; 0: also append to the growth record
# @param DISK_INV_REPORT (optional) - also write the table to this file (0644)
# @param DISK_INV_GROWTH_TSV (optional) - default /var/<org>/<org>-<app>/box-disk-sweep/growth.tsv
# @example ./run -a do_box_disk_inventory
# @example DRY_RUN=0 ./run -a do_box_disk_inventory
# @example DISK_INV_REPORT=/tmp/inv.md ./run -a do_box_disk_inventory
#------------------------------------------------------------------------------
do_box_disk_inventory() {
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  local g=0
  [[ "${DRY_RUN:-1}" == 0 ]] && g=1
  DISK_INV_GROWTH="$g" bash "$PROJ_PATH/src/bash/scripts/box-disk-inventory.sh" || return $?
  # an empty value means the default in both scripts
  DISK_GROWERS_TSV="${DISK_INV_GROWTH_TSV:-}" DISK_GROWERS_BOX="${DISK_INV_BOX:-}" \
    bash "$PROJ_PATH/src/bash/scripts/disk-growers.sh"
}
