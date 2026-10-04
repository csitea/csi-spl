#!/bin/bash

#------------------------------------------------------------------------------
# @description Gcp sync src bucket data to tgt bucket.
# @example ./run -a do_gcp_sync_src_bucket_data_to_tgt_bucket
#------------------------------------------------------------------------------
do_gcp_sync_src_bucket_data_to_tgt_bucket() {
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
  do_gcp_log_identity "<unset>" "${account}" "do_gcp_sync_src_bucket_data_to_tgt_bucket"

  set -e

  REQUIRED_VARS=(HOST_NAME RUN_UNIT PROJ_PATH APP_PATH APP_NAME ORG_PATH BASE_PATH PROJ ENV GROUP USER UID GID OS SRC_BUCKET TGT_BUCKET SRC_ORG SRC_APP SRC_ENV TGT_ORG TGT_APP TGT_ENV)
  do_require_run_vars "${REQUIRED_VARS[@]}"

  # Function Definitions
  # Ensure these functions are defined elsewhere or include their definitions here
  # do_require_run_vars: Checks if required environment variables are set
  # do_log: Logs messages with appropriate formatting
  # quit_on: Logs an error message and exits the script

  # Owner order 2026-10-02 (CLE-77937): runs as the SA resolved above, never
  # an interactive owner login; the SA needs read on SRC_BUCKET and write on
  # TGT_BUCKET, granted SA-to-SA, never by the owner account.

  # Each check is `cmd || quit_on`, never `if ! cmd; then quit_on`: quit_on
  # reads $? and is a no-op when it is 0, which it is inside a `then`.

  # Verify access to Source Bucket
  do_log "INFO Verifying access to source bucket (gs://$SRC_BUCKET)..."
  gcloud storage ls gs://"$SRC_BUCKET" --account="${account}" >/dev/null 2>&1 ||
    quit_on "Access denied or source bucket gs://$SRC_BUCKET does not exist for the active user."

  # Verify access to Target Bucket
  do_log "INFO Verifying access to target bucket (gs://$TGT_BUCKET)..."
  gcloud storage ls gs://"$TGT_BUCKET" --account="${account}" >/dev/null 2>&1 ||
    quit_on "Access denied or target bucket gs://$TGT_BUCKET does not exist for the active user."

  # Debugging: Confirm active credentials
  do_log "INFO Active account: ${account}"

  # Perform the sync operation
  do_log "INFO Starting sync from gs://$SRC_BUCKET to gs://$TGT_BUCKET"
  gcloud storage rsync -r --delete-unmatched-destination-objects gs://"$SRC_BUCKET" gs://"$TGT_BUCKET" --account="${account}" ||
    quit_on "Sync operation failed"

  # Function to list top 10 largest files in a bucket
  list_top_10() {
    local BUCKET=$1
    do_log "INFO Top 10 largest files in bucket (gs://$BUCKET):"
    gcloud storage ls -l gs://"$BUCKET"/** --account="${account}" | grep -v "^TOTAL" | sort -k1 -nr | sed -n 1,10p | awk '{print $3, $1}' | while read -r file size; do
      do_log "INFO    $file - ${size} bytes"
    done
  }

  # List top 10 largest files in the source bucket
  list_top_10 "$SRC_BUCKET"

  # List top 10 largest files in the target bucket
  list_top_10 "$TGT_BUCKET"

}

# Ensure the script is being called with the correct arguments
# This part assumes that you have a mechanism to parse arguments and call the appropriate function
# For example:
# if [[ "$1" == "-a" && "$2" == "do_gcp_sync_src_bucket_data_to_tgt_bucket" ]]; then
#   do_gcp_sync_src_bucket_data_to_tgt_bucket
# fi
