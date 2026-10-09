#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description The terraform state push command is used to manually upload a local state file to remote state. This command also works with local state. https://developer.hashicorp.com/terraform/cli/commands/state/push $ ORG=org APP=app ENV=env STEP=000-step TFSTATE_FILE=./terraform.tfstate make do-tf-state-push
#------------------------------------------------------------------------------
do_tf_state_push() {

  do_log "INFO START ::: provisioning step ${STEP}"

  TFSTATE_FILE=${TFSTATE_FILE:?}

  do_tf_init

  vars_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.vars.tfvars"
  backend_config_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.backend-config.tfvars"

  set -e

  echo "running: "
  #set -x

  terraform -chdir=${tf_run_path} init -backend-config=$backend_config_path -upgrade
  terraform -chdir=${tf_run_path} get -update=true && terraform -chdir=${tf_run_path} state push -lock=false ${PROJ_PATH}/${TFSTATE_FILE}
  rm -rf ${tf_run_path} #&& rm -rf ${modules_tgt_dir}

  set +x
  set +e

  do_simple_log "INFO STOP  ::: provisioning step ${tf_proj}"

}
