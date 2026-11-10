#!/bin/bash
#------------------------------------------------------------------------------
# @description Make the dedicated billing SA (spec 123 section 15, SPL-5220):
# @description cnf env.cost.gcp.billing_sa in export_project (spl-billing in
# @description csi-spl-all), as that project's SA from its key
# @description (do_gcp_pin_account), never the owner.
# @description A DRY RUN unless DRY_RUN=0, and DRY_RUN=0 is the OWNER's go (a
# @description GCP mutation): the dry run reads and prints every call it would
# @description make. Idempotent: what exists is kept. It does two things:
# @description   1. create the SA;
# @description   2. roles/bigquery.jobUser for it on export_project, so
# @description      do_gcp_billing_invoices_fetch can query the billing export.
# @description Then it PRINTS, never runs, the owner's own steps: no project SA
# @description holds a role on a billing account, so only the owner can grant
# @description one. Each is an exact command for an owner GO form:
# @description   - roles/billing.viewer and roles/billing.user on EACH billing
# @description     account (read accounts, projects, spend; link projects);
# @description   - roles/billing.projectManager on a project it is to move;
# @description   - roles/bigquery.dataViewer on the billing export dataset;
# @description   - its key, minted out of band to the per-env key pattern
# @description     (do_gcp_billing_cnf: BILL_KEY), never terraform, never git.
# @description Billing account ids are never committed: the commands carry
# @description <BILLING_ACCOUNT_ID>, read from `gcloud billing accounts list`.
# @param DRY_RUN (optional) - 1 (default): read and report. 0: mutate (the owner's go).
# @example ./run -a do_gcp_billing_sa_create
# @example DRY_RUN=0 ./run -a do_gcp_billing_sa_create
#------------------------------------------------------------------------------
do_gcp_billing_sa_create() {
  local dry_run="${DRY_RUN:-1}" b
  [[ "${dry_run}" == 0 || "${dry_run}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: ${dry_run}"; return 1; }
  for b in gcloud jq yq; do command -v "${b}" &>/dev/null || { do_log "FATAL ${b} is not installed"; return 1; }; done
  do_resolve_oap ORG
  do_resolve_oap APP
  do_gcp_billing_cnf || return 1
  export PROJ_ID="${BILL_PROJECT}"
  do_gcp_pin_account || return 1
  [[ "${GCP_ACCOUNT}" == *.gserviceaccount.com ]] || { do_log "FATAL ${GCP_ACCOUNT} is no service account: the owner account is the gcp-000..004 bootstrap's only"; return 1; }
  _GBS_DRY="${dry_run}" _GBS_FAILED=""
  _GBS_TMP=$(umask 077 && mktemp -d) || return 1
  do_log "INFO billing SA ${BILL_EMAIL} in ${BILL_PROJECT} as=${GCP_ACCOUNT} DRY_RUN=${dry_run}"
  _gbs_sa && _gbs_job_user || _GBS_FAILED="${_GBS_FAILED:-finish: a step stopped without a reason}"
  rm -rf "${_GBS_TMP}"
  [[ -z "${_GBS_FAILED}" ]] || { do_log "FATAL Failed to ${_GBS_FAILED}"; return 1; }
  _gbs_owner_steps
  if [[ "${dry_run}" == 1 ]]; then
    do_log "OK DRY_RUN complete: nothing was changed. DRY_RUN=0 is the owner's go."
  else
    do_log "OK ${BILL_EMAIL} exists with jobUser on ${BILL_PROJECT}; the owner steps above remain"
  fi
}

# _gbs_run <what> <cmd> [args...] - the one mutation gate (as _bes_run).
_gbs_run() {
  local what="$1"; shift
  if [[ "${_GBS_DRY}" == 1 ]]; then do_log "INFO DRY_RUN would run: ${what}"; return 0; fi
  do_log "INFO run: ${what}"
  "$@" >/dev/null 2>"${_GBS_TMP}/err" && return 0
  _GBS_FAILED="${what} ($(tail -n 2 "${_GBS_TMP}/err" | tr '\n' ' '))"
  return 1
}

# _gbs_sa - three-way: exists / reported absent (create) / cannot tell (stop).
_gbs_sa() {
  local out
  if out=$(gcloud iam service-accounts describe "${BILL_EMAIL}" --project="${BILL_PROJECT}" --account="${GCP_ACCOUNT}" --format='value(email)' 2>&1); then
    do_log "OK billing SA ${BILL_EMAIL} exists"; return 0
  fi
  grep -qiE 'not[ _]found|does not exist|unknown service account|404' <<<"${out}" || { _GBS_FAILED="tell whether ${BILL_EMAIL} exists (${out})"; return 1; }
  _gbs_run "gcloud iam service-accounts create ${BILL_SA} --project=${BILL_PROJECT} --account=${GCP_ACCOUNT}" \
    gcloud iam service-accounts create "${BILL_SA}" --display-name="${BILL_SA}" \
      --description="Reads the billing accounts and their projects, moves project billing on the owner's go (spec 123 section 15)." \
      --project="${BILL_PROJECT}" --account="${GCP_ACCOUNT}"
}

_gbs_job_user() {
  local member="serviceAccount:${BILL_EMAIL}" role="roles/bigquery.jobUser"
  if gcloud projects get-iam-policy "${BILL_PROJECT}" --account="${GCP_ACCOUNT}" --format=json 2>/dev/null |
      jq -e --arg r "${role}" --arg m "${member}" '[.bindings[]? | select(.role == $r and (.members | index($m)))] | length > 0' >/dev/null; then
    do_log "OK ${BILL_EMAIL} may run query jobs in ${BILL_PROJECT}"; return 0
  fi
  _gbs_run "gcloud projects add-iam-policy-binding ${BILL_PROJECT} --member=${member} --role=${role} --condition=None --account=${GCP_ACCOUNT}" \
    gcloud projects add-iam-policy-binding "${BILL_PROJECT}" --member="${member}" --role="${role}" --condition=None --account="${GCP_ACCOUNT}"
}

# _gbs_owner_steps - printed only: the owner runs each, with his own login.
_gbs_owner_steps() {
  local m="serviceAccount:${BILL_EMAIL}" r
  do_log "INFO OWNER STEPS (never run by this action; each needs the owner's own login, <OWNER_LOGIN>):"
  for r in roles/billing.viewer roles/billing.user; do
    do_log "INFO   gcloud billing accounts add-iam-policy-binding <BILLING_ACCOUNT_ID> --member=${m} --role=${r} --account=<OWNER_LOGIN>"
  done
  do_log "INFO   (once per billing account; the ids: gcloud billing accounts list --account=<OWNER_LOGIN>)"
  do_log "INFO   gcloud projects add-iam-policy-binding <PROJECT_TO_MOVE> --member=${m} --role=roles/billing.projectManager --condition=None --account=<OWNER_LOGIN>"
  do_log "INFO   console: BigQuery > the billing export dataset > SHARE > ${BILL_EMAIL} as BigQuery Data Viewer"
  do_log "INFO   gcloud iam service-accounts keys create \"\$HOME/.gcp/.${ORG}/key-${ORG}-${APP}-billing.json\" --iam-account=${BILL_EMAIL} --account=<OWNER_LOGIN>"
}
