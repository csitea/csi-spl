#!/usr/bin/env bash
# hook-ping/lib.inc.sh — token and event helpers for the harness ping hooks.
# Callers exit 0 after a failure: a ping hook must not block the agent.

spl_hp_emit_empty() {
  printf '%s\n' '{}'
}

spl_hp_dir_ok() {
  local dir="${HOOK_PING_DIR:-}" live
  [[ -n "$dir" ]] || return 1
  if [[ "${SPOOL_TEST:-}" == 1 ]]; then
    live="${SPOOL_LIVE_ROOT:-/var/spool-hub}"
    case "$dir/" in
      "$live/"*) return 1 ;;
    esac
  fi
  return 0
}

spl_hp_mint() {
  local hex
  hex="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  printf 'ping-%s' "$hex"
}

spl_hp_ask() {
  printf 'Echo this ping token on its own line and nothing else: %s' "$1"
}

spl_hp_record() {
  local tok="$1" ask="$2"
  spl_hp_dir_ok || return 0
  mkdir -p "$HOOK_PING_DIR" || return 0
  printf '%s\n' "$tok" >"$HOOK_PING_DIR/token" || return 0
  printf '%s\n' "$ask" >"$HOOK_PING_DIR/ask" || return 0
}

spl_hp_event() {
  jq -r '(.hook_event_name // .hookEventName // "") | ascii_downcase' <<<"${1:-}" 2>/dev/null || true
}

spl_hp_is_post() {
  case "$1" in
    posttooluse|post_tool_use) return 0 ;;
    *) return 1 ;;
  esac
}
