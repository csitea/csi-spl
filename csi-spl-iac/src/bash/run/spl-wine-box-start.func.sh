#!/bin/bash
#------------------------------------------------------------------------------
# @description Start the wine-box VM. DRY_RUN defaults to 1. The shared power
# @description helper is _wine_box_power in spl-wine-box-stop.func.sh, which
# @description ./run sources before it dispatches. Its own file so the loader
# @description registers do_spl_wine_box_start (one action per file name).
# @param DRY_RUN (optional) - 1: print the plan. Default 1.
# @example DRY_RUN=0 ./run -a do_spl_wine_box_start
#------------------------------------------------------------------------------
do_spl_wine_box_start() { _wine_box_power start; }
