#!/usr/bin/env bash
# Run every mcp-bot test. Each builds its own MCP_BOT_HOME under a tmp dir.
# Usage: bash csi-spl-orc/src/bash/features/mcp-bot/tests/run-all-tests.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in "$HERE"/test-*.sh; do
  echo "== ${t##*/} =="
  bash "$t" || rc=1
done
if [ "$rc" -eq 0 ]; then echo "ALL mcp-bot TESTS PASSED"; else echo "mcp-bot TESTS FAILED"; fi
exit "$rc"
