#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Verify the Gandi API token by listing the account's domains.
# @description Fails fast when no token is present.
# @example ./run -a do_gandi_check_creds
#------------------------------------------------------------------------------
do_gandi_check_creds() {
  do_log "INFO checking Gandi API credentials"
  command -v jq >/dev/null 2>&1 || { do_log "FATAL jq is not installed"; return 1; }
  local out
  out="$(_gandi_api GET /domain/domains)" || return 1
  if echo "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
    do_log "OK Gandi token valid — $(echo "$out" | jq -r 'length') domain(s) visible"
  else
    do_log "ERROR Gandi auth failed: $(echo "$out" | jq -rc '.' 2>/dev/null || echo "$out")"
    return 1
  fi
}
