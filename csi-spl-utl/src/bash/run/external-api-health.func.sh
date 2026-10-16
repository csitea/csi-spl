#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Reliability round row 04 (rel-04, SPL-2232, Refs: SPL-2114):
# @description probe the outbound reachability of the external model and code
# @description APIs this box's lanes need, between the full login probes. A
# @description DNS glitch, a TLS block or a routing drop to one vendor made
# @description freshly spawned lanes fail with nothing recording why.
# @description
# @description Each endpoint of cnf env.box.external_api_check.endpoints is
# @description probed in parallel, payload-free, every step under timeout_s:
# @description   1. getent hosts <host>                        -> dns_ok dns_ms
# @description   2. a TCP connect to <host>:<port>             -> tcp_ok tcp_ms
# @description   3. a TLS handshake with SNI, cert verified    -> tls_ok tls_ms
# @description A failed step skips the next ones (recorded as `-`), so an
# @description endpoint behind a blackhole route is reported within one
# @description timeout_s. One TSV line per endpoint is appended next to the
# @description uplink probe's samples, in its format (ISO-UTC first, 1/0/-,
# @description milliseconds, 7 days kept):
# @description   <dir>/<box>.external-api.tsv
# @description   <ISO-UTC> name host port dns_ok dns_ms tcp_ok tcp_ms tls_ok tls_ms
# @description It is REPORT-ONLY: it changes nothing and exits 0 with an
# @description endpoint down (it prints a WARN line per down endpoint), so it
# @description can share the uplink probe's cron schedule.
# @param EXTERNAL_API_ENDPOINTS (optional) - "name=host:port ...", instead of the cnf
# @param EXTERNAL_API_TIMEOUT (optional) - seconds per step, default cnf timeout_s, else 5
# @param EXTERNAL_API_CNF (optional) - default ../<org-app>-cnf/<org-app>/all.env.yaml
# @param EXTERNAL_API_DIR (optional) - default <UPLINK_PROBE_DIR or
# @param   BOX_CRONS_STATE_DIR or /var/csi/csi-spl>/uplink-probe
# @param EXTERNAL_API_BOX (optional) - default UPLINK_PROBE_BOX, else the short hostname
# @param EXTERNAL_API_NOW (optional) - epoch seconds for "now" (tests)
# @param EXTERNAL_API_GETENT_CMD / EXTERNAL_API_TCP_CMD / EXTERNAL_API_TLS_CMD
# @param   (optional) - replace `getent`, the /dev/tcp connect and the
# @param   `openssl s_client` handshake; called with hosts <host> (getent)
# @param   or <host> <port> (tests)
# @example ./run -a do_net_external_api_check
# @example EXTERNAL_API_ENDPOINTS="github=api.github.com:443" ./run -a do_net_external_api_check
#------------------------------------------------------------------------------
type do_log &>/dev/null || do_log() { echo "$*"; }

