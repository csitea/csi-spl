#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description Terraform destroy of one or more targeted resources only. See
# @description https://developer.hashicorp.com/terraform/cli/commands/destroy
# @description Pass multiple targets as a comma-separated list in TARGET.
# @description Example: ORG=csi APP=spl ENV=prd STEP=007-dns \
# @description   TARGET=google_dns_record_set.api_prd,google_dns_record_set.api_tst \
# @description   make do-tf-destroy-target
#------------------------------------------------------------------------------
do_tf_destroy_target() {

  do_log "INFO START ::: targeted destroy step=${STEP:?} TARGET=${TARGET:?}"

  do_tf_init

  tf_destroy_log_fle=$PROJ_PATH/dat/log/tf_destroy.${ORG:-}-${APP:-}-${ENV:-}.${STEP:-}.log
  test -f $tf_destroy_log_fle && rm -f $tf_destroy_log_fle

  vars_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.vars.tfvars"
  backend_config_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.backend-config.tfvars"

  set -e

  terraform -chdir=${tf_run_path} init -backend-config=$backend_config_path -upgrade -get=true -reconfigure

  while IFS=',' read -ra TARGETS; do
    for target in "${TARGETS[@]}"; do
      terraform -chdir=${tf_run_path} apply -destroy -var-file=$vars_path -auto-approve -lock=false -target=${target} |
        tee -a $tf_destroy_log_fle
    done
  done <<<"$TARGET"

  rm -rf ${tf_run_path}
  set +x
  set +e

  do_simple_log "INFO STOP  ::: targeted destroy step=${tf_proj}"
  do_log "INFO ::: terraform destroy log file: $tf_destroy_log_fle"

}
