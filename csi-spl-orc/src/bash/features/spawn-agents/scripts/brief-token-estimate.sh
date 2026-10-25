#!/usr/bin/env bash
# brief-token-estimate.sh — a cheap token estimate of a lane's seed + brief,
# checked against a budget before the vendor CLI starts (SPL-2177, epic
# SPL-2175, spec 048). No network and no model call: bytes / 4, rounded up,
# the usual rough rate for English prose and code.
#
# Usage: brief-token-estimate.sh FILE...
#   A missing file counts 0 bytes. stdout, at or under the budget:
#     "estimate=<tokens> bytes=<bytes> budget=<budget>"
#   Over it, ONE line on stderr and exit 3, nothing truncated:
#     "FATAL brief-token-estimate: seed + brief estimate <tokens> tokens (<bytes> B / 4) is over the budget <budget> tokens; ..."
#
# SPOOL_BRIEF_TOKEN_BUDGET  the budget in tokens, default 16000. Measured
#   2026-10-25: the largest of the last 20 briefs in dispatch/briefs/ was
#   9726 B and the largest live seed + lifetime/brief.md 18212 B (~4553
#   tokens), so the default is over 3x today's largest.
#
# Exit: 0 at or under the budget, 2 usage or a budget that is not a whole
# number, 3 over the budget.
set -uo pipefail

[ $# -ge 1 ] || { sed -n '7p' "${BASH_SOURCE[0]}" | sed 's/^# *//' >&2; exit 2; }
budget="${SPOOL_BRIEF_TOKEN_BUDGET:-16000}"
[[ "$budget" =~ ^[0-9]+$ ]] || { echo "brief-token-estimate: SPOOL_BRIEF_TOKEN_BUDGET must be a whole number of tokens, got '${budget}'" >&2; exit 2; }

bytes=0
for f in "$@"; do
  [ -r "$f" ] || continue
  bytes=$((bytes + $(wc -c <"$f")))
done
tokens=$(((bytes + 3) / 4))

if [ "$tokens" -gt "$budget" ]; then
  echo "FATAL brief-token-estimate: seed + brief estimate ${tokens} tokens (${bytes} B / 4) is over the budget ${budget} tokens; the CLI does not start. Shorten the brief (point at files instead of pasting them) or raise SPOOL_BRIEF_TOKEN_BUDGET" >&2
  exit 3
fi
printf 'estimate=%s bytes=%s budget=%s\n' "$tokens" "$bytes" "$budget"
