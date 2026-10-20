#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description The terraform state push command is used to manually upload a local state file to remote state. This command also works with local state. https://developer.hashicorp.com/terraform/cli/commands/state/push $ ORG=org APP=app ENV=env STEP=000-step TFSTATE_FILE=./terraform.tfstate DRY_RUN=0 make do-tf-state-push
# @description A dry run unless DRY_RUN=0: by default it inits the step and
# @description pushes nothing. The push runs with -lock=false.
# @param ENV STEP TFSTATE_FILE - required; TFSTATE_FILE is relative to PROJ_PATH
# @param DRY_RUN 1 (default) pushes nothing, 0 pushes
#------------------------------------------------------------------------------
do_tf_state_push() {

  local dry_run="${DRY_RUN:-1}"
  : "${ENV:?ENV must be set}" "${STEP:?STEP must be set}" "${TFSTATE_FILE:?TFSTATE_FILE must be set}"
  [[ -f "${PROJ_PATH}/${TFSTATE_FILE}" ]] || {
    do_log "FATAL no state file ${PROJ_PATH}/${TFSTATE_FILE}"
    return 1
  }

  do_log "INFO START ::: provisioning step ${STEP} DRY_RUN=${dry_run}"

  do_tf_init

  vars_path="${tf_vars_path:-$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.vars.tfvars}"
  backend_config_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.backend-config.tfvars"

  set -e

  echo "running: "
  #set -x

  terraform -chdir=${tf_run_path} init -backend-config=$backend_config_path -upgrade
  if [[ "${dry_run}" != 0 ]]; then
    do_log "INFO DRY_RUN: would run state push -lock=false ${PROJ_PATH}/${TFSTATE_FILE}"
    do_log "INFO DRY_RUN: nothing pushed; DRY_RUN=0 pushes"
  else
    terraform -chdir=${tf_run_path} get -update=true && terraform -chdir=${tf_run_path} state push -lock=false ${PROJ_PATH}/${TFSTATE_FILE}
  fi
  rm -rf ${tf_run_path} #&& rm -rf ${modules_tgt_dir}

  set +x
  set +e

  do_simple_log "INFO STOP  ::: provisioning step ${tf_proj}"

}
