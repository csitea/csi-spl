#!/usr/bin/env bash
#------------------------------------------------------------------------------
# The csi-spl-utl suite inside the iac suite (SPL-2221). csi-spl-utl has no CI
# job of its own; a push touching csi-spl-utl/** classifies as parts=all
# (ci-doc-only.sh), so the iac job of workflow 10 runs this file and, through
# it, every csi-spl-utl/src/bash/tests/*.tst.sh (the reliability round rows).
#   1. at least one utl test exists (a moved dir must not pass as green)
#   2. each utl test exits 0; a red one is named
#------------------------------------------------------------------------------
set -uo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
utl_tests="$(cd "$dir/../../../.." && pwd)/csi-spl-utl/src/bash/tests"

fails=0 n=0
shopt -s nullglob
for t in "$utl_tests"/*.tst.sh; do
  n=$((n + 1))
  if out=$(bash "$t" 2>&1); then
    echo "PASS: utl $(basename "$t")"
  else
    grep '^FAIL' <<< "$out"
    echo "FAIL: utl $(basename "$t")"
    fails=$((fails + 1))
  fi
done

if (( n == 0 )); then
  echo "FAIL: no csi-spl-utl test found under $utl_tests"
  exit 1
fi
echo "utl-suite: $n file(s), $fails failure(s)"
[[ "$fails" -eq 0 ]]
