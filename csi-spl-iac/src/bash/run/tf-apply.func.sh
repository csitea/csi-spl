#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description Tf apply.
#------------------------------------------------------------------------------
do_tf_apply() {
  # Terraform apply for provision using remote state.

  do_simple_log "INFO START ::: provisioning step ${STEP}"
  do_tf_init

  tf_apply_log_fle=$PROJ_PATH/dat/log/tf_apply.${ORG:-}-${APP:-}-${ENV:-}.${STEP:-}.log
  test -f "$tf_apply_log_fle" && rm -f "$tf_apply_log_fle"

  vars_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.vars.tfvars"
  backend_config_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.backend-config.tfvars"

  set -x
  {
    terraform -chdir="${tf_run_path}" init -backend-config="$backend_config_path" -upgrade -get=true -reconfigure 2>&1 &&
    terraform -chdir="${tf_run_path}" apply -var-file="$vars_path" -auto-approve -lock=false 2>&1
  } | tee -a "$tf_apply_log_fle"
  local _rc=${PIPESTATUS[0]}
  set +x

  # Show outputs after successful apply
  if [ "$_rc" -eq 0 ]; then
    echo ""
    echo "=========================================="
    echo "TERRAFORM OUTPUTS:"
    echo "=========================================="
    terraform -chdir="${tf_run_path}" output 2>&1 | tee -a "$tf_apply_log_fle"
    echo "=========================================="
  fi

  test -f "${PROJ_PATH}/src/bash/scripts/run-ansible-${ORG}-${APP}-${ENV}-${STEP}.sh" && {
    do_log "INFO running: ${PROJ_PATH}/src/bash/scripts/run-ansible-${ORG}-${APP}-${ENV}-${STEP}.sh"
    "${PROJ_PATH}/src/bash/scripts/run-ansible-${ORG}-${APP}-${ENV}-${STEP}.sh"
  }
  # jump-init
  # rm -rf ${tf_run_path} # && rm -rf ${modules_tgt_dir}

  do_simple_log "INFO STOP  ::: provisioning step ${tf_proj}"
  do_log "INFO ::: terraform apply log file: $tf_apply_log_fle"

}
