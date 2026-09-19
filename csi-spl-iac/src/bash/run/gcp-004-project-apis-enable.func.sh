#!/bin/bash
#------------------------------------------------------------------------------
# @description Bootstrap step 4/4: enable only the APIs terraform needs to start
# @description (cloudresourcemanager, serviceusage, storage, iam); terraform step
# @description 001-enable-gcp-services enables the rest. Enables only the ones
# @description not already on. Idempotent, and a DRY RUN unless DRY_RUN=0.
# @description Ported from csi-rel-iac gcp-004, in the csi-spl gcp-001 style:
# @description live-credential pre-flight, --account on every call, and no
# @description write to the shared gcloud config or ADC (csi-rel's
# @description `auth application-default set-quota-project` is dropped).
# @param ENV - required: dev or prd
# @param GCP_ACCOUNT (optional) - overrides the resolved identity (do_gcp_bootstrap_account: the project SA key once it exists, else cnf env.gcp.gcp_account_owner_email): the identity that enables the services
# @param DRY_RUN (optional) - 1 (default): read and report. 0: enable.
# @example ENV=dev GCP_ACCOUNT=admin@example.com DRY_RUN=0 ./run -a do_gcp_004_project_apis_enable
#------------------------------------------------------------------------------
do_gcp_004_project_apis_enable() {

  command -v gcloud &>/dev/null || { do_log "FATAL gcloud is not installed"; exit 1; }

  do_gcp_spl_proj_id || exit 1
  do_gcp_pin_bootstrap_account || exit 1

  local dry_run="${DRY_RUN:-1}"
  [[ "${dry_run}" == 0 || "${dry_run}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: ${dry_run}"; exit 1; }

  local acct="--account=${GCP_ACCOUNT}"
  local wanted=(cloudresourcemanager.googleapis.com serviceusage.googleapis.com storage.googleapis.com iam.googleapis.com)

  do_log "INFO PROJ_ID=${PROJ_ID} GCP_ACCOUNT=${GCP_ACCOUNT} DRY_RUN=${dry_run}"

  do_gcp_require_live_account "${GCP_ACCOUNT}" \
    || quit_on "prove ${GCP_ACCOUNT} can mint an access token (gcloud auth login ${GCP_ACCOUNT}, run by the box user)"

  local enabled rc
  enabled=$(gcloud services list --enabled --project="${PROJ_ID}" "${acct}" --format='value(config.name)' 2>&1)
  rc=$?
  [[ ${rc} -eq 0 ]] || { do_log "FATAL cannot list the enabled services of ${PROJ_ID} (rc=${rc}): ${enabled}"; exit 1; }

  local missing=() s
  for s in "${wanted[@]}"; do
    grep -qx "${s}" <<<"${enabled}" || missing+=("${s}")
  done
  if (( ${#missing[@]} == 0 )); then
    do_log "OK the bootstrap APIs are already enabled on ${PROJ_ID} — nothing to do"
    return 0
  fi

  if [[ "${dry_run}" == 1 ]]; then
    do_log "INFO DRY_RUN would run: gcloud services enable ${missing[*]} --project=${PROJ_ID} ${acct}"
    do_log "OK DRY_RUN for ${PROJ_ID} complete: nothing was enabled. Re-run with DRY_RUN=0 to mutate."
    return 0
  fi

  gcloud services enable "${missing[@]}" --project="${PROJ_ID}" "${acct}" || quit_on "enable ${missing[*]}"
  do_log "OK enabled on ${PROJ_ID}: ${missing[*]}"
}
