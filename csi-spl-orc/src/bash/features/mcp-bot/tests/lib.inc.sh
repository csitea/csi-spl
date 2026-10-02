#!/usr/bin/env bash
# lib.inc.sh — shared helpers for the mcp-bot tests. Every test builds its own
# MCP_BOT_HOME under a mktemp dir; the real one and live browsers are never
# touched.

T_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T_FEAT="$(cd "$T_HERE/.." && pwd)"
# shellcheck disable=SC2034  # used by the tests that source this file
T_SCRIPTS="$T_FEAT/scripts"

T_PASS=0; T_FAIL=0
ok()   { T_PASS=$((T_PASS + 1)); echo "ok   - $*"; }
nok()  { T_FAIL=$((T_FAIL + 1)); echo "FAIL - $*"; }
check() {  # DESC CMD...
  local d="$1"; shift
  if "$@"; then ok "$d"; else nok "$d"; fi
}
eq() {  # DESC WANT GOT
  if [ "$2" = "$3" ]; then ok "$1"; else nok "$1 (want '$2', got '$3')"; fi
}
has() {  # DESC NEEDLE HAYSTACK
  case "$3" in *"$2"*) ok "$1" ;; *) nok "$1 (missing '$2')" ;; esac
}
t_done() {
  echo "-- $(basename "$0"): ${T_PASS} passed, ${T_FAIL} failed"
  [ "$T_FAIL" -eq 0 ]
}

# A throwaway MCP_BOT_HOME with the base config seeded from assets/.
t_sandbox() {
  unset MCP_BOT_AGENT_ID MCP_BOT_CHROME_PROFILE MCP_BOT_CHROME_IDLE_MIN \
        MCP_BOT_CHROME_IDLE_SEC MCP_BOT_CHROME_IDLE_POLL_SEC
  T_TMP="$(mktemp -d)"
  export MCP_BOT_HOME="$T_TMP/home"
  mkdir -p "$MCP_BOT_HOME"
  sed "s|__MCP_BOT_HOME__|$MCP_BOT_HOME|g" "$T_FEAT/assets/mcp-config-chrome.json" \
    > "$MCP_BOT_HOME/mcp-config-chrome.json"
  trap 't_cleanup' EXIT
}
t_cleanup() {
  local p
  for p in ${T_PIDS:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$T_TMP"
}

alive() { kill -0 "$1" 2>/dev/null; }
