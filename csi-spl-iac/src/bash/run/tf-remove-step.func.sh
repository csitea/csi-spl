#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description remove all files for a given step
#------------------------------------------------------------------------------
do_tf_remove_step() {
  step=${STEP}
  do_log "WARNING removing ALL files from step ${step} permanently in 5 seconds"
  sleep 5

  rm -rv src/terraform/${step}*
  rm -rv src/tpl/cnf/env/%org%/%app%/%env%/tf/${step}*

}
