#!/usr/bin/env bash
# shellcheck source=../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh
declare -F spl_gcp_temp_sdk_config >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh"

#------------------------------------------------------------------------------
# @description Delete the service account SA_HEAD@<ORG>-<APP>-<ENV>.iam.gserviceaccount.com
# @description from the project <ORG>-<APP>-<ENV>, as that project's SA. Destructive,
# @description so a DRY RUN unless DRY_RUN=0: DRY_RUN=1 (default) prints the gcloud
# @description calls it would make (account, project, service account) and makes none.
# @description A missing ORG, APP, ENV or SA_HEAD is refused before any gcloud call.
# @param DRY_RUN (optional) - 1 (default): print the calls, run none. 0: delete.
# @example ORG=csi APP=spl ENV=dev SA_HEAD=sa-ci-csi-spl-dev ./run -a do_gcp_delete_service_account
# @example ORG=csi APP=spl ENV=dev SA_HEAD=sa-ci-csi-spl-dev DRY_RUN=0 ./run -a do_gcp_delete_service_account
#------------------------------------------------------------------------------
do_gcp_delete_service_account(){
  : "${ORG:?ORG is required}" "${APP:?APP is required}" "${ENV:?ENV is required (dev/prd)}" "${SA_HEAD:?SA_HEAD is required}"
  local dry_run="${DRY_RUN:-1}"
  [[ "${dry_run}" == 0 || "${dry_run}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: ${dry_run}"; return 1; }

  # 1) Construct the project ID from the environment variables
  PROJ_ID="${ORG}-${APP}-${ENV}"
  # 2) Construct the target service account’s email
  SA_EMAIL="$SA_HEAD@${PROJ_ID}.iam.gserviceaccount.com"
  local key_file="$HOME/.gcp/.${ORG}/key-${PROJ_ID}.json"
  local account

  if [[ "${dry_run}" == 1 ]]; then
    # No gcloud call at all: the account comes from ACCOUNT / GCP_ACCOUNT or
    # the key's client_email, as the real run resolves it.
    account="${ACCOUNT:-${GCP_ACCOUNT:-}}"
    [[ -n "${account}" ]] || account=$(do_gcp_sa_key_email "${key_file}") \
      || { do_log "FATAL no gcloud account: set ACCOUNT or provide the key ${key_file}"; return 1; }
    do_log "INFO DRY_RUN would run: gcloud auth activate-service-account --key-file=${key_file}"
    do_log "INFO DRY_RUN would run: gcloud iam service-accounts list --project=${PROJ_ID} --format=value(email) --account=${account}"
    do_log "INFO DRY_RUN would run, if listed: gcloud iam service-accounts delete ${SA_EMAIL} --project=${PROJ_ID} --quiet --account=${account}"
    do_log "OK DRY_RUN for ${SA_EMAIL} complete: nothing was deleted. Re-run with DRY_RUN=0 to delete."
    return 0
  fi

  local _spl_sdk_saved _spl_sdk_dir
  spl_gcp_temp_sdk_config || return 1
  trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN
  # Pin the gcloud identity for this run (spec 012 C-2). `--project` says WHERE
  # a call lands, never WHO it lands as, and `~/.config/gcloud` is one directory
  # shared by every agent on this box — `gcloud config set account` and
  # `auth activate-service-account` are both global writes, so the ambient
  # account is whichever agent ran one last. Resolved ONCE here so another
  # agent cannot move this run's identity between two of its own calls, passed
  # explicitly to each call below, and logged before the first of them so the
  # identity is auditable afterwards rather than inferable from a config file
  # that will have moved by the time anyone looks.
  account=$(do_gcp_account) || quit_on "no gcloud identity could be resolved — set ACCOUNT or GCP_ACCOUNT"
  do_gcp_log_identity "${PROJ_ID}" "${account}" "do_gcp_delete_service_account"

  # 3) Revoke existing auth
  gcloud auth revoke --all

  # 4) Activate the "PROJ_ID" service account using the local key file
  gcloud auth activate-service-account \
    --key-file="${key_file}"
  account=$(do_gcp_isolated_active_account) || quit_on "re-pin --account to the identity just activated in the isolated gcloud config"

  # 5) Set the project
  gcloud config set project "${PROJ_ID}"

  # 6) Check if the SA exists. If yes, delete it. If not, echo a message.

  if gcloud iam service-accounts list --project="${PROJ_ID}" --format="value(email)" --account="${account}" | grep "${SA_EMAIL}" >/dev/null
  then
    echo "Service account ${SA_EMAIL} found in ${PROJ_ID}. Deleting..."
    gcloud iam service-accounts delete "${SA_EMAIL}" --project="${PROJ_ID}" --quiet --account="${account}"
    quit_on "delete service account ${SA_EMAIL}"
  else
    echo "Service account ${SA_EMAIL} does not exist in ${PROJ_ID}."
  fi

}
