#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description List LiveDNS records Gandi serves for the product domain
#              ($DOMAIN or cnf env.dns.BASE_DOMAIN).
# @example ./run -a do_gandi_list_dns_records
# @arg --domain DOMAIN
#------------------------------------------------------------------------------
do_gandi_list_dns_records() {
  local domain
  domain="$(_gandi_domain)" || return 1
  command -v jq >/dev/null 2>&1 || { do_log "FATAL jq is not installed"; return 1; }
  do_log "INFO LiveDNS records for ${domain}:"
  _gandi_api GET "/livedns/domains/${domain}/records" \
    | jq -r '.[]? | "\(.rrset_name)\t\(.rrset_type)\t\(.rrset_ttl)\t\(.rrset_values | join(","))"'
}
