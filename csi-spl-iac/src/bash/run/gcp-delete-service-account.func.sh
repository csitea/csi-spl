#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description Gcp delete service account.
#------------------------------------------------------------------------------
do_gcp_delete_service_account(){
  # Pin the gcloud identity for this run (spec 012 C-2). `--project` says WHERE
  # a call lands, never WHO it lands as, and `~/.config/gcloud` is one directory
  # shared by every agent on this box — `gcloud config set account` and
  # `auth activate-service-account` are both global writes, so the ambient
  # account is whichever agent ran one last. Resolved ONCE here so another
  # agent cannot move this run's identity between two of its own calls, passed
  # explicitly to each call below, and logged before the first of them so the
  # identity is auditable afterwards rather than inferable from a config file
  # that will have moved by the time anyone looks.
  local account
  account=$(do_gcp_account) || quit_on "no gcloud identity could be resolved — set ACCOUNT or GCP_ACCOUNT"
  do_gcp_log_identity "${PROJ_ID:-<unset>}" "${account}" "do_gcp_delete_service_account"


  # 1) Construct the project ID from the environment variables
  PROJ_ID="${ORG}-${APP}-${ENV}"

  # SA_HEAD="sa-ci-${ORG}-${APP}-${ENV}-portfolio"
  # 2) Construct the target service account’s email
  SA_EMAIL="$SA_HEAD@${PROJ_ID}.iam.gserviceaccount.com"

  # 3) Revoke existing auth
  gcloud auth revoke --all

  # 4) Activate the "PROJ_ID" service account using the local key file
  gcloud auth activate-service-account \
    --key-file="$HOME/.gcp/.${ORG}/key-${PROJ_ID}.json"

  # 5) Set the project
  gcloud config set project "${PROJ_ID}"

  # 6) Check if the SA exists. If yes, delete it. If not, echo a message.

  if gcloud iam service-accounts list --project="${PROJ_ID}" --format="value(email)" --account="${account}" | grep -q "${SA_EMAIL}"
  then
    echo "Service account ${SA_EMAIL} found in ${PROJ_ID}. Deleting..."
    gcloud iam service-accounts delete "${SA_EMAIL}" --project="${PROJ_ID}" --quiet --account="${account}"
    quit_on "delete service account ${SA_EMAIL}"
  else
    echo "Service account ${SA_EMAIL} does not exist in ${PROJ_ID}."
  fi

}
