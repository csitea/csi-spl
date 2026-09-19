#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description The terraform destroy command is a convenient way to destroy all remote objects managed by a particular Terraform configuration. https://developer.hashicorp.com/terraform/cli/commands/destroy
#------------------------------------------------------------------------------
do_tf_destroy() {

  do_log "INFO START ::: tf_destroy for step ${STEP}"

  do_tf_init

  tf_destroy_log_fle=$PROJ_PATH/dat/log/tf_destroy.${ORG:-}-${APP:-}-${ENV:-}.${STEP:-}.log
  test -f $tf_destroy_log_fle && rm -f $tf_destroy_log_fle

  # do_backup_region_dynamo_db_tables "$AWS_PROFILE" "$AWS_REGION"

  vars_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.vars.tfvars"
  backend_config_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.backend-config.tfvars"

  set -e          # Exit on error
  set -o pipefail # Ensure the entire pipeline fails if any command does

  echo "running: do_tf_destroy in 5 seconds"
  #set -x
  sleep 5
  {
    terraform -chdir=$tf_run_path init -backend-config=$backend_config_path \
      -upgrade -reconfigure 2>&1 &&
      terraform -chdir=$tf_run_path destroy -var-file=$vars_path -auto-approve -lock=false 2>&1
  } | tee -a $tf_destroy_log_fle
  set +x

  do_log "INFO STOP  ::: tf_destroy for step $tf_proj"
  do_log "INFO ::: terraform destroy log file: $tf_destroy_log_fle"

  set +e

}
