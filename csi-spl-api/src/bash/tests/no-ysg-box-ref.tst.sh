#!/usr/bin/env bash
# Reference-hygiene gate (spec 002 T003 / Constitution "Reference implementation
# is read-only"): the shipped spool source MUST NOT reference, import, or shell
# out to any ysg-box path. ysg-box is the behavioural reference, never a
# dependency. Fails (exit 1) if a match is found.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../../go"

# Match ysg-box as a CODE reference — a filesystem path segment, an import
# path, or ysg-box's own MSGS_ROOT env var — NOT the word in a prose comment
# (the docs legitimately name ysg-box as the behavioural reference).
HITS="$(grep -rnE '/ysg-box|ysg-box/|MSGS_ROOT' "$SRC" \
        --include='*.go' 2>/dev/null || true)"

if [ -n "$HITS" ]; then
  echo "FAIL - spool source references ysg-box (must be reference-only):"
  echo "$HITS"
  exit 1
fi
echo "ok   - no ysg-box reference in spool Go source"
