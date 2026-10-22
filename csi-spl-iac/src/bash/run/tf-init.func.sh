#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description init terraform for the current step , copy the modules and the step folder to the run path and export the required vars
#------------------------------------------------------------------------------
do_tf_init() {

  tf_proj=${STEP:?}
  tgt_app=${APP:?}

  do_require_var ORG "${ORG:-}"
  do_require_var APP "${APP:-}"
  do_require_var ENV "${ENV:-}"
  do_require_var STEP "${STEP:-}"
  do_require_var ACTION "${ACTION:-provision}" # fail safe, never destroy if something breaks

  tf_init_normalise_app
  tf_init_export_vars
  tf_init_switch_terraform
  tf_init_copy_step
  tf_init_private_vars
}

# Canonicalise APP — accept either the suffix-only form ("spl", per the
# do_resolve_oap convention <base>/<ORG>/<ORG>-<APP>/) OR the legacy
# full-name form ("csi-spl", from the docker .env.cin). Strip a leading
# "${ORG}-" if present so that ${ORG}-${APP} is always "csi-spl" — not
# "csi-csi-spl". Export so downstream callers (tf-plan, tf-apply, ...) see
# the normalised value when they compute the per-step paths.
tf_init_normalise_app() {
  if [[ "${APP}" == "${ORG}-"* ]]; then
    APP="${APP#${ORG}-}"
    export APP
    do_log "INFO normalised APP -> ${APP} (was prefixed with ${ORG}-)"
  fi
}

# tf_init_export_vars: the env.json sections as TF_VAR_* and plain vars, the
# run path, the versions and the step's service account key.
tf_init_export_vars() {
  ENV_CONF_JSON_FLE="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV.env.json"

  do_export_json_section_vars_as_tf_vars "$ENV_CONF_JSON_FLE" ".env.aws"
  do_export_json_section_vars_as_tf_vars "$ENV_CONF_JSON_FLE" ".env.gcp"

  do_export_json_section_vars "$ENV_CONF_JSON_FLE" ".env.terrafom"
  do_export_json_section_vars "$ENV_CONF_JSON_FLE" ".env.gcp"
  do_export_json_section_vars "$ENV_CONF_JSON_FLE" ".env.aws"
  do_export_json_section_vars "$ENV_CONF_JSON_FLE" ".env.github"
  do_export_json_section_vars "$ENV_CONF_JSON_FLE" ".env.versions"
  do_export_json_section_vars "$ENV_CONF_JSON_FLE" '.env.steps."'${STEP}'"'

  export TF_VAR_proj_path="${PROJ_PATH}"
  export TF_VAR_base_path="${BASE_PATH}"
  export TF_VAR_org_path="${ORG_PATH}"
  # TF_RUN_DIR_SUFFIX (SPL-1947): a read-only plan (do_tf_plan_pending) runs in
  # its own dir, so the wipe below never hits an apply of the same env + step.
  export tf_run_path=${PROJ_PATH}/bin/${ORG}/${APP}/${ENV}/${tf_proj}${TF_RUN_DIR_SUFFIX:-}
  export TF_LOG=ERROR # DEBUG, TRACE, INFO, WARN or ERROR
  export TF_VAR_TERRAFORM_VERSION=${TERRAFORM_VERSION}
  export TF_VAR_INFRA_VERSION=${INFRA_VERSION}
  TF_VAR_CNF_VER="$(git rev-parse --short HEAD)"
  export TF_VAR_CNF_VER
  export TF_VAR_STEP=${STEP:-}
  export TF_GITHUB_TOKEN=${GITHUB_TOKEN:-}
  # A step that works in ANOTHER project names it as steps.<step>.tf_key_project
  # (046: the off-project backups in csi-spl-bkp, run as that project's SA).
  # Read from the json for THIS step only, never from an exported variable: a
  # value left over from an earlier step in the same shell must not move a
  # later step onto the wrong key.
  local key_project
  key_project=$(jq -r --arg s "$STEP" '.env.steps[$s].tf_key_project // empty' "$ENV_CONF_JSON_FLE" 2>/dev/null)
  export GOOGLE_APPLICATION_CREDENTIALS="$HOME/.gcp/.$ORG/key-${key_project:-$GCP_PROJECT}.json"
  # One plugin cache for every env + step (SPL-2821): keyed per env + step it
  # never shared, and one env-order sweep landed the same two providers 59
  # times (6.0 GB in the tf-runner on sat, 2026-10-22). The old per-step dirs
  # go with do_remove_tf_plugin_cache_per_step.
  export TF_PLUGIN_CACHE_DIR="$HOME/.terraform.d/plugin-cache"
}

