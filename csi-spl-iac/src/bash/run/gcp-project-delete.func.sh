#!/bin/bash

#------------------------------------------------------------------------------
# @description delete a GCP project (30-day grace period, can be undeleted)
# @param ENV - target environment (required)
# @param GCP_PROJECT - GCP project override (default: {ORG}-{APP}-{ENV})
# @param FORCE - skip confirmation prompt (default: false)
# @example ENV=prd ./run -a do_gcp_project_delete
# @example ENV=dev GCP_PROJECT=custom-project-id ./run -a do_gcp_project_delete
#------------------------------------------------------------------------------
do_gcp_project_delete() {
  local _spl_sdk_saved="${CLOUDSDK_CONFIG-}" _spl_sdk_dir
  _spl_sdk_dir="$(mktemp -d)"
  export CLOUDSDK_CONFIG="$_spl_sdk_dir"
  trap 'rm -rf "$_spl_sdk_dir"; if [[ -n "$_spl_sdk_saved" ]]; then export CLOUDSDK_CONFIG="$_spl_sdk_saved"; else unset CLOUDSDK_CONFIG; fi; trap - RETURN' RETURN

  do_require_var ORG ${ORG:-}
  do_require_var APP ${APP:-}
  do_require_var ENV ${ENV:-}

  local GCP_PROJECT="${GCP_PROJECT:-${ORG}-${APP}-${ENV}}"
  local FORCE="${FORCE:-false}"
  local GCLOUD="/opt/google-cloud-sdk/bin/gcloud"
  local GSUTIL="/opt/google-cloud-sdk/bin/gsutil"
  local KEY_FILE="$(eval echo ~/.gcp/.${ORG}/key-${GCP_PROJECT}.json)"

  do_log "INFO GCP_PROJECT: ${GCP_PROJECT}"

  # --- authenticate: the project SA from its key, in this private config ---
  # (owner rule 2026-09-19: the per-env service accounts only; no key is a
  # refusal, never a fall back to whatever auth happens to be around)
  local account
  account=$(PATH="$(dirname "${GCLOUD}"):${PATH}" GCP_SA_KEY_FILE="${GCP_SA_KEY_FILE:-${KEY_FILE}}" do_gcp_account) \
    || { do_log "FATAL no identity for ${GCP_PROJECT}: need ${KEY_FILE} or ACCOUNT / GCP_ACCOUNT"; return 1; }
  do_gcp_log_identity "${GCP_PROJECT}" "${account}" "do_gcp_project_delete"

  ${GCLOUD} config set project "${GCP_PROJECT}" 2>/dev/null

  # --- show project details ---
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

  # --- check lifecycle state ---
  local STATE
  STATE=$(${GCLOUD} projects describe "${GCP_PROJECT}" --account="${account}" \
    --format="value(lifecycleState)" 2>/dev/null)
  if [[ "${STATE}" == "DELETE_REQUESTED" ]]; then
    do_log "WARN project ${GCP_PROJECT} is already in DELETE_REQUESTED state"
    return 0
  fi

  # --- list buckets and sizes ---
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
      # convert bytes to human readable
      local HR_SIZE
      if [[ ${SIZE} -ge 1073741824 ]]; then
        HR_SIZE="$(echo "scale=2; ${SIZE}/1073741824" | bc) GB"
      elif [[ ${SIZE} -ge 1048576 ]]; then
        HR_SIZE="$(echo "scale=2; ${SIZE}/1048576" | bc) MB"
      elif [[ ${SIZE} -ge 1024 ]]; then
        HR_SIZE="$(echo "scale=2; ${SIZE}/1024" | bc) KB"
      else
        HR_SIZE="${SIZE} B"
      fi
      do_log "INFO   ${BUCKET_NAME}: ${HR_SIZE}"
    done <<< "${BUCKETS}"
  else
    do_log "INFO   (no buckets found)"
  fi

  do_log "INFO ============================================="

  # --- confirmation ---
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

  # --- delete project ---
  do_log "INFO deleting project ${GCP_PROJECT} ..."
  ${GCLOUD} projects delete "${GCP_PROJECT}" --account="${account}" --quiet 2>&1
  if [[ $? -ne 0 ]]; then
    do_log "FATAL failed to delete project ${GCP_PROJECT}"
    return 1
  fi

  # --- verify ---
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

  return 0
}
