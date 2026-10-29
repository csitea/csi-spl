#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Reliability round row 03 (rel-03, SPL-2231, Refs: SPL-2114):
# @description the expiry of the public HTTPS certificates. An auto-renewal
# @description that fails silently drops the public API and the WUI with no
# @description warning; this check gives three weeks of it.
# @description
# @description The hosts are derived from the cnf, never written here: for each
# @description env of CERT_EXPIRY_ENVS (default "dev prd"), with
# @description sub = env.dns.env_subdomain of <env>.env.yaml and
# @description B = env.dns.BASE_DOMAIN of all.env.yaml:
# @description   [<sub>.]api.<B>   (env.dns.api_fqdn, the hub)
# @description   [<sub>.]<B>       (the env fqdn, the WUI)
# @description Each host's certificate is fetched in parallel (one timeout for
# @description all), then judged by `openssl x509 -checkend`:
# @description   -checkend 604800  fails (<= 7 d)  -> CRITICAL
# @description   -checkend 1814400 fails (<= 21 d) -> WARNING
# @description   else                              -> OK
# @description and the days remaining are printed from `openssl x509 -enddate`
# @description (whole days, rounded down). One line per host:
# @description   cert-expiry <host> <OK|WARNING|CRITICAL|ERROR> days=<n> notAfter=<date>
# @description
# @description ALERT OR REPORT ONLY. A WARNING / CRITICAL / ERROR host sends ONE
# @description spool note to the orchestrator, only with DRY_RUN=0 (default 1
# @description prints the plan), throttled per host by a state stamp: a host
# @description alerts again when its level changes or after
# @description CERT_EXPIRY_THROTTLE_S (default 86400). An OK host clears its
# @description stamp. Every alert goes through CERT_EXPIRY_SEND_CMD when set
# @description (tests stub it); only the real run resolves spool-send.sh.
# @description Exit 0 whatever the certificates say (cron-friendly); 1 only on
# @description a usage or cnf error.
# @param CERT_EXPIRY_HOSTS (optional) - space-separated hosts, instead of the cnf
# @param CERT_EXPIRY_ENVS (optional) - envs whose hosts are derived, default "dev prd"
# @param CERT_EXPIRY_CNF_DIR (optional) - default ../<org-app>-cnf/<org-app>
# @param CERT_EXPIRY_TIMEOUT (optional) - seconds per fetch, default 5
# @param CERT_EXPIRY_WARN_S / CERT_EXPIRY_CRIT_S (optional) - default 1814400 / 604800
# @param CERT_EXPIRY_FETCH_CMD (optional) - prints the PEM of <host> (tests);
# @param   default openssl s_client -connect <host>:443 -servername <host>
# @param CERT_EXPIRY_STATE_DIR (optional) - default <SPL_STATE_DIR or
# @param   $HOME/.local/state/csi-spl>/cert-expiry
# @param CERT_EXPIRY_THROTTLE_S (optional) - default 86400
# @param CERT_EXPIRY_SEND_CMD (optional) - the sender, called with
# @param   --from <id> --to <id> --kind note --task <task> --body <text>;
# @param   default bash <repo>/csi-spl-orc/.../spawn-agents/scripts/spool-send.sh
# @param CERT_EXPIRY_ALERT_TO / _FROM / _TASK (optional) - default orchestrator /
# @param   $SPOOL_AGENT_ID or cert-expiry-check@<box> / cert-expiry
# @param DRY_RUN (optional) - 1 (default) plans the alerts; 0 sends them
# @example ./run -a do_net_cert_expiry_check
# @example CERT_EXPIRY_HOSTS="api.example.com" ./run -a do_net_cert_expiry_check
#------------------------------------------------------------------------------
type do_log &>/dev/null || do_log() { echo "$*"; }

# spl_box_name: the box name from the config, never the hostname (SPL-4201)
declare -F spl_box_name >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../../csi-spl-orc/lib/bash/funcs/spl-desk-box.func.sh"

