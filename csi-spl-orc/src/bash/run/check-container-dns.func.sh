#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description Compare the tf-runner container DNS (Docker `# ExtServers:`)
#   with the host `/etc/resolv.conf` nameserver. On mismatch, restart the
#   three infra containers (`tf-runner`, `tpl-gen`, `conf-validator`) so they
#   pick up the host resolver (VPN/DHCP drift). Host-side action — no-op
#   inside a container, when Docker is missing, or when the tf-runner is not
#   running, so terraform apply can still proceed.
# @param SKIP_CONTAINER_DNS_CHECK - 1 = skip the check entirely (default 0)
# @param CON_TF_RUNNER - override tf-runner container name
# @param CON_INF_PREFIX - override con-<org>-<app>[-<tree-slug>] prefix
# @param HOST_RESOLV_CONF - host resolv.conf path (default /etc/resolv.conf)
# @param DRY_RUN - 1 = log the restart, do not docker restart
# @example ./run -a do_check_container_dns
# @example CON_TF_RUNNER=con-org-app-tf-runner ./run -a do_check_container_dns
#------------------------------------------------------------------------------

_dns_ensure_helpers() {
  if declare -f _dns_normalize_set >/dev/null 2>&1; then
    return 0
  fi
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  source "${here}/flush-dns.func.sh"
}

# Resolve con-<org>-<app>[-<tree-slug>]-tf-runner. TREE_SLUG covers the
# ora-cam `main` naming; CON_TF_RUNNER wins when tests/operators set it.
_dns_tf_runner_name() {
  if [[ -n "${CON_TF_RUNNER:-}" ]]; then
    printf '%s\n' "$CON_TF_RUNNER"
    return 0
  fi
  local org="${ORG:-}" app="${APP:-}" slug="${TREE_SLUG:-}"
  local names=() n
  if [[ -n "$org" && -n "$app" ]]; then
    [[ -n "$slug" ]] && names+=("con-${org}-${app}-${slug}-tf-runner")
    names+=("con-${org}-${app}-tf-runner")
    names+=("con-${org}-${app}-main-tf-runner")
  fi
  if command -v docker >/dev/null 2>&1; then
    for n in "${names[@]}"; do
      if docker inspect "$n" >/dev/null 2>&1; then
        printf '%s\n' "$n"
        return 0
      fi
    done
  fi
  if ((${#names[@]} > 0)); then
    printf '%s\n' "${names[0]}"
    return 0
  fi
  return 1
}

_dns_wait_tf_runner() {
  local tf_con="$1"
  local i
  for i in $(seq 1 30); do
    if docker exec "$tf_con" true >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  do_log "ERROR ${tf_con} did not become ready after resolver restart"
  return 1
}

do_check_container_dns() {
  _dns_ensure_helpers

  if [[ "${SKIP_CONTAINER_DNS_CHECK:-}" == "1" ]]; then
    do_log "INFO skipping container DNS check (SKIP_CONTAINER_DNS_CHECK=1)"
    return 0
  fi

  # The iac provision action typically runs *inside* tf-runner via docker exec. Restarting
  # ourselves from in here would kill the apply. make do-provision runs this
  # action on the host first.
  if [[ -f /.dockerenv && "${DNS_CHECK_FORCE_HOST:-}" != "1" ]]; then
    do_log "INFO skipping container DNS check (already inside a container)"
    return 0
  fi

  if ! command -v docker >/dev/null 2>&1; then
    do_log "WARN docker CLI not on PATH — skipping container DNS check"
    return 0
  fi
  if ! docker info >/dev/null 2>&1; then
    do_log "WARN Docker daemon not reachable — skipping container DNS check"
    return 0
  fi

  if [[ -z "${ORG:-}" || -z "${APP:-}" ]]; then
    if type do_resolve_oap >/dev/null 2>&1; then
      do_resolve_oap ORG 2>/dev/null || true
      do_resolve_oap APP 2>/dev/null || true
    fi
  fi

  local tf_con
  tf_con="$(_dns_tf_runner_name)" || tf_con=""
  if [[ -z "$tf_con" ]]; then
    do_log "WARN could not resolve tf-runner container name — skipping container DNS check"
    return 0
  fi

  local running
  running="$(docker inspect -f '{{.State.Running}}' "$tf_con" 2>/dev/null || true)"
  if [[ "$running" != "true" ]]; then
    do_log "WARN ${tf_con} is not running — skipping container DNS check"
    return 0
  fi

  local host_file="${HOST_RESOLV_CONF:-/etc/resolv.conf}"
  local host_ns con_blob con_ns
  host_ns="$(_dns_host_nameservers_from_file "$host_file")"
  con_blob="$(docker exec "$tf_con" cat /etc/resolv.conf 2>/dev/null || true)"
  if [[ -z "$con_blob" ]]; then
    do_log "WARN could not read ${tf_con} /etc/resolv.conf — skipping container DNS check"
    return 0
  fi
  con_ns="$(_dns_container_nameservers_from_resolv "$con_blob")"

  if [[ -z "$host_ns" || -z "$con_ns" ]]; then
    do_log "WARN resolver sets incomplete (host '${host_ns}', container '${con_ns}') — skipping"
    return 0
  fi

  if [[ "$host_ns" == "$con_ns" ]]; then
    do_log "OK container DNS matches host (${host_ns})"
    return 0
  fi

  local prefix="${CON_INF_PREFIX:-${tf_con%-tf-runner}}"
  local to_restart=() svc n
  for svc in tf-runner tpl-gen conf-validator; do
    n="${prefix}-${svc}"
    if docker inspect "$n" >/dev/null 2>&1; then
      to_restart+=("$n")
    fi
  done
  if ((${#to_restart[@]} == 0)); then
    to_restart=("$tf_con")
  fi

  if [[ "${DRY_RUN:-}" == "1" ]]; then
    do_log "WARN resolver changed (host ${host_ns}, container ${con_ns}) — restarted"
    do_log "INFO DRY_RUN: would docker restart ${to_restart[*]}"
    return 0
  fi

  do_log "INFO docker restart ${to_restart[*]}"
  if ! docker restart "${to_restart[@]}"; then
    do_log "ERROR docker restart failed after resolver mismatch"
    return 1
  fi
  do_log "WARN resolver changed (host ${host_ns}, container ${con_ns}) — restarted"

  _dns_wait_tf_runner "$tf_con" || return $?
  do_log "OK infra containers ready after DNS restart"
  return 0
}
