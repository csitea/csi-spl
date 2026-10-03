#!/bin/env bash

#------------------------------------------------------------------------------
# @description fetch secrets from GCP Secret Manager and export as environment variables
# @param ENV - target environment (required: dev, tst — never prd)
# @param SECRETS_FILTER - only fetch secrets containing this substring (optional, e.g., "test")
# @param GCP_PROJECT - GCP project override (optional, default: ORG-APP-ENV)
# @example ENV=dev ./run -a do_gcp_fetch_secrets
# @example ENV=dev SECRETS_FILTER=test ./run -a do_gcp_fetch_secrets
#------------------------------------------------------------------------------
do_gcp_fetch_secrets() {
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
  account=$(do_gcp_account) || quit_on "no gcloud identity could be resolved — set ACCOUNT or GCP_ACCOUNT"
  do_gcp_log_identity "${project:-<unset>}" "${account}" "do_gcp_fetch_secrets"

  local org_app="${ORG_APP:?ORG_APP is required}"
  local org="${org_app%%-*}"
  local app="${org_app##*-}"
  local env_name="${ENV:-}"
  local project="${GCP_PROJECT:-${org}-${app}-${env_name}}"
  local prefix="${org}-${app}-"
  local filter="${SECRETS_FILTER:-}"
  local key_file="${GCP_KEY_FILE:-$HOME/.gcp/.${org}/key-${org}-${app}-${env_name}.json}"

  if [[ -z "$env_name" ]]; then
    do_log "FATAL ENV is required. Usage: ENV=dev ./run -a do_gcp_fetch_secrets"
  return 1
  fi

  if [[ "$env_name" == "prd" ]]; then
    do_log "FATAL Refusing to fetch production secrets. Use Cloud Run secret injection for prd."
  return 1
  fi

  do_log "INFO Fetching secrets from GCP Secret Manager (project: $project)"

  # Authenticate with GCP
  if [[ -f "$key_file" ]]; then
    gcloud auth activate-service-account --key-file="$key_file" --quiet 2>/dev/null
    account=$(do_gcp_isolated_active_account) || quit_on "re-pin --account to the identity just activated in the isolated gcloud config"
    do_log "INFO Authenticated with $(basename "$key_file")"
  else
    do_log "WARN Key file not found: $key_file — using current gcloud auth"
  fi

  gcloud config set project "$project" --quiet 2>/dev/null

  # Build filter for gcloud secrets list
  local gcloud_filter="name:${prefix}"
  if [[ -n "$filter" ]]; then
    gcloud_filter="${gcloud_filter} AND name:${filter}"
    do_log "INFO Filtering secrets by: $filter"
  fi

  # List matching secrets
  local secrets
  secrets=$(gcloud secrets list \
    --filter="$gcloud_filter" \
    --format="value(name)" \
    --project="$project" \
    --account="${account}" 2>/dev/null)

  if [[ -z "$secrets" ]]; then
    do_log "WARN No secrets found matching '$gcloud_filter' in project $project"
    return 0
  fi

  local count=0
  local failed=0

  while IFS= read -r secret_id; do
    [[ -z "$secret_id" ]] && continue

    local value
    if value=$(gcloud secrets versions access latest \
      --secret="$secret_id" \
      --project="$project" \
      --account="${account}" 2>/dev/null) && [[ -n "$value" ]]; then
      # Convert secret_id to env var name:
      #   csi-spl-stripe-secret-key → STRIPE_SECRET_KEY
      local env_var
      env_var=$(echo "${secret_id#${prefix}}" | tr '-' '_' | tr '[:lower:]' '[:upper:]')

      export "$env_var"="$value"
      count=$((count + 1))
    else
      failed=$((failed + 1))
      do_log "WARN Failed to fetch: $secret_id"
    fi
  done <<< "$secrets"

  echo ""
  echo "═══════════════════════════════════════════════════════════════════════"
  echo "FETCHED $count secrets from $project ($failed failed)"
  echo "═══════════════════════════════════════════════════════════════════════"
  echo ""
  if [[ -n "$filter" ]]; then
    echo "FILTER: $filter"
  fi
  echo "ENV VARS exported to current shell"
  echo ""

  do_log "OK Exported $count secrets from $project"
}
