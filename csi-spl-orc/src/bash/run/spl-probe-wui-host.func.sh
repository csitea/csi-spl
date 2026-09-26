#!/bin/bash
#------------------------------------------------------------------------------
# @description Read-only probe of ONE public WUI host: the apex <fqdn> or a
# @description tenant host <tenant>.<fqdn> (SPL-959, a Firebase custom domain of
# @description the env's site). Checks, one line each ("<check> <PASS|FAIL>
# @description <detail>"):
# @description   dns    the host resolves
# @description   tls    curl verifies the cert for the host (ssl_verify_result 0)
# @description   page   GET / is 200 and is the Nuxt WUI (a /_nuxt/ asset)
# @description   deep   GET <DEEP_PATH> is 200 (the SPA fallback serves a
# @description          deep link on this host too)
# @description   auth   GET /api/v1/auth/providers is 200 JSON (the Firebase
# @description          rewrite reaches the hub from this host)
# @description Exit 0 only when every check passes. No credential, no mutation.
# @param HOST - the host to probe
# @param DEEP_PATH (optional) - default /issues
# @example HOST=acme.dev.example.test ./run -a do_spl_probe_wui_host
#------------------------------------------------------------------------------
do_spl_probe_wui_host() {
  do_require_bin curl || return 1
  local host="${HOST:-}" deep="${DEEP_PATH:-/issues}" fails=0 out code body
  [[ "$host" =~ ^[a-z0-9.-]+$ ]] || { do_log "FATAL HOST must be a DNS name, got: '$host'"; return 1; }
  _wprobe() { printf '%-6s %s %s\n' "$1" "$2" "$3"; [[ "$2" == PASS ]] || fails=$((fails + 1)); }

  out="$(getent hosts "$host" | awk '{print $1}' | tr '\n' ' ')"
  [[ -n "$out" ]] && _wprobe dns PASS "$out" || _wprobe dns FAIL "does not resolve"

  body="$(mktemp)" || return 1
  out="$(curl -sS -o "$body" -w '%{http_code} %{ssl_verify_result}' --max-time 20 "https://$host/" 2>&1)"
  code="${out%% *}"
  [[ "${out##* }" == 0 && "$code" =~ ^[0-9]{3}$ ]] && _wprobe tls PASS "verified" || _wprobe tls FAIL "$out"
  if [[ "$code" == 200 ]] && grep -q '/_nuxt/' "$body"; then _wprobe page PASS "200 WUI"; else _wprobe page FAIL "$code $(head -c 120 "$body" | tr '\n' ' ')"; fi

  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "https://$host$deep" 2>&1)"
  [[ "$code" == 200 ]] && _wprobe deep PASS "$deep 200" || _wprobe deep FAIL "$deep $code"

  out="$(curl -sS -o "$body" -w '%{http_code} %{content_type}' --max-time 20 "https://$host/api/v1/auth/providers" 2>&1)"
  [[ "$out" == "200 application/json"* ]] && _wprobe auth PASS "$out" || _wprobe auth FAIL "$out"
  rm -f "$body"
  [[ $fails == 0 ]] || { do_log "FATAL $host: $fails WUI check(s) failed"; return 1; }
  do_log "OK $host serves the WUI (dns, tls, page, deep link, auth rewrite)"
}
