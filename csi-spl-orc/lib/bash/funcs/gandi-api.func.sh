#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Shared Gandi API v5 helpers (token + curl). Not actions (no do_ prefix).
#
# Morph of dob-luk-iac lib/bash/funcs/gandi-api.func.sh for spool orc
# (007 T014 follow-up): public DNS is Gandi LiveDNS, not Cloud DNS.
# Domain: $DOMAIN, else cnf env.dns.BASE_DOMAIN (never a hostname literal).
#
# Auth: $GANDI_PAT -> $GANDI_TOKEN -> $HOME/.gandi/.<org>/token (mode 600).
# org is cnf env.ORG or $ORG. Never hardcode a token.
# GANDI_AUTH_SCHEME default Bearer; GANDI_API_BASE overridable.
#------------------------------------------------------------------------------

_gandi_cnf_all() {
  printf '%s' "${APP_PATH:?APP_PATH is not set}/csi-spl-cnf/csi-spl/all.env.yaml"
}

_gandi_org() {
  local org="${ORG:-}" f
  if [[ -z "$org" && -n "${APP_PATH:-}" ]]; then
    f="${APP_PATH}/csi-spl-cnf/csi-spl/dev.env.yaml"
    [[ -f "$f" ]] && org=$(yq -r '.env.ORG // ""' "$f" 2>/dev/null) || true
  fi
  if [[ -z "$org" || "$org" == null ]]; then
    do_log "FATAL ORG is empty (set ORG or cnf env.ORG)" >&2
    return 1
  fi
  printf '%s' "$org"
}

_gandi_token() {
  local org tok f
  org="$(_gandi_org)" || return 1
  tok="${GANDI_PAT:-${GANDI_TOKEN:-}}"
  if [[ -z "$tok" ]]; then
    f="${HOME}/.gandi/.${org}/token"
    [[ -f "$f" ]] && tok="$(tr -d ' \t\r\n' < "$f")"
  fi
  if [[ -z "$tok" ]]; then
    do_log "FATAL no Gandi API token. Set GANDI_PAT, or write a Personal Access Token to ~/.gandi/.${org}/token (chmod 600)." >&2
    return 1
  fi
  printf '%s' "$tok"
}

# $DOMAIN wins; else cnf env.dns.BASE_DOMAIN (the single source).
_gandi_domain() {
  local d="${DOMAIN:-}" cnf
  if [[ -n "$d" && "$d" != null ]]; then
    printf '%s' "$d"
    return 0
  fi
  cnf="$(_gandi_cnf_all)"
  [[ -f "$cnf" ]] || { do_log "FATAL missing $cnf (APP_PATH=${APP_PATH:-unset})" >&2; return 1; }
  d=$(yq -r '.env.dns.BASE_DOMAIN // ""' "$cnf")
  [[ -n "$d" && "$d" != null && "$d" == *.* ]] || {
    do_log "FATAL set DOMAIN or env.dns.BASE_DOMAIN in $cnf" >&2
    return 1
  }
  printf '%s' "$d"
}

# usage: _gandi_api <METHOD> <path> [json_body]  (path starts with /)
# GANDI_MAX_TIME bounds --max-time (default 30). A timeout returns curl exit 28.
_gandi_api() {
  local method="$1" path="$2" body="${3:-}"
  local base="${GANDI_API_BASE:-https://api.gandi.net/v5}"
  local scheme="${GANDI_AUTH_SCHEME:-Bearer}"
  local tok
  command -v curl >/dev/null 2>&1 || { do_log "FATAL curl is not installed" >&2; return 1; }
  tok="$(_gandi_token)" || return 1
  local -a args=(-sS --connect-timeout 10 --max-time "${GANDI_MAX_TIME:-30}" -X "$method" -H "Authorization: ${scheme} ${tok}" -H "Accept: application/json")
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" -d "$body")
  curl "${args[@]}" "${base}${path}"
}
