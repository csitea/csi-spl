#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description add all template files for including a new terraform step
# @example cd csi-spl-iac && STEP=<NNN-step-name> ./run -a do_tf_new_step
#------------------------------------------------------------------------------
do_tf_new_step() {
  # $1 : step_name in the form 014-step-name
  step=${STEP}

  tf_new_step_refuse "${step}" && return 1

  # =====================================================================================    copy template of state bucket for step
  do_log "INFO copy terraform state-bucket template"
  cp -r lib/tpl/terraform/step-remote-bucket src/terraform/${step}-remote-bucket

  do_log "INFO replace step-name from tpl to src/terraform/${step}-remote-bucket"
  contents=$(cat src/terraform/${step}-remote-bucket/03-s3-bucket.tf | sed s/step-name/${step}/g)
  echo "${contents}" >src/terraform/${step}-remote-bucket/03-s3-bucket.tf

  # =====================================================================================    copy configuration file for remote bucket
  do_log "INFO  copy terraform state bucket template files to src/tpl/cnf/env/%org%/%app%/%env%/tf/${step}-remote-bucket.vars.tfvars.tpl"
  contents=$(cat src/terraform/${step}-remote-bucket/tpl/step-name-remote-bucket.vars.tfvars.tpl |
    sed s/step-name/${step}/g)
  echo "${contents}" >src/tpl/cnf/env/%org%/%app%/%env%/tf/${step}-remote-bucket.vars.tfvars.tpl

  do_log "INFO removing template files from src/terraform/${step}-remote-bucket"
  rm -v src/terraform/${step}-remote-bucket/tpl/step-name-remote-bucket.vars.tfvars.tpl

  # =====================================================================================    copy backend config tpl for step
  do_log "INFO copy terraform backend template files to src/tpl/cnf/env/%org%/%app%/%env%/tf/${step}.backend-config.tfvars.tpl"
  contents=$(cat src/terraform/${step}-remote-bucket/tpl/step-name.backend-config.tfvars.tpl |
    sed s/step-name/${step}/g)
  echo "${contents}" >src/tpl/cnf/env/%org%/%app%/%env%/tf/${step}.backend-config.tfvars.tpl

  do_log "INFO removing template files from src/terraform/${step}-remote-bucket/tpl/step-name.backend-config.tfvars.tpl"
  rm -rv src/terraform/${step}-remote-bucket/tpl/step-name.backend-config.tfvars.tpl

  # =====================================================================================    copy basic vars tpl for step
  do_log "INFO copy terraform backend template files to src/terraform/${step}-remote-bucket/tpl/step-name.vars.tfvars.tpl"
  contents=$(cat src/terraform/${step}-remote-bucket/tpl/step-name.vars.tfvars.tpl |
    sed s/step-name/${step}/g)
  echo "${contents}" >src/tpl/cnf/env/%org%/%app%/%env%/tf/${step}.vars.tfvars.tpl

  do_log "INFO removing template files from src/terraform/${step}-remote-bucket/tpl/step-name.vars.tfvars.tpl"
  rm -rv src/terraform/${step}-remote-bucket/tpl/step-name.vars.tfvars.tpl

  # =====================================================================================    remove tpl folder
  do_log "INFO remove folder rm -rv src/terraform/${step}-remote-bucket/template"
  rm -rv src/terraform/${step}-remote-bucket/tpl

  # =====================================================================================    create step dir
  do_log "INFO create step dir src/terraform/${step}"
  mkdir src/terraform/${step}

  # =====================================================================================    copy basic files
  do_log "INFO copy terraform basic step files to src/terraform/${step}"
  cp -r lib/tpl/terraform/step/* src/terraform/${step}
}

# tf_new_step_refuse <step>: logs one FATAL line and returns 0 when the step
# must not be laid out (it already exists, or a template dir the copy needs is
# not on the tree), else returns 1. The templates came from csi-rel and never
# reached this tree (spec 007 csi-rel-flow-map.md), so on the real tree the
# action refuses up front instead of failing half-way through the copy.
tf_new_step_refuse() {
  local step="$1" tpl missing=()
  if compgen -G "src/terraform/*${step}*" >/dev/null; then
    do_log "FATAL there already exists terraform files for this step in src/terraform"
    return 0
  elif compgen -G "src/tpl/cnf/env/%org%/%app%/%env%/tf/*${step}*" >/dev/null; then
    do_log "FATAL there already exists template files for this step in src/tpl/cnf/env/%org%/%app%/%env%/tf"
    return 0
  fi
  for tpl in lib/tpl/terraform/step-remote-bucket lib/tpl/terraform/step "src/tpl/cnf/env/%org%/%app%/%env%/tf"; do
    [[ -d "${tpl}" ]] || missing+=("${tpl}")
  done
  if ((${#missing[@]})); then
    do_log "FATAL missing template dir(s) for a new step, nothing was created: ${missing[*]}"
    return 0
  fi
  return 1
}
