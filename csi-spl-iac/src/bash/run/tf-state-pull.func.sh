#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description The terraform state pull command is used to manually download and output the state from remote state. This command also works with local state. https://developer.hashicorp.com/terraform/cli/commands/state/pull $ ORG=org APP=app ENV=env STEP=000-step make do-tf-state-pull
#------------------------------------------------------------------------------
do_tf_state_pull() {

  do_log "INFO START ::: provisioning step ${STEP}"

  do_tf_init

  local backend_config_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.backend-config.tfvars"

  set -e

  echo "running: "
  #set -x

  mkdir -p $PROJ_PATH/dat/tmp/
  terraform -chdir=${tf_run_path} init -backend-config=$backend_config_path -upgrade
  terraform -chdir=${tf_run_path} get -update=true && terraform -chdir=${tf_run_path} state pull >$PROJ_PATH/dat/tmp/${ORG}-${APP}-${ENV}-${tf_proj}-terraform.tfstate
  # rm -rf ${tf_run_path} #&& rm -rf ${modules_tgt_dir}

  set +x
  set +e

  do_log "INFO saving terraform state into $PROJ_PATH/dat/tmp/${ORG}-${APP}-${ENV}-${tf_proj}-terraform.tfstate"
  do_simple_log "INFO STOP  ::: provisioning step ${tf_proj}"

}
