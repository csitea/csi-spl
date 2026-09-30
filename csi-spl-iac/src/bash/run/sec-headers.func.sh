#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Security-headers check against a deployed environment (default the
# @description dev hub). Verifies the response carries HSTS, X-Content-Type-
# @description Options, Referrer-Policy and a frame/CSP control. Runs a negative
# @description control first: a local mock that omits headers MUST be flagged. A
# @description check that passes the mock proves nothing and the action fails
# @description closed. Read-only, one request (well under the 5 req/s dev cap).
# @param SEC_HEADERS_URL (optional) - target; default the dev WUI host derived
# @param        from cnf: https://<env.dns.env_subdomain>.<env.dns.BASE_DOMAIN>
# @param        (csi-spl-cnf/csi-spl/all.env.yaml), so no host literal lives here.
# @param SEC_HEADERS_SKIP_SCAN (optional) - 1 to run only the control (local dev)
# @example SEC_HEADERS_URL=https://dev.<host> ./run -a do_sec_headers
#------------------------------------------------------------------------------

_SEC_HEADERS_REQUIRED=(
  "strict-transport-security"
  "x-content-type-options"
  "referrer-policy"
)
# At least one framing/embedding control:
_SEC_HEADERS_FRAME_ANY=("content-security-policy" "x-frame-options")

_sec_headers_need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  do_log "FATAL $1 is not on PATH -- the check proved nothing"
  return 1
}

# The dev WUI host, derived from cnf so the domain literal lives ONLY in
# csi-spl-cnf (env.dns.BASE_DOMAIN). Convention: dev serves dev.<BASE_DOMAIN>.
# Prints the https URL, or nothing if cnf cannot be read.
_sec_headers_default_url() {
  local base="${APP_PATH:-}" cnf="" dom
  for cnf in "$base/../csi-spl-cnf/csi-spl/all.env.yaml" \
             "$base/csi-spl-cnf/csi-spl/all.env.yaml" \
             "${SEC_HEADERS_CNF:-}"; do
    [[ -n "$cnf" && -f "$cnf" ]] || continue
    if command -v yq >/dev/null 2>&1; then
      dom=$(yq -r '.env.dns.BASE_DOMAIN // ""' "$cnf" 2>/dev/null)
    fi
    [[ -z "${dom:-}" ]] && dom=$(sed -n 's/^[[:space:]]*BASE_DOMAIN:[[:space:]]*//p' "$cnf" | head -1 | tr -d '"'"'"' ')
    [[ -n "${dom:-}" ]] && { printf 'https://dev.%s\n' "$dom"; return 0; }
  done
  return 1
}

# Print the missing required headers for a URL (empty = all present). Echoes
# "UNREACHABLE" if the endpoint could not be fetched.
_sec_headers_missing() {
  local url="$1" hdrs miss=() h
  hdrs=$(curl -sS -I -L --max-time 20 "$url" 2>/dev/null | tr 'A-Z' 'a-z') || true
  if [[ -z "$hdrs" ]]; then printf 'UNREACHABLE\n'; return 0; fi
  for h in "${_SEC_HEADERS_REQUIRED[@]}"; do
    grep -qi "^$h:" <<<"$hdrs" || miss+=("$h")
  done
  local any=0 f
  for f in "${_SEC_HEADERS_FRAME_ANY[@]}"; do grep -qi "^$f:" <<<"$hdrs" && any=1; done
  [[ "$any" -eq 0 ]] && miss+=("content-security-policy|x-frame-options")
  printf '%s\n' "${miss[@]}"
}

# A local server that returns only one of the required headers, so the check must
# report the rest as missing. Prints "PORT PID SCRIPT".
_sec_headers_mock() {
  local port script
  port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
  script=$(mktemp --suffix=.py)
  cat >"$script" <<'PY'
import sys,http.server
port=int(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(200)
        self.send_header("X-Content-Type-Options","nosniff")
        self.end_headers()
    def do_GET(self): self.do_HEAD()
    def log_message(self,*a): pass
http.server.HTTPServer(("127.0.0.1",port),H).serve_forever()
PY
  python3 "$script" "$port" >/dev/null 2>&1 &
  printf '%s %s %s\n' "$port" "$!" "$script"
}

do_sec_headers() {
  _sec_headers_need curl || return 1
  _sec_headers_need python3 || return 1

  # --- control: a mock omitting headers must be flagged ----------------------
  local pm port pid script
  pm=$(_sec_headers_mock); read -r port pid script <<<"$pm"
  sleep 1
  local cmiss
  cmiss=$(_sec_headers_missing "http://127.0.0.1:$port")
  kill "$pid" >/dev/null 2>&1 || true
  rm -f "$script"
  if [[ -z "$cmiss" || "$cmiss" == "UNREACHABLE" ]]; then
    do_log "FATAL control: the check did not flag a header-less mock -- it proves nothing"
    return 1
  fi
  do_log "INFO security-headers control flagged the mock's missing headers"

  if [[ "${SEC_HEADERS_SKIP_SCAN:-0}" == 1 ]]; then
    do_log "INFO SEC_HEADERS_SKIP_SCAN=1 -- control only (no live request)"
    return 0
  fi

  # The scan target (only needed here): explicit SEC_HEADERS_URL or the dev host
  # derived from cnf, so no host literal lives in this action.
  local url="${SEC_HEADERS_URL:-$(_sec_headers_default_url)}"
  if [[ -z "$url" ]]; then
    do_log "FATAL no SEC_HEADERS_URL and could not derive the dev host from cnf (env.dns.BASE_DOMAIN)"
    return 1
  fi

  # --- scan: the deployed target --------------------------------------------
  do_log "INFO security-headers scan of $url (read-only, one request)"
  local miss
  miss=$(_sec_headers_missing "$url")
  if [[ "$miss" == "UNREACHABLE" ]]; then
    do_log "FATAL $url could not be fetched -- the header gate could not verify (fail closed)"
    return 1
  fi
  if [[ -z "$miss" ]]; then
    do_log "INFO security-headers: all required headers present on $url"
    return 0
  fi
  do_log "FATAL security-headers: missing on $url:"
  printf '%s\n' "$miss" | sed 's/^/  /'
  return 1
}
