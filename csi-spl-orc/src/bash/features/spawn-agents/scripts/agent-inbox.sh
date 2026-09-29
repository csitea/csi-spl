#!/usr/bin/env bash
# agent-inbox.sh — list the reports an agent (an orchestrator) has not seen
# yet, from both mailboxes of the switch-over (specs/048 switch-over §3):
#
#   spool   $SPOOL_ROOT/<ID>/inbox/*.json - what agents of this harness send
#   legacy  $SPOOL_LEGACY_INBOX_ROOT/*/outbox/*.md - what agents spawned by the
#           frozen engine write for their orchestrator (only when that root is set)
#
# Nothing is moved or acknowledged: `spool recv --ack` stays the way to archive.
# "New" is newer than a seen-mark, a file whose mtime is the last listing; each
# listing moves it forward unless --peek. The first listing of an id with no
# mark shows the newest --first (default 20) of each kind.
#
# Usage:
#   agent-inbox.sh --as <ID> [--peek] [--first N]
#
# stdout, one line per report, oldest first:
#   spool   <ts> <from> <kind> <task_id> <file>  <first body line, cut>
#   legacy  <mtime UTC> <agent> <file>  <subject from the file name>
# then "new: <n spool>, <n legacy>".
# Env: SPOOL_AGENT_INBOX_MARK - the mark file (default <SPOOL_ROOT>/<ID>/.agent-inbox-seen)
# Exit: 0 listed (even none), 2 usage, 3 no spool mailbox for <ID>.
set -uo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
SPOOL_ENV_NO_BINS=1 spool_env_resolve

usage() { sed -n '/^# Usage:/,/^# Env:/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' >&2; exit 2; }
AS="" PEEK=0 FIRST=20
while [ "$#" -gt 0 ]; do
  case "$1" in
    --as)    [ "$#" -ge 2 ] || usage; AS="$2"; shift 2 ;;
    --peek)  PEEK=1; shift ;;
    --first) [ "$#" -ge 2 ] || usage; FIRST="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "agent-inbox: unknown argument $1" >&2; usage ;;
  esac
done
[ -n "$AS" ] || usage
spool_valid_id "$AS" || exit 2
[[ "$FIRST" =~ ^[0-9]+$ ]] || usage
INBOX="$SPOOL_ROOT/$AS/inbox"
[ -d "$INBOX" ] || { echo "agent-inbox: no spool mailbox $INBOX" >&2; exit 3; }
MARK="${SPOOL_AGENT_INBOX_MARK:-$SPOOL_ROOT/$AS/.agent-inbox-seen}"
NOW="$(mktemp)"; trap 'rm -f "$NOW"' EXIT   # the new mark, taken BEFORE the scan

newer() {  # DIR... : files newer than the mark, or the newest FIRST when there is none
  if [ -e "$MARK" ]; then find "$@" -maxdepth 1 -type f -newer "$MARK" -printf '%T@ %p\n' 2>/dev/null
  else find "$@" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n "$FIRST"; fi
}

n_spool=0
while read -r _ f; do
  [ -n "$f" ] || continue
  case "$f" in *.json) ;; *) continue ;; esac
  python3 - "$f" <<'EOF_PY' && n_spool=$((n_spool + 1))
import json, sys
p = sys.argv[1]
try:
    d = json.load(open(p))
except (OSError, ValueError):
    sys.exit(1)
body = (d.get("body") or "").strip().splitlines()
first = (body[0] if body else "")[:120]
print("spool  %s %s %s %s %s  %s" % (d.get("ts", "?"), d.get("from", "?"), d.get("kind", "?"),
                                     d.get("task_id", "-"), p, first))
EOF_PY
done < <(newer "$INBOX" | sort -n)

n_legacy=0
if [ -n "${SPOOL_LEGACY_INBOX_ROOT:-}" ] && [ -d "$SPOOL_LEGACY_INBOX_ROOT" ]; then
  while read -r ts f; do
    [ -n "$f" ] || continue
    agent="$(basename "$(dirname "$(dirname "$f")")")"
    subj="$(basename "$f" .md | sed -E 's/^[0-9TZ]+--[^-]+-[0-9]+--//')"
    printf 'legacy %s %s %s  %s\n' "$(date -u -d "@${ts%.*}" +%Y-%m-%dT%H:%M:%SZ)" "$agent" "$f" "$subj"
    n_legacy=$((n_legacy + 1))
  done < <(newer "$SPOOL_LEGACY_INBOX_ROOT"/*/outbox | grep -E '\.md$' | sort -n)
fi

echo "new: $n_spool spool, $n_legacy legacy"
[ "$PEEK" = 1 ] || touch -r "$NOW" "$MARK" 2>/dev/null || echo "agent-inbox: WARN cannot write the seen-mark $MARK" >&2
