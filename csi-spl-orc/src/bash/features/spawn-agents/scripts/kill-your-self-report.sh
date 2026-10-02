#!/usr/bin/env bash
# kill-your-self-report.sh — read-only discovery for /exit-clean and
# /kill-your-self (ported from the frozen box engine, specs/048 SPL-1160):
# which agent this is, what is still unread in its spool inbox, what git
# holds unpushed, and the candidate spec tasks.md files to tick. Edits nothing;
# the agent owns the checkboxes, the commit and the /exit.
#
# Usage: kill-your-self-report.sh [WORKDIR]      (default: $PWD)
set -uo pipefail
_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
# shellcheck source=../lib/agent-state.inc.sh
. "$_here/../lib/agent-state.inc.sh"
SPOOL_ENV_NO_BINS=1 spool_env_resolve

WORKDIR="${WORKDIR:-${1:-$PWD}}"
echo "=== kill-your-self discovery (read-only) ==="
echo "WORKDIR:  $WORKDIR"
echo "user:     $(id -un)"
echo "date:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# The id: the session's own env first, then the worktree path, then the window.
ID="${SPOOL_AGENT_ID:-${MCP_BOT_AGENT_ID:-}}" SRC=env
if [ -z "$ID" ] && [[ "$WORKDIR" =~ (^|[^A-Za-z0-9])${SPOOL_AGENT_ID_RX}([^0-9]|$) ]]; then ID="${BASH_REMATCH[2]}" SRC=path; fi
wname=""
if [ -n "${TMUX_PANE:-}" ]; then
  spool_tmux_argv
  wname="$("${SPOOL_TM[@]}" list-panes -a -F '#{pane_id}	#{window_name}' 2>/dev/null | awk -F '\t' -v p="$TMUX_PANE" '$1 == p { print $2; exit }')"
  if [ -z "$ID" ]; then ID="$(an_strip "$wname" | grep -oE "^${SPOOL_AGENT_ID_RX}" || true)"; SRC=window; fi
fi
kind="$(spl_kind_of_agent_id "$ID")" || kind=unknown
echo "agent id: ${ID:-unknown}${ID:+ (from $SRC)}   kind: $kind"
echo "window:   ${wname:-n/a}"
if [ -n "$ID" ] && [ -d "$SPOOL_ROOT/$ID/inbox" ]; then
  echo "spool:    $(find "$SPOOL_ROOT/$ID/inbox" -maxdepth 1 -type f | wc -l) unread in $SPOOL_ROOT/$ID/inbox (spool recv --as $ID; --ack once acted on)"
fi

echo
echo "=== git ==="
if git -C "$WORKDIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  br="$(git -C "$WORKDIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  up="$(git -C "$WORKDIR" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)"
  trunk="$(git -C "$WORKDIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/master)"
  echo "branch:   $br"
  echo "dirty:    $(git -C "$WORKDIR" status --porcelain 2>/dev/null | wc -l) path(s)"
  if git -C "$WORKDIR" rev-parse --verify -q "$trunk" >/dev/null; then
    echo "not on $trunk: $(git -C "$WORKDIR" rev-list --count "$trunk..HEAD" 2>/dev/null) commit(s) (as of the last fetch)"
  fi
  [ -n "$up" ] && echo "upstream: $up"
else
  echo "not a git work tree"
fi

echo
echo "=== candidate specs/*/tasks.md (newest first, cap 20) ==="
find "$WORKDIR" \( -path '*/.git/*' -o -path '*/node_modules/*' -o -path '*/.venv/*' \) -prune -o \
  -type f -path '*/specs/*/tasks.md' -printf '%T@|%p\n' 2>/dev/null | sort -t'|' -k1,1nr | head -20 |
while IFS='|' read -r mt path; do
  slug="$(printf '%s' "$path" | sed -n 's|.*/specs/\([^/]*\)/tasks.md|\1|p')"
  open_n="$(grep -cE '^[[:space:]]*- \[ \]' "$path" 2>/dev/null)"; done_n="$(grep -cE '^[[:space:]]*- \[[xX]\]' "$path" 2>/dev/null)"
  echo "  $path"
  echo "    slug=$slug  open=${open_n:-0}  done=${done_n:-0}  mtime=$(date -u -d "@${mt%.*}" +%Y-%m-%dT%H:%M:%SZ)"
done

echo
echo "=== notes ==="
echo "- Open the active feature's tasks.md and tick only the boxes that are truly done."
echo "- Prefer the feature your brief names over the newest mtime."
echo "- This script never edits files and never exits the agent."
