#!/usr/bin/env bash
# riname.sh — rename an agent's tmux window to "<ID> <title>" (with the
# SPOOL_BOX_TAG in front when one is set), keeping the id.
#
# Forked from the box engine's riname.sh, cut down to the two forms an agent
# needs. tmux only accepts clients whose uid owns the server, so the calls hop
# to $SPOOL_BOX_USER; the sudo hop strips TMUX_PANE, which is why `--agent`
# exists: it resolves the pane through $SPOOL_ROOT/registry.tsv and the live
# window names (spool_pane_of) and survives the hop.
#
# Window names are load-bearing (spool-send.sh and next-agent-id.sh read them),
# so the target is validated against the live pane list before any rename, and
# a failed rename is reported, never swallowed.
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
