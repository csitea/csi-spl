#!/bin/bash

#------------------------------------------------------------------------------
# @description list storage buckets for all GCP project environments
# @description Each env runs as its own project SA (do_gcp_each_env_sa).
# @example ORG=csi APP=csi-spl ./run -a do_gcp_list_buckets
#------------------------------------------------------------------------------
_gcp_list_buckets_one() {
  local project="$1" account="$2"
  echo "Listing buckets for project ${project}..."
  gcloud storage buckets list --format="table(name, location, storageClass)" --account="${account}" --project="${project}" \
    || echo "Error: Failed to list buckets for project ${project}." >&2
}

do_gcp_list_buckets() {
  do_gcp_each_env_sa _gcp_list_buckets_one
}
