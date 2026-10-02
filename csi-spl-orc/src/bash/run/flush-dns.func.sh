#!/bin/bash
#------------------------------------------------------------------------------
# @description Flush the operator / CI host DNS resolver cache and verify a
# @description test name resolves via a public fallback nameserver.
# @description
# @description Morph of csi-rel-orc do_flush_dns (spec 033). Feature-detects
# @description resolvectl / systemd-resolve, systemd-resolved, nscd and
# @description NetworkManager; adds NAMESERVER to resolv.conf only if absent.
# @description
# @description DRY_RUN=1 (default): log the steps a real run would take, mutate
# @description nothing. The real run sudo-restarts resolvers and may append
# @description /etc/resolv.conf — on a shared box that is host-wide, so it is
# @description owner-gated the same way as the other cloud actions.
# @description
# @description TEST_DOMAIN has no baked default (the product FQDN lives in
# @description cnf). Pass TEST_DOMAIN, or set ENV=dev|prd to read env.dns.fqdn.
# @param TEST_DOMAIN (optional) - name to resolve; default: cnf env.dns.fqdn when ENV is set
# @param ENV (optional) - dev or prd: fills TEST_DOMAIN from cnf when unset
# @param NAMESERVER (optional) - public fallback (default: 8.8.8.8)
# @param DRY_RUN (optional) - 1 (default): log only. 0: flush / maybe edit resolv.conf
# @example TEST_DOMAIN=example.test ./run -a do_flush_dns
# @example ENV=dev DRY_RUN=0 ./run -a do_flush_dns
# @arg --test-domain TEST_DOMAIN
# @arg --env ENV
# @arg --nameserver NAMESERVER
#------------------------------------------------------------------------------
do_flush_dns() {
  local dry=1 rc=0
  if declare -f spl_dry_run >/dev/null; then
    if spl_dry_run; then
      dry=1
    else
      rc=$?
      [[ $rc -eq 1 ]] || return "$rc"
      dry=0
    fi
  fi

  local nameserver="${NAMESERVER:-8.8.8.8}"
  local test_domain="${TEST_DOMAIN:-}"
  if [[ -z "$test_domain" && -n "${ENV:-}" ]] && declare -f do_spl_cloud_cnf >/dev/null; then
    do_spl_cloud_cnf || return 1
    test_domain="$SPL_FQDN"
  fi
  if [[ -z "$test_domain" ]]; then
    do_log "FATAL TEST_DOMAIN is required (or set ENV=dev|prd to read env.dns.fqdn from cnf)"
    return 1
  fi

  do_log "INFO flushing DNS cache on this host (DRY_RUN=$dry nameserver=$nameserver test_domain=$test_domain)"

  if command -v resolvectl >/dev/null 2>&1; then
    _spl_flush_run "$dry" "resolvectl flush-caches" sudo resolvectl flush-caches
  elif command -v systemd-resolve >/dev/null 2>&1; then
    _spl_flush_run "$dry" "systemd-resolve --flush-caches" sudo systemd-resolve --flush-caches
  else
    do_log "INFO no resolvectl / systemd-resolve on PATH"
  fi

  if command -v systemctl >/dev/null 2>&1 && systemctl is-active systemd-resolved >/dev/null 2>&1; then
    _spl_flush_run "$dry" "systemctl restart systemd-resolved" sudo systemctl restart systemd-resolved
  fi

  if command -v nscd >/dev/null 2>&1; then
    _spl_flush_run "$dry" "nscd -i hosts" sudo nscd -i hosts
  fi

  if command -v systemctl >/dev/null 2>&1 && systemctl is-active NetworkManager >/dev/null 2>&1; then
    _spl_flush_run "$dry" "systemctl restart NetworkManager" sudo systemctl restart NetworkManager
  fi

  _spl_flush_fallback_ns "$dry" "$nameserver"
  _spl_flush_check "$test_domain" "$nameserver"
  if (( dry )); then
    do_log "OK DRY_RUN DNS flush complete: nothing was mutated. Re-run with DRY_RUN=0 to flush."
  else
    do_log "OK DNS flush completed"
  fi
}

# _spl_flush_run <dry> <msg> <cmd...>: run one flush command (logged, its
# failure tolerated), or only say what it would run when <dry> is 1.
_spl_flush_run() {
  local dry="$1" msg="$2"; shift 2
  if (( dry )); then
    do_log "INFO DRY_RUN would: $*"
    return 0
  fi
  do_log "INFO $msg"
  "$@" && do_log "OK $msg" || true
}

# _spl_flush_fallback_ns <dry> <nameserver>: append the fallback nameserver to
# /etc/resolv.conf unless it is there already.
_spl_flush_fallback_ns() {
  local dry="$1" nameserver="$2"
  if grep -q "^nameserver ${nameserver}" /etc/resolv.conf 2>/dev/null; then
    do_log "INFO fallback nameserver ${nameserver} already in /etc/resolv.conf"
  elif (( dry )); then
    do_log "INFO DRY_RUN would append 'nameserver ${nameserver}' to /etc/resolv.conf"
  else
    do_log "INFO adding fallback nameserver ${nameserver} to /etc/resolv.conf"
    sudo bash -c "echo 'nameserver ${nameserver}' >> /etc/resolv.conf" && do_log "OK added nameserver ${nameserver}" || true
  fi
}

# _spl_flush_check <domain> <nameserver>: does <domain> resolve via
# <nameserver> now (a WARN, never a failure).
_spl_flush_check() {
  local test_domain="$1" nameserver="$2" result
  if ! command -v dig >/dev/null 2>&1; then
    do_log "WARN dig is not installed; skipped the resolution check"
    return 0
  fi
  result=$(dig A "$test_domain" +short @"$nameserver" 2>/dev/null || true)
  if [[ -n "$result" ]]; then
    do_log "OK DNS resolves: ${test_domain} -> ${result}"
  else
    do_log "WARN DNS resolution failed for ${test_domain} via ${nameserver}"
  fi
}
