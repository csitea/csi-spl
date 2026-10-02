#!/bin/bash

#------------------------------------------------------------------------------
# @description export DNS zones and records from GCP Cloud DNS for all environments
# @example ORG=csi APP=csi-spl ./run -a do_gcp_export_dns
#------------------------------------------------------------------------------
do_gcp_export_dns() {
  local _spl_sdk_saved="${CLOUDSDK_CONFIG-}" _spl_sdk_dir
  _spl_sdk_dir="$(mktemp -d)"
  export CLOUDSDK_CONFIG="$_spl_sdk_dir"
  trap 'rm -rf "$_spl_sdk_dir"; if [[ -n "$_spl_sdk_saved" ]]; then export CLOUDSDK_CONFIG="$_spl_sdk_saved"; else unset CLOUDSDK_CONFIG; fi; trap - RETURN' RETURN
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
  # This action walks several envs: each env's identity is that env's project
  # SA, activated from its key and re-pinned inside the loop (owner rule
  # 2026-09-19: the per-env service accounts only, never the owner account).


  do_resolve_oap ORG
  do_resolve_oap APP

declare -A env_keys=(
  ["dev"]="$HOME/.gcp/.${ORG:-}/key-${ORG:-}-${APP:-}-dev.json"
  ["prd"]="$HOME/.gcp/.${ORG:-}/key-${ORG:-}-${APP:-}-prd.json"
  ["tst"]="$HOME/.gcp/.${ORG:-}/key-${ORG:-}-${APP:-}-tst.json"
)

for env in "${!env_keys[@]}"; do
  expanded_key_path="${env_keys[$env]}"
  export GOOGLE_APPLICATION_CREDENTIALS="${expanded_key_path}"

  do_log "INFO Exporting DNS configuration for $env environment"
  PROJECT_ID=$(jq -r '.project_id' $GOOGLE_APPLICATION_CREDENTIALS)
  if ! gcloud auth activate-service-account --key-file="${expanded_key_path}" --quiet &>/dev/null; then
    do_log "WARN no usable project SA key for $env (${expanded_key_path}); skipping it"
    continue
  fi
  account=$(do_gcp_isolated_active_account) || quit_on "re-pin --account to the identity just activated in the isolated gcloud config"

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
