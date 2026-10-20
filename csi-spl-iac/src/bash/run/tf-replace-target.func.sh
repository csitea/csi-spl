#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description Tf replace target: re-create the named resources only.
# @description Pass multiple targets as a comma-separated list in TARGET.
# @description A dry run unless DRY_RUN=0: by default each target gets a
# @description `plan -replace=<t>` (shows what would change, changes nothing);
# @description DRY_RUN=0 runs `apply -auto-approve -replace=<t>`.
# @param ENV STEP TARGET - required
# @param DRY_RUN 1 (default) plans only, 0 replaces
# @example ENV=dev STEP=031-gcp-hub-ingress TARGET=<addr>,<addr> \
# @example   DRY_RUN=0 ./run -a do_tf_replace_target
#------------------------------------------------------------------------------
do_tf_replace_target() {

  local dry_run="${DRY_RUN:-1}" verb="apply" approve="-auto-approve"
  : "${ENV:?ENV must be set}" "${STEP:?STEP must be set}" "${TARGET:?TARGET must be set}"
  [[ "${dry_run}" != 0 ]] && verb="plan" approve=""

  do_log "INFO START ::: provisioning step ${STEP:-} TARGET=${TARGET} DRY_RUN=${dry_run}"

  do_tf_init

  vars_path="${tf_vars_path:-$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.vars.tfvars}"
  backend_config_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.backend-config.tfvars"

  set -e

  echo "running: "
  #set -x

  terraform -chdir=${tf_run_path} init -backend-config=$backend_config_path -upgrade

  while IFS=',' read -ra TARGETS; do
    for target in "${TARGETS[@]}"; do
      # shellcheck disable=SC2086  # approve is empty on a dry run on purpose
      terraform -chdir=${tf_run_path} ${verb} -var-file=$vars_path ${approve} -lock=false -replace=${target}
    done
  done <<<"$TARGET"

  rm -rf ${tf_run_path} #&& rm -rf ${modules_tgt_dir}
  set +x

  set +e

  [[ "${dry_run}" != 0 ]] && do_log "INFO DRY_RUN: nothing replaced; DRY_RUN=0 replaces"
  do_simple_log "INFO STOP  ::: provisioning step ${tf_proj}"

}
