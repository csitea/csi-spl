#!/bin/bash
#------------------------------------------------------------------------------
# @description Create csi-spl-bkp-tfstate, the terraform state bucket of the
# @description off-project backup project csi-spl-bkp (iac step 046, spec 044
# @description contingency T077). dev and prd get their state bucket from step
# @description 000, which renders from <env>.env.yaml; csi-spl-bkp has no env
# @description file (it is not an environment, it holds two environments'
# @description copies), so this one bucket is a named action instead of an
# @description ad-hoc `gcloud storage buckets create`.
# @description Run it after the owner's bootstrap `ENV=bkp do_gcp_000_bootstrap_gcp_env`
# @description (project, billing, SA + key, APIs), as the csi-spl-bkp SA from
# @description its key: never the owner account. Same hygiene as a 000 bucket:
# @description versioning on (a state file is the one thing here that is
# @description rewritten), uniform access, public access prevented.
# @description Idempotent, and a DRY RUN unless DRY_RUN=0.
# @description PROJECT_ENV=all makes csi-spl-all-tfstate the same way: the state of
# @description the satellite steps 059/060 (spec 057), after ENV=all gcp-000.
# @param PROJECT_ENV (optional) - bkp (default) or all
# @param DRY_RUN (optional) - 1 (default): read and report. 0: create.
# @param GCP_REGION (optional) - default europe-north1, the estate's region
# @example DRY_RUN=0 ./run -a do_gcp_bkp_state_bucket_create
#------------------------------------------------------------------------------
do_gcp_bkp_state_bucket_create() {

  command -v gcloud &>/dev/null || { do_log "FATAL gcloud is not installed"; exit 1; }

  ENV="${PROJECT_ENV:-bkp}"
  [[ "${ENV}" == bkp || "${ENV}" == all ]] || { do_log "FATAL PROJECT_ENV must be bkp or all, got: ${ENV}"; exit 1; }
  do_gcp_spl_proj_id || exit 1
  do_gcp_pin_account || exit 1

  local dry_run="${DRY_RUN:-1}"
  [[ "${dry_run}" == 0 || "${dry_run}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: ${dry_run}"; exit 1; }

  local acct="--account=${GCP_ACCOUNT}"
  local bucket="gs://${PROJ_ID}-tfstate" region="${GCP_REGION:-europe-north1}"
  do_log "INFO PROJ_ID=${PROJ_ID} bucket=${bucket} GCP_ACCOUNT=${GCP_ACCOUNT} DRY_RUN=${dry_run}"

  do_gcp_require_live_account "${GCP_ACCOUNT}" \
    || quit_on "prove ${GCP_ACCOUNT} can mint an access token (its key is minted by ENV=${ENV} do_gcp_000_bootstrap_gcp_env)"

  # Three-way, as gcp-001: exists / reported absent / could not tell. Only a
  # reported absence may create; anything else stops.
  local out rc
  out=$(gcloud storage buckets describe "${bucket}" --project="${PROJ_ID}" "${acct}" --format='value(name)' 2>&1)
  rc=$?
  if [[ ${rc} -eq 0 ]]; then
    do_log "OK ${bucket} already exists - nothing to do"
    return 0
  fi
  grep -qiE 'not found|does not exist|404' <<<"${out}" \
    || { do_log "FATAL cannot tell whether ${bucket} exists (rc=${rc}): ${out}"; exit 1; }

  if [[ "${dry_run}" == 1 ]]; then
    do_log "INFO DRY_RUN would run: gcloud storage buckets create ${bucket} --project=${PROJ_ID} --location=${region} --uniform-bucket-level-access --public-access-prevention ${acct}, then enable versioning"
    do_log "OK DRY_RUN complete: nothing was created. Re-run with DRY_RUN=0 to mutate."
    return 0
  fi

  gcloud storage buckets create "${bucket}" --project="${PROJ_ID}" --location="${region}" \
    --uniform-bucket-level-access --public-access-prevention "${acct}" || quit_on "create ${bucket}"
  gcloud storage buckets update "${bucket}" --versioning "${acct}" || quit_on "enable versioning on ${bucket}"
  do_log "OK created ${bucket} (versioned, uniform, public access prevented)"
}
