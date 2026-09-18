#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Show registrar-level name servers for the product domain
#              ($DOMAIN or cnf env.dns.BASE_DOMAIN). Read-only. Public NS
#              must stay on Gandi LiveDNS.
# @example ./run -a do_gandi_get_nameservers
# @arg --domain DOMAIN
#------------------------------------------------------------------------------
do_gandi_get_nameservers() {
  local domain
  domain="$(_gandi_domain)" || return 1
  command -v jq >/dev/null 2>&1 || { do_log "FATAL jq is not installed"; return 1; }
  do_log "INFO current registrar name servers for ${domain}:"
  _gandi_api GET "/domain/domains/${domain}/nameservers" | jq -r '.[]?'
}
