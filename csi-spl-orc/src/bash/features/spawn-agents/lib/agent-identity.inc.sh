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
#   ai_reconcile [--apply] record, then rename every agent window whose name is
#                          not "<tag>: <ID> [badge] <title>" from its record
#                          (dry run without --apply: RENAME plans only)
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

# The box tag: configured (SPOOL_BOX_TAG, BOX_TAG), else the one most agent
# windows already carry - so a box that always showed one never loses it.
ai_tag() {
  local t="${SPOOL_BOX_TAG:-${BOX_TAG:-}}"
  [ -n "$t" ] || t="$(ai_panes | cut -f5 | sed -nE 's/^([A-Za-z0-9][A-Za-z0-9._-]*): (CLE|GRK|AGY|QWN)-[0-9]+.*/\1/p' \
    | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')"
  printf '%s' "$t"
}

# Names come FROM the map: nothing else may decide an agent window's name.
# Each rename is a compare-and-set on the pane (the window must still carry
# the name the plan was computed from), addressed by pane id, never an index;
# and the window stops taking names from the CLI's terminal title
# (allow-rename) or from tmux (automatic-rename). One run at a time: cron and
# the tmux hooks may fire together.
ai_reconcile() {
  local apply=0 out line pane old new cur n=0 lock
  [ "${1:-}" = --apply ] && apply=1
  if [ "$apply" = 1 ]; then
    mkdir -p "$(ai_dir)" 2>/dev/null
    lock="$(ai_dir)/.reconcile.lock"
    exec 7>>"$lock" || return 1
    flock -w 20 7 || { echo "reconcile: another run holds $lock - skipped"; return 0; }
    out="$(ai_panes | ai_py reconcile --tag "$(ai_tag)" --apply)" || { exec 7>&-; return 1; }
  else
    out="$(ai_panes | ai_py reconcile --tag "$(ai_tag)")" || return 1
  fi
  while IFS= read -r line; do
    case "$line" in
      RENAME$'\t'*)
        IFS=$'\t' read -r _ pane old new <<< "$line"
        if [ "$apply" = 0 ]; then echo "PLAN rename $pane: '$old' -> '$new'"; continue; fi
        cur="$(ai_tmux display-message -p -t "$pane" '#{window_name}' 2>/dev/null)"
        if [ "$cur" != "$old" ]; then echo "SKIP $pane: renamed meanwhile to '$cur' - next pass"; continue; fi
        ai_tmux set-window-option -t "$pane" allow-rename off >/dev/null 2>&1
        ai_tmux set-window-option -t "$pane" automatic-rename off >/dev/null 2>&1
        if ai_tmux rename-window -t "$pane" "$new" 2>/dev/null; then echo "RENAMED $pane: '$old' -> '$new'"; n=$((n + 1))
        else echo "FAILED rename $pane to '$new'"; fi ;;
      *) echo "$line" ;;
    esac
  done <<< "$out"
  [ "$apply" = 1 ] && exec 7>&-
  return 0
}
ai_check()  { ai_panes | ai_py check; }
ai_alive()  { ai_py alive "${1:?ai_alive: agent id}" </dev/null; }
ai_hash()   { ai_py hash </dev/null; }
