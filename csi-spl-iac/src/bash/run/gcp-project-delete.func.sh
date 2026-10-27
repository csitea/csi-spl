#!/bin/bash
# shellcheck source=../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh
declare -F spl_gcp_temp_sdk_config >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh"

#------------------------------------------------------------------------------
# @description delete a GCP project (30-day grace period, can be undeleted)
# @param ENV - target environment (required)
# @param GCP_PROJECT - GCP project override (default: {ORG}-{APP}-{ENV})
# @param FORCE - skip confirmation prompt (default: false)
# @example ENV=prd ./run -a do_gcp_project_delete
# @example ENV=dev GCP_PROJECT=custom-project-id ./run -a do_gcp_project_delete
#------------------------------------------------------------------------------
# The steps below read the caller's locals by bash dynamic scope (no global):
#   GCP_PROJECT FORCE GCLOUD GSUTIL KEY_FILE   (do_gcp_project_delete)
#   account                                    (filled by _gcpprojdel_authenticate)
# Each step returns 1 on a failure, and the action passes it on (step || return 1).
do_gcp_project_delete() {
  local _spl_sdk_saved _spl_sdk_dir
  spl_gcp_temp_sdk_config || return 1
  trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN

  do_require_var ORG ${ORG:-}
  do_require_var APP ${APP:-}
  do_require_var ENV ${ENV:-}

  local GCP_PROJECT="${GCP_PROJECT:-${ORG}-${APP}-${ENV}}"
  local FORCE="${FORCE:-false}"
  local GCLOUD="/opt/google-cloud-sdk/bin/gcloud"
  local GSUTIL="/opt/google-cloud-sdk/bin/gsutil"
  local KEY_FILE="$HOME/.gcp/.${ORG}/key-${GCP_PROJECT}.json"

  do_log "INFO GCP_PROJECT: ${GCP_PROJECT}"

  local account
  _gcpprojdel_authenticate || return 1
  _gcpprojdel_show_details || return 1
  # "done" is a predicate: true when a delete was already requested, and the
  # action then ends here with rc 0, before any gsutil or delete call
  _gcpprojdel_already_requested && return 0
  _gcpprojdel_list_buckets
  _gcpprojdel_confirm || return 1
  _gcpprojdel_delete || return 1
  _gcpprojdel_verify

  return 0
}

# --- authenticate: the project SA from its key, in this private config ---
# (owner rule 2026-09-19: the per-env service accounts only; no key is a
# refusal, never a fall back to whatever auth happens to be around)
_gcpprojdel_authenticate() {
  account=$(PATH="$(dirname "${GCLOUD}"):${PATH}" GCP_SA_KEY_FILE="${GCP_SA_KEY_FILE:-${KEY_FILE}}" do_gcp_account) \
    || { do_log "FATAL no identity for ${GCP_PROJECT}: need ${KEY_FILE} or ACCOUNT / GCP_ACCOUNT"; return 1; }
  do_gcp_log_identity "${GCP_PROJECT}" "${account}" "do_gcp_project_delete"

  ${GCLOUD} config set project "${GCP_PROJECT}" 2>/dev/null
}

# --- show project details ---
_gcpprojdel_show_details() {
  do_log "INFO ============================================="
  do_log "INFO Project Details"
  do_log "INFO ============================================="

  local PROJECT_INFO
  PROJECT_INFO=$(${GCLOUD} projects describe "${GCP_PROJECT}" --account="${account}" \
    --format="table(projectId, name, lifecycleState, createTime)" 2>&1)
  if [[ $? -ne 0 ]]; then
    do_log "FATAL failed to describe project: ${PROJECT_INFO}"
    return 1
  fi
  echo "${PROJECT_INFO}"
}

