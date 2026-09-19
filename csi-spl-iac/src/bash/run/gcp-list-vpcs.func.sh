#!/bin/bash

#------------------------------------------------------------------------------
# @description list VPCs, subnets, and peerings for all GCP project environments
# @example ORG=csi APP=csi-spl ./run -a do_gcp_list_vpcs
#------------------------------------------------------------------------------
do_gcp_list_vpcs() {
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
  do_gcp_log_identity "${PROJECT_ID:-<unset>}" "${account}" "do_gcp_list_vpcs"


  test -z ${ORG:-} && ORG=$(do_resolve_oa ORG)
  test -z ${APP:-} && APP=$(do_resolve_oa APP)
  
  ENVS=("all" "dev" "prd" "stg")  # Environments to loop over

  NETWORKING_REPORT_PATH="${APP_PATH}/${APP}-cnf/${APP}/gcp/networking-report.txt"
  mkdir -p $(dirname "$NETWORKING_REPORT_PATH")
  echo "" > "$NETWORKING_REPORT_PATH"

  # Iterate over each environment and list vpcs
  for ENV in "${ENVS[@]}"; do
      echo "START ::: $ORG-$APP-$ENV gcp project entries:" | tee -a "$NETWORKING_REPORT_PATH"
      
      # Construct project ID and service account naming based on convention
      PROJECT_ID="${ORG}-${APP}-${ENV}"
      SERVICE_ACCOUNT="${PROJECT_ID}"
      KEY_FILE_PATH="$HOME/.gcp/.${ORG}/key-${SERVICE_ACCOUNT}.json"

      # Check if the key file exists
      if [[ ! -f "$KEY_FILE_PATH" ]]; then
          do_log "INFO Error: Service account key file $KEY_FILE_PATH not found for environment $ENV."
          continue
      fi

      # Authenticate with the service account key (suppressing standard output and standard error)
      do_log "INFO Authenticating with service account key for project $PROJECT_ID..."
      gcloud auth activate-service-account --key-file="$KEY_FILE_PATH" &> /dev/null
      if [[ $? -ne 0 ]]; then
          do_log "INFO Error: Failed to authenticate with $KEY_FILE_PATH for project $PROJECT_ID." >&2
          continue
      fi

      # Set the project in gcloud configuration (suppressing standard output and standard error)
      gcloud config set project "${PROJECT_ID}" &> /dev/null
      if [[ $? -ne 0 ]]; then
          do_log "INFO Error: Failed to set project to $PROJECT_ID." >&2
          continue
      fi

      # List all vpcs in the current project
      do_log "INFO Listing VPCs for project $PROJECT_ID..."
      
      { 
        gcloud compute networks list --account="${account}" --project="${PROJECT_ID}"
        gcloud compute networks peerings list --network="vpc-${ORG}-${APP}-${ENV}-back" --account="${account}" --project="${PROJECT_ID}"
        gcloud compute networks subnets list --network="vpc-${ORG}-${APP}-${ENV}-back" --account="${account}" --project="${PROJECT_ID}"
      } | tee -a "$NETWORKING_REPORT_PATH"

      if [[ $? -ne 0 ]]; then
          do_log "INFO Error: Failed to list VPCs for project $PROJECT_ID." >&2
      fi

      # Check peering status if not in "all" environment
      if [[ "$ENV" != "all" ]]; then
          PEERING_NAME="peer-${ORG}-${APP}-${ENV}-to-all-back"
          do_log "INFO Checking peering status for $PEERING_NAME..."
          
          PEERING_STATUS=$(gcloud compute networks peerings describe "$PEERING_NAME" --network="vpc-${ORG}-${APP}-${ENV}-back" --format="value(state)" --account="${account}" --project="${PROJECT_ID}" 2>/dev/null)
          
          if [[ "$PEERING_STATUS" == "ACTIVE" ]]; then
              do_log "INFO Peering $PEERING_NAME is ACTIVE."
              echo "PEERING_STATUS: ACTIVE" | tee -a "$NETWORKING_REPORT_PATH"
          else
              do_log "INFO Peering $PEERING_NAME is NOT ACTIVE or does not exist."
              echo "PEERING_STATUS: $PEERING_STATUS" | tee -a "$NETWORKING_REPORT_PATH"
          fi
      fi

      echo "STOP  ::: $ORG-$APP-$ENV gcp project entries:" | tee -a "$NETWORKING_REPORT_PATH"
      do_log "INFO ==============================================="

  done

  do_log "INFO produced the following report file:"
  do_log "INFO $NETWORKING_REPORT_PATH"

}