# terraform: `init` runs under an flock beside the plugin cache, every other
# subcommand straight through. Terraform does not make the cache safe for two
# concurrent `init` writers, and two DIFFERENT steps may init at once (the
# prd order gate plans dev inside a prd run, two operators, two steps); the
# lock costs the length of an init whose providers are already cached.
# Defined here so every caller of do_tf_init (tf-apply, tf-plan, ...) gets it.
# TF_INIT_LOCK_WAIT (optional) - seconds to wait for the lock, default 1800.
terraform() {
  local a sub=""
  for a in "$@"; do [[ "$a" == -* ]] || { sub="$a"; break; }; done
  if [[ "$sub" == init && -n "${TF_PLUGIN_CACHE_DIR:-}" ]]; then
    flock -w "${TF_INIT_LOCK_WAIT:-1800}" "${TF_PLUGIN_CACHE_DIR%/}.lock" terraform "$@"
  else
    command terraform "$@"
  fi
}

# tf_init_switch_terraform: the plugin cache dir, then the pinned terraform
# version; quit_on exits when the switch failed.
tf_init_switch_terraform() {
  if [[ ! -d "$TF_PLUGIN_CACHE_DIR" ]]; then mkdir -p "$TF_PLUGIN_CACHE_DIR"; fi

  flock /tmp/tfswitch.lock tfswitch ${TERRAFORM_VERSION}
  quit_on "switching  to terraform version ${TERRAFORM_VERSION}"
}

# tf_init_copy_step: wipe the run dir first (one run per env + step), copy the
# step into it and keep ../modules in sync with the source by md5.
tf_init_copy_step() {
  tf_src_path="$PROJ_PATH/src/terraform/$tf_proj"
  # Only remove the tf_run_path if the ACTION is destroy
  # if [[ "${ACTION}" == "destroy" ]]; then
  if [[ -d "${tf_run_path}" ]]; then rm -r "${tf_run_path}"; fi
  # fi

  mkdir -p ${PROJ_PATH}/bin/${ORG}/${APP}/${ENV}
  cp -r ${tf_src_path} ${tf_run_path}

  # First-run bootstrap: ensure ../modules is copied before md5-comparing it.
  if [[ ! -d "${tf_run_path}/../modules" ]]; then
    do_log "INFO first-run: copying ${tf_src_path}/../modules -> ${tf_run_path}/../modules"
    cp -r "${tf_src_path}/../modules" "${tf_run_path}/../"
  fi

  md5modules_bin=$(find ${tf_run_path}/../modules -type f -exec md5sum {} \; | md5sum)
  md5modules=$(find ${tf_src_path}/../modules -type f -exec md5sum {} \; | md5sum)

  # if they're not equal, the copy again
  if [[ "${md5modules_bin}" == "${md5modules}" ]]; then
    do_log "INFO modules folder MD5 is consistent: ${md5modules}"
    do_log "INFO sync is not needed"
  else
    do_log "WARNING modules folder MD5 diverged: ${md5modules_bin} -- ${md5modules}"
    do_log "INFO copying ${tf_src_path} to ${tf_run_path}"
    rm -rf "${tf_run_path}/../modules" && cp -r "${tf_src_path}/../modules" "${tf_run_path}/../"
  fi

  do_log "INFO copying ${tf_src_path} to ${tf_run_path}"
}

# tf_init_private_vars (SPL-1874): the step's tfvars as terraform reads them,
# in tf_vars_path. A tracked file with a hidden-workspace placeholder
# (ws-hidden-NN) is resolved through the private overlay into the run dir
# (removed with it, mode 600). No overlay, or a placeholder it does not map:
# FATAL and EXIT, never a plan or an apply with placeholders.
tf_init_private_vars() {
  local tracked="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.vars.tfvars"
  tf_vars_path="$tracked"
  if [[ -f "$tracked" ]] && spl_private_has_tokens "$tracked"; then
    tf_vars_path="${tf_run_path}/$tf_proj.private.vars.tfvars"
    spl_private_resolve "$tracked" "$tf_vars_path" || {
      do_log "FATAL $tf_proj: the tfvars name hidden workspaces and the private overlay cannot resolve them"
      exit 1
    }
    do_log "INFO $tf_proj.vars.tfvars: placeholders resolved from the private overlay"
  fi
  export tf_vars_path
}