# --- check lifecycle state --- rc 0 = already DELETE_REQUESTED (done), 1 = go on
_gcpprojdel_already_requested() {
  local STATE
  STATE=$(${GCLOUD} projects describe "${GCP_PROJECT}" --account="${account}" \
    --format="value(lifecycleState)" 2>/dev/null)
  if [[ "${STATE}" == "DELETE_REQUESTED" ]]; then
    do_log "WARN project ${GCP_PROJECT} is already in DELETE_REQUESTED state"
    return 0
  fi
  return 1
}

# --- list buckets and sizes ---
_gcpprojdel_list_buckets() {
  do_log "INFO ---------------------------------------------"
  do_log "INFO Buckets in project ${GCP_PROJECT}:"
  do_log "INFO ---------------------------------------------"

  local BUCKETS
  BUCKETS=$(${GSUTIL} ls -p "${GCP_PROJECT}" 2>/dev/null)
  if [[ -n "${BUCKETS}" ]]; then
    while IFS= read -r BUCKET_URL; do
      [[ -z "${BUCKET_URL}" ]] && continue
      local BUCKET_NAME="${BUCKET_URL#gs://}"
      BUCKET_NAME="${BUCKET_NAME%/}"
      local SIZE
      SIZE=$(${GSUTIL} du -s "${BUCKET_URL}" 2>/dev/null | awk '{print $1}')
      SIZE=${SIZE:-0}
      do_log "INFO   ${BUCKET_NAME}: $(_gcpprojdel_human_size "${SIZE}")"
    done <<< "${BUCKETS}"
  else
    do_log "INFO   (no buckets found)"
  fi

  do_log "INFO ============================================="
}

# _gcpprojdel_human_size <bytes> -> "<n> GB|MB|KB" (bc, two decimals) or "<n> B"
_gcpprojdel_human_size() {
  local SIZE=$1 HR_SIZE
  if [[ ${SIZE} -ge 1073741824 ]]; then
    HR_SIZE="$(echo "scale=2; ${SIZE}/1073741824" | bc) GB"
  elif [[ ${SIZE} -ge 1048576 ]]; then
    HR_SIZE="$(echo "scale=2; ${SIZE}/1048576" | bc) MB"
  elif [[ ${SIZE} -ge 1024 ]]; then
    HR_SIZE="$(echo "scale=2; ${SIZE}/1024" | bc) KB"
  else
    HR_SIZE="${SIZE} B"
  fi
  echo "${HR_SIZE}"
}

# --- confirmation --- reads the project id from stdin unless FORCE=true
_gcpprojdel_confirm() {
  if [[ "${FORCE}" != "true" ]]; then
    do_log "WARN you are about to delete project: ${GCP_PROJECT}"
    do_log "WARN this action has a 30-day grace period (can be undeleted)"
    echo ""
    echo "Are you sure? Type the project ID to confirm: "
    read -r CONFIRM
    if [[ "${CONFIRM}" != "${GCP_PROJECT}" ]]; then
      do_log "INFO deletion cancelled — input did not match project ID"
      return 1
    fi
  fi
}

# --- delete project ---
_gcpprojdel_delete() {
  do_log "INFO deleting project ${GCP_PROJECT} ..."
  ${GCLOUD} projects delete "${GCP_PROJECT}" --account="${account}" --quiet 2>&1
  if [[ $? -ne 0 ]]; then
    do_log "FATAL failed to delete project ${GCP_PROJECT}"
    return 1
  fi
}

# --- verify ---
_gcpprojdel_verify() {
  local NEW_STATE
  NEW_STATE=$(${GCLOUD} projects describe "${GCP_PROJECT}" --account="${account}" \
    --format="value(lifecycleState)" 2>/dev/null)
  if [[ "${NEW_STATE}" == "DELETE_REQUESTED" ]]; then
    do_log "INFO project ${GCP_PROJECT} is now in DELETE_REQUESTED state"
    do_log "INFO the project will be permanently deleted after 30 days"
    do_log "INFO to undelete: gcloud projects undelete ${GCP_PROJECT}"
  else
    do_log "WARN unexpected state after deletion: ${NEW_STATE}"
  fi
}
