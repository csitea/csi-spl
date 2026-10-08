#!/bin/bash
#------------------------------------------------------------------------------
# @description Remove the build and test leftovers of finished runs from /tmp:
# @description top-level go-build<N>, tmp.<X>, Test<Name><N> and <id>-gocache
# @description entries, only when idle for TMP_STALE_AGE_H hours, not
# @description root-owned and held by no process (cwd or open fd). Removed as
# @description their owner. One PLAN|REMOVE / KEEP line per entry. Dry run
# @description unless DRY_RUN=0. Runs every 4 h inside do_box_disk_sweep.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param TMP_STALE_AGE_H (optional) - idle hours before removal, default 24
# @param TMP_STALE_ROOT (optional) - default /tmp
# @example ./run -a do_tmp_stale_sweep
# @example DRY_RUN=0 ./run -a do_tmp_stale_sweep
#------------------------------------------------------------------------------
do_tmp_stale_sweep() {
  DRY_RUN="${DRY_RUN:-1}" bash "$PROJ_PATH/src/bash/scripts/tmp-stale-sweep.sh"
}
