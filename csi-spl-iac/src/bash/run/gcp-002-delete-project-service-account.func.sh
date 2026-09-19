#------------------------------------------------------------------------------
# @description Gcp 002 delete project service account.
#------------------------------------------------------------------------------
do_gcp_002_delete_project_service_account() {
  local _spl_sdk_saved="${CLOUDSDK_CONFIG-}" _spl_sdk_dir
  _spl_sdk_dir="$(mktemp -d)"
  export CLOUDSDK_CONFIG="$_spl_sdk_dir"
  trap 'rm -rf "$_spl_sdk_dir"; if [[ -n "$_spl_sdk_saved" ]]; then export CLOUDSDK_CONFIG="$_spl_sdk_saved"; else unset CLOUDSDK_CONFIG; fi; trap - RETURN' RETURN
  # Pin the gcloud identity for this run (spec 012 C-2). `--project` says WHERE
  # a call lands, never WHO it lands as, and `~/.config/gcloud` is one directory
  # shared by every agent on this box — `gcloud config set account` and
  # `auth activate-service-account` are both global writes, so the ambient
  # account is whichever agent ran one last. Resolved ONCE here so another
  # agent cannot move this run's identity between two of its own calls, passed
  # explicitly to each call below, and logged before the first of them so the
  # identity is auditable afterwards rather than inferable from a config file
  # that will have moved by the time anyone looks.
  local account
  account=$(do_gcp_account) || quit_on "no gcloud identity could be resolved — set ACCOUNT or GCP_ACCOUNT"
  do_gcp_log_identity "${PROJ_ID:-<unset>}" "${account}" "do_gcp_002_delete_project_service_account"

    # ────────────────────────────────────────────────────────────────
    # Required / expected environment variables
    # ────────────────────────────────────────────────────────────────
    : "${ORG:?ORG is required}"
    : "${APP:?APP is required}"
    : "${ENV:?ENV is required}"
    : "${GCP_ACCOUNT:?GCP_ACCOUNT is required (e.g. your-email@domain.com)}"

    # Construct identifiers (same as creation)
    local PROJ_ID="${ORG}-${APP}-${ENV}"
    local SA_NAME="${PROJ_ID}"
    local SA_EMAIL="${SA_NAME}@${PROJ_ID}.iam.gserviceaccount.com"
    local KEY_FILE="$HOME/.gcp/.${ORG}/key-${SA_NAME}.json"

    do_log "INFO" "Starting deletion of service account: ${SA_EMAIL} in project ${PROJ_ID}"

    # ────────────────────────────────────────────────────────────────
    # Authentication – most reliable sequence in 2025
    # ────────────────────────────────────────────────────────────────
    do_log "INFO" "Ensuring fresh gcloud authentication..."

    # 1. Revoke everything old (best effort)
    gcloud auth revoke --all 2>/dev/null || true

    # 2. Force application-default credentials login (what Terraform / most SDKs use)
    gcloud auth application-default revoke 2>/dev/null || true

    # 3. Interactive user login + update ADC
    if ! gcloud auth login --update-adc --quiet; then
        do_log "ERROR" "gcloud auth login failed. Please run it manually first:"
        echo "    gcloud auth login"
        echo "    gcloud auth application-default login"
  return 1
    fi
    account=$(do_gcp_isolated_active_account) || quit_on "re-pin --account to the identity just activated in the isolated gcloud config"

    # 4. Explicitly set the desired account
    do_log "INFO" "Setting active account to ${GCP_ACCOUNT}"
    if ! gcloud config set account "${GCP_ACCOUNT}"; then
        do_log "ERROR" "Failed to set account ${GCP_ACCOUNT}"
  return 1
    fi

    # 5. Final validation – both user credentials and ADC
    if ! gcloud auth print-access-token --account="${account}" >/dev/null 2>&1; then
        do_log "ERROR" "No valid user credentials after login"
  return 1
    fi

    if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
        do_log "WARNING" "ADC still not valid — running application-default login"
        if ! gcloud auth application-default login --quiet; then
            do_log "ERROR" "application-default login also failed"
            do_log "ERROR" "Please run manually: gcloud auth application-default login"
  return 1
        fi
    fi

    do_log "SUCCESS" "Authenticated as ${GCP_ACCOUNT} (user + ADC)"

    # ────────────────────────────────────────────────────────────────
    # Actual cleanup
    # ────────────────────────────────────────────────────────────────

    # Check if SA exists
    if ! gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJ_ID}" --account="${account}" >/dev/null 2>&1; then
        do_log "INFO" "Service account ${SA_EMAIL} does not exist — nothing to delete"
        # Still clean local key if present
        if [[ -f "${KEY_FILE}" ]]; then
            rm -f "${KEY_FILE}" && do_log "INFO" "Removed stale local key file: ${KEY_FILE}"
        fi
        return 0
    fi

    do_log "INFO" "Found service account ${SA_EMAIL} — cleaning up"

    # Delete all keys first
    do_log "INFO" "Deleting all keys attached to ${SA_EMAIL}"
    local KEY_IDS
    KEY_IDS=$(gcloud iam service-accounts keys list \
        --iam-account="${SA_EMAIL}" \
        --project="${PROJ_ID}" \
        --format="value(name)" \
      --account="${account}" 2>/dev/null || true)

    if [[ -n "${KEY_IDS}" ]]; then
        for key_id in ${KEY_IDS}; do
            do_log "INFO" "Deleting key: ${key_id}"
            gcloud iam service-accounts keys delete "${key_id}" \
                --iam-account="${SA_EMAIL}" --quiet \
              --account="${account}" \
              --project="${PROJ_ID}" || \
                do_log "WARN" "Failed to delete key ${key_id} — continuing anyway"
        done
    else
        do_log "INFO" "No keys found to delete"
    fi

    # Delete the service account itself
    do_log "INFO" "Deleting service account ${SA_EMAIL}"
    if ! gcloud iam service-accounts delete "${SA_EMAIL}" \
        --project="${PROJ_ID}" --quiet \
      --account="${account}"; then
        do_log "ERROR" "Failed to delete service account ${SA_EMAIL}"
  return 1
    fi

    # Local key file cleanup
    if [[ -f "${KEY_FILE}" ]]; then
        rm -f "${KEY_FILE}"
        do_log "INFO" "Removed local service account key file: ${KEY_FILE}"
    fi

    do_log "SUCCESS" "Service account ${SA_EMAIL} and related resources deleted successfully"
}
