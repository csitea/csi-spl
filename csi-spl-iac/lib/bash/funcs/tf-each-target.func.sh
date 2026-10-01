#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Init the terraform of $STEP once, then run a callback on each
# @description comma-separated address in $TARGET, then drop the run dir. The
# @description one body behind do_tf_taint_target / do_tf_untaint_target /
# @description do_tf_state_show (CLE-77915, refactor item 3: three copies).
# @description Runs inside the tf-runner container like every do_tf_* action.
# @param $1 a label for the START/STOP log lines
# @param $2 the callback; called as <callback> <terraform address>
# @param TARGET - required: one address or a comma-separated list
# @example do_tf_each_target "tf state show" _tf_state_show_one
#------------------------------------------------------------------------------
do_tf_each_target() {
  local label="${1:?label}" callback="${2:?callback}"

  do_log "INFO START ::: ${label} - step ${STEP}"

  TARGET=${TARGET:?}

  do_tf_init

  local backend_config_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.backend-config.tfvars"

  set -e

  terraform -chdir="${tf_run_path}" init -backend-config="$backend_config_path" -upgrade

  local targets target
  IFS=',' read -ra targets <<<"$TARGET"
  for target in "${targets[@]}"; do
    "${callback}" "${target}"
  done

  rm -rf "${tf_run_path}"

  set +e

  do_simple_log "INFO STOP  ::: ${label} - step ${tf_proj}"
}