do_net_external_api_check() {
  local cnf oa tmo eps dir box file now ts cut down=0 n=0 t0 t1 ep i tmp
  local name host port dnsok dnsms tcpok tcpms tlsok tlsms
  local -a list pids
  oa="$(basename "${PROJ_PATH:-csi-spl-utl}")"; oa="${oa%-utl}"
  cnf="${EXTERNAL_API_CNF:-${PROJ_PATH:-.}/../$oa-cnf/$oa/all.env.yaml}"
  tmo="${EXTERNAL_API_TIMEOUT:-}"
  eps="${EXTERNAL_API_ENDPOINTS:-}"
  if [[ -r "$cnf" ]] && command -v yq >/dev/null 2>&1; then
    [[ -n "$tmo" ]] || tmo="$(yq -r '.env.box.external_api_check.timeout_s // ""' "$cnf" 2>/dev/null)"
    [[ -n "$eps" ]] || eps="$(yq -r '.env.box.external_api_check.endpoints[]? | .name + "=" + .host + ":" + (.port | tostring)' "$cnf" 2>/dev/null | tr '\n' ' ')"
  fi
  tmo="${tmo:-5}"
  [[ "$tmo" =~ ^[1-9][0-9]?$ ]] || { do_log "FATAL EXTERNAL_API_TIMEOUT must be 1..99 seconds, got: '$tmo'"; return 1; }
  read -ra list <<<"$eps"
  ((${#list[@]})) || { do_log "FATAL no endpoints: set cnf env.box.external_api_check.endpoints ($cnf) or EXTERNAL_API_ENDPOINTS"; return 1; }
  for ep in "${list[@]}"; do
    [[ "$ep" =~ ^[a-z0-9-]+=[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] || { do_log "FATAL endpoint '$ep' is not name=host:port"; return 1; }
  done
  dir="${EXTERNAL_API_DIR:-${UPLINK_PROBE_DIR:-${BOX_CRONS_STATE_DIR:-/var/csi/csi-spl}/uplink-probe}}"
  box="${EXTERNAL_API_BOX:-${UPLINK_PROBE_BOX:-$(hostname -s 2>/dev/null)}}"
  [[ "$box" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { do_log "FATAL the box id '$box' is not a plain name (set EXTERNAL_API_BOX)"; return 1; }
  file="$dir/$box.external-api.tsv"
  now="${EXTERNAL_API_NOW:-${EPOCHSECONDS:-$(date +%s)}}"
  ts="$(TZ=UTC printf '%(%Y-%m-%dT%H:%M:%SZ)T' "$now")"
  tmp="$(mktemp -d)" || { do_log "WARN cannot make a temp dir: no sample"; return 0; }
  t0="$(ext_api_ms)"
  for i in "${!list[@]}"; do
    ext_api_probe "${list[$i]}" "$tmo" >"$tmp/$i" &
    pids+=($!)
  done
  wait "${pids[@]}" 2>/dev/null
  t1="$(ext_api_ms)"
  mkdir -p "$dir" 2>/dev/null || do_log "WARN cannot create $dir: samples not kept"
  for i in "${!list[@]}"; do
    IFS=$'\t' read -r name host port dnsok dnsms tcpok tcpms tlsok tlsms <"$tmp/$i" || continue
    n=$((n + 1))
    if [[ -d "$dir" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$name" "$host" "$port" "$dnsok" "$dnsms" "$tcpok" "$tcpms" "$tlsok" "$tlsms" >>"$file" 2>/dev/null ||
        do_log "WARN cannot append to $file"
    fi
    if [[ "$tlsok" == 1 ]]; then
      echo "external-api $ts $name $host:$port ok dns=${dnsms}ms tcp=${tcpms}ms tls=${tlsms}ms"
    else
      down=$((down + 1))
      do_log "WARN external-api $ts $name $host:$port DOWN dns_ok=$dnsok tcp_ok=$tcpok tls_ok=$tlsok (dns=${dnsms}ms tcp=${tcpms}ms tls=${tlsms}ms)"
    fi
  done
  rm -rf "$tmp"
  if [[ -f "$file" ]]; then
    cut="$(TZ=UTC printf '%(%Y-%m-%dT%H:%M:%SZ)T' $((now - 7 * 86400)))"
    ext_api_trim "$file" "$cut"
  fi
  echo "external-api $ts box=$box endpoints=$n down=$down wall=$((t1 - t0))ms file=$file"
  return 0
}

# do_external_api_health - the file-name alias run.sh derives for this file
do_external_api_health() { do_net_external_api_check "$@"; }

# ext_api_ms - a millisecond wall clock (no fork)
ext_api_ms() { local t="${EPOCHREALTIME/[.,]/}"; printf '%s' "$((10#$t / 1000))"; }

# ext_api_probe <name=host:port> <timeout> - prints one TSV row:
# name host port dns_ok dns_ms tcp_ok tcp_ms tls_ok tls_ms
ext_api_probe() {
  local ep="$1" tmo="$2" name host port t0 dnsok=0 dnsms=0 tcpok=- tcpms=0 tlsok=- tlsms=0
  local -a getent tcp tls
  name="${ep%%=*}"; host="${ep#*=}"; port="${host##*:}"; host="${host%:*}"
  read -ra getent <<<"${EXTERNAL_API_GETENT_CMD:-getent}"
  read -ra tcp <<<"${EXTERNAL_API_TCP_CMD:-}"
  read -ra tls <<<"${EXTERNAL_API_TLS_CMD:-}"
  # shellcheck disable=SC2016 # $1 and $2 expand in the child bash
  ((${#tcp[@]})) || tcp=(bash -c 'exec 3<>"/dev/tcp/$1/$2"' _)
  # shellcheck disable=SC2016 # $1 and $2 expand in the child bash
  ((${#tls[@]})) || tls=(bash -c 'openssl s_client -connect "$1:$2" -servername "$1" -verify_return_error -brief </dev/null' _)
  t0="$(ext_api_ms)"
  timeout "$tmo" "${getent[@]}" hosts "$host" >/dev/null 2>&1 && dnsok=1
  dnsms=$(( $(ext_api_ms) - t0 ))
  if [[ "$dnsok" == 1 ]]; then
    tcpok=0; t0="$(ext_api_ms)"
    timeout "$tmo" "${tcp[@]}" "$host" "$port" >/dev/null 2>&1 && tcpok=1
    tcpms=$(( $(ext_api_ms) - t0 ))
  fi
  if [[ "$tcpok" == 1 ]]; then
    tlsok=0; t0="$(ext_api_ms)"
    timeout "$tmo" "${tls[@]}" "$host" "$port" >/dev/null 2>&1 && tlsok=1
    tlsms=$(( $(ext_api_ms) - t0 ))
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$host" "$port" "$dnsok" "$dnsms" "$tcpok" "$tcpms" "$tlsok" "$tlsms"
}

# ext_api_trim <file> <cutoff-iso> - drops the samples older than the cutoff,
# only when the first line is older
ext_api_trim() {
  local file="$1" cut="$2" first=""
  IFS=$'\t' read -r first _ <"$file" || return 0
  [[ "$first" < "$cut" ]] || return 0
  if awk -F'\t' -v cut="$cut" '$1 >= cut' "$file" >"$file.tmp.$$"; then
    mv -f "$file.tmp.$$" "$file" || do_log "WARN cannot trim $file"
  else
    rm -f "$file.tmp.$$"; do_log "WARN cannot trim $file"
  fi
  return 0
}

# Register the row's action name with run.sh's function map when sourced
if declare -p _func_to_file &>/dev/null; then
  _func_to_file["do_net_external_api_check"]="${BASH_SOURCE[0]}"
fi
