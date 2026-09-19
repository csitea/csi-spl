#!/bin/bash

#------------------------------------------------------------------------------
# @description list Cloud Scheduler jobs for all GCP project environments
# @example ORG=csi APP=csi-spl ./run -a do_gcp_list_scheduler_jobs
#------------------------------------------------------------------------------
do_gcp_list_scheduler_jobs() {
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
  do_gcp_log_identity "${PROJECT_ID:-<unset>}" "${account}" "do_gcp_list_scheduler_jobs"


  # Required variables for organization, application, and environments
  do_resolve_oap ORG
  do_resolve_oap APP
  ENVS=("all" "dev" "prd" "stg")  # Environments to loop over

  # Define the location (region) for Cloud Scheduler
  LOCATION="europe-west3"   # Update this if needed

  # Iterate over each environment and list scheduler jobs
  for ENV in "${ENVS[@]}"; do
      # Construct project ID and service account naming based on convention
      PROJECT_ID="${ORG}-${APP}-${ENV}"
      SERVICE_ACCOUNT="${PROJECT_ID}"
      KEY_FILE_PATH="$HOME/.gcp/.${ORG}/key-${SERVICE_ACCOUNT}.json"

      # Check if the key file exists
      if [[ ! -f "$KEY_FILE_PATH" ]]; then
          echo "Error: Service account key file $KEY_FILE_PATH not found for environment $ENV."
          continue
      fi

      # Authenticate with the service account key (suppressing standard output and standard error)
      echo "Authenticating with service account key for project $PROJECT_ID..."
      gcloud auth activate-service-account --key-file="$KEY_FILE_PATH" &> /dev/null
      if [[ $? -ne 0 ]]; then
          echo "Error: Failed to authenticate with $KEY_FILE_PATH for project $PROJECT_ID." >&2
          continue
      fi

      # Set the project in gcloud configuration (suppressing standard output and standard error)
      gcloud config set project "${PROJECT_ID}" &> /dev/null
      if [[ $? -ne 0 ]]; then
          echo "Error: Failed to set project to $PROJECT_ID." >&2
          continue
      fi

      # List all Cloud Scheduler jobs in the current project, specifying location
      echo "Listing Cloud Scheduler jobs for project $PROJECT_ID in location $LOCATION..."
      gcloud scheduler jobs list --location="${LOCATION}" --format="table(name, schedule, state)" --account="${account}" --project="${PROJECT_ID}"
      if [[ $? -ne 0 ]]; then
          echo "Error: Failed to list Cloud Scheduler jobs for project $PROJECT_ID." >&2
      fi

      echo "==============================================="
  done

}

# do_gcp_list_scheduler_jobs
# Authenticating with service account key for project csi-spl-all...
# Listing Cloud Scheduler jobs for project csi-spl-all in location europe-west3...
# ===============================================
# Authenticating with service account key for project csi-spl-dev...
# Listing Cloud Scheduler jobs for project csi-spl-dev in location europe-west3...
# ID                SCHEDULE    STATE
# download-fingrid  20 * * * *  ENABLED
# ===============================================
# Authenticating with service account key for project csi-spl-prd...
# Listing Cloud Scheduler jobs for project csi-spl-prd in location europe-west3...
# ID                SCHEDULE      STATE
# download-fingrid  */30 * * * *  ENABLED
# ===============================================
# Authenticating with service account key for project csi-spl-stg...
# Listing Cloud Scheduler jobs for project csi-spl-stg in location europe-west3...
# ID                SCHEDULE    STATE
# download-fingrid  20 * * * *  ENABLED
# ===============================================
