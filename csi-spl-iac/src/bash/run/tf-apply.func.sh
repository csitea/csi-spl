#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description Tf apply.
#------------------------------------------------------------------------------
declare -F env_order_gate >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/check-dev-leads-prd.func.sh"

do_tf_apply() {
  # Terraform apply for provision using remote state.
  # SPL-1947: a prd apply waits until dev carries the same change.
  env_order_gate || return $?

  do_simple_log "INFO START ::: provisioning step ${STEP}"
  do_tf_init

  tf_apply_log_fle=$PROJ_PATH/dat/log/tf_apply.${ORG:-}-${APP:-}-${ENV:-}.${STEP:-}.log
  test -f "$tf_apply_log_fle" && rm -f "$tf_apply_log_fle"

  vars_path="${tf_vars_path:-$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.vars.tfvars}"
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

  # The step's run-ansible script (written by its 07-ansible.tf) runs after a
  # good apply. Its exit status is the playbook's (failed>0 or unreachable>0 ->
  # non-zero) and it is this action's status: dropped, a failed playbook made
  # `make do-provision` exit 0 (step 061 on dev, failed=1, exit 0).
  local _ansible="${PROJ_PATH}/src/bash/scripts/run-ansible-${ORG}-${APP}-${ENV}-${STEP}.sh"
  if [ "$_rc" -eq 0 ] && [ -f "$_ansible" ]; then
    do_log "INFO running: $_ansible"
    "$_ansible"
    _rc=$?
    [ "$_rc" -eq 0 ] || do_log "ERROR the playbook failed with status $_rc (its PLAY RECAP is above): $_ansible"
  elif [ -f "$_ansible" ]; then
    do_log "ERROR terraform apply failed with status $_rc, so the playbook did not run: $_ansible"
  fi
  # jump-init
  # rm -rf ${tf_run_path} # && rm -rf ${modules_tgt_dir}

  do_simple_log "INFO STOP  ::: provisioning step ${tf_proj}"
  do_log "INFO ::: terraform apply log file: $tf_apply_log_fle"
  return "$_rc"
}
