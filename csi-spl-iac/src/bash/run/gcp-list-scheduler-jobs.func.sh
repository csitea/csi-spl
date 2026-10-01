#!/bin/bash

#------------------------------------------------------------------------------
# @description list Cloud Scheduler jobs for all GCP project environments
# @description Each env runs as its own project SA (do_gcp_each_env_sa).
# @param LOCATION (optional) - default europe-west3
# @example ORG=csi APP=csi-spl ./run -a do_gcp_list_scheduler_jobs
#------------------------------------------------------------------------------
_gcp_list_scheduler_jobs_one() {
  local project="$1" account="$2"
  echo "Listing Cloud Scheduler jobs for project ${project} in location ${LOCATION}..."
  gcloud scheduler jobs list --location="${LOCATION}" --format="table(name, schedule, state)" --account="${account}" --project="${project}" \
    || echo "Error: Failed to list Cloud Scheduler jobs for project ${project}." >&2
}

do_gcp_list_scheduler_jobs() {
  LOCATION="${LOCATION:-europe-west3}"
  do_gcp_each_env_sa _gcp_list_scheduler_jobs_one
}
