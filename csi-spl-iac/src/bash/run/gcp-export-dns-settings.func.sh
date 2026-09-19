#!/bin/bash

#------------------------------------------------------------------------------
# @description Gcp export dns settings.
#------------------------------------------------------------------------------
do_gcp_export_dns_settings() {
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
  do_gcp_log_identity "${PROJECT_ID:-<unset>}" "${account}" "do_gcp_export_dns_settings"


  REQUIRED_VARS=(HOST_NAME RUN_UNIT PROJ_PATH APP_PATH APP_NAME ORG_PATH BASE_PATH PROJ ENV GROUP USER UID GID OS)
  do_require_run_vars "${REQUIRED_VARS[@]}"

  REQUIRED_VARS=(ORG APP ENV)
  do_require_run_vars "${REQUIRED_VARS[@]}"

  # Set up variables based on the provided naming conventions
  PROJECT_ID="${ORG}-${APP}-${ENV}"
  ADMIN_KEY_PATH="${HOME}/.gcp/.$ORG/key-$ORG-$APP-$ENV.json"
  OUTPUT_FILE="${PROJ_PATH}/dns_settings_${PROJECT_ID}.txt"

  # Authenticate with Google Cloud using the admin credential file
  if [[ ! -f "${ADMIN_KEY_PATH}" ]]; then
    do_log "FATAL Error: Admin key file not found at ${ADMIN_KEY_PATH}"
    exit 1
  fi

  do_log "INFO Authenticating with GCP using admin key..."
  gcloud auth activate-service-account --key-file="${ADMIN_KEY_PATH}"
  account=$(do_gcp_isolated_active_account) || quit_on "re-pin --account to the identity just activated in the isolated gcloud config"
  quit_on "authentication failed"

  # Set the Google Cloud project
  do_log "INFO Setting GCP project to ${PROJECT_ID}..."
  gcloud config set project ${PROJECT_ID}

  # Export DNS settings
  do_log "INFO Exporting DNS settings for project ${PROJECT_ID}..."
  
  # List all DNS managed zones
  do_log "INFO Listing all DNS managed zones:"
  gcloud dns managed-zones list --format="table(name,dnsName,description)" --account="${account}" --project="${PROJECT_ID}" > "${OUTPUT_FILE}"
  quit_on "failed to list DNS managed zones"

  # For each managed zone, export the record sets
  while read -r zone_name _; do
    if [[ "${zone_name}" != "NAME" ]]; then  # Skip the header row
      do_log "INFO Exporting records for zone: ${zone_name}"
      echo -e "\nRecords for zone: ${zone_name}" >> "${OUTPUT_FILE}"
      gcloud dns record-sets list --zone="${zone_name}" --format="table(name,type,ttl,rrdatas[])" --account="${account}" --project="${PROJECT_ID}" >> "${OUTPUT_FILE}"
      quit_on "failed to export records for zone ${zone_name}"
    fi
  done < <(tail -n +2 "${OUTPUT_FILE}")  # Skip the header row

  # Export Cloud DNS policies if any
  do_log "INFO Exporting Cloud DNS policies..."
  echo -e "\nCloud DNS Policies:" >> "${OUTPUT_FILE}"
  gcloud dns policies list --format="table(name,description,enableInboundForwarding,enableLogging)" --account="${account}" --project="${PROJECT_ID}" >> "${OUTPUT_FILE}"
  quit_on "failed to export DNS policies"

  # Clean up authentication
  gcloud auth revoke --all --quiet
  quit_on "failed to revoke authentication"

  do_log "INFO DNS settings exported to ${OUTPUT_FILE}"
  do_log "INFO Script execution completed."
}
