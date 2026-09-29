#!/bin/bash
#------------------------------------------------------------------------------
# @description Bootstrap step 2/4: create the project's IaC service account
# @description <org>-<app>-<env>@<project> and download ONE key for it to
# @description $HOME/.gcp/.<org>/key-<org>-<app>-<env>.json (mode 600). That key
# @description is the identity the local deploy, terraform and (via step 120)
# @description the GitHub deploy jobs authenticate with. Idempotent, and a DRY
# @description RUN unless DRY_RUN=0.
# @description
# @description Ported from csi-rel-iac gcp-002-create-project-service-account,
# @description in the csi-spl gcp-001 style:
# @description   1. A pre-flight proves GCP_ACCOUNT can mint a token before any
# @description      state is read (do_gcp_require_live_account).
# @description   2. The SA check is three-way (exists / reported absent / could
# @description      not tell); "could not tell" aborts.
# @description   3. Every gcloud call carries --account. Nothing is written to
# @description      the shared gcloud config (no config set, no login).
# @description   4. The org policy iam.disableServiceAccountKeyCreation is lifted
# @description      ONLY when a key must be created AND it is enforced on the
# @description      project, and it is re-enforced on EVERY path after that,
# @description      including a failed key create (csi-rel quit before it).
# @description   5. A key file on disk for an SA that does not exist is stale:
# @description      refuse rather than keep it or overwrite it.
# @description The key is never printed; only its path is logged.
# @param ENV - required: dev, prd or bkp (csi-spl-bkp, the off-project backups of iac 046)
# @param GCP_ACCOUNT (optional) - overrides the resolved identity (do_gcp_bootstrap_account: the project SA key once it exists, else cnf env.gcp.gcp_account_owner_email): an org-level human identity (orgpolicy.policyAdmin, iam admin)
# @param GCP_ORG_ID (optional) - overrides cnf env.gcp.gcp_org_id: the org the key-creation policy is set on
# @param DRY_RUN (optional) - 1 (default): read and report, mutate nothing. 0: mutate.
# @example ENV=dev ./run -a do_gcp_002_create_project_service_account
#------------------------------------------------------------------------------
do_gcp_002_create_project_service_account() {

  command -v gcloud &>/dev/null || { do_log "FATAL gcloud is not installed"; exit 1; }

  do_gcp_spl_proj_id || exit 1
  do_gcp_pin_bootstrap_account || exit 1
  GCP_ORG_ID=$(do_gcp_org_id)
  do_require_var GCP_ORG_ID "${GCP_ORG_ID:-}"

  local dry_run="${DRY_RUN:-1}"
  [[ "${dry_run}" == 0 || "${dry_run}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: ${dry_run}"; exit 1; }

  local acct="--account=${GCP_ACCOUNT}"
  local sa_id="${PROJ_ID}"
  local sa_email="${sa_id}@${PROJ_ID}.iam.gserviceaccount.com"
  local key_dir="${HOME}/.gcp/.${ORG}"
  local key_file="${key_dir}/key-${PROJ_ID}.json"
  local constraint="iam.disableServiceAccountKeyCreation"

  do_log "INFO PROJ_ID=${PROJ_ID} SA=${sa_email} key=${key_file} GCP_ACCOUNT=${GCP_ACCOUNT} org=${GCP_ORG_ID} DRY_RUN=${dry_run}"

  # ---- PRE-FLIGHT -- before ANY state is read -------------------------------
  do_gcp_require_live_account "${GCP_ACCOUNT}" \
    || quit_on "prove ${GCP_ACCOUNT} can mint an access token (gcloud auth login ${GCP_ACCOUNT}, run by the box user)"

  # ---- What is missing (three-way on the SA) --------------------------------
  local out rc need_sa need_key=false
  out=$(gcloud iam service-accounts describe "${sa_email}" --project="${PROJ_ID}" "${acct}" --format='value(email)' 2>&1)
  rc=$?
  if [[ ${rc} -eq 0 ]]; then
    need_sa=false
  elif printf '%s' "${out}" | grep -qiE 'NOT_FOUND|does not exist|not found'; then
    need_sa=true
  else
    do_log "ERROR cannot tell whether ${sa_email} exists (rc=${rc}): ${out}"
    do_log "FATAL refusing to create an SA or a key on an unread answer"
    exit 1
  fi
  [[ -f "${key_file}" ]] || need_key=true

  if [[ "${need_sa}" == true && "${need_key}" == false ]]; then
    do_log "FATAL ${key_file} exists but ${sa_email} does not: the key is stale. Move it away and re-run."
    exit 1
  fi
  if [[ "${need_sa}" == false && "${need_key}" == false ]]; then
    do_log "OK ${sa_email} and ${key_file} already present — nothing to do"
    return 0
  fi

  # ---- Is key creation blocked on this project? -----------------------------
  # Read the effective policy FIRST - never mutate on a state we cannot read.
  # The one exception: a brand-new project (the first ENV=bkp bootstrap) has not
  # enabled orgpolicy.googleapis.com yet, so the read is impossible until this
  # step's own API prerequisites are on (gcp-004 turns on the terraform APIs but
  # runs AFTER this step); when, and only when, the read fails BECAUSE that API
  # is off, enable it (and iam, for the SA + key below) and read again. dev and
  # prd never reach here: their SA + key already exist, the step returned above.
  local enforced=false dep_apis="orgpolicy.googleapis.com iam.googleapis.com"
  out=$(gcloud org-policies describe "${constraint}" --project="${PROJ_ID}" --effective "${acct}" 2>&1)
  rc=$?
  if [[ ${rc} -ne 0 ]] && printf '%s' "${out}" | grep -qiE 'orgpolicy\.googleapis\.com|Organization Policy API|SERVICE_DISABLED|has not been used'; then
    if [[ "${dry_run}" == 1 ]]; then
      do_log "INFO DRY_RUN would run: gcloud services enable ${dep_apis} --project=${PROJ_ID} ${acct}, then re-read ${constraint}"
      rc=0
    else
      do_log "INFO enabling ${dep_apis} on ${PROJ_ID} (this step's own prerequisites for reading/lifting ${constraint} and minting the key)"
      # shellcheck disable=SC2086
      gcloud services enable ${dep_apis} --project="${PROJ_ID}" "${acct}" >/dev/null || quit_on "enable ${dep_apis} on ${PROJ_ID}"
      out=$(gcloud org-policies describe "${constraint}" --project="${PROJ_ID}" --effective "${acct}" 2>&1)
      rc=$?
    fi
  fi
  if [[ ${rc} -eq 0 ]]; then
    printf '%s' "${out}" | grep -qE 'enforce: *true' && enforced=true
  elif [[ "${dry_run}" != 1 ]]; then
    do_log "FATAL cannot read the effective ${constraint} on ${PROJ_ID} (rc=${rc}): ${out}"; exit 1
  fi

  if [[ "${dry_run}" == 1 ]]; then
    [[ "${need_sa}" == true ]] && do_log "INFO DRY_RUN would run: gcloud iam service-accounts create ${sa_id} --project=${PROJ_ID} ${acct}"
    [[ "${enforced}" == true ]] && do_log "INFO DRY_RUN would lift ${constraint} at org ${GCP_ORG_ID} for the key create, then re-enforce it"
    do_log "INFO DRY_RUN would run: gcloud iam service-accounts keys create ${key_file} --iam-account=${sa_email} ${acct}"
    do_log "OK DRY_RUN for ${PROJ_ID} complete: nothing was created. Re-run with DRY_RUN=0 to mutate."
    return 0
  fi

  local tmp
  tmp=$(mktemp -d) || exit 1
  _gcp002_policy() {  # <true|false>
    printf 'name: organizations/%s/policies/%s\nspec:\n  rules:\n    - enforce: %s\n' \
      "${GCP_ORG_ID}" "${constraint}" "$1" >"${tmp}/policy-$1.yaml"
    gcloud org-policies set-policy "${tmp}/policy-$1.yaml" "${acct}" >/dev/null
  }

  local lifted=false failed=""
  if [[ "${enforced}" == true ]]; then
    do_log "INFO lifting ${constraint} at org ${GCP_ORG_ID} for the key create"
    gcloud organizations add-iam-policy-binding "${GCP_ORG_ID}" \
      --member="user:${GCP_ACCOUNT}" --role="roles/orgpolicy.policyAdmin" --condition=None \
      "${acct}" >/dev/null || failed="grant roles/orgpolicy.policyAdmin to ${GCP_ACCOUNT}"
    if [[ -z "${failed}" ]]; then
      if _gcp002_policy false; then
        lifted=true
        # the project-level reset propagates faster than the org change
        gcloud org-policies reset "${constraint}" --project="${PROJ_ID}" "${acct}" >/dev/null 2>&1 || true
      else
        failed="lift ${constraint}"
      fi
    fi
  fi

  if [[ -z "${failed}" && "${need_sa}" == true ]]; then
    do_log "INFO creating service account ${sa_id}"
    gcloud iam service-accounts create "${sa_id}" --display-name="${sa_id}" \
      --description="IaC + deploy identity of ${PROJ_ID}. Key minted by do_gcp_002." \
      --project="${PROJ_ID}" "${acct}" >/dev/null || failed="create ${sa_email}"
  fi

  if [[ -z "${failed}" ]]; then
    do_log "INFO creating the SA key (retry with backoff while the policy change propagates)"
    ( umask 077; mkdir -p "${key_dir}" )
    local created=false wait_secs
    for wait_secs in 10 30 60 120; do
      sleep "${wait_secs}"
      if ( umask 077; gcloud iam service-accounts keys create "${key_file}" \
             --iam-account="${sa_email}" --project="${PROJ_ID}" "${acct}" >/dev/null 2>&1 ); then
        created=true; break
      fi
      rm -f "${key_file}"
      do_log "WARNING key creation not allowed yet, retrying"
    done
    if [[ "${created}" == true ]]; then chmod 600 "${key_file}"; else failed="create a key for ${sa_email}"; fi
  fi

  # ---- Re-enforce: on EVERY path once it was lifted -------------------------
  if [[ "${lifted}" == true ]]; then
    if _gcp002_policy true; then
      do_log "INFO ${constraint} re-enforced at org ${GCP_ORG_ID}"
    else
      do_log "ERROR could not re-enforce ${constraint} at org ${GCP_ORG_ID}: set it back by hand NOW"
      failed="${failed:+${failed}; }re-enforce ${constraint}"
    fi
  fi
  rm -rf "${tmp}"
  unset -f _gcp002_policy

  [[ -z "${failed}" ]] || { do_log "FATAL Failed to ${failed}"; exit 1; }
  do_log "OK ${sa_email} ready; key at ${key_file} (mode 600, not printed)"
}
