#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description Remove all files of a given step: src/terraform/<STEP>* and its
# @description tf templates, relative to the cwd (the ./run root).
# @description A dry run unless DRY_RUN=0: by default it lists the paths that
# @description would go and removes nothing.
# @param STEP - required; an empty STEP would match every step
# @param DRY_RUN 1 (default) lists only, 0 removes
# @example STEP=007-dns DRY_RUN=0 ./run -a do_tf_remove_step
#------------------------------------------------------------------------------
do_tf_remove_step() {
  local step="${STEP:?STEP must be set}" dry_run="${DRY_RUN:-1}"

  if [[ "${dry_run}" != 0 ]]; then
    do_log "INFO DRY_RUN: would remove step ${step}:"
    ls -d src/terraform/"${step}"* src/tpl/cnf/env/%org%/%app%/%env%/tf/"${step}"* 2>/dev/null
    do_log "INFO DRY_RUN: nothing removed; DRY_RUN=0 removes"
    return 0
  fi

  do_log "WARNING removing ALL files from step ${step} permanently in 5 seconds"
  sleep 5

  rm -rv src/terraform/"${step}"*
  rm -rv src/tpl/cnf/env/%org%/%app%/%env%/tf/"${step}"*

}
