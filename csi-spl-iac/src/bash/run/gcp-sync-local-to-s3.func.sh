#!/bin/bash

#------------------------------------------------------------------------------
# @description sync local directory to GCS bucket (dry-run by default)
# @example ORG=csi APP=csi-spl ENV=dev ./run -a do_gcp_sync_local_to_s3
# @example ORG=csi APP=csi-spl ENV=dev SRC_DIR=/path/to/local ./run -a do_gcp_sync_local_to_s3
#------------------------------------------------------------------------------
do_gcp_sync_local_to_s3() {
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
  do_gcp_log_identity "<unset>" "${account}" "do_gcp_sync_local_to_s3"

  do_require_var ORG ${ORG:-}
  do_require_var APP ${APP:-}
  do_require_var ENV ${ENV:-}

  echo $APP_PATH
  # Define variables
  export DEFAULT_SRC_DIR="${APP_PATH}/$ORG-$APP-dat/src/web/html/" # Source directory
  export SRC_DIR="${SRC_DIR:-$DEFAULT_SRC_DIR}"
  export GCS_BUCKET="gs://${ORG}-${APP}-${ENV}-bucket" # GCS bucket name

  # Dry run of gcloud storage rsync command for safety
  gcloud storage rsync --delete-unmatched-destination-objects -r --dry-run -x ".git/|wp-config.php" ${SRC_DIR} ${GCS_BUCKET} --account="${account}"

  # If you're satisfied with the dry run output, drop --dry-run to perform the actual sync
  # gcloud storage rsync --delete-unmatched-destination-objects -r -x ".git/|wp-config.php" ${SRC_DIR} ${GCS_BUCKET}

  local _rc=$?
}
