#!/usr/bin/env bash
# Run every *.tst.sh next to this file; exit non-zero if any fails.
set -uo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
# CLE-77923: no test may write the live spool root or ring a live pane. Under
# SPOOL_TEST=1 spool-send.sh / agent-send.sh / spool-notify.sh refuse the live
# root, poke no box tmux and relay nothing to the hub. A refusal is logged to
# SPOOL_TEST_GUARD_LOG and fails the suite: callers often send 2>/dev/null, so
# a test can pass while a send of its own tried to reach the live root.
export SPOOL_TEST=1
# specs/061 FR-004: pin the clock the legacy agent-id cutoff reads, so the
# CLE-/PRB-/ORC- fixtures here do not turn the suite red at
# SPOOL_LEGACY_ID_UNTIL on their own. The cutoff itself is tested in
# features/spawn-agents/tests/test-agent-id.sh; L9c drops this pin when it
# converts the fixtures to c-NNN.
export SPOOL_NOW="${SPOOL_NOW:-2026-10-01T00:00:00Z}"
guard_own=0
if [[ -z "${SPOOL_TEST_GUARD_LOG:-}" ]]; then
  SPOOL_TEST_GUARD_LOG=$(mktemp); guard_own=1
fi
export SPOOL_TEST_GUARD_LOG
fails=0 n=0
for t in "$dir"/*.tst.sh; do
  [[ -f "$t" ]] || continue
  n=$((n + 1))
  echo "=== $(basename "$t")"
  bash "$t" || { echo "FAILED: $(basename "$t")"; fails=$((fails + 1)); }
done
echo "=== $((n - fails))/$n test files passed"
if [[ -s "$SPOOL_TEST_GUARD_LOG" ]]; then
  echo "FAILED: a test reached for the live spool root (refused by the SPOOL_TEST guard):"
  sed 's/^/  /' "$SPOOL_TEST_GUARD_LOG"
  fails=$((fails + 1))
fi
(( guard_own )) && rm -f "$SPOOL_TEST_GUARD_LOG"
[[ "$fails" -eq 0 ]]
