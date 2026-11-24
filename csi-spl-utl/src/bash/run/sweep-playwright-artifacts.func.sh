#!/bin/bash
#------------------------------------------------------------------------------
# @description Remove the /tmp/playwright-artifacts-* dirs a browser MCP seat
# @description left behind (SPL-6407: every download and page snapshot of the
# @description firefox / playwright MCP lands there, private documents
# @description included, and nothing removes them). A dir goes only when
# @description nothing in it changed for PW_ART_AGE_H hours and no process has
# @description its cwd or an open file under it; removed as its owner. One
# @description PLAN|DO remove / KEEP line per dir. Dry run unless DRY_RUN=0.
# @description DEFAULT-OFF: by hand only, no cron and no sweep step runs it
# @description until the owner turns it on.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param PW_ART_ROOT (optional) - default /tmp
# @param PW_ART_AGE_H (optional) - idle hours before removal, default 24
# @param PW_ART_SUDO (optional) - 1 (default) or 0: only this user's processes and dirs
# @example ./run -a do_sweep_playwright_artifacts
# @example DRY_RUN=0 ./run -a do_sweep_playwright_artifacts
#------------------------------------------------------------------------------
do_sweep_playwright_artifacts() {
  DRY_RUN="${DRY_RUN:-1}" bash "$PROJ_PATH/src/bash/scripts/playwright-artifacts-sweep.sh"
}
