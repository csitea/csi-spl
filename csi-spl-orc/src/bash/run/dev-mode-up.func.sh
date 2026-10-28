#!/bin/bash
#------------------------------------------------------------------------------
# @description Start local dev mode (spec 148, row B6): the prerequisite check,
# @description then the root compose file's dev profile, built from this
# @description checkout. The work is do_dev_mode_ctl (dev-mode-ctl.func.sh).
# @param DEV_MODE_BUILD - optional: 1 (default) build from the checkout, 0 pull the pinned images
# @example ./run -a do_dev_mode_up
#------------------------------------------------------------------------------
do_dev_mode_up() {
  DEV_MODE_CMD=up do_dev_mode_ctl "$@"
}
