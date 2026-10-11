#!/bin/bash
#------------------------------------------------------------------------------
# @description Switch on the Cloud Billing API (cloudbilling.googleapis.com) in
# @description one project, so its project SA can read the project's billing
# @description link (step 058, the wine-box budget, and the billing reads of
# @description gcp-billing-export-setup). The per-env project SA only
# @description (do_gcp_pin_account), --account on every call, never the owner.
# @description Idempotent, and a DRY RUN unless DRY_RUN=0.
# @param ENV - required: dev, prd, bkp or all (the project <org>-<app>-<env>)
# @param DRY_RUN (optional) - 1 (default): read and report. 0: enable.
# @example ENV=dev ./run -a do_gcp_cloud_billing_api_enable
# @example ENV=dev DRY_RUN=0 ./run -a do_gcp_cloud_billing_api_enable
#------------------------------------------------------------------------------
do_gcp_cloud_billing_api_enable() {
  local api=cloudbilling.googleapis.com dry_run="${DRY_RUN:-1}" enabled rc
  [[ "${dry_run}" == 0 || "${dry_run}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: ${dry_run}"; return 1; }
  command -v gcloud &>/dev/null || { do_log "FATAL gcloud is not installed"; return 1; }
  do_gcp_spl_proj_id || return 1
  do_gcp_pin_account || return 1

  enabled=$(gcloud services list --enabled --project="${PROJ_ID}" --account="${GCP_ACCOUNT}" --format='value(config.name)' 2>&1)
  rc=$?
  [[ ${rc} -eq 0 ]] || { do_log "FATAL cannot list the enabled services of ${PROJ_ID} (rc=${rc}): ${enabled}"; return 1; }
  if grep -qx "${api}" <<<"${enabled}"; then
    do_log "OK ${api} is already enabled on ${PROJ_ID}: nothing to do"
    return 0
  fi
  if [[ "${dry_run}" == 1 ]]; then
    do_log "INFO DRY_RUN would run: gcloud services enable ${api} --project=${PROJ_ID} --account=${GCP_ACCOUNT}"
    do_log "OK DRY_RUN complete: nothing was enabled. Re-run with DRY_RUN=0 to enable."
    return 0
  fi
  gcloud services enable "${api}" --project="${PROJ_ID}" --account="${GCP_ACCOUNT}" \
    || { do_log "FATAL gcloud services enable ${api} failed on ${PROJ_ID} as ${GCP_ACCOUNT}"; return 1; }
  do_log "OK enabled ${api} on ${PROJ_ID}"
}
