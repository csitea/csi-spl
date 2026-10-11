#!/bin/bash
#------------------------------------------------------------------------------
# @description Plan or apply step 058 (the dev wine-box budget) with the
# @description billing account read from csi-spl-dev's own billing link. The
# @description dev project SA only (do_gcp_pin_account), read only. The id is
# @description never printed, logged or written to a file: it reaches
# @description terraform only through the environment of the one make run
# @description (TF_VAR_billing_account_id), and that run's output is masked.
# @description GCP_BILLING_ACCOUNT_ID, when set, is used as is.
# @description Terraform runs only through make / tf-runner (csi-spl-orc).
# @param TF_VERB (optional) - plan (default) or provision (apply)
# @example ./run -a do_spl_wine_box_budget_tf
# @example TF_VERB=provision ./run -a do_spl_wine_box_budget_tf
#------------------------------------------------------------------------------
do_spl_wine_box_budget_tf() {
  local verb="${TF_VERB:-plan}" target bill rc mask=XXXXXX-XXXXXX-XXXXXX
  case "${verb}" in
    plan) target=do-tf-plan ;;
    provision) target=do-provision ;;
    *) do_log "FATAL TF_VERB must be plan or provision, got: ${verb}"; return 1 ;;
  esac
  command -v gcloud &>/dev/null || { do_log "FATAL gcloud is not installed"; return 1; }
  export ENV=dev
  do_gcp_spl_proj_id || return 1
  unset ACCOUNT GCP_ACCOUNT
  do_gcp_pin_account || return 1

  bill="${GCP_BILLING_ACCOUNT_ID:-}"
  if [[ -z "${bill}" ]]; then
    bill=$(gcloud billing projects describe "${PROJ_ID}" --account="${GCP_ACCOUNT}" --format='value(billingAccountName)' 2>/dev/null)
    bill="${bill#billingAccounts/}"
  fi
  [[ "${bill}" =~ ^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$ ]] || {
    do_log "FATAL no billing account: GCP_BILLING_ACCOUNT_ID is unset and the billing link of ${PROJ_ID} cannot be read as ${GCP_ACCOUNT} (cloudbilling API on? permission resourcemanager.projects.get?). REPORT it; nothing ran"
    return 1
  }
  do_log "INFO billing account ${mask} resolved for ${PROJ_ID} as ${GCP_ACCOUNT} (never printed); running make ${target} STEP=058-gcp-wine-box-budget"

  GCP_BILLING_ACCOUNT_ID="${bill}" make -C "${APP_PATH}/csi-spl-orc" "${target}" ENV=dev STEP=058-gcp-wine-box-budget 2>&1 \
    | while IFS= read -r line; do printf '%s\n' "${line//${bill}/${mask}}"; done
  rc=${PIPESTATUS[0]}
  bill=""
  return "${rc}"
}
