#!/bin/bash
#------------------------------------------------------------------------------
# @description Measure the X-Forwarded-For chain the deployed hub receives on
# @description one path (spec 017 T012 / FR-SEC-006), so
# @description SPOOL_HUB_TRUSTED_PROXY_HOPS is set from a measurement, never
# @description assumed. Reads GET /v1/debug/client-ip (the hub mounts it when
# @description cnf SPOOL_HUB_CLIENT_IP_PROBE=true; it echoes only the caller's
# @description own chain) PROBE_N times with a spoofed marker entry 192.0.2.1:
# @description every entry right of the marker was appended by a proxy, the
# @description first of them is this caller's address, so hops = the number
# @description of appended entries. Prints `<env> hops=<n> ...` and whether the
# @description deployed hops already key on the caller (current=yes|no).
# @description
# @description PROBE_MODE=spoof-control instead fires PROBE_N GETs at
# @description /api/v1/auth/providers, each with a NEW spoofed entry, and counts
# @description 429s: with SPOOL_HUB_EDGE_AUTH_PER_IP=<L> and the right hops,
# @description PROBE_N > L must yield 429s (the spoof does not move the key).
# @description Read-only against GCP: no gcloud call at all.
# @description Exit: 0 measured (or control held), 3 inconsistent samples or the
# @description control saw no 429, 1 cannot tell (probe off, unreachable, bad cnf).
# @param ENV - required: dev or prd
# @param HUB_URL (optional) - default https://<cnf env.dns.api_fqdn>
# @param PROBE_N (optional) - samples / control requests, default 3
# @param PROBE_MODE (optional) - measure (default) or spoof-control
# @example ENV=dev ./run -a do_spl_probe_client_ip
# @example ENV=dev PROBE_MODE=spoof-control PROBE_N=130 ./run -a do_spl_probe_client_ip
#------------------------------------------------------------------------------
do_spl_probe_client_ip() {
  do_require_bin yq || return 1
  do_require_bin curl || return 1
  do_spl_cloud_cnf || return 1

  local url="${HUB_URL:-}" n="${PROBE_N:-3}" mode="${PROBE_MODE:-measure}"
  if [[ -z "$url" ]]; then
    local api
    api="$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
    [[ -n "$api" && "$api" != null ]] || { do_log "FATAL cnf env.dns.api_fqdn is empty for $ENV; set HUB_URL"; return 1; }
    url="https://$api"
  fi
  url="${url%/}"
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL PROBE_N must be a positive integer, got: $n"; return 1; }

  case "$mode" in
    measure) _spl_probe_measure "$url" "$n" ;;
    spoof-control) _spl_probe_spoof_control "$url" "$n" ;;
    *) do_log "FATAL PROBE_MODE must be measure or spoof-control, got: $mode"; return 1 ;;
  esac
}

_spl_probe_measure() {
  local url="$1" n="$2" marker="192.0.2.1" i body hops first seen="" chain client deployed
  for ((i = 1; i <= n; i++)); do
    body="$(curl -sS -m 15 -H "X-Forwarded-For: $marker" -H 'Cache-Control: no-cache' \
      -w '\n%{http_code}' "$url/v1/debug/client-ip" 2>&1)" || {
      do_log "FATAL $url/v1/debug/client-ip unreachable: $(tail -1 <<<"$body")"; return 1; }
    [[ "$(tail -1 <<<"$body")" == 200 ]] || {
      do_log "FATAL $url/v1/debug/client-ip answered $(tail -1 <<<"$body") (SPOOL_HUB_CLIENT_IP_PROBE off, or an older hub image)"
      return 1; }
    body="$(sed '$d' <<<"$body")"
    chain="$(yq -p json -o json -I0 '.x_forwarded_for' <<<"$body")"
    [[ "$(yq -p json -r '.x_forwarded_for[0] // ""' <<<"$body")" == "$marker" ]] || {
      echo "$ENV inconsistent url=$url sample=$i chain=$chain (the spoofed marker is not the first entry: a proxy rewrote the header)"
      return 3; }
    hops="$(yq -p json -r '.x_forwarded_for | length - 1' <<<"$body")"
    first="$(yq -p json -r '.x_forwarded_for[1] // ""' <<<"$body")"
    client="$(yq -p json -r '.client_ip' <<<"$body")"
    deployed="$(yq -p json -r '.trusted_proxy_hops' <<<"$body")"
    if [[ -n "$seen" && "$seen" != "$hops $first" ]]; then
      echo "$ENV inconsistent url=$url samples disagree: '$seen' vs '$hops $first'"
      return 3
    fi
    seen="$hops $first"
  done
  local current=no
  [[ "$hops" -ge 1 && "$client" == "$first" && "$deployed" == "$hops" ]] && current=yes
  echo "$ENV hops=$hops url=$url n=$n chain=$chain peer=$(yq -p json -r '.peer' <<<"$body") deployed_hops=$deployed current=$current"
}

_spl_probe_spoof_control() {
  local url="$1" n="$2" i code ok=0 limited=0 other=0
  for ((i = 1; i <= n; i++)); do
    code="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' \
      -H "X-Forwarded-For: 192.0.2.$((i % 250 + 1))" "$url/api/v1/auth/providers" 2>/dev/null)" || code=000
    case "$code" in
      429) limited=$((limited + 1)) ;;
      2??|4??) ok=$((ok + 1)) ;;
      *) other=$((other + 1)) ;;
    esac
  done
  if [[ "$limited" -gt 0 ]]; then
    echo "$ENV control=held url=$url n=$n served=$ok limited=$limited other=$other (a rotated spoofed X-Forwarded-For did not escape the per-IP limit)"
    return 0
  fi
  echo "$ENV control=no-429 url=$url n=$n served=$ok limited=0 other=$other (limit off, PROBE_N not above SPOOL_HUB_EDGE_AUTH_PER_IP, or the spoof moved the key)"
  return 3
}
