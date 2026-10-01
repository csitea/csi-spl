#!/bin/bash

#------------------------------------------------------------------------------
# @description list firewall rules for all GCP project environments
# @description Each env runs as its own project SA (do_gcp_each_env_sa).
# @example ORG=csi APP=csi-spl ./run -a do_gcp_list_firewall_rules
#------------------------------------------------------------------------------
_gcp_list_firewall_rules_one() {
  local project="$1" account="$2"
  echo "Listing firewall rules for project ${project}..."
  gcloud compute firewall-rules list --format="table(name, network, direction, priority, allowed)" --account="${account}" --project="${project}" \
    || echo "Error: Failed to list firewall rules for project ${project}." >&2
}

do_gcp_list_firewall_rules() {
  do_gcp_each_env_sa _gcp_list_firewall_rules_one
}
