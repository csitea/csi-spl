#!/usr/bin/env bash
# Run every *.tst.sh next to this file; exit non-zero if any fails.
set -uo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
fails=0 n=0
for t in "$dir"/*.tst.sh; do
  [[ -f "$t" ]] || continue
  n=$((n + 1))
  echo "=== $(basename "$t")"
  bash "$t" || { echo "FAILED: $(basename "$t")"; fails=$((fails + 1)); }
done
echo "=== $((n - fails))/$n test files passed"
[[ "$fails" -eq 0 ]]
