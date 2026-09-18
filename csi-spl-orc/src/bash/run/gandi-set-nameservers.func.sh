#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Registrar name servers for the product domain. MUTATING.
#              Dry-run unless CONFIRM=yes. Option A (owner, 2026-09-18): the
#              domain is delegated to the Cloud DNS zone 025-gcp-dns-zone
#              adopts, so the expected targets are that zone's ns-cloud-*
#              servers (`gcloud dns managed-zones describe <zone>
#              --format='value(nameServers)'`). Changing them moves every
#              public record at once: a wrong value takes the domain offline
#              for up to the TLD NS TTL.
# @param NAMESERVERS - required: comma-separated NS hostnames
# @param DOMAIN - optional: override cnf env.dns.BASE_DOMAIN
# @param CONFIRM - optional: yes to apply
# @example NAMESERVERS=<ns1>,<ns2>,<ns3>,<ns4> ./run -a do_gandi_set_nameservers
# @example NAMESERVERS=<ns1>,<ns2>,<ns3>,<ns4> CONFIRM=yes ./run -a do_gandi_set_nameservers
# @arg --domain DOMAIN
# @arg --nameservers NAMESERVERS
#------------------------------------------------------------------------------
do_gandi_set_nameservers() {
  local domain ns json out
  domain="$(_gandi_domain)" || return 1
  ns="${NAMESERVERS:?set NAMESERVERS=ns1,ns2,... (comma-separated)}"
  command -v jq >/dev/null 2>&1 || { do_log "FATAL jq is not installed"; return 1; }

  json="$(printf '%s' "$ns" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0)) | {nameservers: .}')"
  [[ "$(jq '.nameservers | length' <<<"$json")" -ge 2 ]] ||
    { do_log "FATAL at least two name servers are required, got: ${ns}"; return 1; }

  do_log "WARNING will SET registrar name servers for ${domain} to: ${ns}"
  if [[ "${CONFIRM:-}" != "yes" ]]; then
    do_log "INFO dry-run: re-run with CONFIRM=yes to apply. Payload: ${json}"
    return 0
  fi
  out="$(_gandi_api PUT "/domain/domains/${domain}/nameservers" "$json")" || return 1
  do_log "OK registrar name servers for ${domain} set: ${out}"
}
