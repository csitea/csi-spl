#!/bin/bash
#------------------------------------------------------------------------------
# @description Import live Cloud Run (and the other 030 addresses that already
#   exist) into the 030-cloud-run-hub terraform state. IMPORT ONLY — never
#   apply. The POSIX importer
#   src/bash/scripts/tf-030-import-existing-cloud-run.sh runs inside a
#   throwaway hashicorp/terraform image against a scratch copy of the step
#   (later steps read src/bash/scripts/tf-import-table.sh). Idempotent
#   (address already in state = skip); a resource that
#   is not live is reported and skipped, non-fatal. Does not use the
#   decommissioned inf SA key; credentials are the per-env key under
#   $HOME/.gcp/.<org>/key-<gcp-project>.json.
# @output run log - $LOG_DIR/$PROJ.YYYYMMDD.log (do_log; LOG_DIR is $PROJ_PATH/dat/log/bash)
# @param ENV - target environment (dev or prd) [required]
# @param TF_IMAGE - terraform image (optional; default hashicorp/terraform:1.9)
# @param TF_030_WORK - scratch work dir (optional; default /var/tmp/tf-030-<env>)
# @example ENV=dev ./run -a do_tf_030_import_existing_cloud_run
# @example ENV=prd ./run -a do_tf_030_import_existing_cloud_run
#------------------------------------------------------------------------------
do_tf_030_import_existing_cloud_run() {
  local env_name="${ENV:-}"
  if [[ -z "$env_name" ]]; then
    do_log "FATAL ENV is required. Usage: ENV=dev ./run -a do_tf_030_import_existing_cloud_run"
    return 1
  fi
  case "$env_name" in
    dev|prd) ;;
    inf)
      do_log "FATAL ENV=inf is decommissioned; use the per-env key under \$HOME/.gcp/.<org>/key-<org>-<app>-<env>.json"
      return 1
      ;;
    *)
      do_log "FATAL ENV must be one of dev|prd (got '${env_name}')"
      return 1
      ;;
  esac

  # Resolve from THIS checkout, not docker .env APP_PATH (which may point at
  # the shared tree while we are in a worktree).
  local orc_dir root
  orc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  root="$(cd "${orc_dir}/.." && pwd)"

  local step="030-cloud-run-hub"
  local script="${orc_dir}/src/bash/scripts/tf-030-import-existing-cloud-run.sh"
  local tf_src="${root}/csi-spl-iac/src/terraform/${step}"
  local vars="${root}/csi-spl-cnf/csi-spl/${env_name}/tf/${step}.vars.tfvars"
  local backend="${root}/csi-spl-cnf/csi-spl/${env_name}/tf/${step}.backend-config.tfvars"

  [[ -f "$script" ]]  || { do_log "FATAL missing importer $script"; return 1; }
  [[ -d "$tf_src" ]]  || { do_log "FATAL missing terraform step $tf_src"; return 1; }
  [[ -f "$vars" ]]    || { do_log "FATAL missing tfvars $vars"; return 1; }
  [[ -f "$backend" ]] || { do_log "FATAL missing backend-config $backend"; return 1; }

  local org project
  org="$(awk -F= '/^[[:space:]]*org[[:space:]]*=/{gsub(/[ "]+/, "", $2); print $2; exit}' "$vars")"
  project="$(awk -F= '/^[[:space:]]*gcp_project[[:space:]]*=/{gsub(/[ "]+/, "", $2); print $2; exit}' "$vars")"
  [[ -n "$org" && -n "$project" ]] || { do_log "FATAL could not parse org/gcp_project from $vars"; return 1; }

  local host_key="${HOME}/.gcp/.${org}/key-${project}.json"
  if [[ ! -f "$host_key" ]]; then
    do_log "FATAL missing credentials ${host_key} (do not fall back to an inf key)"
    return 1
  fi

  command -v docker >/dev/null 2>&1 || { do_log "FATAL docker is required"; return 1; }

  local work="${TF_030_WORK:-/var/tmp/tf-030-${env_name}}"
  case "$work" in
    *tf-030*) ;;
    *) do_log "FATAL refuse to reset a work dir that does not contain tf-030: $work"; return 1 ;;
  esac
  rm -rf "$work"
  mkdir -p "$work"
  cp -a "${tf_src}/." "$work/"
  cp -a "$vars" "$backend" "$script" "$work/"

  local tf_image="${TF_IMAGE:-hashicorp/terraform:1.9}"
  local tf_home="/home/tf"
  local gcp_key_in_ctr="${tf_home}/.gcp/.${org}/key-${project}.json"

  do_log "INFO INIT  ${step} env=${env_name} work=${work} image=${tf_image}"
  if ! _tf030_docker "$work" "$tf_home" "$gcp_key_in_ctr" "$step" \
      "$tf_image" init -input=false -backend-config="${step}.backend-config.tfvars"; then
    do_log "ERROR terraform init failed for ${step} ${env_name}"
    return 1
  fi

  do_log "INFO IMPORT ${step} env=${env_name} (import only; will not apply)"
  if ! _tf030_docker "$work" "$tf_home" "$gcp_key_in_ctr" "$step" \
      --entrypoint sh "$tf_image" /tf/tf-030-import-existing-cloud-run.sh "${step}.vars.tfvars"; then
    do_log "ERROR importer failed for ${step} ${env_name}"
    return 1
  fi

  do_log "OK ${step} ${env_name} import finished (import only). Next: terraform plan. Do NOT apply."
  return 0
}

# _tf030_docker <work dir> <container home> <key in container> <step> <args...>:
# one terraform-image run over <work> as the caller's uid, the per-env key
# mounted read-only, the TF_VAR_* the steps expect; <args...> follow the
# environment flags (an optional --entrypoint, the image, its arguments).
_tf030_docker() {
  local work="$1" tf_home="$2" gcp_key_in_ctr="$3" step="$4"; shift 4
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    -v "${work}:/tf" -w /tf \
    -v "${HOME}/.gcp:${tf_home}/.gcp:ro" \
    -e HOME="${tf_home}" \
    -e GOOGLE_APPLICATION_CREDENTIALS="${gcp_key_in_ctr}" \
    -e TF_VAR_STEP="${step}" \
    -e TF_VAR_proj_path=/tf \
    -e TF_VAR_base_path=/ \
    -e TF_VAR_TERRAFORM_VERSION=1.9 \
    -e TF_VAR_INFRA_VERSION=0 \
    -e TF_VAR_CNF_VER=import \
    -e TF_IN_AUTOMATION=1 \
    "$@"
}
