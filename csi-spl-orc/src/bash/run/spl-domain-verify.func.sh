#!/bin/bash
#------------------------------------------------------------------------------
# @description Make this env's service account a VERIFIED OWNER of
# @description env.dns.BASE_DOMAIN, which Cloud Run needs before step 032 can
# @description create a domain mapping. csi-rel's one-time runbook for step
# @description 005-gcp-domain-verification (csi-rel-doc/specs/010-orc-deploy/
# @description spec.md), as a named action; same siteVerification REST calls.
# @description
# @description Default (TOKEN): POST /siteVerification/v1/token for a DNS_CNAME
# @description token and print the verification_records entry to add under
# @description steps.005-gcp-domain-verification in <env>.env.yaml. Then
# @description re-render, provision 005 (the CNAME lands in the prd apex zone),
# @description and run again with VERIFY=1: POST webResource, which prints the
# @description owners. LIST=1 lists what the SA already owns.
# @description
# @description Runs ONLY as the env SA (key ~/.gcp/.<org>/key-<project>.json,
# @description or SPL_SA_KEY) in a throwaway CLOUDSDK_CONFIG; the shared
# @description ~/.config/gcloud and the owner account are never used.
# @description Needs siteverification.googleapis.com enabled (step 001).
# @param ENV - dev or prd
# @param VERIFY (optional) - 1: finalise ownership (after 005 is provisioned)
# @param LIST (optional) - 1: list the web resources the SA owns
# @param SPL_SA_KEY (optional) - the env SA key file
# @example ENV=dev ./run -a do_spl_domain_verify
# @example ENV=dev VERIFY=1 ./run -a do_spl_domain_verify
#------------------------------------------------------------------------------
do_spl_domain_verify() {
  do_require_bin gcloud || return 1
  do_require_bin curl || return 1
  do_require_bin jq || return 1
  spl_require_cloud_env || return 1
  do_spl_cloud_cnf || return 1

  local domain key cfg api=https://www.googleapis.com/siteVerification/v1
  domain="$(yq -r '.env.dns.BASE_DOMAIN // ""' "$SPL_CNF")"
  [[ "$domain" == *.* ]] || { do_log "FATAL env.dns.BASE_DOMAIN is not set in $SPL_CNF"; return 1; }
  key="${SPL_SA_KEY:-$HOME/.gcp/.${SPL_ORG_APP%%-*}/key-$SPL_PROJECT.json}"
  [[ -r "$key" ]] || { do_log "FATAL no service-account key for $SPL_PROJECT at $key (set SPL_SA_KEY)"; return 1; }

  cfg="$(mktemp -d)" || return 1
  (
    export CLOUDSDK_CONFIG="$cfg"
    gcloud auth activate-service-account --key-file="$key" >/dev/null 2>&1 ||
      { do_log "FATAL cannot activate the $SPL_PROJECT key $key"; exit 1; }
    local account token site out
    account="$(do_gcp_isolated_active_account)" || exit 1
    do_gcp_log_identity "$SPL_PROJECT" "$account" "do_spl_domain_verify"
    token="$(gcloud auth print-access-token --account="$account" \
      --scopes=https://www.googleapis.com/auth/siteverification 2>/dev/null)"
    [[ -n "$token" ]] || { do_log "FATAL no siteverification access token for $account"; exit 1; }
    site="{\"site\":{\"type\":\"INET_DOMAIN\",\"identifier\":\"$domain\"}"

    if [[ "${LIST:-0}" == 1 ]]; then
      out="$(curl -sS -H "Authorization: Bearer $token" "$api/webResource")" || exit 1
      jq -r '.items[]?.site.identifier' <<<"$out"
      jq -e '.error' <<<"$out" >/dev/null 2>&1 && { do_log "FATAL $(jq -c '.error.message' <<<"$out")"; exit 1; }
      do_log "OK listed the web resources $account owns"
      exit 0
    fi

    if [[ "${VERIFY:-0}" == 1 ]]; then
      out="$(curl -sS -X POST -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
        "$api/webResource?verificationMethod=DNS_CNAME" -d "${site}}")" || exit 1
      jq -e --arg a "$account" '.owners | index($a)' <<<"$out" >/dev/null 2>&1 || {
        do_log "FATAL $account is not an owner of $domain: $(jq -c '.error.message // .' <<<"$out")"
        exit 1
      }
      do_log "OK $account is a verified owner of $domain (owners: $(jq -c '.owners' <<<"$out"))"
      exit 0
    fi

    out="$(curl -sS -X POST -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
      "$api/token" -d "${site},\"verificationMethod\":\"DNS_CNAME\"}")" || exit 1
    local tok src tgt
    tok="$(jq -r '.token // ""' <<<"$out")"
    read -r src tgt <<<"$tok"
    [[ -n "$src" && -n "$tgt" ]] || { do_log "FATAL no DNS_CNAME token for $domain: $(jq -c '.error.message // .' <<<"$out")"; exit 1; }
    [[ "$src" == *.* ]] || src="$src.$domain"
    printf '      verification_records:\n        - source: %s.\n          target: %s.\n' "${src%.}" "${tgt%.}"
    do_log "OK token for $account on $domain: add the entry above to steps.005-gcp-domain-verification in $ENV.env.yaml, re-render, provision 005, then VERIFY=1"
  )
  local rc=$?
  rm -rf "$cfg"
  return $rc
}
