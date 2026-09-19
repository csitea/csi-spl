#!/bin/bash

#------------------------------------------------------------------------------
# @description export DNS zones and records from GCP Cloud DNS for all environments
# @example ORG=csi APP=csi-spl ./run -a do_gcp_export_dns
#------------------------------------------------------------------------------
do_gcp_export_dns() {
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
  do_gcp_log_identity "${PROJECT_ID:-<unset>}" "${account}" "do_gcp_export_dns"


  do_resolve_oap ORG
  do_resolve_oap APP

declare -A env_keys=(
  ["dev"]="~/.gcp/.${ORG:-}/key-${ORG:-}-${APP:-}-dev.json"
  ["prd"]="~/.gcp/.${ORG:-}/key-${ORG:-}-${APP:-}-prd.json"
  ["tst"]="~/.gcp/.${ORG:-}/key-${ORG:-}-${APP:-}-tst.json"
)

for env in "${!env_keys[@]}"; do
  expanded_key_path=$(eval echo ${env_keys[$env]})
  export GOOGLE_APPLICATION_CREDENTIALS="${expanded_key_path}"

  do_log "INFO Exporting DNS configuration for $env environment"
  PROJECT_ID=$(jq -r '.project_id' $GOOGLE_APPLICATION_CREDENTIALS)

  gcloud config set project ${PROJECT_ID:-}
  quit_on "Setting project"

  # List DNS Managed Zones
  gcloud dns managed-zones list --format="json" --account="${account}" --project="${PROJECT_ID}" > ~/dns-managed-zones-${env}.json
  quit_on "Listing DNS Managed Zones"

  # Export DNS Records for each zone
  zones=$(gcloud dns managed-zones list --format="value(name)" --account="${account}" --project="${PROJECT_ID}")
  for zone in $zones; do
    gcloud dns record-sets export ~/dns-records-${zone}-${env}.yaml --zone=$zone --account="${account}" --project="${PROJECT_ID}"
    quit_on "Exporting DNS records for $zone"
  done

  do_log "INFO Export completed for $env environment"

done

}
