#!/usr/bin/env bash
# Run every spawn-agents test. Each one uses a throwaway SPOOL_ROOT and a
# private tmux server; nothing touches /var/spool-hub or the box user's tmux.
# Usage: bash csi-spl-orc/src/bash/features/spawn-agents/tests/run-all-tests.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# CLE-77923: under SPOOL_TEST=1 the send/notify path refuses the live root.
export SPOOL_TEST=1
rc=0
for t in "$HERE"/test-*.sh; do
  echo "== ${t##*/} =="
  bash "$t" || rc=1
done
if [ "$rc" -eq 0 ]; then echo "ALL spawn-agents TESTS PASSED"; else echo "spawn-agents TESTS FAILED"; fi
exit "$rc"
