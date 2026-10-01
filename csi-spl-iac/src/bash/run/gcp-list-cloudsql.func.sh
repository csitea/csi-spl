#!/bin/bash

#------------------------------------------------------------------------------
# @description list Cloud SQL instances for all GCP project environments
# @description Each env runs as its own project SA (do_gcp_each_env_sa).
# @example ORG=csi APP=csi-spl ./run -a do_gcp_list_cloudsql
#------------------------------------------------------------------------------
_gcp_list_cloudsql_one() {
  local project="$1" account="$2"
  echo "Listing Cloud SQL instances for project ${project}..."
  gcloud sql instances list --format="table(name, region, ipAddresses[].ipAddress)" --account="${account}" --project="${project}" \
    || echo "Error: Failed to list Cloud SQL instances for project ${project}." >&2
}

do_gcp_list_cloudsql() {
  do_gcp_each_env_sa _gcp_list_cloudsql_one
}
