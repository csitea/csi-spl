#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description List domains in the Gandi account (fqdn + status).
# @example ./run -a do_gandi_list_domains
#------------------------------------------------------------------------------
do_gandi_list_domains() {
  command -v jq >/dev/null 2>&1 || { do_log "FATAL jq is not installed"; return 1; }
  do_log "INFO Gandi domains:"
  _gandi_api GET /domain/domains | jq -r '.[] | "\(.fqdn)\t[\(.status // [] | join(","))]"'
}
