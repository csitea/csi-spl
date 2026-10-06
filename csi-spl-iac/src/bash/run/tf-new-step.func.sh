#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description add all template files for including a new terraform step
#------------------------------------------------------------------------------
do_tf_new_step() {
  # $1 : step_name in the form 014-step-name
  step=${STEP}

  # check if step with same name exists
  step_exists=0

  if compgen -G "src/terraform/*${step}*" >/dev/null; then
    do_log "FATAL there already exists terraform files for this step in src/terraform"
  elif compgen -G "src/tpl/cnf/env/%org%/%app%/%env%/tf/*${step}*" >/dev/null; then
    do_log "FATAL there already exists template files for this step in src/tpl/cnf/env/%org%/%app%/%env%/tf"
  fi

  if [[ ${step_exists} -ge 1 ]]; then
  return 1
  else
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

  fi
}
