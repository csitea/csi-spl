#!/usr/bin/env bash
# lib.inc.sh — shared fixtures for the spawn-agents tests.
#
# Every test runs against a throwaway SPOOL_ROOT and, where it needs tmux, a
# PRIVATE tmux server on a socket under that tmp dir, owned by the user running
# the test. Nothing here touches the real spool root or the box user's tmux.

T_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T_FEAT="$(cd "$T_HERE/.." && pwd)"
T_SCRIPTS="$T_FEAT/scripts"
T_REPO="$(cd "$T_FEAT/../../../../.." && pwd)"

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
hasnt() {  # DESC NEEDLE HAYSTACK
  case "$3" in *"$2"*) nok "$1 (unexpected '$2')" ;; *) ok "$1" ;; esac
}
t_done() {
  echo "-- $(basename "$0"): ${T_PASS} passed, ${T_FAIL} failed"
  [ "$T_FAIL" -eq 0 ]
}

# A fresh sandbox: SPOOL_ROOT, a socket path, and this user as both the box
# and the agent user (no sudo hop).
t_sandbox() {
  # A test run from inside a live agent's pane inherits that agent's pane,
  # socket and id; scripts that honour them would reach the REAL box tmux
  # (CLE-77907: 4 tests red only when run from an agent pane).
  unset TMUX TMUX_PANE MCP_BOT_AGENT_ID SPOOL_AGENT_ID SPOOL_NOTIFY_CMD SPOOL_BOX_ENV
  local k
  for k in CLE GRK AGY QWN; do unset "${k}_TMUX_PANE" "${k}_TMUX_SOCK"; done
  T_TMP="$(mktemp -d)"
  export SPOOL_ROOT="$T_TMP/spool"
  export SPOOL_TMUX_SOCKET="$T_TMP/tmux.sock"
  export SPOOL_BOX_USER="$(id -un)" SPOOL_AGENT_USER="$(id -un)"
  export SPOOL_BOX_TAG=""
  export SPAWN_TEST_SANDBOX=1
  mkdir -p "$SPOOL_ROOT"
  trap 't_cleanup' EXIT
}
t_cleanup() {
  tmux -S "$SPOOL_TMUX_SOCKET" kill-server 2>/dev/null || true
  rm -rf "$T_TMP"
}

# A private tmux server whose first window is a placeholder that stays active.
t_tmux() {  # [ENV=VAL ...] — extra env for the server (panes inherit it)
  env "$@" tmux -S "$SPOOL_TMUX_SOCKET" -f /dev/null new-session -d -s t -n home -x 200 -y 50 'sleep 600'
  tmux -S "$SPOOL_TMUX_SOCKET" set-option -g remain-on-exit on >/dev/null
}
# A window named NAME running CMD; prints its pane id.
t_window() {  # NAME CMD
  tmux -S "$SPOOL_TMUX_SOCKET" new-window -d -t t: -n "$1" -P -F '#{pane_id}' "$2"
}

# The spool binary: the repo's build output, built once if absent.
t_spool_bin() {
  local b="$T_REPO/csi-spl-api/src/go/spool-hub-api/bin/spool"
  if [ ! -x "$b" ]; then
    bash "$T_REPO/csi-spl-api/src/bash/build.sh" "$b" >/dev/null || return 1
  fi
  export SPOOL_BIN="$b"
}
