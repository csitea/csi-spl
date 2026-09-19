#!/bin/bash
#------------------------------------------------------------------------------
# The resolver-set helpers do_check_container_dns needs, copied UNCHANGED from
# csi-rel-orc src/bash/run/flush-dns.func.sh (lines 13-90), where they sit
# beside csi-rel's do_flush_dns. csi-spl keeps its own do_flush_dns (a
# DRY_RUN-gated morph without these helpers), so they live here: run.sh sources
# lib/bash/funcs first, and check-container-dns then skips sourcing flush-dns.
#------------------------------------------------------------------------------

# IPv4 addresses from arbitrary text (ExtServers wrappers, nameserver lines).
_dns_extract_ips() {
  local s="${1:-}"
  [[ -z "$s" ]] && return 0
  printf '%s\n' "$s" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' || true
}

# Sorted unique space-separated set. Drops Docker's embedded 127.0.0.11.
_dns_normalize_set() {
  local raw="${1:-}"
  printf '%s\n' "$raw" \
    | awk 'NF && $1 != "127.0.0.11" {print $1}' \
    | sort -u \
    | tr '\n' ' ' \
    | sed 's/[[:space:]]*$//'
}

_dns_is_loopback_only() {
  local set="${1:-}" tok
  [[ -z "$set" ]] && return 0
  for tok in $set; do
    case "$tok" in
      127.*|::1) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# `nameserver` lines from a resolv.conf blob.
_dns_nameservers_from_resolv() {
  local blob="${1:-}"
  local lines
  lines="$(printf '%s\n' "$blob" | grep -E '^[[:space:]]*nameserver[[:space:]]' || true)"
  _dns_extract_ips "$lines"
}

# Last `# ExtServers:` line (Docker Engine internal resolver comment).
_dns_ext_servers_from_resolv() {
  local blob="${1:-}"
  local line
  line="$(printf '%s\n' "$blob" | grep -E '^#[[:space:]]*ExtServers:' | tail -n 1 || true)"
  _dns_extract_ips "$line"
}

# Host nameservers from a resolv.conf file. Loopback stubs (systemd-resolved
# 127.0.0.53) are replaced with `resolvectl dns` upstreams when available.
_dns_host_nameservers_from_file() {
  local file="${1:-/etc/resolv.conf}"
  local blob ips resolved
  blob="$(cat "$file" 2>/dev/null || true)"
  ips="$(_dns_normalize_set "$(_dns_nameservers_from_resolv "$blob")")"
  if _dns_is_loopback_only "$ips"; then
    resolved=""
    if command -v resolvectl >/dev/null 2>&1; then
      resolved="$(_dns_normalize_set "$(_dns_extract_ips "$(resolvectl dns 2>/dev/null || true)")")"
    fi
    if [[ -n "$resolved" ]] && ! _dns_is_loopback_only "$resolved"; then
      ips="$resolved"
    fi
  fi
  printf '%s\n' "$ips"
}

# Container-side set: ExtServers when present, else non-embedded nameservers
# (legacy Docker copies the host resolver into the container).
_dns_container_nameservers_from_resolv() {
  local blob="${1:-}"
  local ext ns
  ext="$(_dns_normalize_set "$(_dns_ext_servers_from_resolv "$blob")")"
  if [[ -n "$ext" ]]; then
    printf '%s\n' "$ext"
    return 0
  fi
  ns="$(_dns_normalize_set "$(_dns_nameservers_from_resolv "$blob")")"
  printf '%s\n' "$ns"
}

