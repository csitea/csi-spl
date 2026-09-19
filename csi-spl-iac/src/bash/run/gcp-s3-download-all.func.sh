#!/bin/bash

#------------------------------------------------------------------------------
# @description download all GCS buckets from a GCP project to local /var/ storage
# @param ENV - target environment (required: dev, tst, prd, all)
# @param GCP_PROJECT - GCP project override (default: {ORG}-{APP}-{ENV})
# @param TARGET_BASE - base directory override (default: /var/{ORG}/{ORG}-{APP})
# @param SKIP_EMPTY - skip empty buckets (default: true)
# @example ENV=prd ./run -a do_gcp_s3_download_all
# @example ENV=dev GCP_PROJECT=custom-project-id ./run -a do_gcp_s3_download_all
#------------------------------------------------------------------------------
do_gcp_s3_download_all() {
  local _spl_sdk_saved="${CLOUDSDK_CONFIG-}" _spl_sdk_dir
  _spl_sdk_dir="$(mktemp -d)"
  export CLOUDSDK_CONFIG="$_spl_sdk_dir"
  trap 'rm -rf "$_spl_sdk_dir"; if [[ -n "$_spl_sdk_saved" ]]; then export CLOUDSDK_CONFIG="$_spl_sdk_saved"; else unset CLOUDSDK_CONFIG; fi; trap - RETURN' RETURN

  do_require_var ORG ${ORG:-}
  do_require_var APP ${APP:-}
  do_require_var ENV ${ENV:-}

  local GCP_PROJECT="${GCP_PROJECT:-${ORG}-${APP}-${ENV}}"
  local TARGET_BASE="${TARGET_BASE:-/var/${ORG}/${ORG}-${APP}}"
  local SKIP_EMPTY="${SKIP_EMPTY:-true}"
  local GCLOUD="/opt/google-cloud-sdk/bin/gcloud"
  local GSUTIL="/opt/google-cloud-sdk/bin/gsutil"
  local TARGET_DIR="${TARGET_BASE}/${ORG}-${APP}-${ENV}/dat/s3"
  local KEY_FILE="$(eval echo ~/.gcp/.${ORG}/key-${GCP_PROJECT}.json)"

  do_log "INFO GCP_PROJECT: ${GCP_PROJECT}"
  do_log "INFO TARGET_DIR: ${TARGET_DIR}"

  # --- validate key file ---
  if [[ ! -f "${KEY_FILE}" ]]; then
    do_log "FATAL service account key not found: ${KEY_FILE}"
    return 1
  fi

  # --- authenticate ---
  do_log "INFO activating service account from ${KEY_FILE}"
  ${GCLOUD} auth activate-service-account --key-file="${KEY_FILE}" 2>&1
  if [[ $? -ne 0 ]]; then
    do_log "FATAL failed to activate service account"
    return 1
  fi

  ${GCLOUD} config set project "${GCP_PROJECT}" 2>/dev/null

  # --- list buckets ---
  do_log "INFO listing buckets in project ${GCP_PROJECT}"
  local BUCKETS
  BUCKETS=$(${GSUTIL} ls -p "${GCP_PROJECT}" 2>&1)
  if [[ $? -ne 0 ]]; then
    do_log "FATAL failed to list buckets: ${BUCKETS}"
    return 1
  fi

  if [[ -z "${BUCKETS}" ]]; then
    do_log "WARN no buckets found in project ${GCP_PROJECT}"
    return 0
  fi

  # --- download each bucket ---
  local TOTAL=0
  local DOWNLOADED=0
  local SKIPPED=0
  local FAILED=0
  local SUMMARY=""

  while IFS= read -r BUCKET_URL; do
    [[ -z "${BUCKET_URL}" ]] && continue
    TOTAL=$((TOTAL + 1))

    local BUCKET_NAME="${BUCKET_URL#gs://}"
    BUCKET_NAME="${BUCKET_NAME%/}"

    # skip internal GCF buckets
    if [[ "${BUCKET_NAME}" == gcf-sources-* ]]; then
      do_log "INFO skipping internal bucket: ${BUCKET_NAME}"
      SKIPPED=$((SKIPPED + 1))
      SUMMARY="${SUMMARY}\n  SKIP  ${BUCKET_NAME} (gcf-sources)"
      continue
    fi

    # check if bucket is empty when SKIP_EMPTY is true
    if [[ "${SKIP_EMPTY}" == "true" ]]; then
      local COUNT
      COUNT=$(${GSUTIL} ls "${BUCKET_URL}" 2>/dev/null | head -1)
      if [[ -z "${COUNT}" ]]; then
        do_log "INFO skipping empty bucket: ${BUCKET_NAME}"
        SKIPPED=$((SKIPPED + 1))
        SUMMARY="${SUMMARY}\n  SKIP  ${BUCKET_NAME} (empty)"
        continue
      fi
    fi

    local BUCKET_TARGET="${TARGET_DIR}/${BUCKET_NAME}"
    do_log "INFO syncing ${BUCKET_URL} -> ${BUCKET_TARGET}"

    sudo -u <DEV_USER> mkdir -p "${BUCKET_TARGET}"
    if [[ $? -ne 0 ]]; then
      do_log "ERROR failed to create directory: ${BUCKET_TARGET}"
      FAILED=$((FAILED + 1))
      SUMMARY="${SUMMARY}\n  FAIL  ${BUCKET_NAME} (mkdir failed)"
      continue
    fi

    ${GSUTIL} -m rsync -r "${BUCKET_URL}" "${BUCKET_TARGET}" 2>&1
    if [[ $? -ne 0 ]]; then
      do_log "ERROR failed to sync bucket: ${BUCKET_NAME}"
      FAILED=$((FAILED + 1))
      SUMMARY="${SUMMARY}\n  FAIL  ${BUCKET_NAME} (rsync failed)"
      continue
    fi

    local SIZE
    SIZE=$(du -sh "${BUCKET_TARGET}" 2>/dev/null | cut -f1)
    DOWNLOADED=$((DOWNLOADED + 1))
    SUMMARY="${SUMMARY}\n  OK    ${BUCKET_NAME} (${SIZE})"
    do_log "INFO completed: ${BUCKET_NAME} (${SIZE})"

  done <<< "${BUCKETS}"

  # --- summary ---
  do_log "INFO ============================================="
  do_log "INFO Download Summary for ${GCP_PROJECT}"
  do_log "INFO ============================================="
  do_log "INFO Total buckets:      ${TOTAL}"
  do_log "INFO Downloaded:         ${DOWNLOADED}"
  do_log "INFO Skipped:            ${SKIPPED}"
  do_log "INFO Failed:             ${FAILED}"
  do_log "INFO Target directory:   ${TARGET_DIR}"
  do_log "INFO ---------------------------------------------"
  echo -e "${SUMMARY}"
  do_log "INFO ============================================="

  if [[ ${FAILED} -gt 0 ]]; then
    return 1
  fi
  return 0
}
