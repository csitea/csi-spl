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
#   ai_alive_fast ID       the same rule as ai_alive, pure bash (prints the pid)
#   ai_pane_of ID [PANES]  the live pane of a live agent, from the map, verified
#   ai_live_ids            every agent the map proves alive
#
# Settings: SPOOL_ROOT (default /var/spool-hub); SPOOL_TMUX_SOCKET (else $TMUX,
# else the caller's default socket). Test seams: AI_PROC_ROOT (a fake /proc),
# AI_PANES_FILE (the pane list instead of asking tmux).

AI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_PY="$AI_LIB_DIR/../scripts/agent-identity.py"
# shellcheck source=proc-owner.inc.sh
. "$AI_LIB_DIR/proc-owner.inc.sh"

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

# Record ID from that one pid while another live process still carries the
# id (the hourly rotation's overlap, spec 060 FR-006).
ai_adopt() { ai_panes | ai_py adopt "$1" "$2"; }

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

# ── fast readers (pure bash builtins, no fork: the notifier's hot path) ─────
# A record's scalar fields into AI_REC[key]. The writer is ours:
# json.dump(indent=1, sort_keys=True), one ' "key": value,' per line.
declare -gA AI_REC=()
ai_load() {  # ID -> AI_REC; non-zero when there is no such record
  local f line re='^ "([a-z_]+)": "?([^",]*)"?,?$'
  AI_REC=()
  f="$(ai_dir)/$1.json"
  [ -r "$f" ] || return 1
  while IFS= read -r line; do
    [[ "$line" =~ $re ]] && AI_REC[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
  done < "$f"
  [ "${AI_REC[id]:-}" = "$1" ]
}
ai_field() { ai_load "$1" || return 1; local v="${AI_REC[$2]:-}"; [ "$v" = null ] && v=""; printf '%s\n' "$v"; }  # ID KEY

# The same liveness rule as `agent-identity.py alive`: the record says alive,
# the pid exists with the recorded start time, is that agent's CLI (argv[0],
# argv[1] behind a node loader, else comm), and carries SPOOL_AGENT_ID (or
# MCP_BOT_AGENT_ID) = ID. Prints the pid.
ai_alive_fast() {  # ID
  local id="$1" root="${AI_PROC_ROOT:-/proc}" pid start kind st a0="" a1="" comm="" kv ok=0
  local -a f
  ai_load "$id" || return 1
  [ "${AI_REC[alive]:-}" = true ] || return 1
  pid="${AI_REC[pid]:-}"; start="${AI_REC[proc_start]:-}"; kind="${AI_REC[kind]:-claude}"
  [[ "$pid" =~ ^[0-9]+$ ]] && [ -n "$start" ] || return 1
  { IFS= read -r st < "$root/$pid/stat"; } 2>/dev/null || return 1
  st="${st##*) }"; read -r -a f <<< "$st"
  [ "${f[19]:-}" = "$start" ] || return 1
  { IFS= read -r -d '' a0; IFS= read -r -d '' a1; } < "$root/$pid/cmdline" 2>/dev/null
  { IFS= read -r comm < "$root/$pid/comm"; } 2>/dev/null
  a0="${a0##*/}"; a1="${a1##*/}"
  case "$a0" in node|nodejs|bun|deno|ld-linux*) a0="$a1" ;; esac
  [ "$a0" = "$kind" ] || [ "$comm" = "$kind" ] || return 1
  # Another user's agent (the agent user) through its owner (proc-owner.inc.sh);
  # a readable environ stays a builtin read, no fork.
  if [ -r "$root/$pid/environ" ]; then
    while IFS= read -r -d '' kv; do
      case "$kv" in "SPOOL_AGENT_ID=$id"|"MCP_BOT_AGENT_ID=$id") ok=1; break ;; esac
    done < "$root/$pid/environ" 2>/dev/null
  else
    while IFS= read -r -d '' kv; do
      case "$kv" in "SPOOL_AGENT_ID=$id"|"MCP_BOT_AGENT_ID=$id") ok=1; break ;; esac
    done < <(spool_proc_environ "$root" "$pid")
  fi
  [ "$ok" = 1 ] || return 1
  printf '%s\n' "$pid"
}

# The pane of a live agent, from the map: only when ai_alive_fast proves the
# process AND that pane is in LIVE-PANES (newline list; default: ask tmux).
ai_pane_of() {  # ID [LIVE-PANES]
  local id="$1" live="${2-}" pane p
  ai_alive_fast "$id" >/dev/null || return 1
  pane="${AI_REC[pane_id]:-}"
  [ -n "$pane" ] && [ "$pane" != null ] || return 1
  [ -n "$live" ] || live="$(ai_tmux list-panes -a -F '#{pane_id}' 2>/dev/null)"
  while IFS= read -r p; do
    [ "$p" = "$pane" ] && { printf '%s\n' "$pane"; return 0; }
  done <<< "$live"
  return 1
}

# Every agent the map proves alive, one id per line.
ai_live_ids() {
  local f id
  for f in "$(ai_dir)"/*.json; do
    [ -e "$f" ] || continue
    id="${f##*/}"; id="${id%.json}"
    [[ "$id" =~ ^(CLE|GRK|AGY|QWN)-[0-9]+$ ]] || continue
    ai_alive_fast "$id" >/dev/null && printf '%s\n' "$id"
  done
  return 0
}
