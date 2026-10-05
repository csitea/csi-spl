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
  # Before the mktemp: a missing tool then leaves no private gcloud dir behind.
  # return, not exit: this body is sourced into the ./run shell.
  command -v gcloud &>/dev/null || { echo "gcloud is not installed"; return 1; }
  command -v gsutil &>/dev/null || { echo "gsutil is not installed"; return 1; }

  local _spl_sdk_saved="${CLOUDSDK_CONFIG-}" _spl_sdk_dir
  _spl_sdk_dir="$(mktemp -d)"
  export CLOUDSDK_CONFIG="$_spl_sdk_dir"
  trap 'rm -rf "$_spl_sdk_dir"; if [[ -n "$_spl_sdk_saved" ]]; then export CLOUDSDK_CONFIG="$_spl_sdk_saved"; else unset CLOUDSDK_CONFIG; fi; trap - RETURN' RETURN
  # Pin the gcloud identity for this run (spec 012 C-2): resolved ONCE, passed
  # to each call, logged before the first one.
  local account
  account=$(do_gcp_account) || quit_on "resolve the per-env SA from its key (\$HOME/.gcp/.<org>/key-<org>-<app>-<env>.json) or set ACCOUNT / GCP_ACCOUNT"
  do_gcp_log_identity "${PROJ_ID:-<unset>}" "${account}" "${caller}"

  do_log "INFO using the gcloud version: $(gcloud --version --account="${account}")"

  do_require_var ORG $ORG
  do_require_var APP $APP
  do_require_var ENV $ENV

  PROJ_ID=${PROJ_ID:-$ORG-$APP-$ENV}
  do_require_var PROJ_ID ${PROJ_ID:-}
  PROJ_NAME=${PROJ_NAME:-$PROJ_ID}
  do_require_var GCP_BILLING_ACCOUNT_ID ${GCP_BILLING_ACCOUNT_ID:-}

  # Owner order 2026-10-02 (CLE-77937): the per-env SA from its key, never an
  # interactive owner login. A permission the SA lacks is granted to it by the
  # named action do_gcp_003_configure_proj_sa_permissions, never worked around.
  do_log "INFO ${verb} APIs: $*"
  gcloud services "${verb}" "$@" --project "${PROJ_ID:-}" \
    --account="${account}" \
    || quit_on "API ${verb} as ${account} (a missing permission: ENV=${ENV} DRY_RUN=0 ./run -a do_gcp_003_configure_proj_sa_permissions)"
}
