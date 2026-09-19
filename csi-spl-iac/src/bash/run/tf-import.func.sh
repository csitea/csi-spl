#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description import an existing resource into Terraform state
# @example ENV=all STEP=120-github-general-secrets TARGET='resource.name[0]' ID='repo:VAR' ./run -a do_tf_import
#------------------------------------------------------------------------------
do_tf_import() {
  export ACTION="${ACTION:-provision}"

  do_require_var ENV "${ENV:-}"
  do_require_var STEP "${STEP:-}"
  do_require_var TARGET "${TARGET:-}"
  do_require_var ID "${ID:-}"

  do_tf_init

  local vars_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/${STEP}.vars.tfvars"
  local backend_config_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/${STEP}.backend-config.tfvars"

  do_log "INFO START ::: importing resource into step ${STEP}"
  do_log "INFO TARGET: ${TARGET}"
  do_log "INFO ID:     ${ID}"

  set -x
  {
    terraform -chdir=${tf_run_path} init -backend-config=$backend_config_path -upgrade -get=true -reconfigure 2>&1 &&
    terraform -chdir=${tf_run_path} import -var-file=$vars_path -lock=false "${TARGET}" "${ID}" 2>&1
  }
  local _rc=${PIPESTATUS[0]}
  set +x

  if [ $_rc -eq 0 ]; then
    do_log "OK Resource imported successfully: ${TARGET} -> ${ID}"
  else
    do_log "FATAL Failed to import resource: ${TARGET} -> ${ID}"
  fi

  do_log "INFO STOP  ::: importing resource into step ${STEP}"
}
