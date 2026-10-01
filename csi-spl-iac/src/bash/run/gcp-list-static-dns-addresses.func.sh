#!/bin/bash

#------------------------------------------------------------------------------
# @description list static external IP addresses for all GCP project environments
# @description Each env runs as its own project SA (do_gcp_each_env_sa).
# @example ORG=csi APP=csi-spl ./run -a do_gcp_list_static_dns_addresses
#------------------------------------------------------------------------------
_gcp_list_static_dns_addresses_one() {
  local project="$1" account="$2"
  echo "Listing static IP addresses for project ${project}..."
  gcloud compute addresses list --format="table(name, address, region, status)" --filter="addressType=EXTERNAL" --account="${account}" --project="${project}" \
    || echo "Error: Failed to list static IP addresses for project ${project}." >&2
}

do_gcp_list_static_dns_addresses() {
  do_gcp_each_env_sa _gcp_list_static_dns_addresses_one
}
