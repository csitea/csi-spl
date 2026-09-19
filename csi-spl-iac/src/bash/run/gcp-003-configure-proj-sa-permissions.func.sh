#!/bin/bash
#------------------------------------------------------------------------------
# @description Bootstrap step 3/4: grant the project's IaC service account
# @description (<org>-<app>-<env>@<project>, made by gcp-002) roles/owner on its
# @description own project, so its key can run every terraform step and the
# @description deploy (image push, Cloud Run roll, Firebase Hosting). Runtime
# @description least-privilege IAM stays in the terraform steps. Idempotent, and
# @description a DRY RUN unless DRY_RUN=0.
# @description Ported from csi-rel-iac gcp-003, in the csi-spl gcp-001 style:
# @description live-credential pre-flight, three-way SA check, --account on
# @description every call, no write to the shared gcloud config, and no grant
# @description when the binding is already there.
# @param ENV - required: dev or prd
# @param GCP_ACCOUNT (optional) - overrides the resolved identity (do_gcp_bootstrap_account: the project SA key once it exists, else cnf env.gcp.gcp_account_owner_email): an identity allowed to set the project IAM policy
# @param DRY_RUN (optional) - 1 (default): read and report. 0: grant.
# @example ENV=dev GCP_ACCOUNT=admin@example.com DRY_RUN=0 ./run -a do_gcp_003_configure_proj_sa_permissions
#------------------------------------------------------------------------------
do_gcp_003_configure_proj_sa_permissions() {

  command -v gcloud &>/dev/null || { do_log "FATAL gcloud is not installed"; exit 1; }

  do_gcp_spl_proj_id || exit 1
  do_gcp_pin_bootstrap_account || exit 1

  local dry_run="${DRY_RUN:-1}"
  [[ "${dry_run}" == 0 || "${dry_run}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: ${dry_run}"; exit 1; }

  local acct="--account=${GCP_ACCOUNT}"
  local sa_email="${PROJ_ID}@${PROJ_ID}.iam.gserviceaccount.com"
  local member="serviceAccount:${sa_email}" role="roles/owner"

  do_log "INFO PROJ_ID=${PROJ_ID} member=${member} role=${role} GCP_ACCOUNT=${GCP_ACCOUNT} DRY_RUN=${dry_run}"

  do_gcp_require_live_account "${GCP_ACCOUNT}" \
    || quit_on "prove ${GCP_ACCOUNT} can mint an access token (gcloud auth login ${GCP_ACCOUNT}, run by the box user)"

  local out rc
  out=$(gcloud iam service-accounts describe "${sa_email}" --project="${PROJ_ID}" "${acct}" --format='value(email)' 2>&1)
  rc=$?
  if [[ ${rc} -ne 0 ]]; then
    if printf '%s' "${out}" | grep -qiE 'NOT_FOUND|does not exist|not found'; then
      do_log "FATAL ${sa_email} does not exist: run do_gcp_002_create_project_service_account first"
    else
      do_log "FATAL cannot tell whether ${sa_email} exists (rc=${rc}): ${out}"
    fi
    exit 1
  fi

  out=$(gcloud projects get-iam-policy "${PROJ_ID}" "${acct}" \
          --flatten='bindings[].members' \
          --filter="bindings.role=${role} AND bindings.members=${member}" \
          --format='value(bindings.role)' 2>&1)
  rc=$?
  [[ ${rc} -eq 0 ]] || { do_log "FATAL cannot read the IAM policy of ${PROJ_ID} (rc=${rc}): ${out}"; exit 1; }
  if [[ -n "${out}" ]]; then
    do_log "OK ${member} already holds ${role} on ${PROJ_ID} — nothing to do"
    return 0
  fi

  if [[ "${dry_run}" == 1 ]]; then
    do_log "INFO DRY_RUN would run: gcloud projects add-iam-policy-binding ${PROJ_ID} --member=${member} --role=${role} --condition=None ${acct}"
    do_log "OK DRY_RUN for ${PROJ_ID} complete: nothing was granted. Re-run with DRY_RUN=0 to mutate."
    return 0
  fi

  gcloud projects add-iam-policy-binding "${PROJ_ID}" --member="${member}" --role="${role}" \
    --condition=None "${acct}" >/dev/null || quit_on "grant ${role} to ${member}"
  do_log "OK ${member} holds ${role} on ${PROJ_ID}"
}