do_net_cert_expiry_check() {
  local warn_s="${CERT_EXPIRY_WARN_S:-1814400}" crit_s="${CERT_EXPIRY_CRIT_S:-604800}"
  local tmo="${CERT_EXPIRY_TIMEOUT:-5}" dry="${DRY_RUN:-1}" hosts tmp i host level days end
  local n=0 bad=0 t0 t1
  local -a list pids
  command -v openssl >/dev/null 2>&1 || { do_log "FATAL openssl is not on PATH"; return 1; }
  [[ "$tmo" =~ ^[1-9][0-9]?$ ]] || { do_log "FATAL CERT_EXPIRY_TIMEOUT must be 1..99 seconds, got: '$tmo'"; return 1; }
  [[ "$warn_s" =~ ^[0-9]+$ && "$crit_s" =~ ^[0-9]+$ ]] || { do_log "FATAL CERT_EXPIRY_WARN_S / _CRIT_S must be seconds"; return 1; }
  hosts="${CERT_EXPIRY_HOSTS:-}"
  [[ -n "$hosts" ]] || hosts="$(cert_expiry_cnf_hosts)" || return 1
  read -ra list <<<"$hosts"
  ((${#list[@]})) || { do_log "FATAL no hosts: set CERT_EXPIRY_HOSTS or the cnf env.dns.BASE_DOMAIN"; return 1; }
  for host in "${list[@]}"; do
    [[ "$host" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || { do_log "FATAL host '$host' is not a DNS name"; return 1; }
  done

  tmp="$(mktemp -d)" || { do_log "FATAL cannot make a temp dir"; return 1; }
  t0="$(cert_expiry_ms)"
  for i in "${!list[@]}"; do
    cert_expiry_fetch "${list[$i]}" "$tmo" >"$tmp/$i.pem" 2>/dev/null &
    pids+=($!)
  done
  wait "${pids[@]}" 2>/dev/null
  t1="$(cert_expiry_ms)"

  for i in "${!list[@]}"; do
    host="${list[$i]}"; n=$((n + 1))
    read -r level days end < <(cert_expiry_judge "$tmp/$i.pem" "$warn_s" "$crit_s")
    if [[ "$level" == OK ]]; then
      echo "cert-expiry $host OK days=$days notAfter=$end"
      cert_expiry_clear "$host" "$dry"
    else
      bad=$((bad + 1))
      do_log "WARN cert-expiry $host $level days=$days notAfter=$end"
      cert_expiry_alert "$host" "$level" "$days" "$end" "$dry"
    fi
  done
  rm -rf "$tmp"
  echo "cert-expiry hosts=$n not_ok=$bad wall=$((t1 - t0))ms warn<=$((warn_s / 86400))d crit<=$((crit_s / 86400))d"
  return 0
}

# cert_expiry_cnf_hosts - prints the hosts derived from the cnf (see the header);
# its FATAL lines go to stderr, as its stdout is the host list
cert_expiry_cnf_hosts() {
  local oa dir base env sub out=""
  oa="$(basename "${PROJ_PATH:-csi-spl-utl}")"; oa="${oa%-utl}"
  dir="${CERT_EXPIRY_CNF_DIR:-${PROJ_PATH:-.}/../$oa-cnf/$oa}"
  command -v yq >/dev/null 2>&1 || { do_log "FATAL yq is not on PATH: set CERT_EXPIRY_HOSTS" >&2; return 1; }
  [[ -r "$dir/all.env.yaml" ]] || { do_log "FATAL no cnf at $dir/all.env.yaml: set CERT_EXPIRY_CNF_DIR or CERT_EXPIRY_HOSTS" >&2; return 1; }
  base="$(yq -r '.env.dns.BASE_DOMAIN // ""' "$dir/all.env.yaml" 2>/dev/null)"
  [[ -n "$base" ]] || { do_log "FATAL env.dns.BASE_DOMAIN is empty in $dir/all.env.yaml" >&2; return 1; }
  for env in ${CERT_EXPIRY_ENVS:-dev prd}; do
    [[ -r "$dir/$env.env.yaml" ]] || { do_log "FATAL no cnf at $dir/$env.env.yaml" >&2; return 1; }
    sub="$(yq -r '.env.dns.env_subdomain // ""' "$dir/$env.env.yaml" 2>/dev/null)"
    out+="${sub:+$sub.}api.$base ${sub:+$sub.}$base "
  done
  echo "$out"
}

# cert_expiry_fetch <host> <timeout> - prints the PEM the host serves on 443
cert_expiry_fetch() {
  local host="$1" tmo="$2"
  local -a cmd
  read -ra cmd <<<"${CERT_EXPIRY_FETCH_CMD:-}"
  if ((${#cmd[@]})); then
    timeout "$tmo" "${cmd[@]}" "$host"
  else
    timeout "$tmo" openssl s_client -connect "$host:443" -servername "$host" </dev/null 2>/dev/null |
      openssl x509 2>/dev/null
  fi
}

# cert_expiry_judge <pem-file> <warn_s> <crit_s> - prints "<level> <days> <notAfter>"
# (the date with _ for blanks, so it stays one field)
cert_expiry_judge() {
  local pem="$1" warn_s="$2" crit_s="$3" end ep now days level=OK
  end="$(openssl x509 -noout -enddate -in "$pem" 2>/dev/null)"; end="${end#notAfter=}"
  ep="$(date -u -d "$end" +%s 2>/dev/null)"
  if [[ -z "$end" || -z "$ep" ]]; then
    echo "ERROR - no-certificate"
    return 0
  fi
  now="${EPOCHSECONDS:-$(date +%s)}"
  days=$(( (ep - now) / 86400 ))
  (( ep < now )) && days=$(( -((now - ep + 86399) / 86400) ))
  if ! openssl x509 -noout -checkend "$crit_s" -in "$pem" >/dev/null 2>&1; then
    level=CRITICAL
  elif ! openssl x509 -noout -checkend "$warn_s" -in "$pem" >/dev/null 2>&1; then
    level=WARNING
  fi
  echo "$level $days ${end// /_}"
}

# cert_expiry_stamp <host> - the throttle stamp path of a host
cert_expiry_stamp() {
  echo "${CERT_EXPIRY_STATE_DIR:-${SPL_STATE_DIR:-$HOME/.local/state/csi-spl}/cert-expiry}/$1.stamp"
}

# cert_expiry_clear <host> <dry> - an OK host forgets its last alert (real run only)
cert_expiry_clear() {
  local stamp; stamp="$(cert_expiry_stamp "$1")"
  [[ "$2" == 0 && -f "$stamp" ]] && rm -f "$stamp"
  return 0
}

# cert_expiry_alert <host> <level> <days> <notAfter> <dry> - one throttled note
cert_expiry_alert() {
  local host="$1" level="$2" days="$3" end="$4" dry="$5" stamp prev="" at=0 now box body from
  local to="${CERT_EXPIRY_ALERT_TO:-orchestrator}" task="${CERT_EXPIRY_ALERT_TASK:-cert-expiry}"
  local throttle="${CERT_EXPIRY_THROTTLE_S:-86400}"
  local -a send
  box="$(spl_box_name)"
  from="${CERT_EXPIRY_ALERT_FROM:-${SPOOL_AGENT_ID:-cert-expiry-check@$box}}"
  stamp="$(cert_expiry_stamp "$host")"
  now="${EPOCHSECONDS:-$(date +%s)}"
  [[ -f "$stamp" ]] && read -r prev at <"$stamp"
  [[ "$at" =~ ^[0-9]+$ ]] || at=0
  if [[ "$prev" == "$level" ]] && (( now - at < throttle )); then
    do_log "INFO cert-expiry $host $level alert throttled by $stamp"
    return 0
  fi
  body="cert-expiry $level: the TLS certificate of $host expires in $days day(s) (notAfter ${end//_/ }), checked on $box. Warning at <= 21 d, critical at <= 7 d: check the certificate renewal."
  [[ "$level" == ERROR ]] && body="cert-expiry ERROR: no certificate could be read from $host:443, checked on $box."
  if [[ "$dry" != 0 ]]; then
    do_log "INFO PLAN note to $to on task $task: $body"
    return 0
  fi
  read -ra send <<<"${CERT_EXPIRY_SEND_CMD:-}"
  if ! ((${#send[@]})); then
    send=(bash "${PROJ_PATH:-.}/../csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh")
    [[ -f "${send[1]}" ]] || { do_log "WARN no spool-send.sh at ${send[1]}: alert not sent"; return 0; }
  fi
  if "${send[@]}" --from "$from" --to "$to" --kind note --task "$task" --body "$body" >/dev/null 2>&1; then
    { mkdir -p "$(dirname "$stamp")" && echo "$level $now" >"$stamp"; } 2>/dev/null ||
      do_log "WARN cannot write $stamp: the next run alerts again"
    do_log "INFO cert-expiry $host $level note sent to $to"
  else
    do_log "WARN cert-expiry $host: the note to $to failed"
  fi
  return 0
}

# cert_expiry_ms - a millisecond wall clock (no fork)
cert_expiry_ms() { local t="${EPOCHREALTIME/[.,]/}"; printf '%s' "$((10#$t / 1000))"; }
