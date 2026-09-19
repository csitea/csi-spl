#!/bin/bash

#------------------------------------------------------------------------------
# @description sync GCS bucket from source to target environment (revokes auth after)
# @example ORG=csi APP=csi-spl SRC_ENV=dev TGT_ENV=prd ./run -a do_gcp_sync_src_s3_to_tgt_s3_silent
#------------------------------------------------------------------------------
do_gcp_sync_src_s3_to_tgt_s3_silent() {
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
  do_gcp_log_identity "<unset>" "${account}" "do_gcp_sync_src_s3_to_tgt_s3_silent"


  do_require_var ORG ${ORG:-}
  do_require_var APP ${APP:-}
  do_require_var SRC_ENV ${SRC_ENV:-}
  do_require_var TGT_ENV ${TGT_ENV:-}

  # Define source and target credentials
  SRC_CREDENTIALS=$(eval echo ~/.gcp/.${ORG}/key-${ORG}-${APP}-${SRC_ENV}.json)
  TGT_CREDENTIALS=$(eval echo ~/.gcp/.${ORG}/key-${ORG}-${APP}-${TGT_ENV}.json)

  # Define source and destination buckets
  SRC_BUCKET="gs://${ORG}-${APP}-${SRC_ENV}-site"
  TGT_BUCKET="gs://${ORG}-${APP}-${TGT_ENV}-site"

  # Authenticate for source project
  gcloud auth activate-service-account --key-file=$SRC_CREDENTIALS
  account=$(do_gcp_isolated_active_account) || quit_on "re-pin --account to the identity just activated in the isolated gcloud config"

  # Set up a named configuration for the target project
  gcloud config configurations create target_config
  gcloud config set account $(jq -r '.client_email' $TGT_CREDENTIALS)
  gcloud auth activate-service-account --key-file=$TGT_CREDENTIALS
  account=$(do_gcp_isolated_active_account) || quit_on "re-pin --account to the identity just activated in the isolated gcloud config"

  # # Dry run of gcloud storage rsync command for safety
  # gcloud storage rsync --delete-unmatched-destination-objects -r --dry-run \
  #   -x "wp-config\.php|wp-content/plugins/|wp-content/themes/" \
  #   ${SRC_BUCKET} ${TGT_BUCKET}

  #If you're satisfied with the dry run output, remove the -n flag to perform the actual sync
  gcloud storage rsync --delete-unmatched-destination-objects -r \
    -x "wp-config\.php" \
    ${SRC_BUCKET} ${TGT_BUCKET} \
    --account="${account}"

  local _rc=$?

  # Clean up: remove the target configuration and revoke all authentications
  gcloud config configurations delete target_config --quiet
  gcloud auth revoke --all

  return $_rc
}
