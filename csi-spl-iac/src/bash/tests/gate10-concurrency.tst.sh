#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Gate 10's concurrency is a per-ref COALESCING queue (spec 072 US1): one gate
# running, at most one pending, a newer push replaces the pending one. The
# trunk tip then gets a finished verdict once per gate wall time (~25 min,
# 2026-10-04 n=13), and that verdict covers every sha pushed since the last.
# The "cancelled" runs on master are the replaced pending ones, not lost gates.
#
# What it asserts on .github/workflows/10_ci-quality.yml:
#   1. concurrency.group is keyed on github.ref and NOT on github.sha /
#      run_id / run_number (a per-sha group queues every push: ~15 pushes/h x
#      ~70 job-min a gate against a 4-runner pool grows without bound);
#   2. concurrency.cancel-in-progress is false (true kills the running gate on
#      every push; with a push every ~4 min and a ~25 min gate, NO verdict on
#      master ever finishes).
# CONTROLS: a copy with cancel-in-progress true, and one with a per-sha group,
# are both red.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
W10="${W10:-$APP_ROOT/.github/workflows/10_ci-quality.yml}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v yq >/dev/null || { echo "FAIL: yq is required"; exit 1; }

check10() {  # <wf 10 file> - prints the first violation, or nothing
  local f="$1" g c
  g=$(yq '.concurrency.group' "$f"); c=$(yq '.concurrency.cancel-in-progress' "$f")
  [[ "$g" == *'github.ref'* ]] || { echo "group '$g' is not keyed on github.ref"; return; }
  [[ "$g" =~ github\.(sha|run_id|run_number|run_attempt) ]] && { echo "group '$g' is per run/sha: every push queues a gate"; return; }
  [[ "$c" == false ]] || { echo "cancel-in-progress is '$c' (want false: true kills the running gate on every push)"; return; }
}

v=$(check10 "$W10"); [[ -z "$v" ]] && pass "wf 10: per-ref group, cancel-in-progress false" || fail "wf 10: $v"

yq '.concurrency.cancel-in-progress = true' "$W10" >"$T/c1.yml"
[[ -n "$(check10 "$T/c1.yml")" ]] && pass "CONTROL: cancel-in-progress true is caught" \
  || fail "CONTROL: cancel-in-progress true passed"
yq '.concurrency.group = "quality-gate-${{ github.ref }}-${{ github.sha }}"' "$W10" >"$T/c2.yml"
[[ -n "$(check10 "$T/c2.yml")" ]] && pass "CONTROL: a per-sha group is caught" \
  || fail "CONTROL: a per-sha group passed"

echo "---"; (( fails == 0 )) && echo "PASS: all gate10-concurrency.tst.sh assertions" || { echo "gate10-concurrency: $fails failed"; exit 1; }
