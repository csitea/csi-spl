#!/bin/bash

#------------------------------------------------------------------------------
# @description Create the GCP project csi-spl-<env> and link its billing account.
# @description Idempotent, and a DRY RUN unless DRY_RUN=0.
# @description
# @description Adapted from pas-psf-iac gcp-001-create-project.func.sh, keeping
# @description its safety property and dropping everything the spool does not
# @description need:
# @description   1. A pre-flight proves GCP_ACCOUNT can mint an access token
# @description      BEFORE anything is read or decided (a non-empty token, not
# @description      an exit code -- see do_gcp_require_live_account).
# @description   2. The existence check is three-way: exists / reported absent /
# @description      could not tell. Only "reported absent" may create; "could not
# @description      tell" aborts, so a dead or refused credential is never read
# @description      as "the project does not exist".
# @description   3. EVERY gcloud call carries --account (or runs under the
# @description      caller's CLOUDSDK_CONFIG). Unlike pas-psf, nothing is written
# @description      to the shared gcloud config: no `config set account`, no
# @description      `config set project`, no interactive login.
# @description Who runs it and where the project goes come from cnf env.gcp
# @description (gcp_account_owner_email, gcp_org_id; the env overrides); who
# @description pays comes from the environment and fails fast. The project id is read from
# @description csi-spl-cnf and must equal csi-spl-<env>.
# @param ENV - required: dev, prd, bkp (csi-spl-bkp, the off-project backups of iac 046) or all (csi-spl-all, the satellite of spec 057)
# @param GCP_ACCOUNT (optional) - overrides the resolved identity (do_gcp_bootstrap_account: the project SA key once it exists, else cnf env.gcp.gcp_account_owner_email): the identity that creates the project and links billing
# @param GCP_ORG_ID or GCP_FOLDER_ID - the parent of the project, exactly one; GCP_ORG_ID defaults to cnf env.gcp.gcp_org_id when GCP_FOLDER_ID is unset
# @param GCP_BILLING_ACCOUNT_ID - required: XXXXXX-XXXXXX-XXXXXX
# @param DRY_RUN (optional) - 1 (default): print the mutating commands, run none of them. 0: mutate.
# @example ENV=dev GCP_BILLING_ACCOUNT_ID=XXXXXX-XXXXXX-XXXXXX ./run -a do_gcp_001_create_project
#------------------------------------------------------------------------------
do_gcp_001_create_project() {

  command -v gcloud &>/dev/null || { do_log "FATAL gcloud is not installed"; exit 1; }

  do_resolve_oap ORG
  do_resolve_oap APP
  do_require_var ENV "${ENV:-}"
  do_gcp_pin_bootstrap_account || exit 1
  do_require_var GCP_BILLING_ACCOUNT_ID "${GCP_BILLING_ACCOUNT_ID:-}"

  # bkp: csi-spl-bkp, the off-project backup project (iac 046, spec 044 T077)
  # all: csi-spl-all, the satellite agent box (iac 059/060, spec 057)
  [[ "${ENV}" == dev || "${ENV}" == prd || "${ENV}" == bkp || "${ENV}" == all ]] || { do_log "FATAL ENV must be dev, prd, bkp or all, got: ${ENV}"; exit 1; }

  # the org comes from cnf env.gcp.gcp_org_id unless the env names a parent
  [[ -n "${GCP_FOLDER_ID:-}" ]] || GCP_ORG_ID=$(do_gcp_org_id)

  local parent_flag
  if [[ -n "${GCP_ORG_ID:-}" && -n "${GCP_FOLDER_ID:-}" ]]; then
    do_log "FATAL set exactly one of GCP_ORG_ID and GCP_FOLDER_ID, not both"; exit 1
  elif [[ -n "${GCP_ORG_ID:-}" ]]; then
    parent_flag="--organization=${GCP_ORG_ID}"
  elif [[ -n "${GCP_FOLDER_ID:-}" ]]; then
    parent_flag="--folder=${GCP_FOLDER_ID}"
  else
    do_log "FATAL the environment variable GCP_ORG_ID or GCP_FOLDER_ID must have a value (no default)"; exit 1
  fi

  local dry_run="${DRY_RUN:-1}"
  [[ "${dry_run}" == 0 || "${dry_run}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: ${dry_run}"; exit 1; }

  # The id comes from the committed config, and is cross-checked against the
  # convention, so a worktree-derived ORG/APP cannot name a new project.
  local cnf_file="${APP_PATH}/${ORG}-${APP}-cnf/${ORG}-${APP}/${ENV}.env.yaml"
  local cnf_proj=""
  # ENV=all: all.env.yaml is the SHARED base, not csi-spl-all's env file
  if [[ "${ENV}" != all && -f "${cnf_file}" ]] && command -v yq &>/dev/null; then
    cnf_proj=$(yq -r '.env.gcp.gcp_project // ""' "${cnf_file}" 2>/dev/null)
  fi
  local proj_id="${ORG}-${APP}-${ENV}"
  if [[ -n "${cnf_proj}" && "${cnf_proj}" != "${proj_id}" ]]; then
    do_log "FATAL ${cnf_file} says gcp_project=${cnf_proj}, the convention says ${proj_id}; refusing"
    exit 1
  fi
  export PROJ_ID="${proj_id}"

  do_log "INFO ORG=${ORG} APP=${APP} ENV=${ENV} PROJ_ID=${PROJ_ID} GCP_ACCOUNT=${GCP_ACCOUNT} parent=${parent_flag} DRY_RUN=${dry_run}"

  # ---- PRE-FLIGHT -- before ANY state is read -------------------------------
  do_gcp_require_live_account "${GCP_ACCOUNT}" \
    || quit_on "prove ${GCP_ACCOUNT} can mint an access token (gcloud auth login ${GCP_ACCOUNT}, run by the box user)"

  # ---- Create the project (idempotent, and three-way) -----------------------
  local describe_out="" describe_rc=0
  describe_out=$(gcloud projects describe "${PROJ_ID}" \
                   --account="${GCP_ACCOUNT}" \
                   --format='value(projectId)' 2>&1)
  describe_rc=$?

  if [[ "${describe_rc}" -eq 0 ]]; then
    do_log "INFO Project ${PROJ_ID} already exists — skipping create"
  elif printf '%s' "${describe_out}" \
       | grep -iE 'NOT_FOUND|does not exist|it may not exist|could not be found|was not found' >/dev/null; then
    if [[ "${dry_run}" == 1 ]]; then
      do_log "INFO DRY_RUN would run: gcloud projects create ${PROJ_ID} --name=${PROJ_ID} ${parent_flag} --account=${GCP_ACCOUNT}"
    else
      do_log "INFO Creating project ${PROJ_ID}"
      gcloud projects create "${PROJ_ID}" \
        --name="${PROJ_ID}" \
        "${parent_flag}" \
        --labels="org=${ORG},app=${APP},env=${ENV}" \
        --account="${GCP_ACCOUNT}" || quit_on "Project creation failed"
    fi
  else
    do_log "ERROR Cannot determine whether project ${PROJ_ID} exists (rc=${describe_rc})"
    do_log "ERROR gcloud said: ${describe_out}"
    do_log "FATAL Error: Failed to establish the state of ${PROJ_ID} — refusing to run 'projects create' on an unread answer"
    exit "${describe_rc}"
  fi

  # ---- Link billing (idempotent) -------------------------------------------
  # In a dry run on an absent project this describe fails; that is expected
  # and reads as "not linked".
  if [[ "$(gcloud billing projects describe "${PROJ_ID}" \
             --account="${GCP_ACCOUNT}" \
             --format='value(billingEnabled)' 2>/dev/null)" == "True" ]]; then
    do_log "INFO Billing already linked for ${PROJ_ID} — skipping"
  elif [[ "${dry_run}" == 1 ]]; then
    do_log "INFO DRY_RUN would run: gcloud billing projects link ${PROJ_ID} --billing-account=${GCP_BILLING_ACCOUNT_ID} --account=${GCP_ACCOUNT}"
  else
    do_log "INFO Linking billing account to ${PROJ_ID}"
    gcloud billing projects link "${PROJ_ID}" \
      --billing-account="${GCP_BILLING_ACCOUNT_ID}" \
      --account="${GCP_ACCOUNT}" || quit_on "Billing account linking failed"
  fi

  if [[ "${dry_run}" == 1 ]]; then
    do_log "OK DRY_RUN for ${PROJ_ID} complete: nothing was created or linked. Re-run with DRY_RUN=0 to mutate."
  else
    do_log "OK Project ${PROJ_ID} ready (created + billing linked)"
  fi
}
