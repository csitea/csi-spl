#!/bin/bash
#------------------------------------------------------------------------------
# @description Status of the private local hub, as the hub user: the compose
# @description services, GET /healthz on the hub, the WUI, and every listener
# @description on the local hub's ports bound to loopback only (a wildcard or
# @description a public address on one of them is a FAIL), then L5's full
# @description listener gate (do_spl_local_hub_ports_gate) when present.
# @description Exit: 0 all PASS; 1 a FAIL.
# @example ./run -a do_spl_local_hub_status
#------------------------------------------------------------------------------
do_spl_local_hub_status() {
  spl_local_hub_cnf || return 1
  if ! spl_local_hub_is_user; then spl_local_hub_reexec do_spl_local_hub_status; return; fi
  spl_local_hub_env && do_gen_docker_env || return 1
  local fails=0 p code
  lde_compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'
  spl_local_hub_services_running || fails=$((fails + 1))
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' --resolve "$LDE_SMOKE_TENANT.localhost:$LDE_HUB_PORT:127.0.0.1" \
    "http://$LDE_SMOKE_TENANT.localhost:$LDE_HUB_PORT/healthz")
  _slh_status_line hub "$code" || fails=$((fails + 1))
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://localhost:$LDE_WUI_PORT/")
  _slh_status_line wui "$code" || fails=$((fails + 1))
  for p in "$LDE_PG_PORT" "$LDE_GCS_PORT" "$LDE_HUB_PORT" "$LDE_WUI_PORT"; do
    spl_local_hub_loopback_only "$p" || fails=$((fails + 1))
  done
  if declare -F do_spl_local_hub_ports_gate >/dev/null; then
    do_spl_local_hub_ports_gate || fails=$((fails + 1))
  else
    do_log "WARN do_spl_local_hub_ports_gate is not on this tree: only the four local hub ports were checked"
  fi
  (( fails == 0 )) || { do_log "ERROR local hub: $fails FAIL"; return 1; }
  do_log "OK local hub $LDE_COMPOSE_PROJECT: all PASS"
}

_slh_status_line() {
  [[ "$2" == 200 ]] && { do_log "OK $1 -> 200"; return 0; }
  do_log "ERROR $1 -> ${2:-no answer}"; return 1
}

# spl_local_hub_loopback_only <port> -- every listener on <port> is bound to
# 127.0.0.0/8 or ::1. No listener at all is a FAIL too (the service is down).
spl_local_hub_loopback_only() {
  local p="$1" addrs a bad=()
  addrs="$(${LOCAL_HUB_SS:-ss} -Hltn "sport = :$p" 2>/dev/null | awk '{print $4}')"
  [[ -n "$addrs" ]] || { do_log "ERROR port $p: nothing listens"; return 1; }
  while IFS= read -r a; do
    [[ "$a" == 127.* || "$a" == "[::1]:"* ]] || bad+=("$a")
  done <<<"$addrs"
  (( ${#bad[@]} == 0 )) || { do_log "ERROR port $p listens beyond loopback: ${bad[*]}"; return 1; }
  do_log "OK port $p: loopback only ($(tr '\n' ' ' <<<"$addrs"))"
}

# spl_local_hub_services_running -- every service of the project is running;
# a restarting or exited one (a job looping on its own error) is a FAIL.
spl_local_hub_services_running() {
  local svc state bad=() n=0
  while read -r svc state; do
    [[ -n "$svc" ]] || continue
    n=$((n + 1))
    [[ "$state" == running ]] || bad+=("$svc is $state")
  done < <(lde_compose ps -a --format '{{.Service}} {{.State}}' 2>/dev/null)
  ((n > 0)) || { do_log "ERROR no service of ${LDE_COMPOSE_PROJECT:-the project} runs"; return 1; }
  ((${#bad[@]} == 0)) || { do_log "ERROR not running: ${bad[*]}"; return 1; }
  do_log "OK all $n services running"
}
