#!/bin/bash

#------------------------------------------------------------------------------
# @description sync GCS bucket contents to local directory
# @example ORG=csi APP=csi-spl ENV=dev ./run -a do_gcp_sync_s3_to_local
# @example ORG=csi APP=csi-spl ENV=dev TGT_DIR=/custom/path ./run -a do_gcp_sync_s3_to_local
#------------------------------------------------------------------------------
do_gcp_sync_s3_to_local() {
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
  do_gcp_log_identity "<unset>" "${account}" "do_gcp_sync_s3_to_local"


  do_require_var ORG ${ORG:-}
  do_require_var APP ${APP:-}
  do_require_var ENV ${ENV:-}

  export GOOGLE_APPLICATION_CREDENTIALS="$HOME/.gcp/.${ORG}/key-${ORG}-${APP}-${ENV}.json"

  # Authenticate using the service account key file
  gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS
  account=$(do_gcp_isolated_active_account) || quit_on "re-pin --account to the identity just activated in the isolated gcloud config"

  # Define variables
  export GCS_BUCKET="gs://${ORG}-${APP}-${ENV}-site"                           # GCS bucket name
  export DEFAULT_TGT_DIR="${APP_PATH}/$ORG-$APP-dat/${ORG}-${APP}-${ENV}-site" # Target directory
  export TGT_DIR="${TGT_DIR:-$DEFAULT_TGT_DIR}"

  # Ensure the target directory exists
  mkdir -p ${TGT_DIR}

  # # Dry run of gcloud storage rsync command for safety
  # gcloud storage rsync --delete-unmatched-destination-objects -r --dry-run \
  #   -x "wp-config\.php \
  #   ${GCS_BUCKET} ${TGT_DIR}

  # If you're satisfied with the dry run output, remove the -n flag to perform the actual sync
  gcloud storage rsync --delete-unmatched-destination-objects -r \
    -x "wp-config\.php" \
    ${GCS_BUCKET} ${TGT_DIR} \
    --account="${account}"

  local _rc=$?

}
