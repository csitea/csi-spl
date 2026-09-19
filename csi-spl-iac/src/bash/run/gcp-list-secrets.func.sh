#------------------------------------------------------------------------------
# @description list secrets from GCP Secret Manager for all environments
# @example ORG=csi APP=csi-spl ./run -a do_gcp_list_secrets
#------------------------------------------------------------------------------
do_gcp_list_secrets() {
  # Define the environments
  ENVIRONMENTS=("all" "dev" "stg" "prd")

  # Define service account key paths
  declare -A SA_KEYS=(
    ["all"]="~/.gcp/.$ORG/key-$ORG-$APP-all.json"
    ["dev"]="~/.gcp/.$ORG/key-$ORG-$APP-dev.json"
    ["stg"]="~/.gcp/.$ORG/key-$ORG-$APP-stg.json"
    ["prd"]="~/.gcp/.$ORG/key-$ORG-$APP-prd.json"
  )

  # Iterate through each environment
  for ENV in "${ENVIRONMENTS[@]}"; do
    do_log "INFO Listing secrets for environment: $ENV"

    # Authenticate using the service account for this environment
    sa_key=$(eval echo "${SA_KEYS[$ENV]}")
    if [[ -f "${sa_key}" ]]; then
      do_log "DEBUG Authenticating with service account: ${sa_key}"
      echo gcloud auth activate-service-account --key-file="${sa_key}"
      echo gcloud config set project "$ORG-$APP-${ENV}"  # Set the active GCP project
    else
      do_log "ERROR Service account key file for $ENV not found!"
      continue
    fi

    # List secrets containing "acc" in their name
    do_log "INFO Secrets containing 'acc' in the name for $ENV:"
    echo gcloud secrets list --filter="name~'acc'" --format="value(name)"
  done

  do_log "INFO Secret listing completed!"
}
