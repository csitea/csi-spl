#!/usr/bin/env bash
# Who is calling: the agent id read from a process chain, and whether an id is
# a role seat. Used by spool-send.sh (send_from_guard, SPL-3654) and by
# do_spl_sender_audit (SPL-5136). The why of the chain walk is above
# send_from_guard. Needs spool-env.inc.sh sourced first.
_spool_caller_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# A role seat (001-003, or an id lease.conf names) takes every topic by design.
send_role_seat() {  # ID
  spl_is_role_seat "$1" && return 0
  grep -qxE "LEASE_(MASTER|FAILOVER|ORCH)=$1" "$SPOOL_ROOT/dispatch/lease.conf" 2>/dev/null
}

# The caller's pids, itself first, up to (not into) the tmux server or pid 1.
send_caller_chain() {  # ROOT PID
  local root="$1" pid="$2" n=0 comm
  while [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && [ "$n" -lt 64 ]; do
    comm="$(cat "$root/$pid/comm" 2>/dev/null)" || break
    case "$comm" in tmux*) break ;; esac
    echo "$pid"
    pid="$(awk '/^PPid:/ { print $2; exit }' "$root/$pid/status" 2>/dev/null)"
    n=$((n + 1))
  done
}

# The agent id of the outermost pid of CHAIN whose environ carries one. A
# root-owned hop (sudo, su) holds a copy of its parent's environ: skipped, so
# no read needs root.
send_caller_env_id() {  # ROOT CHAIN
  local root="$1" p v id="" own=()
  local -A by=()
  for p in $2; do [ "$(stat -c %u "$root/$p" 2>/dev/null)" = 0 ] || own+=("$p"); done
  [ "${#own[@]}" -gt 0 ] || return 0
  declare -F spool_proc_env_get >/dev/null || . "$_spool_caller_dir/proc-owner.inc.sh"
  while read -r p v; do
    [ -n "${by[$p]:-}" ] || by[$p]="$(_spool_bare_agent_id "$v")"
  done < <(spool_proc_env_get "$root" SPOOL_AGENT_ID "${own[@]}" 2>/dev/null
           spool_proc_env_get "$root" MCP_BOT_AGENT_ID "${own[@]}" 2>/dev/null)
  for p in "${own[@]}"; do [ -n "${by[$p]:-}" ] && id="${by[$p]}"; done
  printf '%s' "$id"
}

# The agent id the window of the first tmux pane in CHAIN is named for.
send_caller_pane_id() {  # CHAIN
  local p pid w
  local -A win=()
  spool_tmux_argv
  while IFS=$'\t' read -r pid w; do
    [ -n "$pid" ] && win[$pid]="$w"
  done < <(timeout 5 "${SPOOL_TM[@]}" list-panes -a -F '#{pane_pid}	#{window_name}' 2>/dev/null)
  for p in $1; do
    [ -n "${win[$p]+x}" ] && { spool_id_of_window "${win[$p]}"; return 0; }
  done
  return 0
}

# "<id> <how>" of the caller, or nothing when no agent is in its chain.
send_caller_id() {
  local root=/proc pid=$$ chain
  if [ "${SPOOL_TEST:-}" = 1 ]; then root="${SPOOL_FROM_GUARD_PROC:-}"; pid="${SPOOL_FROM_GUARD_PID:-$$}"; fi
  [ -n "$root" ] || return 0
  chain="$(send_caller_chain "$root" "$pid")"
  [ -n "$chain" ] || return 0
  send_chain_caller "$root" "$chain"
}

# "<id> <how>" of the agent running CHAIN, or nothing.
send_chain_caller() {  # ROOT CHAIN
  local id
  id="$(send_caller_env_id "$1" "$2")"
  [ -n "$id" ] && { echo "$id environ"; return 0; }
  id="$(send_caller_pane_id "$2")"
  [ -n "$id" ] && echo "$id pane"
  return 0
}
