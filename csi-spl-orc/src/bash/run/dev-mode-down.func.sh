#!/bin/bash
#------------------------------------------------------------------------------
# @description Stop local dev mode (spec 148, row B6): removes the dev
# @description profile's containers; --purge also removes its volumes (the
# @description database, the files, the mail). The work is do_dev_mode_ctl.
# @param DEV_MODE_PURGE - optional: 1 = also remove the volumes (same as --purge)
# @example ./run -a do_dev_mode_down
# @example ./run -a do_dev_mode_down --purge
#------------------------------------------------------------------------------
do_dev_mode_down() {
  DEV_MODE_CMD=down do_dev_mode_ctl "$@"
}
