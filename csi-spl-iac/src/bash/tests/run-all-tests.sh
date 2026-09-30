#!/usr/bin/env bash
# Run every *.tst.sh next to this file; exit non-zero if any fails.
#
# Each test runs under a PER-TEST TIMEOUT (IAC_TEST_TIMEOUT, default 120 s): a
# test that hangs (tf-steps render is network-bound and once hung an agent for
# five hours) is KILLED and counted as a FAILURE with its name, never a hang.
# This is what makes the pre-push hook (which runs this suite) safe to gate on.
set -uo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
to="${IAC_TEST_TIMEOUT:-120}"
fails=0 n=0
for t in "$dir"/*.tst.sh; do
  [[ -f "$t" ]] || continue
  n=$((n + 1))
  echo "=== $(basename "$t")"
  rc=0
  timeout -k 5 "$to" bash "$t" || rc=$?
  if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
    echo "TIMED OUT (>${to}s), killed: $(basename "$t")"; fails=$((fails + 1))
  elif [[ "$rc" -ne 0 ]]; then
    echo "FAILED: $(basename "$t")"; fails=$((fails + 1))
  fi
done
echo "=== $((n - fails))/$n test files passed"
[[ "$fails" -eq 0 ]]
