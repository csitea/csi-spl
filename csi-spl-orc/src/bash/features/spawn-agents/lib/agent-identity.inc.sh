#!/usr/bin/env bash
# agent-identity.inc.sh — the box's one identity map, for bash callers.
#
# $SPOOL_ROOT/agents/<ID>.json, one record per agent, plus index.json (a hash
# of every record, changing exactly when one does). The values come from each
# agent's PROCESS (scripts/agent-identity.py), never from a window name or a
# registry row. The named run actions do_spl_agent_identity_record / _check
# are the entry points; this file is what they, and any resolver, source.
#
#   ai_dir                 the map's directory
#   ai_panes               every tmux pane: session, window_id, pane_id, pane_pid, name
#   ai_record [--apply]    merge the live facts into the map (dry run without --apply)
#   ai_check               the map vs the live box; exit 1 on drift
#   ai_alive ID            print the pid, exit 0, when ID's record names a process that still IS ID
#   ai_hash                the map's hash
#
# Settings: SPOOL_ROOT (default /var/spool-hub); SPOOL_TMUX_SOCKET (else $TMUX,
# else the caller's default socket). Test seams: AI_PROC_ROOT (a fake /proc),
# AI_PANES_FILE (the pane list instead of asking tmux).

AI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_PY="$AI_LIB_DIR/../scripts/agent-identity.py"

ai_dir() { printf '%s/agents' "${SPOOL_ROOT:-/var/spool-hub}"; }

# tmux on the box's server, as the user who owns its socket.
ai_tmux() {
  local sock="${SPOOL_TMUX_SOCKET:-}" owner
  [ -n "$sock" ] || { sock="${TMUX:-}"; sock="${sock%%,*}"; }
  [ -n "$sock" ] || sock="/tmp/tmux-$(id -u)/default"
  owner="$(stat -c %U "$sock" 2>/dev/null || true)"
  if [ -n "$owner" ] && [ "$owner" != "$(id -un)" ]; then sudo -n -u "$owner" tmux -u -S "$sock" "$@"
  else tmux -u -S "$sock" "$@"; fi
}

ai_panes() {
  if [ -n "${AI_PANES_FILE:-}" ]; then cat "$AI_PANES_FILE"; return 0; fi
  ai_tmux list-panes -a -F '#{session_name}	#{window_id}	#{pane_id}	#{pane_pid}	#{window_name}' 2>/dev/null || true
}

ai_py() { python3 "$AI_PY" --dir "$(ai_dir)" --proc-root "${AI_PROC_ROOT:-/proc}" "$@"; }

ai_record() { ai_panes | ai_py record "$@"; }
ai_check()  { ai_panes | ai_py check; }
ai_alive()  { ai_py alive "${1:?ai_alive: agent id}" </dev/null; }
ai_hash()   { ai_py hash </dev/null; }
