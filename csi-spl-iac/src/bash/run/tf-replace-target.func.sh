#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description Tf replace target.
#------------------------------------------------------------------------------
do_tf_replace_target() {

  do_log "INFO START ::: provisioning step ${STEP:-}"

  TARGET=${TARGET:?}

  do_tf_init

  vars_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.vars.tfvars"
  backend_config_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.backend-config.tfvars"

  set -e

  echo "running: "
  #set -x

  terraform -chdir=${tf_run_path} init -backend-config=$backend_config_path -upgrade

  while IFS=',' read -ra TARGETS; do
    for target in "${TARGETS[@]}"; do
      terraform -chdir=${tf_run_path} apply -var-file=$vars_path -auto-approve -lock=false -replace=${target}
    done
  done <<<"$TARGET"

  rm -rf ${tf_run_path} #&& rm -rf ${modules_tgt_dir}
  set +x

  set +e

  do_simple_log "INFO STOP  ::: provisioning step ${tf_proj}"

}
