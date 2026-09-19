#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description If Terraform currently considers a particular object as tainted but you've determined that it's actually functioning correctly and need not be replaced, you can use terraform untaint to remove the taint marker from that object. https://developer.hashicorp.com/terraform/cli/commands/untaint
#------------------------------------------------------------------------------
do_tf_untaint_target() {

  do_log "INFO START ::: provisioning step ${STEP}"

  TARGET=${TARGET:?}

  do_tf_init

  # do_backup_region_dynamo_db_tables "$AWS_PROFILE" "$AWS_REGION"

  vars_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.vars.tfvars"
  backend_config_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.backend-config.tfvars"

  set -e

  echo "running: "
  #set -x

  terraform -chdir=${tf_run_path} init -backend-config=$backend_config_path -upgrade

  while IFS=',' read -ra TARGETS; do
    for target in "${TARGETS[@]}"; do
      terraform -chdir=${tf_run_path} untaint -lock=false -allow-missing ${target}
    done
  done <<<"$TARGET"

  rm -rf ${tf_run_path} #&& rm -rf ${modules_tgt_dir}
  set +x

  set +e

  do_simple_log "INFO STOP  ::: provisioning step ${tf_proj}"

}
