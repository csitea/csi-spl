#!/bin/bash
#------------------------------------------------------------------------------
# @description Enable or disable a list of GCP APIs on <ORG>-<APP>-<ENV>: the
# @description one body behind do_gcp_project_apis_{enable,disable} and
# @description do_gcp_modify_project_apis_{enable,disable} (CLE-77915, refactor
# @description item 3: four csi-rel ports whose bodies differed only in the
# @description verb and the service list). Disable is destructive: never run
# @description without the owner's go for that call (CLAUDE.md).
# @param $1 enable | disable
# @param $2 the calling action's name, logged with the identity
# @param $3.. the services, e.g. iam.googleapis.com
# @example do_gcp_project_apis enable do_gcp_project_apis_enable iam.googleapis.com
#------------------------------------------------------------------------------
do_gcp_project_apis() {
  local verb="${1:-}" caller="${2:-}"
  shift 2 || true
  [[ "${verb}" == enable || "${verb}" == disable ]] \
    || { do_log "FATAL do_gcp_project_apis: verb must be enable or disable, got '${verb}'"; return 1; }
  (( $# > 0 )) || { do_log "FATAL do_gcp_project_apis: no services given"; return 1; }

  local _spl_sdk_saved="${CLOUDSDK_CONFIG-}" _spl_sdk_dir
  _spl_sdk_dir="$(mktemp -d)"
  export CLOUDSDK_CONFIG="$_spl_sdk_dir"
  trap 'rm -rf "$_spl_sdk_dir"; if [[ -n "$_spl_sdk_saved" ]]; then export CLOUDSDK_CONFIG="$_spl_sdk_saved"; else unset CLOUDSDK_CONFIG; fi; trap - RETURN' RETURN
  # Pin the gcloud identity for this run (spec 012 C-2): resolved ONCE, passed
  # to each call, logged before the first one.
  local account
  account=$(do_gcp_account) || quit_on "no gcloud identity could be resolved — set ACCOUNT or GCP_ACCOUNT"
  do_gcp_log_identity "${PROJ_ID:-<unset>}" "${account}" "${caller}"

  command -v gcloud &>/dev/null || { echo "gcloud is not installed"; exit 1; }
  command -v gsutil &>/dev/null || { echo "gsutil is not installed"; exit 1; }

  do_log "INFO using the gcloud version: $(gcloud --version --account="${account}")"

  do_require_var ORG $ORG
  do_require_var APP $APP
  do_require_var ENV $ENV

  PROJ_ID=${PROJ_ID:-$ORG-$APP-$ENV}
  do_require_var PROJ_ID ${PROJ_ID:-}
  PROJ_NAME=${PROJ_NAME:-$PROJ_ID}
  do_require_var GCP_BILLING_ACCOUNT_ID ${GCP_BILLING_ACCOUNT_ID:-}

  do_log "INFO Login and set project"
  gcloud auth login --update-adc || quit_on "Login failed"
  account=$(do_gcp_isolated_active_account) || quit_on "re-pin --account to the identity just activated in the isolated gcloud config"

  gcloud auth application-default set-quota-project "${PROJ_ID:-}" || quit_on "Setting quota project failed"

  gcloud config set project "${PROJ_ID:-}" || quit_on "Setting project failed"

  do_log "INFO ${verb} APIs: $*"
  gcloud services "${verb}" "$@" --project "${PROJ_ID:-}" \
    --account="${account}" || quit_on "API ${verb} failed"
}
