#!/bin/bash
#------------------------------------------------------------------------------
# @description Poll ONE Firebase Hosting custom domain of the env's WUI site
# @description (019: the apex, or a tenant host <tenant>.<fqdn>, SPL-959) until
# @description Firebase serves it: hostState HOST_ACTIVE, ownershipState
# @description OWNERSHIP_ACTIVE and cert.state CERT_ACTIVE. Read-only: the
# @description firebasehosting v1beta1 customDomains GET, nothing is written.
# @description Also prints the DNS updates Firebase still asks for, so a wrong
# @description 025 record is visible on the first poll.
# @description
# @description Runs ONLY as the env SA (key ~/.gcp/.<org>/key-<project>.json,
# @description or SPL_SA_KEY) in a throwaway CLOUDSDK_CONFIG.
# @param ENV - dev or prd
# @param DOMAIN - the custom domain (e.g. <tenant>.<fqdn>)
# @param TIMEOUT_SECONDS (optional) - max wait (default 3600)
# @param POLL_SECONDS (optional) - poll interval (default 30)
# @param SPL_SA_KEY (optional) - the env SA key file
# @example ENV=dev DOMAIN=acme.dev.example.test ./run -a do_spl_wait_for_firebase_domain
#------------------------------------------------------------------------------
do_spl_wait_for_firebase_domain() {
  do_require_bin gcloud || return 1
  do_require_bin curl || return 1
  do_require_bin jq || return 1
  [[ "${ENV:-}" == dev || "${ENV:-}" == prd ]] || { do_log "FATAL ENV must be dev or prd, got: '${ENV:-}'"; return 1; }
  local domain="${DOMAIN:-}"
  [[ "$domain" =~ ^[a-z0-9.-]+$ ]] || { do_log "FATAL DOMAIN must be a DNS name, got: '$domain'"; return 1; }
  do_spl_cloud_cnf || return 1
  local key cfg site="$SPL_ORG_APP-$ENV-site"
  key="${SPL_SA_KEY:-$HOME/.gcp/.${SPL_ORG_APP%%-*}/key-$SPL_PROJECT.json}"
  [[ -r "$key" ]] || { do_log "FATAL no service-account key for $SPL_PROJECT at $key (set SPL_SA_KEY)"; return 1; }

  cfg="$(mktemp -d)" || return 1
  (
    export CLOUDSDK_CONFIG="$cfg"
    gcloud auth activate-service-account --key-file="$key" >/dev/null 2>&1 ||
      { do_log "FATAL cannot activate the $SPL_PROJECT key $key"; exit 1; }
    local account
    account="$(do_gcp_isolated_active_account)" || exit 1
    do_gcp_log_identity "$SPL_PROJECT" "$account" "do_spl_wait_for_firebase_domain"
    spl_firebase_domain_poll "$domain" "$SPL_PROJECT" "$site" "$account" \
      "${TIMEOUT_SECONDS:-3600}" "${POLL_SECONDS:-30}"
  )
  local rc=$?
  rm -rf "$cfg"
  return $rc
}

# spl_firebase_domain_state <customDomain json> -> "<host> <ownership> <cert>"
spl_firebase_domain_state() {
  jq -r '"\(.hostState // "absent") \(.ownershipState // "absent") \(.cert.state // "absent")"' 2>/dev/null <<<"$1"
}

# spl_firebase_domain_poll <domain> <project> <site> <account> <timeout> <poll>
spl_firebase_domain_poll() {
  local domain="$1" project="$2" site="$3" account="$4" timeout="$5" poll="$6"
  local deadline=$(($(date +%s) + timeout)) attempt=0 js state tok asks
  local url="https://firebasehosting.googleapis.com/v1beta1/projects/$project/sites/$site/customDomains/$domain"
  while :; do
    attempt=$((attempt + 1))
    tok="$(gcloud auth print-access-token --account="$account" 2>/dev/null)"
    js="$(curl -sS -H "Authorization: Bearer $tok" -H "x-goog-user-project: $project" "$url" 2>/dev/null)"
    [[ -n "$js" ]] || js='{}'
    state="$(spl_firebase_domain_state "$js")"
    if [[ $attempt == 1 ]]; then
      jq -e '.error' >/dev/null 2>&1 <<<"$js" && do_log "WARN $domain: $(jq -c '.error | {code, status, message}' <<<"$js")"
      asks="$(jq -r '.requiredDnsUpdates.desired[]?.records[]? | "\(.domainName) \(.type) \(.rdata)"' 2>/dev/null <<<"$js")"
      [[ -n "$asks" ]] && do_log "INFO $domain: Firebase wants DNS: $(tr '\n' ';' <<<"$asks")"
    fi
    if [[ "$state" == "HOST_ACTIVE OWNERSHIP_ACTIVE CERT_ACTIVE" ]]; then
      do_log "OK $domain is served by $site: $state (attempt $attempt)"
      return 0
    fi
    if [[ $(date +%s) -ge $deadline ]]; then
      do_log "FATAL $domain not active on $site after ${timeout}s (host ownership cert: ${state:-unknown})"
      return 1
    fi
    do_log "INFO attempt=$attempt $domain host ownership cert: ${state:-unknown} -- sleeping ${poll}s"
    sleep "$poll"
  done
}
