#!/usr/bin/env bash
# agent-watch.sh — watch every spawned agent pane and print ONE line per pane
# that needs a human (or a nudge). Silence means every agent is working, or
# idle with nothing waiting. Ported from the frozen box engine (specs/048,
# SPL-1160) onto the spool.
#
#   DIALOG  a confirmation prompt is waiting for a choice
#   TYPED   unsent text sits in the prompt -> never nudged (a nudge would
#           append to it and submit both)
#   MAIL    idle with unread messages -> nudged with one shell-inert line
#
# An agent is known by its pane's process tree (agent_of_ps: the launcher
# argv, else the id its run-as hop exports), never by its window title (two windows can carry one title). Orchestrators
# (xxx-00, ORC-n, @agent-role orc) and this watcher's own agent
# ($SPOOL_AGENT_ID / $MCP_BOT_AGENT_ID) are skipped. "Unread" is read from the
# mailbox the agent was spawned with, the same routing as agent-send.sh:
#   in $SPOOL_ROOT/registry.tsv           -> $SPOOL_ROOT/<ID>/inbox/*.json
#   $SPOOL_LEGACY_INBOX_ROOT/<ID>/inbox   -> the markdown inbox (a lone
#                                            *--brief.md is the agent's own
#                                            seed brief, never nudged about)
#   else $SPOOL_ROOT/<ID>/inbox           -> the spool
#
# Usage: agent-watch.sh [--once]      (loops every AGENT_WATCH_INTERVAL, 240 s)
set -uo pipefail
_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
# shellcheck source=../lib/agent-state.inc.sh
. "$_here/../lib/agent-state.inc.sh"
SPOOL_ENV_NO_BINS=1 spool_env_resolve
ONCE=0; [ "${1:-}" = --once ] && ONCE=1
spool_tmux_argv
TM=("${SPOOL_TM[@]}")
SELF="${SPOOL_AGENT_ID:-${MCP_BOT_AGENT_ID:-}}"
LEGACY="${SPOOL_LEGACY_INBOX_ROOT:-}"

unread() {  # ID -> "<count> <inbox dir>"
  local id="$1" dir
  if [ -r "$SPOOL_ROOT/registry.tsv" ] && cut -f1 "$SPOOL_ROOT/registry.tsv" | grep -x "$id" >/dev/null; then dir="$SPOOL_ROOT/$id/inbox"
  elif [ -n "$LEGACY" ] && [ -d "$LEGACY/$id/inbox" ]; then
    dir="$LEGACY/$id/inbox"
    local n; n="$(find "$dir" -maxdepth 1 -type f | wc -l)"
    if [ "$n" = 1 ] && find "$dir" -maxdepth 1 -type f -name '*--brief.md' | grep . >/dev/null; then echo "0 $dir"; return; fi
  else dir="$SPOOL_ROOT/$id/inbox"; fi
  echo "$(find "$dir" -maxdepth 1 -type f 2>/dev/null | wc -l) $dir"
}

scan() {
  local p pid sid args id wname role scr busy prompt_line prompt_rest n dir
  for p in $("${TM[@]}" list-panes -a -F '#{pane_id}' 2>/dev/null); do
    pid="$("${TM[@]}" display -p -t "$p" '#{pane_pid}' 2>/dev/null)" || continue
    sid="$(ps -o sid= -p "$pid" 2>/dev/null | tr -d ' ')"; [ -n "$sid" ] || continue
    args="$(ps -o args= -g "$sid" 2>/dev/null | agent_of_ps)"
    [ -n "$args" ] || continue                        # not an agent pane
    id="${args##* }"
    wname="$("${TM[@]}" display -p -t "$p" '#{window_name}' 2>/dev/null)"
    role="$("${TM[@]}" show-options -wqv -t "$p" @agent-role 2>/dev/null)"
    agent_is_orc "$(an_strip "$wname")" "$role" && continue
    [ -n "$SELF" ] && [ "$id" = "$SELF" ] && continue
    scr="$("${TM[@]}" capture-pane -p -t "$p" 2>/dev/null)"
    if printf '%s' "$scr" | grep -E '❯ 1\.|Do you want to|\(y/n\)|Yes, and|No, and tell' >/dev/null; then
      echo "DIALOG $id ($p) a prompt is waiting: $(printf '%s' "$scr" | grep -E 'Do you want to|❯ 1\.' | sed -n 1p | cut -c1-90)"
      continue
    fi
    # The LIVE prompt is the LAST ❯ line (the first is scrollback); the glyph is
    # followed by a no-break space, so strip every blank before asking.
    prompt_line="$(printf '%s\n' "$scr" | grep '❯' | tail -1 || true)"
    prompt_rest="$(printf '%s' "$prompt_line" | sed 's/❯//g; s/│//g; s/\xc2\xa0//g' | tr -d '[:space:]')"
    if [ -n "$prompt_rest" ]; then
      echo "TYPED $id ($p) unsent text in the prompt -> NOT nudged: $(printf '%s' "$prompt_line" | cut -c1-70)"
      continue
    fi
    # Busy: a spinner or token counter too, not only the footer - a nudge into
    # a working agent's prompt corrupts its next turn; a missed one costs minutes.
    busy=0
    [ "$(classify_screen "$scr")" = busy ] && busy=1
    read -r n dir < <(unread "$id")
    if [ "$busy" = 0 ] && [ "${n:-0}" -gt 0 ]; then
      "${TM[@]}" send-keys -t "$p" -l ": 'SPOOL ${id}: ${n} unread message(s) in ${dir}/ - read, act, archive'"
      sleep 0.2
      "${TM[@]}" send-keys -t "$p" Enter
      echo "MAIL  $id ($p) idle with $n unread -> nudged"
    fi
  done
}

while true; do
  scan
  [ "$ONCE" = 1 ] && exit 0
  sleep "${AGENT_WATCH_INTERVAL:-240}"
done
