#!/usr/bin/env bash
# riname.sh — rename an agent's tmux window to "<ID> <title>" (with the
# SPOOL_BOX_TAG in front when one is set), keeping the id.
#
# The title goes into the agent's record in the identity map
# ($SPOOL_ROOT/agents/<ID>.json, SPEC-agent-identity-map.md) and the window is
# then named FROM the map by the reconcile: the pane is the one whose process
# tree holds the process carrying SPOOL_AGENT_ID=<ID>, never a registry row or
# a window index. That is what stops one agent's title landing on another
# agent's window. Only an agent the map cannot see (its environment is
# unreadable from here) falls back to the old path: the registry + window-name
# lookup (spool_pane_of), which proves the pane by the id its window carries.
#
# The id: --agent, else the caller's own SPOOL_AGENT_ID / MCP_BOT_AGENT_ID,
# else the id in the name of the window $TMUX_PANE is in.
#
# Usage:
#   riname.sh --agent <ID> "<title>"     # rename that agent's window
#   riname.sh "<title>"                  # rename THIS window (needs $TMUX_PANE)
#
# Exit: 0 renamed, 2 usage, 4 no live window for the id, 5 tmux refused.
set -uo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
spool_env_resolve

AGENT=""
if [ "${1:-}" = --agent ]; then AGENT="${2:-}"; shift 2 || true; fi
TITLE_TXT="${1:-}"
[ -n "$TITLE_TXT" ] || { sed -n '/^# Usage:/,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
# A title is one line of plain text: no tmux format escapes, no control bytes.
TITLE_TXT="$(printf '%s' "$TITLE_TXT" | tr -d '\000-\037#' | cut -c1-60)"

[ -n "$AGENT" ] || AGENT="${SPOOL_AGENT_ID:-${MCP_BOT_AGENT_ID:-}}"

# 1. Through the map.
if [ -n "$AGENT" ] && spool_valid_id "$AGENT" 2>/dev/null; then
  # shellcheck source=../lib/agent-identity.inc.sh
  . "$_here/../lib/agent-identity.inc.sh"
  [ -n "$(ai_py alive "$AGENT" </dev/null)" ] || ai_record --apply >/dev/null 2>&1
  if ai_py set-title "$AGENT" "$TITLE_TXT" </dev/null >/dev/null 2>&1; then
    out="$(ai_reconcile --apply)"
    pane="$(ai_py alive "$AGENT" </dev/null >/dev/null && python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pane_id") or "")' "$(ai_dir)/$AGENT.json" 2>/dev/null)"
    if [ -n "$pane" ]; then
      cur="$(ai_tmux display-message -p -t "$pane" '#{window_name}' 2>/dev/null)"
      echo "riname: ${pane} -> ${cur} (from the identity map)"
      printf '%s\n' "$out" | grep -E '^FAILED' >&2 && exit 5
      exit 0
    fi
  fi
fi

# 2. Fallback: the agent is not in the map (unreadable from this user).
spool_tmux_argv
if [ -n "$AGENT" ]; then
  spool_valid_id "$AGENT" || exit 2
  PANE="$(spool_pane_of "$AGENT")"
  [ -n "$PANE" ] || { echo "riname: no live window carries ${AGENT}" >&2; exit 4; }
else
  PANE="${TMUX_PANE:-}"
  [ -n "$PANE" ] || { echo "riname: no \$TMUX_PANE here; pass --agent <ID>" >&2; exit 2; }
  CUR="$("${SPOOL_TM[@]}" display-message -p -t "$PANE" '#{window_name}' 2>/dev/null)"
  AGENT="$(spool_id_of_window "$CUR")"
  [ -n "$AGENT" ] || { echo "riname: window '${CUR}' carries no agent id; pass --agent <ID>" >&2; exit 4; }
fi

NEW="$(spool_decorate "$AGENT") ${TITLE_TXT}"
if "${SPOOL_TM[@]}" rename-window -t "$PANE" "$NEW" 2>/dev/null; then
  echo "riname: ${PANE} -> ${NEW}"
else
  echo "riname: tmux refused to rename ${PANE}" >&2
  exit 5
fi
