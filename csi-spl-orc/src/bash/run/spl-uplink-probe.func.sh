#!/bin/bash
#------------------------------------------------------------------------------
# @description Measure this box's uplink WHILE it is down (a box dropped out of
# @description the fleet 3 times on 2026-10-12; every outage was measured after
# @description the link had healed). One run = ONE sample, at most ~15 s:
# @description   1. ping -c 3 -W 1 -w 4 the default route's gateway -> loss %
# @description   2. getent hosts <hub API host>, under timeout 5
# @description   3. a TCP connect to <hub API host>:443, under timeout 5
# @description appended as one TSV line to <dir>/<box>.tsv:
# @description   <ISO-UTC> gw_loss_pct dns_ok dns_ms tcp_ok tcp_ms iface
# @description dns_ok / tcp_ok are 1 or 0, or `-` when the hub host is unknown
# @description (the cnf could not be read: not a network fault). Samples older
# @description than 7 days are dropped. It only measures: no network change.
# @description The probe exits 0 even with the link down: it never fails its
# @description cron (row uplink-probe of cnf/box-crons/box-crons.manifest).
# @description
# @description UPLINK_PROBE_CMD=report prints the outage windows of the last
# @description UPLINK_PROBE_HOURS: runs of consecutive samples with the gateway
# @description at 100% loss, the DNS lookup failed or the TCP connect failed,
# @description each with its span and which check failed, then the count and
# @description the longest window. This is what an orchestrator reads.
# @description
# @description The hub API host is cnf env.dns.api_fqdn of ENV, the value
# @description do_spl_desk_cnf makes the desk's SPL_HUB_URL from
# @description (lib/bash/funcs/spl-cloud-cnf.func.sh): no literal host here.
# @param UPLINK_PROBE_CMD (optional) - probe (default) | report
# @param UPLINK_PROBE_HOURS (optional) - report: the last N hours, default 24
# @param UPLINK_PROBE_DIR (optional) - default <BOX_CRONS_STATE_DIR or
# @param   /var/csi/csi-spl>/uplink-probe
# @param UPLINK_PROBE_BOX (optional) - default the box id (spl_desk_box_default)
# @param ENV (optional) - dev | prd, the hub to reach; default prd
# @param UPLINK_HUB_HOST (optional) - the host to resolve and connect to,
# @param   instead of the cnf's
# @param UPLINK_PROBE_NOW (optional) - epoch seconds for "now" (tests)
# @param UPLINK_ROUTE_CMD / UPLINK_PING_CMD / UPLINK_GETENT_CMD /
# @param   UPLINK_TCP_CMD (optional) - replace `ip -4 route show default`,
# @param   `ping`, `getent` and the /dev/tcp connect (tests)
# @example ./run -a do_spl_uplink_probe
# @example UPLINK_PROBE_CMD=report ./run -a do_spl_uplink_probe
# @example UPLINK_PROBE_CMD=report UPLINK_PROBE_HOURS=6 UPLINK_PROBE_BOX=<box> ./run -a do_spl_uplink_probe
#------------------------------------------------------------------------------
do_spl_uplink_probe() {
  local cmd="${UPLINK_PROBE_CMD:-probe}" dir box file
  dir="${UPLINK_PROBE_DIR:-${BOX_CRONS_STATE_DIR:-/var/csi/csi-spl}/uplink-probe}"
  box="${UPLINK_PROBE_BOX:-$(spl_desk_box_default)}"
  [[ "$box" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { do_log "FATAL the box id '$box' is not a plain name (set UPLINK_PROBE_BOX)"; return 1; }
  file="$dir/$box.tsv"
  case "$cmd" in
    probe) spl_uplink_sample "$file"; return 0 ;;
    report) spl_uplink_report "$file" "${UPLINK_PROBE_HOURS:-24}" "$box" ;;
    *) do_log "FATAL UPLINK_PROBE_CMD must be probe or report, got: '$cmd'"; return 1 ;;
  esac
}

# spl_uplink_iso <epoch> - prints the epoch as <ISO-UTC> (no fork)
spl_uplink_iso() { TZ=UTC printf '%(%Y-%m-%dT%H:%M:%SZ)T' "$1"; }

# spl_uplink_now - epoch seconds, UPLINK_PROBE_NOW when set
spl_uplink_now() { printf '%s' "${UPLINK_PROBE_NOW:-${EPOCHSECONDS:-$(date +%s)}}"; }

# spl_uplink_ms - a millisecond wall clock (no fork)
spl_uplink_ms() { local t="${EPOCHREALTIME/[.,]/}"; printf '%s' "$((10#$t / 1000))"; }

# spl_uplink_hub_host - the hub API host: UPLINK_HUB_HOST, else cnf
# env.dns.api_fqdn of ENV (default prd). Empty when the cnf cannot be read.
spl_uplink_hub_host() {
  if [[ -n "${UPLINK_HUB_HOST:-}" ]]; then printf '%s' "$UPLINK_HUB_HOST"; return 0; fi
  local e="${ENV:-prd}"
  (
    ENV="$e" do_spl_cloud_cnf >/dev/null 2>&1 || exit 0
    h="$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF" 2>/dev/null)" || exit 0
    [[ "$h" =~ ^[A-Za-z0-9.-]+$ ]] && printf '%s' "$h"
    exit 0
  )
}

