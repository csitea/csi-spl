#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Registrar nameservers for the product domain. KEEP dry-run only:
#              this product's NS stay on Gandi LiveDNS. REFUSES ns-cloud-* and
#              googledomains.com. CONFIRM=yes is ignored; this action never
#              PUTs (dob-luk used it for GCP takeover — not here).
# @param NAMESERVERS - required: comma-separated NS hostnames
# @param DOMAIN - optional: override cnf env.dns.BASE_DOMAIN
# @example NAMESERVERS=ns-101-a.gandi.net,ns-102-b.gandi.net ./run -a do_gandi_set_nameservers
# @arg --domain DOMAIN
# @arg --nameservers NAMESERVERS
#------------------------------------------------------------------------------
do_gandi_set_nameservers() {
  local domain ns json s
  domain="$(_gandi_domain)" || return 1
  ns="${NAMESERVERS:?set NAMESERVERS=ns1,ns2,... (comma-separated)}"

  local -a ns_arr
  IFS=',' read -ra ns_arr <<< "$ns"
  for s in "${ns_arr[@]}"; do
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    if [[ "$s" == *ns-cloud-* || "$s" == *googledomains.com* ]]; then
      do_log "FATAL refusing GCP Cloud DNS nameserver: $s"
      do_log "FATAL public NS stay on Gandi LiveDNS; do not re-delegate to ns-cloud-*"
      return 1
    fi
  done

  if command -v jq >/dev/null 2>&1; then
    json="$(printf '%s' "$ns" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0)) | {nameservers: .}')"
  else
    json="(jq not installed; nameservers=${ns})"
  fi

  do_log "WARNING would SET registrar name servers for ${domain} to: ${ns}"
  do_log "INFO dry-run only: do_gandi_set_nameservers never applies on this product (NS stay on Gandi LiveDNS). Payload: ${json}"
  return 0
}
