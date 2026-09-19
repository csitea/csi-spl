#!/bin/bash

#------------------------------------------------------------------------------
# @description Gcp list service accounts.
# @example ./run -a do_gcp_list_service_accounts
#------------------------------------------------------------------------------
do_gcp_list_service_accounts() {
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
  do_gcp_log_identity "${PROJECT_ID:-<unset>}" "${account}" "do_gcp_list_service_accounts"

  # Resolve ORG and APP values from your environment or config
  do_resolve_oap ORG
  do_resolve_oap APP
  
  # List of environments to handle
  ENVS=("all" "dev" "prd" "stg")

  # Iterate over each environment
  for ENV in "${ENVS[@]}"; do
      # Construct project ID and service account naming conventions
      PROJECT_ID="${ORG}-${APP}-${ENV}"
      SERVICE_ACCOUNT="${PROJECT_ID}"
      KEY_FILE_PATH="$HOME/.gcp/.${ORG}/key-${SERVICE_ACCOUNT}.json"

      # Check if the service account key file exists
      if [[ ! -f "$KEY_FILE_PATH" ]]; then
          echo "Error: Service account key file $KEY_FILE_PATH not found for environment $ENV."
          continue
      fi

      # Authenticate with the service account key
      echo "Authenticating with service account key for project $PROJECT_ID..."
      gcloud auth activate-service-account --key-file="$KEY_FILE_PATH" &> /dev/null
      if [[ $? -ne 0 ]]; then
          echo "Error: Failed to authenticate with $KEY_FILE_PATH for project $PROJECT_ID." >&2
          continue
      fi
      account=$(do_gcp_isolated_active_account) || quit_on "re-pin --account to the identity just activated in the isolated gcloud config"

      # Set the active project in gcloud
      gcloud config set project "${PROJECT_ID}" &> /dev/null
      if [[ $? -ne 0 ]]; then
          echo "Error: Failed to set project to $PROJECT_ID." >&2
          continue
      fi

      # List all service accounts in the current project
      echo "Listing user-managed service accounts for project $PROJECT_ID..."
      gcloud iam service-accounts list --format="table(name, email, disabled)" --account="${account}" --project="${PROJECT_ID}"
      if [[ $? -ne 0 ]]; then
          echo "Error: Failed to list service accounts for project $PROJECT_ID." >&2
      fi

      echo "Listing google-managed service accounts for project $PROJECT_ID..."
      gcloud beta iam service-accounts list --project $PROJECT_ID \
          --include-managed-service-accounts \
        --account="${account}"

      echo "==============================================="
  done

}