# spl_uplink_gateway - prints "<gw> <iface>" of the default route, or nothing.
# The whole route listing is read into a variable first: no pipe, so no
# SIGPIPE under pipefail (m-869's `ip route | awk ... exit` reddened the gate).
spl_uplink_gateway() {
  local out line w prev gw="" dev=""
  out="$(${UPLINK_ROUTE_CMD:-ip -4 route show default} 2>/dev/null)" || true
  while IFS= read -r line; do
    [[ "$line" == default* ]] || continue
    prev=""
    for w in $line; do
      [[ "$prev" == via ]] && gw="$w"
      [[ "$prev" == dev ]] && dev="$w"
      prev="$w"
    done
    [[ -n "$gw" ]] && break
  done <<<"$out"
  [[ -n "$gw" ]] && printf '%s %s' "$gw" "${dev:--}"
  return 0
}

# spl_uplink_sample <file> - takes one sample and appends it; never fails
spl_uplink_sample() {
  local file="$1" gw="" iface="" loss=100 out host dns_ok=- dns_ms=0 tcp_ok=- tcp_ms=0 t0 now ts
  local -a getent tcp
  read -ra getent <<<"${UPLINK_GETENT_CMD:-getent}"
  read -ra tcp <<<"${UPLINK_TCP_CMD:-}"
  # shellcheck disable=SC2016 # $1 and $2 expand in the child bash
  ((${#tcp[@]})) || tcp=(bash -c 'exec 3<>"/dev/tcp/$1/$2"' _)
  read -r gw iface <<<"$(spl_uplink_gateway)"
  [[ -n "$iface" ]] || iface=-
  if [[ -n "$gw" ]]; then
    out="$(${UPLINK_PING_CMD:-ping} -n -q -c 3 -W 1 -w 4 "$gw" 2>&1)" || true
    [[ "$out" =~ ([0-9]+)(\.[0-9]+)?%\ packet\ loss ]] && loss="${BASH_REMATCH[1]}"
  fi
  host="$(spl_uplink_hub_host)"
  if [[ -n "$host" ]]; then
    t0="$(spl_uplink_ms)"
    if timeout 5 "${getent[@]}" hosts "$host" >/dev/null 2>&1; then dns_ok=1; else dns_ok=0; fi
    dns_ms=$(( $(spl_uplink_ms) - t0 ))
    t0="$(spl_uplink_ms)"
    if timeout 5 "${tcp[@]}" "$host" 443 >/dev/null 2>&1; then tcp_ok=1; else tcp_ok=0; fi
    tcp_ms=$(( $(spl_uplink_ms) - t0 ))
  else
    do_log "WARN no hub API host (cnf env.dns.api_fqdn of ENV=${ENV:-prd} unreadable): dns and tcp recorded as -"
  fi
  now="$(spl_uplink_now)"
  ts="$(spl_uplink_iso "$now")"
  mkdir -p "${file%/*}" 2>/dev/null || { do_log "WARN cannot create ${file%/*}: sample not kept"; return 0; }
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$loss" "$dns_ok" "$dns_ms" "$tcp_ok" "$tcp_ms" "$iface" >>"$file" ||
    { do_log "WARN cannot append to $file"; return 0; }
  spl_uplink_trim "$file" "$(spl_uplink_iso $((now - 7 * 86400)))"
  echo "uplink-probe $ts gw_loss=$loss% dns_ok=$dns_ok ${dns_ms}ms tcp_ok=$tcp_ok ${tcp_ms}ms iface=$iface"
  return 0
}

# spl_uplink_trim <file> <cutoff-iso> - drops the samples older than the
# cutoff, only when the first line is older (one line read per sample else)
spl_uplink_trim() {
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

# spl_uplink_report <file> <hours> <box> - the outage windows of the last
# <hours>: runs of consecutive down samples, merged into one window each
spl_uplink_report() {
  local file="$1" hours="$2" box="$3" cut
  [[ "$hours" =~ ^[1-9][0-9]{0,3}$ ]] || { do_log "FATAL UPLINK_PROBE_HOURS must be 1..9999, got: '$hours'"; return 1; }
  [[ -r "$file" ]] || { echo "uplink-probe $box: no samples yet ($file)"; return 0; }
  cut="$(spl_uplink_iso $(($(spl_uplink_now) - hours * 3600)))"
  awk -F'\t' -v cut="$cut" -v hours="$hours" -v box="$box" '
    function close_window() {
      if (!open) return
      n++
      line[n] = sprintf("  %s .. %s  %d samples  gw_down=%d dns_fail=%d tcp_fail=%d", ws, we, wn, wg, wd, wt)
      if (wn > longest) { longest = wn; lws = ws; lwe = we }
      open = 0
    }
    $1 < cut || NF < 7 { next }
    {
      samples++
      down = ($2 == 100 || $3 == "0" || $5 == "0")
      if (!down) { close_window(); next }
      if (!open) { open = 1; ws = $1; wn = 0; wg = 0; wd = 0; wt = 0 }
      we = $1; wn++
      wg += ($2 == 100); wd += ($3 == "0"); wt += ($5 == "0")
    }
    END {
      close_window()
      printf "uplink-probe %s: last %d h, %d samples, %d outage windows", box, hours, samples, n
      if (n) printf ", longest %d samples (%s .. %s)", longest, lws, lwe
      printf "\n"
      for (i = 1; i <= n; i++) print line[i]
    }' "$file"
}
