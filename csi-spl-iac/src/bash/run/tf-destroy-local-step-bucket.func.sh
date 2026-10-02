#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description Terraform destroy for provision using local state.
#------------------------------------------------------------------------------
do_tf_destroy_local_step_bucket() {

  do_log "INFO START ::: tf_destroy for step ${STEP}"

  do_tf_init

  tf_destroy_log_fle=$PROJ_PATH/dat/log/tf_destroy.${ORG:-}-${APP:-}-${ENV:-}.${STEP:-}.log
  test -f $tf_destroy_log_fle && rm -f $tf_destroy_log_fle

  # for do_tf_local_apply $tf_proj is evaluated as step-remote-bucket
  main_step=$(echo ${tf_proj} | sed s/-remote-bucket//g)
  # we agree that only s3 states are provisioned locally, any state that is
  # more complex than this should live in an s3.

  do_export_json_section_vars "$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV.env.json" ".env.aws"
  do_export_json_section_vars "$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV.env.json" '.env.steps."'${main_step}'"'
  #do_export_json_section_vars "$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV.env.json" '.env.steps."'${tf_proj}'"'

  # do_backup_region_dynamo_db_tables "$AWS_PROFILE" "$AWS_REGION"

  vars_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.vars.tfvars"

  ts=$(date "+%Y%m%d_%H%M%S")
  state_path_to_load="$PROJ_PATH/cnf/terraform/$tf_proj/$ORG.$APP.$ENV.tfstate"
  state_path_bak="$PROJ_PATH/dat/terraform/${tf_proj}/terraform.$ts.bak.tfstate"
  #state_path="$PROJ_PATH/src/terraform/$tf_proj/terraform.tfstate"
  state_path="${tf_run_path}/terraform.tfstate"

  # load the RIGHT previous local state
  test -f "$state_path" && rm -v "$state_path"
  test -d "cnf/terraform/$tf_proj" || mkdir -p "cnf/terraform/$tf_proj"
  test -f "$state_path_to_load" && cp "$state_path_to_load" "$state_path"

  set -e  # Exit on error
  set -o pipefail  # Ensure the entire pipeline fails if any command does

  echo "running: "
  #set -x

  {
    terraform -chdir=$tf_run_path init -upgrade 2>&1 &&
    terraform -chdir=$tf_run_path destroy -var-file=$vars_path -auto-approve 2>&1
  } | tee -a $tf_destroy_log_fle

  set +x
  set +e


  # save the applied local state
  test -f "$state_path_to_load" && cp "$state_path_to_load" "$state_path_bak"
  test -f "$state_path" && cp "$state_path" "$state_path_to_load"

  do_log "INFO STOP  ::: tf_destroy for step $tf_proj"
  do_log "INFO ::: terraform destroy log file: $tf_destroy_log_fle"

}
