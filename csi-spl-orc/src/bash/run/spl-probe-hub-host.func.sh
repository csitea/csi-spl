#!/bin/bash
#------------------------------------------------------------------------------
# @description Read-only probe of ONE public hub host (a 032 Cloud Run domain
# @description mapping: env.dns.api_fqdn or <tenant>.<fqdn>): which DNS it
# @description resolves to, the TLS cert it serves (subject/issuer, so a
# @description default edge cert is visible), GET /version, /v1/health, and a
# @description real WebSocket upgrade (RFC 6455, HTTP/1.1) on /v1/ws (box) and
# @description /v1/wui/ws (WUI). A 101 means the upgrade crossed the mapping and
# @description reached the hub; the box/WUI auth that follows is the m3 e2e's.
# @description One line per check, "<check> <PASS|FAIL> <detail>"; exit 0 only
# @description when every check passes. No credential, no mutation.
# @param HOST - the host to probe (e.g. the env's api_fqdn)
# @param EXPECT_COMMIT (optional) - /version must contain this commit prefix
# @param WS_OK (optional) - statuses accepted on /v1/ws (default "101"). The
# @param   box WS is tenant-scoped by Host: on the api host the hub answers 404
# @param   unknown_tenant, so probe the api host with WS_OK=404
# @param WUI_WS_OK (optional) - space-separated statuses accepted on /v1/wui/ws
# @param   without a session (default "101 401 403"): the hub may refuse before
# @param   the upgrade, which still proves the path reaches it
# @example HOST=dev.api.example.test ./run -a do_spl_probe_hub_host
#------------------------------------------------------------------------------
do_spl_probe_hub_host() {
  do_require_bin curl || return 1
  local host="${HOST:-}" fails=0 out code
  [[ "$host" =~ ^[a-z0-9.-]+$ ]] || { do_log "FATAL HOST must be a DNS name, got: '$host'"; return 1; }
  local wui_ok="${WUI_WS_OK:-101 401 403}"
  _probe() { printf '%-14s %s %s\n' "$1" "$2" "$3"; [[ "$2" == PASS ]] || fails=$((fails + 1)); }

  out="$(getent hosts "$host" | awk '{print $1}' | tr '\n' ' ')"
  local cname
  cname="$(command -v dig >/dev/null && dig +short CNAME "$host" | head -1)"
  [[ -n "$out" ]] && _probe dns PASS "${cname:+$cname }$out" || _probe dns FAIL "does not resolve"

  if command -v openssl >/dev/null; then
    local pem sans
    pem="$(echo | timeout 15 openssl s_client -connect "$host:443" -servername "$host" 2>/dev/null)"
    out="$(openssl x509 -noout -subject -issuer -enddate <<<"$pem" 2>/dev/null | tr '\n' ' ')"
    sans="$(openssl x509 -noout -ext subjectAltName <<<"$pem" 2>/dev/null | tr ',' '\n' | sed -n 's/^ *DNS://p' | tr '\n' ' ')"
    if [[ " $sans " == *" $host "* || " $sans " == *" *.${host#*.} "* ]]; then
      _probe tls PASS "$out SAN: $sans"
    else
      _probe tls FAIL "${out:-no certificate} SAN: ${sans:-none}"
    fi
  fi

  out="$(curl -sS -m 15 "https://$host/version" 2>&1)"
  if [[ "$out" == *'"commit"'* && ( -z "${EXPECT_COMMIT:-}" || "$out" == *"$EXPECT_COMMIT"* ) ]]; then
    _probe version PASS "$out"
  else
    _probe version FAIL "${out:0:200}"
  fi

  code="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "https://$host/v1/health" 2>/dev/null)"
  [[ "$code" == 200 ]] && _probe health PASS "/v1/health $code" || _probe health FAIL "/v1/health ${code:-none}"

  local key p want
  key="$(head -c 16 /dev/urandom | base64)"
  for p in /v1/ws /v1/wui/ws; do
    code="$(curl -sS -m 10 --http1.1 -o /dev/null -w '%{http_code}' \
      -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
      -H "Sec-WebSocket-Key: $key" "https://$host$p" 2>/dev/null)"
    [[ "$p" == /v1/ws ]] && want="${WS_OK:-101}" || want="$wui_ok"
    if [[ " $want " == *" $code "* ]]; then
      _probe "ws $p" PASS "$code"
    else
      _probe "ws $p" FAIL "${code:-none} (want one of: $want)"
    fi
  done

  if [[ $fails == 0 ]]; then
    do_log "OK hub host $host: dns, tls, /version, /v1/health and the ws upgrades all pass"
    return 0
  fi
  do_log "FATAL hub host $host: $fails check(s) failed"
  return 1
}
