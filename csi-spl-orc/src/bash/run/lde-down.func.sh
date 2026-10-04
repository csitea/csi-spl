#!/bin/bash
#------------------------------------------------------------------------------
# @description lde-down: the inverse of do_lde_up -- stop THIS tree's whole dev
# @description stack (hub, WUI, pg, gcs). Data volumes are kept unless
# @description LDE_PURGE=1. Same as do_teardown_app_inf; never touches another
# @description tree's project or anything in the cloud.
# @param LDE_PURGE (optional) - 1: also remove the volumes (a clean database)
# @example ./run -a do_lde_down
# @example LDE_PURGE=1 ./run -a do_lde_down
#------------------------------------------------------------------------------
do_lde_down() {
  do_teardown_app_inf
}
