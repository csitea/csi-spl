#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Show what a full-step destroy WOULD remove, changing nothing:
# @description `terraform plan -destroy` for STEP in ENV, in the tf-runner, as
# @description the step's key (do_tf_init: tf_key_project or the env project).
# @description The read-only first half of `make do-deprovision` (spec 057:
# @description the owner's "destroy and recreate it" goes plan -> destroy).
# @param ENV STEP - required
# @example ENV=prd STEP=060-gcp-vm-satellite ./run -a do_tf_plan_destroy
#------------------------------------------------------------------------------
do_tf_plan_destroy() {
  do_log "INFO START ::: plan -destroy for step ${STEP:?}"
  do_tf_init
  vars_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.vars.tfvars"
  backend_config_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.backend-config.tfvars"
  local rc=0
  terraform -chdir="${tf_run_path}" init -backend-config="$backend_config_path" -upgrade -reconfigure >/dev/null || rc=$?
  [[ $rc -eq 0 ]] && { terraform -chdir="${tf_run_path}" plan -destroy -var-file="$vars_path" -lock=false || rc=$?; }
  rm -rf "${tf_run_path}"
  do_log "INFO STOP  ::: plan -destroy for step ${tf_proj} (nothing was changed)"
  return $rc
}
