#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description The terraform destroy command is a convenient way to destroy all remote objects managed by a particular Terraform configuration. https://developer.hashicorp.com/terraform/cli/commands/destroy
# @example cd csi-spl-orc && ENV=<env> STEP=<step> make do-deprovision
#------------------------------------------------------------------------------
# shellcheck source=../../../lib/bash/funcs/tf-log-mask.func.sh
declare -F do_tf_log_mask >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/tf-log-mask.func.sh"
do_tf_destroy() {

  do_log "INFO START ::: tf_destroy for step ${STEP}"

  do_tf_init

  tf_destroy_log_fle=$PROJ_PATH/dat/log/tf_destroy.${ORG:-}-${APP:-}-${ENV:-}.${STEP:-}.log
  test -f "$tf_destroy_log_fle" && rm -f "$tf_destroy_log_fle"
  do_tf_log_open "$tf_destroy_log_fle" || return 1

  vars_path="${tf_vars_path:-$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.vars.tfvars}"
  backend_config_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.backend-config.tfvars"

  set -e          # Exit on error
  set -o pipefail # Ensure the entire pipeline fails if any command does

  echo "running: do_tf_destroy in 5 seconds"
  #set -x
  sleep 5
  {
    terraform -chdir="$tf_run_path" init -backend-config="$backend_config_path" \
      -upgrade -reconfigure 2>&1 &&
      terraform -chdir="$tf_run_path" destroy -input=false -var-file="$vars_path" -auto-approve -lock=false 2>&1
  } | do_tf_log_mask | tee -a "$tf_destroy_log_fle"
  set +x

  do_log "INFO STOP  ::: tf_destroy for step $tf_proj"
  do_log "INFO ::: terraform destroy log file: $tf_destroy_log_fle"

  set +e

}
