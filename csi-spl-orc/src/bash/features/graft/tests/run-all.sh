#!/usr/bin/env bash
# Run every graft test. Each builds its own sandbox under a tmp dir.
# Usage: bash csi-spl-orc/src/bash/features/graft/tests/run-all.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in "$HERE"/test-*.sh; do
  echo "== ${t##*/} =="
  bash "$t" || rc=1
done
if [ "$rc" -eq 0 ]; then echo "ALL graft TESTS PASSED"; else echo "graft TESTS FAILED"; fi
exit "$rc"
