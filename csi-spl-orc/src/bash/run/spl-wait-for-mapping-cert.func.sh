#!/bin/bash
#------------------------------------------------------------------------------
# @description Poll a 032 Cloud Run domain mapping until its Google-managed
# @description cert is provisioned (condition CertificateProvisioned == True).
# @description csi-rel-orc do_wait_for_cert, for the domain mapping it was
# @description written for. It replaces this repo's 031-era do_wait_for_cert
# @description (Certificate Manager cert), retired with 031 (007 T090).
# @description
# @description One change from the donor, not a new behaviour: its
# @description --format='value(status.conditions[?type=...].status)' is always
# @description empty on this gcloud (pas-psf F-28, wait-for-cert-parses-
# @description conditions.tst.sh), so the conditions are read as json with jq.
# @description Also prints the DNS records the mapping asks for.
# @description
# @description Runs ONLY as the env SA (key ~/.gcp/.<org>/key-<project>.json,
# @description or SPL_SA_KEY) in a throwaway CLOUDSDK_CONFIG.
# @param ENV - dev or prd
# @param DOMAIN - the mapped host (e.g. dev.api.<BASE_DOMAIN>, t1.<fqdn>)
# @param TIMEOUT_SECONDS (optional) - max wait (default 3600)
# @param POLL_SECONDS (optional) - poll interval (default 30)
# @param SPL_SA_KEY (optional) - the env SA key file
# @example ENV=dev DOMAIN=t1.dev.example.test ./run -a do_spl_wait_for_mapping_cert
#------------------------------------------------------------------------------
do_spl_wait_for_mapping_cert() {
  do_require_bin gcloud || return 1
  do_require_bin jq || return 1
  spl_require_cloud_env || return 1
  local domain="${DOMAIN:-}"
  [[ -n "$domain" ]] || { do_log "FATAL DOMAIN is required (the mapped host)"; return 1; }
  do_spl_cloud_cnf || return 1
  local key cfg
  key="${SPL_SA_KEY:-$HOME/.gcp/.${SPL_ORG_APP%%-*}/key-$SPL_PROJECT.json}"
  [[ -r "$key" ]] || { do_log "FATAL no service-account key for $SPL_PROJECT at $key (set SPL_SA_KEY)"; return 1; }

  cfg="$(mktemp -d)" || return 1
  (
    export CLOUDSDK_CONFIG="$cfg"
    gcloud auth activate-service-account --key-file="$key" >/dev/null 2>&1 ||
      { do_log "FATAL cannot activate the $SPL_PROJECT key $key"; exit 1; }
    local account
    account="$(do_gcp_isolated_active_account)" || exit 1
    do_gcp_log_identity "$SPL_PROJECT" "$account" "do_spl_wait_for_mapping_cert"
    spl_mapping_cert_poll "$domain" "$SPL_PROJECT" "$SPL_REGION" "$account" \
      "${TIMEOUT_SECONDS:-3600}" "${POLL_SECONDS:-30}"
  )
  local rc=$?
  rm -rf "$cfg"
  return $rc
}

# spl_mapping_cert_poll <domain> <project> <region> <account> <timeout> <poll>
spl_mapping_cert_poll() {
  local domain="$1" project="$2" region="$3" account="$4" timeout="$5" poll="$6"
  local deadline=$(($(date +%s) + timeout)) attempt=0 js status records
  while :; do
    attempt=$((attempt + 1))
    js="$(gcloud beta run domain-mappings describe --domain="$domain" --region="$region" \
      --project="$project" --account="$account" --format=json 2>/dev/null)"
    [[ -n "$js" ]] || js='{}'
    status="$(jq -r '[.status.conditions[]? | select(.type=="CertificateProvisioned")][0].status // ""' <<<"$js" 2>/dev/null)"
    if [[ $attempt == 1 ]]; then
      records="$(jq -r '.status.resourceRecords[]? | "\(.name // "@") \(.type) \(.rrdata)"' <<<"$js" 2>/dev/null)"
      [[ -n "$records" ]] && do_log "INFO $domain asks for DNS: $(tr '\n' ';' <<<"$records")"
    fi
    if [[ "$status" == True ]]; then
      do_log "OK cert provisioned for $domain (attempt $attempt)"
      return 0
    fi
    if [[ $(date +%s) -ge $deadline ]]; then
      do_log "FATAL cert not provisioned for $domain after ${timeout}s (last CertificateProvisioned='${status:-absent}')"
      return 1
    fi
    do_log "INFO attempt=$attempt CertificateProvisioned='${status:-pending}' -- sleeping ${poll}s"
    sleep "$poll"
  done
}
