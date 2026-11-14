#!/bin/bash
#------------------------------------------------------------------------------
# @description Check the dedicated billing SA (spec 123 section 15, SPL-5220)
# @description and print the owner's steps for it. It CREATES NOTHING: the SA
# @description (cnf env.cost.gcp.billing_sa in export_project, spl-billing in
# @description csi-spl-all) and its roles/bigquery.jobUser on export_project
# @description are terraform step 002-gcp-billing-sa (SPL-5265, owner HUM-10
# @description #laskut f655b326: "the sa account must be created as terraform
# @description step"), so there is one creator of the SA:
# @description   cd csi-spl-orc && ENV=prd STEP=002-gcp-billing-sa make do-tf-plan
# @description   then make do-provision, on the owner's go.
# @description Read only, as export_project's SA from its key
# @description (do_gcp_pin_account), never the owner: it reports whether the SA
# @description and the jobUser binding exist (absent -> points to the step),
# @description then PRINTS, never runs, the owner's own steps. Each is an
# @description exact command for an owner GO form:
# @description   - roles/billing.admin for the export_project SA on EACH
# @description     billing account, once: step 002 then grants the billing SA
# @description     roles/billing.viewer + roles/billing.user there (SPL-5506,
# @description     owner msg a508c121: "I grant csi-spl-all Billing Admin
# @description     once; Terraform does the rest"), via do_gcp_billing_sa_tf;
# @description   - roles/billing.projectManager on a project it is to move;
# @description   - roles/bigquery.dataViewer on the billing export dataset.
# @description Its key is no owner step: step 002 makes it and writes it to
# @description BILL_KEY (do_gcp_billing_cnf), owner msg 8d767855 (SPL-5457).
# @description Billing account ids are never committed: the commands carry
# @description <BILLING_ACCOUNT_ID>, read from `gcloud billing accounts list`.
# @param DRY_RUN (optional) - 1 (default), the only value: 0 is refused, the step creates the SA.
# @example ./run -a do_gcp_billing_sa_create
#------------------------------------------------------------------------------
do_gcp_billing_sa_create() {
  local dry_run="${DRY_RUN:-1}" b
  [[ "${dry_run}" == 0 || "${dry_run}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: ${dry_run}"; return 1; }
  if [[ "${dry_run}" == 0 ]]; then
    do_log "FATAL DRY_RUN=0 refused: this action creates nothing. The billing SA and its jobUser are terraform step ${_GBS_STEP}: $(_gbs_step_cmd)"
    return 1
  fi
  for b in gcloud jq yq; do command -v "${b}" &>/dev/null || { do_log "FATAL ${b} is not installed"; return 1; }; done
  do_resolve_oap ORG
  do_resolve_oap APP
  do_gcp_billing_cnf || return 1
  export PROJ_ID="${BILL_PROJECT}"
  do_gcp_pin_account || return 1
  [[ "${GCP_ACCOUNT}" == *.gserviceaccount.com ]] || { do_log "FATAL ${GCP_ACCOUNT} is no service account: the owner account is the gcp-000..004 bootstrap's only"; return 1; }
  do_log "INFO billing SA ${BILL_EMAIL} in ${BILL_PROJECT} as=${GCP_ACCOUNT} (read only)"
  local missing=""
  _gbs_sa || return 1
  [[ "${_GBS_HAVE}" == 1 ]] || missing="the SA"
  _gbs_job_user || return 1
  [[ "${_GBS_HAVE}" == 1 ]] || missing="${missing:+${missing} and }its jobUser"
  if [[ -n "${missing}" ]]; then
    do_log "WARN ${missing} missing: terraform step ${_GBS_STEP} creates them: $(_gbs_step_cmd)"
  else
    do_log "OK ${BILL_EMAIL} exists with jobUser on ${BILL_PROJECT} (terraform step ${_GBS_STEP})"
  fi
  _gbs_owner_steps
  do_log "OK nothing was changed: this action never mutates"
}

_GBS_STEP=002-gcp-billing-sa

_gbs_step_cmd() {
  printf 'cd csi-spl-orc && ENV=prd STEP=%s make do-tf-plan, then make do-provision on the owner'"'"'s go' "${_GBS_STEP}"
}

# _gbs_sa - three-way: exists (_GBS_HAVE=1) / reported absent (0) / cannot tell (return 1).
_gbs_sa() {
  local out
  _GBS_HAVE=0
  if out=$(gcloud iam service-accounts describe "${BILL_EMAIL}" --project="${BILL_PROJECT}" --account="${GCP_ACCOUNT}" --format='value(email)' 2>&1); then
    do_log "OK billing SA ${BILL_EMAIL} exists"; _GBS_HAVE=1; return 0
  fi
  grep -qiE 'not[ _]found|does not exist|unknown service account|404' <<<"${out}" || { do_log "FATAL cannot tell whether ${BILL_EMAIL} exists (${out})"; return 1; }
  do_log "INFO billing SA ${BILL_EMAIL} does not exist"
}

# _gbs_job_user - sets _GBS_HAVE=1 when the binding is there; return 1 when the policy cannot be read.
_gbs_job_user() {
  local member="serviceAccount:${BILL_EMAIL}" role="roles/bigquery.jobUser" pol
  _GBS_HAVE=0
  pol=$(gcloud projects get-iam-policy "${BILL_PROJECT}" --account="${GCP_ACCOUNT}" --format=json 2>/dev/null) \
    || { do_log "FATAL cannot read the IAM policy of ${BILL_PROJECT} as ${GCP_ACCOUNT}"; return 1; }
  if jq -e --arg r "${role}" --arg m "${member}" '[.bindings[]? | select(.role == $r and (.members | index($m)))] | length > 0' >/dev/null <<<"${pol}"; then
    do_log "OK ${BILL_EMAIL} may run query jobs in ${BILL_PROJECT}"; _GBS_HAVE=1
  else
    do_log "INFO ${BILL_EMAIL} has no ${role} on ${BILL_PROJECT}"
  fi
}

# _gbs_owner_steps - printed only: the owner runs each, with his own login.
_gbs_owner_steps() {
  local m="serviceAccount:${BILL_EMAIL}"
  do_log "INFO OWNER STEPS (never run by this action; each needs the owner's own login, <OWNER_LOGIN>):"
  do_log "INFO   gcloud billing accounts add-iam-policy-binding <BILLING_ACCOUNT_ID> --member=serviceAccount:${GCP_ACCOUNT} --role=roles/billing.admin --account=<OWNER_LOGIN>"
  do_log "INFO   (once per billing account; the ids: gcloud billing accounts list --account=<OWNER_LOGIN>). Then step ${_GBS_STEP} grants ${BILL_EMAIL} roles/billing.viewer + roles/billing.user on each (owner msg a508c121): cd csi-spl-iac && ./run -a do_gcp_billing_sa_tf"
  do_log "INFO   gcloud projects add-iam-policy-binding <PROJECT_TO_MOVE> --member=${m} --role=roles/billing.projectManager --condition=None --account=<OWNER_LOGIN>"
  do_log "INFO   console: BigQuery > the billing export dataset > SHARE > ${BILL_EMAIL} as BigQuery Data Viewer"
  do_log "INFO KEY: terraform step ${_GBS_STEP} makes it and writes ${BILL_KEY} (mode 0600) on the box that applies (owner msg 8d767855); its private key is in that step's state"
}
