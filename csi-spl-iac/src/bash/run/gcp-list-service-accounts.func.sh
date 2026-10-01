#!/bin/bash

#------------------------------------------------------------------------------
# @description list user- and google-managed service accounts for all GCP project environments
# @description Each env runs as its own project SA (do_gcp_each_env_sa).
# @example ORG=csi APP=csi-spl ./run -a do_gcp_list_service_accounts
#------------------------------------------------------------------------------
_gcp_list_service_accounts_one() {
  local project="$1" account="$2"
  echo "Listing user-managed service accounts for project ${project}..."
  gcloud iam service-accounts list --format="table(name, email, disabled)" --account="${account}" --project="${project}" \
    || echo "Error: Failed to list service accounts for project ${project}." >&2
  echo "Listing google-managed service accounts for project ${project}..."
  gcloud beta iam service-accounts list --include-managed-service-accounts --account="${account}" --project="${project}"
}

do_gcp_list_service_accounts() {
  do_gcp_each_env_sa _gcp_list_service_accounts_one
}
