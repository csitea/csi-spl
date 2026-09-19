#!/bin/bash

#------------------------------------------------------------------------------
# @description sync data between GCS buckets from source to target environment
# @example SRC_BUCKET=gs://org-app-dev-site TGT_BUCKET=gs://org-app-prd-site ALL_CREDENTIALS=~/.gcp/.org/key-all.json ./run -a do_gcp_sync_src_s3_to_tgt_s3
#------------------------------------------------------------------------------
do_gcp_sync_src_s3_to_tgt_s3() {
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
  do_gcp_log_identity "<unset>" "${account}" "do_gcp_sync_src_s3_to_tgt_s3"



  # Define source and destination buckets
  SRC_BUCKET="${SRC_BUCKET:-gs://${ORG}-${APP}-${SRC_ENV}-site}"
  TGT_BUCKET="${TGT_BUCKET:-gs://${ORG}-${APP}-${TGT_ENV}-site}"


  do_require_var SRC_BUCKET ${SRC_BUCKET:-}
  do_require_var TGT_BUCKET ${TGT_BUCKET:-}
  do_require_var ALL_CREDENTIALS ${ALL_CREDENTIALS:-}

  # Debug logging
  do_log "INFO" "SRC_BUCKET=${SRC_BUCKET}"
  do_log "INFO" "TGT_BUCKET=${TGT_BUCKET}"
  do_log "INFO" "Using 'all' environment credentials from: ${ALL_CREDENTIALS}"
  do_log "INFO" "Starting sync from ${SRC_BUCKET} to ${TGT_BUCKET}"

  # Authenticate using the 'all' environment service account
  # gcloud auth revoke --all
  gcloud auth activate-service-account --key-file="${ALL_CREDENTIALS}"
  quit_on "Authentication with 'all' environment service account failed"

  # Sync data using gcloud storage rsync
  gcloud storage rsync --delete-unmatched-destination-objects -r \
    -x "wp-config\.php" \
    "${SRC_BUCKET}" "${TGT_BUCKET}" \
    --account="${account}"
  quit_on "sync data from ${SRC_BUCKET} to ${TGT_BUCKET}"

  # Revoke all authentications
  # gcloud auth revoke --all
  local _rc=$?
}
