#!/bin/bash
#------------------------------------------------------------------------------
# @description Run a callback once per env of <ORG>-<APP>, each time as that
# @description env's project SA (owner rule 2026-09-19: the per-env service
# @description accounts only, never the owner account), in a throwaway
# @description CLOUDSDK_CONFIG so the shared ~/.config/gcloud is never written.
# @description An env whose key is missing or does not activate is reported and
# @description skipped; the others still run.
# @description
# @description The one body behind the do_gcp_list_* actions (CLE-77915,
# @description refactor item 3): seven files carried this loop copied, and one
# @description copy called a do_resolve_oa that does not exist.
# @param $1 the callback; called as <callback> <project-id> <account> <env>
# @param GCP_EACH_ENVS (optional) - space-separated envs, default "all dev prd stg"
# @example do_gcp_each_env_sa _gcp_list_buckets_one
#------------------------------------------------------------------------------
do_gcp_each_env_sa() {
  local callback="${1:-}"
  [[ -n "${callback}" ]] && declare -F "${callback}" >/dev/null \
    || { do_log "FATAL do_gcp_each_env_sa: give a callback function, got '${callback}'"; return 1; }

  local _spl_sdk_saved="${CLOUDSDK_CONFIG-}" _spl_sdk_dir
  _spl_sdk_dir="$(mktemp -d)"
  export CLOUDSDK_CONFIG="$_spl_sdk_dir"
  trap 'rm -rf "$_spl_sdk_dir"; if [[ -n "$_spl_sdk_saved" ]]; then export CLOUDSDK_CONFIG="$_spl_sdk_saved"; else unset CLOUDSDK_CONFIG; fi; trap - RETURN' RETURN

  do_resolve_oap ORG
  do_resolve_oap APP

  local env project key account
  for env in ${GCP_EACH_ENVS:-all dev prd stg}; do
    project="${ORG}-${APP}-${env}"
    key="$HOME/.gcp/.${ORG}/key-${project}.json"
    if [[ ! -f "${key}" ]]; then
      echo "Error: Service account key file ${key} not found for environment ${env}."
      continue
    fi
    echo "Authenticating with service account key for project ${project}..."
    if ! gcloud auth activate-service-account --key-file="${key}" &>/dev/null; then
      echo "Error: Failed to authenticate with ${key} for project ${project}." >&2
      continue
    fi
    account=$(do_gcp_isolated_active_account) || quit_on "re-pin --account to the identity just activated in the isolated gcloud config"
    if ! gcloud config set project "${project}" &>/dev/null; then
      echo "Error: Failed to set project to ${project}." >&2
      continue
    fi
    "${callback}" "${project}" "${account}" "${env}"
    echo "==============================================="
  done
}
