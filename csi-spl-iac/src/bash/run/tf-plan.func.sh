#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description Tf plan.
#------------------------------------------------------------------------------
do_tf_plan() {

  do_log "INFO START ::: provisioning step ${STEP:?}"

  do_tf_init

  vars_path="${tf_vars_path:-$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.vars.tfvars}"
  backend_config_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.backend-config.tfvars"

  set -e

  echo "running: "
  #set -x

  terraform -chdir=${tf_run_path} init -backend-config=$backend_config_path -upgrade
  terraform -chdir=${tf_run_path} plan -out=${ORG}-${APP}-${ENV}.tfplan -var-file=$vars_path -lock=false
  #terraform -chdir=${tf_run_path} show -json ${ORG}-${APP}-${ENV}.tfplan | jq -r > ${ORG}-${APP}-${ENV}.tfplan
  #cat ${ORG}-${APP}-${ENV}.tfplan | jq -r '.planned_values.root_module.resources[].address'

  rm -rf ${tf_run_path} #&& rm -rf ${modules_tgt_dir}
  set +x

  set +e

  do_simple_log "INFO STOP  ::: provisioning step ${tf_proj}"

}
