#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description Terraform destroy of one or more targeted resources only. See
# @description https://developer.hashicorp.com/terraform/cli/commands/destroy
# @description Pass multiple targets as a comma-separated list in TARGET.
# @description A dry run unless DRY_RUN=0: by default each target gets a
# @description `plan -destroy -target=<t>` (shows what would go, changes
# @description nothing); DRY_RUN=0 runs `apply -destroy -target=<t>`.
# @param ENV STEP TARGET - required
# @param DRY_RUN 1 (default) plans only, 0 destroys
# @example ENV=prd STEP=007-dns \
# @example   TARGET=google_dns_record_set.api_prd,google_dns_record_set.api_tst \
# @example   DRY_RUN=0 ./run -a do_tf_destroy_target
#------------------------------------------------------------------------------
do_tf_destroy_target() {

  local dry_run="${DRY_RUN:-1}" verb="apply -destroy -auto-approve"
  : "${ENV:?ENV must be set}" "${STEP:?STEP must be set}" "${TARGET:?TARGET must be set}"
  [[ "${dry_run}" != 0 ]] && verb="plan -destroy"

  do_log "INFO START ::: targeted destroy step=${STEP} TARGET=${TARGET} DRY_RUN=${dry_run}"

  do_tf_init

  tf_destroy_log_fle=$PROJ_PATH/dat/log/tf_destroy.${ORG:-}-${APP:-}-${ENV:-}.${STEP:-}.log
  test -f $tf_destroy_log_fle && rm -f $tf_destroy_log_fle

  vars_path="${tf_vars_path:-$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.vars.tfvars}"
  backend_config_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.backend-config.tfvars"

  set -e

  terraform -chdir=${tf_run_path} init -backend-config=$backend_config_path -upgrade -get=true -reconfigure

  while IFS=',' read -ra TARGETS; do
    for target in "${TARGETS[@]}"; do
      # shellcheck disable=SC2086  # verb is two or three words on purpose
      terraform -chdir=${tf_run_path} ${verb} -var-file=$vars_path -lock=false -target=${target} |
        tee -a $tf_destroy_log_fle
    done
  done <<<"$TARGET"

  rm -rf ${tf_run_path}
  set +x
  set +e

  [[ "${dry_run}" != 0 ]] && do_log "INFO DRY_RUN: nothing destroyed; DRY_RUN=0 destroys"
  do_simple_log "INFO STOP  ::: targeted destroy step=${tf_proj}"
  do_log "INFO ::: terraform destroy log file: $tf_destroy_log_fle"

}
