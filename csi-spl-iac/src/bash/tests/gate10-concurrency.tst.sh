#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Gate 10's concurrency is a per-ref COALESCING queue for PUSH runs (spec 072
# US1): one gate running, at most one pending, a newer push replaces the
# pending one. The trunk tip then gets a finished verdict once per gate wall
# time (~25 min, 2026-10-04 n=13), and that verdict covers every sha pushed
# since the last. The "cancelled" runs on master are the replaced pending ones.
#
# With a push every 1-4 min the pending push run never started at all (12 of
# 12 master runs read 2026-10-12 cancelled while queued; no verdict since
# 2026-10-10T04:41Z), so a SCHEDULE (hourly) and a workflow_dispatch run get a
# group of their own, keyed on run_id, which no push can replace.
#
# What it asserts on .github/workflows/10_ci-quality.yml:
#   1. concurrency.group is keyed on github.ref;
#   2. every per-run part of it (github.sha / run_id / run_number /
#      run_attempt) sits in an expression gated ONLY on
#      github.event_name == 'schedule' and == 'workflow_dispatch', so a push
#      run's group stays per ref (a per-sha group queues every push: ~15
#      pushes/h x ~70 job-min a gate against a 4-runner pool grows without
#      bound);
#   3. there IS such a run_id part, gated on both schedule and
#      workflow_dispatch, and `on:` has a schedule (else a push replaces the
#      hourly / dispatched run and master again has no verdict);
#   4. concurrency.cancel-in-progress is false (true kills the running gate on
#      every push; with a push every ~4 min and a ~25 min gate, NO verdict on
#      master ever finishes).
# CONTROLS, each red: cancel-in-progress true; a per-sha group; run_id on push
# runs too; schedule left in the shared group; dispatch left in it; no
# schedule trigger.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
W10="${W10:-$APP_ROOT/.github/workflows/10_ci-quality.yml}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v yq >/dev/null || { echo "FAIL: yq is required"; exit 1; }

PER_RUN='github\.(sha|run_id|run_number|run_attempt)'

check_seg() {  # <one ${{ }} expression> - violation for a per-run part, or nothing
  local seg="$1" conds ev
  conds=$(grep -oE "github\.event_name *(==|!=) *'[a-z_]+'" <<<"$seg")
  [[ -n "$conds" ]] || { echo "'$seg' puts a per-run key on every event, push included"; return; }
  while read -r ev; do
    [[ "$ev" =~ ==\ *\'(schedule|workflow_dispatch)\'$ ]] \
      || { echo "'$seg': condition '$ev' (want only == 'schedule' / == 'workflow_dispatch'; a push run must keep the per-ref group)"; return; }
  done <<<"$conds"
  grep -q "== *'schedule'" <<<"$seg" || { echo "'$seg' leaves schedule runs in the push group"; return; }
  grep -q "== *'workflow_dispatch'" <<<"$seg" || { echo "'$seg' leaves workflow_dispatch runs in the push group"; return; }
}

check10() {  # <wf 10 file> - prints the first violation, or nothing
  local f="$1" g c seg v found=0
  g=$(yq '.concurrency.group' "$f"); c=$(yq '.concurrency.cancel-in-progress' "$f")
  [[ "$g" == *'github.ref'* ]] || { echo "group '$g' is not keyed on github.ref"; return; }
  while read -r seg; do
    [[ -n "$seg" && "$seg" =~ $PER_RUN ]] || continue
    v=$(check_seg "$seg"); [[ -z "$v" ]] || { echo "$v"; return; }
    [[ "$seg" == *github.run_id* ]] && found=1
  done < <(grep -oP '\$\{\{.*?\}\}' <<<"$g")
  (( found )) || { echo "group '$g' gives schedule/dispatch runs no run_id group: a push replaces them"; return; }
  [[ "$(yq '.on | has("schedule")' "$f")" == true ]] || { echo "no schedule trigger: master gets no hourly verdict"; return; }
  [[ "$c" == false ]] || { echo "cancel-in-progress is '$c' (want false: true kills the running gate on every push)"; return; }
}

v=$(check10 "$W10"); [[ -z "$v" ]] && pass "wf 10: push group per ref, schedule/dispatch per run_id, hourly schedule, cancel-in-progress false" || fail "wf 10: $v"

control() {  # <name> <yq edit>
  yq "$2" "$W10" >"$T/c.yml"
  v=$(check10 "$T/c.yml")
  [[ -n "$v" ]] && pass "CONTROL: $1 is caught ($v)" || fail "CONTROL: $1 passed"
}
control "cancel-in-progress true" '.concurrency.cancel-in-progress = true'
control "a per-sha group" '.concurrency.group = "quality-gate-${{ github.ref }}-${{ github.sha }}"'
control "run_id on push runs too" \
  ".concurrency.group = \"quality-gate-\${{ github.ref }}\${{ (github.event_name == 'schedule' || github.event_name == 'workflow_dispatch' || github.event_name == 'push') && format('-{0}', github.run_id) || '' }}\""
control "run_id on every non-schedule event (!= form)" \
  ".concurrency.group = \"quality-gate-\${{ github.ref }}\${{ github.event_name != 'schedule' && format('-{0}', github.run_id) || '' }}\""
control "schedule left in the shared group (old group)" '.concurrency.group = "quality-gate-${{ github.ref }}"'
control "schedule left in the shared group (dispatch only)" \
  ".concurrency.group = \"quality-gate-\${{ github.ref }}\${{ github.event_name == 'workflow_dispatch' && format('-{0}', github.run_id) || '' }}\""
control "dispatch left in the shared group" \
  ".concurrency.group = \"quality-gate-\${{ github.ref }}\${{ github.event_name == 'schedule' && format('-{0}', github.run_id) || '' }}\""
control "no schedule trigger" 'del(.on.schedule)'

echo "---"; (( fails == 0 )) && echo "PASS: all gate10-concurrency.tst.sh assertions" || { echo "gate10-concurrency: $fails failed"; exit 1; }
