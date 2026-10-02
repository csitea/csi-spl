#!/usr/bin/env bash
# agent-id-legacy-report.sh — count the legacy agent ids (CLE-/GRK-/AGY-/QWN-,
# specs/061 FR-013, T062) still in use on THIS machine. One line per source:
#   LEGACY <source> <count> [roles <n>] <ids...>
# sources:
#   windows     tmux windows whose name carries a legacy id
#   spool_dirs  real dirs under $SPOOL_ROOT named by a legacy id (a link left
#               by agent-id-rename.sh is an alias, not counted)
#   live_dirs   the spool_dirs a window also carries (a running agent)
#   registry    distinct legacy ids in registry.tsv column 1
#   records     identity records agents/<ID>.json with alive true
# The role ids (001-003) are counted apart ("roles <n>"): they move at the
# rotations (L6). The hub's sends and lane rows are counted by the action
# (do_spl_agent_id_legacy_report with ENV).
#
# Usage: agent-id-legacy-report.sh
# Env: SPOOL_ROOT, SPOOL_TMUX_SOCKET.
set -euo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
spool_env_resolve

R="$SPOOL_ROOT"
TOK='(CLE|GRK|AGY|QWN)-[0-9]+'

# _line SOURCE — the ids on stdin, one per line: deduplicated, roles apart.
_line() {
  local ids roles n r
  ids="$(grep -E "^${TOK}\$" | sort -u || true)"
  roles="$(grep -cE -- '-0*[123]$' <<<"$ids" || true)"
  n="$(grep -c . <<<"$ids" || true)"
  r=""; [ "$roles" -gt 0 ] && r=" roles ${roles}"
  printf 'LEGACY %-10s %s%s %s\n' "$1" "$n" "$r" "$(tr '\n' ' ' <<<"$ids" | sed 's/ *$//')"
}

spool_tmux_argv
wins="$("${SPOOL_TM[@]}" list-windows -a -F '#{window_name}' 2>/dev/null \
  | grep -oE "(^|[^A-Za-z0-9])${TOK}([^0-9]|\$)" | grep -oE "$TOK" | sort -u || true)"
dirs="$(find "$R" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sed 's/@.*//' | sort -u || true)"

_line windows <<<"$wins"
_line spool_dirs <<<"$dirs"
comm -12 <(grep -E "^${TOK}\$" <<<"$dirs" | sort -u || true) <(printf '%s\n' "$wins" | sort -u) | _line live_dirs
{ [ -r "$R/registry.tsv" ] && cut -f1 "$R/registry.tsv" | sed 's/@.*//'; true; } | _line registry
python3 - "$R/agents" <<'EOF' 2>/dev/null | _line records
import glob, json, os, sys
for f in glob.glob(os.path.join(sys.argv[1], "*.json")):
    try:
        d = json.load(open(f))
    except (OSError, ValueError):
        continue
    if isinstance(d, dict) and d.get("alive"):
        print(d.get("id", ""))
EOF
