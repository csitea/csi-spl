#!/bin/bash

#------------------------------------------------------------------------------
# @description disable GCP APIs for a project
# @example ORG=csi APP=csi-spl ENV=dev GCP_BILLING_ACCOUNT_ID=xxx ./run -a do_gcp_project_apis_disable
#------------------------------------------------------------------------------
do_gcp_project_apis_disable() {
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
  do_gcp_log_identity "${PROJ_ID:-<unset>}" "${account}" "do_gcp_project_apis_disable"


  # Ensure gcloud is installed and in PATH
  command -v gcloud &>/dev/null || { echo "gcloud is not installed"; exit 1; }
  command -v gsutil &>/dev/null || { echo "gsutil is not installed"; exit 1; }

  do_log "INFO using the gcloud version: $(gcloud --version --account="${account}")"
  
  # Ensure necessary variables are set
  do_require_var ORG $ORG
  do_require_var APP $APP
  do_require_var ENV $ENV
  
  # Project and billing variables
  PROJ_ID=${PROJ_ID:-$ORG-$APP-$ENV}
  do_require_var PROJ_ID ${PROJ_ID:-}
  PROJ_NAME=${PROJ_NAME:-$PROJ_ID}
  do_require_var GCP_BILLING_ACCOUNT_ID ${GCP_BILLING_ACCOUNT_ID:-}

  do_log "INFO Login and set project"
  gcloud auth login --update-adc || quit_on "Login failed"
  account=$(do_gcp_isolated_active_account) || quit_on "re-pin --account to the identity just activated in the isolated gcloud config"

  gcloud auth application-default set-quota-project "${PROJ_ID:-}" || quit_on "Setting quota project failed"

  gcloud config set project "${PROJ_ID:-}" || quit_on "Setting project failed"


  do_log "INFO Enabling necessary APIs"
  gcloud services disable \
    cloudresourcemanager.googleapis.com \
    compute.googleapis.com \
    sheets.googleapis.com \
    dns.googleapis.com \
    servicemanagement.googleapis.com \
    secretmanager.googleapis.com \
    iam.googleapis.com \
    cloudfunctions.googleapis.com \
    cloudscheduler.googleapis.com \
    storage.googleapis.com \
    cloudapis.googleapis.com --project "${PROJ_ID:-}" \
    --account="${account}" || quit_on "API enabling failed"


  do_log "INFO Service account created and key saved"
}
