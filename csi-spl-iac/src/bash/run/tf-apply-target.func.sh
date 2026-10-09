#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description Tf apply target.
#------------------------------------------------------------------------------
do_tf_apply_target() {

  do_log "INFO START ::: provisioning step ${STEP}"

  TARGET=${TARGET:?}

  # Same log file convention as do_tf_apply. It was referenced at the end of this
  # function but never set here, so a SUCCESSFUL targeted apply still ended with
  # an unbound-variable error and a non-zero exit.
  tf_apply_log_fle=$PROJ_PATH/dat/log/tf_apply.${ORG:-}-${APP:-}-${ENV:-}.${STEP:-}.log
  mkdir -p "$(dirname "$tf_apply_log_fle")" 2>/dev/null || true
  test -f "$tf_apply_log_fle" && rm -f "$tf_apply_log_fle"

  do_tf_init

  vars_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.vars.tfvars"
  backend_config_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.backend-config.tfvars"

  set -e

  echo "running: "
  #set -x

  terraform -chdir=${tf_run_path} init -backend-config=$backend_config_path -upgrade

  while IFS=',' read -ra TARGETS; do
    for target in "${TARGETS[@]}"; do
      terraform -chdir=${tf_run_path} apply -var-file=$vars_path -auto-approve -lock=false -target=${target} \
        2>&1 | tee -a "$tf_apply_log_fle"
    done
  done <<<"$TARGET"

  rm -rf ${tf_run_path} #&& rm -rf ${modules_tgt_dir}
  set +x

  set +e

  do_simple_log "INFO STOP  ::: provisioning step ${tf_proj}"
  do_log "INFO ::: terraform apply log file: $tf_apply_log_fle"

}
