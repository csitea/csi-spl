#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Gate 10 fail-fast (spec 072 US1): once any job of a master gate run is red,
# the e2e shards stop, so the run ends and the waiting run starts. Before it,
# run 37206701762 held the one slot per ref until 14:36Z with shards 1/3 and
# 2/3 red since 14:12Z (3/3 hung in no-x-scroll to its 45 min timeout).
#
# What it asserts:
#   1. the long steps of wf 10 run under csi-spl-orc/src/bash/scripts/gate-fail-fast.sh:
#      the e2e shards (wui-e2e-mock-serve.sh) and the hub and orc
#      run-all-tests.sh (after an iac red, orc-suite held 37212423666 10.5 min);
#   2. GATE_FAIL_FAST is set on a master push only (a pull request through
#      wf 11 keeps the full red report);
#   3. those jobs read the run's jobs (actions: read) and no job of wf 10 asks
#      for actions: write (wf 11 grants read only; more fails every PR);
#   4. the script, with a stubbed gh: stops the command (and its children)
#      within seconds of a red job and exits 1; with no red job, passes the
#      command's own status through; a failing jobs query is not a red;
#      off (GATE_FAIL_FAST unset), never queries.
# CONTROLS: a wf with the wrapper dropped (e2e, and orc alone), one with GATE_FAIL_FAST on every
# event, one asking actions: write, and a script that only runs the command
# (no watcher) are each red.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
W10="${W10:-$APP_ROOT/.github/workflows/10_ci-quality.yml}"
FF="${FF:-$APP_ROOT/csi-spl-orc/src/bash/scripts/gate-fail-fast.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v yq >/dev/null || { echo "FAIL: yq is required"; exit 1; }
[[ -x "$FF" ]] || { echo "FAIL: no executable $FF"; exit 1; }

# job -> the command its wrapped step must run (literal; a dot in the
# bash match below is a wildcard, which only loosens it)
declare -A WRAPPED=(
  [wui-e2e]='wui-e2e-mock-serve.sh'
  [hub-suite]='csi-spl-api/src/bash/tests/run-all-tests.sh'
  [orc-suite]='csi-spl-orc/src/bash/tests/run-all-tests.sh'
)
check_wf() {  # <wf 10 file> - prints the first violation, or nothing
  local f="$1" j run ff w
  for j in "${!WRAPPED[@]}"; do
    run=$(yq ".jobs.$j.steps[] | select(.run | contains(\"${WRAPPED[$j]}\")) | .run" "$f")
    [[ "$run" =~ gate-fail-fast\.sh[[:space:]\\]+bash[[:space:]]+[^[:space:]]*${WRAPPED[$j]} ]] \
      || { echo "$j: ${WRAPPED[$j]} does not run under gate-fail-fast.sh"; return; }
    ff=$(yq ".jobs.$j.steps[] | select(.run | contains(\"gate-fail-fast\")) | .env.GATE_FAIL_FAST" "$f")
    [[ "$ff" == *"github.event_name == 'push'"* && "$ff" == *"refs/heads/master"* ]] \
      || { echo "$j: GATE_FAIL_FAST '$ff' is not limited to a master push"; return; }
    [[ "$(yq ".jobs.$j.permissions.actions" "$f")" == read ]] \
      || { echo "$j does not grant actions: read (the watcher reads the run's jobs)"; return; }
  done
  w=$(yq '[.permissions.actions, .jobs[].permissions.actions] | map(select(. == "write")) | length' "$f")
  [[ "$w" == 0 ]] || { echo "actions: write asked ($w): wf 11 grants read only, every PR would fail at startup"; return; }
}

v=$(check_wf "$W10"); [[ -z "$v" ]] && pass "wf 10: e2e, hub and orc under gate-fail-fast, master push only, actions: read" || fail "wf 10: $v"

# --- the script, against a stubbed gh -------------------------------------
reset_bin
export PATH="$T/bin:$PATH" GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 GATE_FAIL_FAST_POLL_S=1
gh_red()   { stub gh "echo called >>$T/gh.calls; echo 'wui: browser e2e (mock, generated) 1/3'"; }
gh_green() { stub gh "echo called >>$T/gh.calls; exit 0"; }
gh_down()  { stub gh "echo called >>$T/gh.calls; echo 'HTTP 502' >&2; exit 1"; }

check_script() {  # <script> - prints the first violation, or nothing
  local s="$1" out rc t0 secs
  rm -f "$T/gh.calls" "$T/child.pid"
  gh_red; t0=$SECONDS
  out=$(GATE_FAIL_FAST=1 timeout 60 bash "$s" bash -c "echo \$\$ >$T/child.pid; sleep 20; exit 0" 2>&1); rc=$?
  secs=$((SECONDS - t0))
  (( rc == 1 && secs < 10 )) || { echo "a red job did not stop the command (rc=$rc after ${secs}s)"; return; }
  [[ "$out" == *"::error::gate fail-fast"*"1/3"* ]] || { echo "the stop does not name the red job: $out"; return; }
  sleep 0.5; kill -0 "$(cat "$T/child.pid")" 2>/dev/null && { echo "the command's child survived the stop"; return; }
  gh_green
  GATE_FAIL_FAST=1 bash "$s" bash -c 'sleep 2; exit 3' >/dev/null 2>&1; rc=$?
  (( rc == 3 )) || { echo "with no red job the command's status 3 came back as $rc"; return; }
  gh_down
  GATE_FAIL_FAST=1 bash "$s" bash -c 'sleep 3; exit 0' >/dev/null 2>&1; rc=$?
  (( rc == 0 )) || { echo "a failing jobs query stopped a green command (rc=$rc)"; return; }
  gh_red; rm -f "$T/gh.calls"
  env -u GATE_FAIL_FAST bash "$s" bash -c 'sleep 2; exit 0' >/dev/null 2>&1; rc=$?
  (( rc == 0 )) && [[ ! -e "$T/gh.calls" ]] || { echo "off (no GATE_FAIL_FAST) it still queried or stopped (rc=$rc)"; return; }
}

v=$(check_script "$FF"); [[ -z "$v" ]] && pass "gate-fail-fast.sh: stops on a red job, passes status through, off by default" || fail "gate-fail-fast.sh: $v"

# --- CONTROLS ---------------------------------------------------------------
# drop_wrapper <wf> <regex of the wrapped command> - the wf without the
# gate-fail-fast.sh line in front of that command
drop_wrapper() {
  awk -v cmd="$2" '{l[NR]=$0} END {for (i = 1; i <= NR; i++) {
    if (l[i] ~ /scripts\/gate-fail-fast\.sh \\$/ && l[i+1] ~ cmd) continue; print l[i] }}' "$1"
}
drop_wrapper "$W10" '.' >"$T/c1.yml"
grep -q 'scripts/gate-fail-fast\.sh \\$' "$T/c1.yml" && fail "CONTROL setup: a wrapper is still in c1"
[[ -n "$(check_wf "$T/c1.yml")" ]] && pass "CONTROL: the steps without gate-fail-fast.sh are caught" \
  || fail "CONTROL: the steps without gate-fail-fast.sh passed"
drop_wrapper "$W10" 'csi-spl-orc/src/bash/tests/run-all-tests' >"$T/c1b.yml"
(( $(diff "$W10" "$T/c1b.yml" | grep -c '^<') == 1 )) || fail "CONTROL setup: c1b did not drop exactly the orc wrapper"
[[ -n "$(check_wf "$T/c1b.yml")" ]] && pass "CONTROL: orc-suite alone without gate-fail-fast.sh is caught" \
  || fail "CONTROL: orc-suite alone without gate-fail-fast.sh passed"
yq '(.jobs.hub-suite.steps[] | select(.env.GATE_FAIL_FAST) | .env.GATE_FAIL_FAST) = "1"' "$W10" >"$T/c2.yml"
[[ -n "$(check_wf "$T/c2.yml")" ]] && pass "CONTROL: fail-fast on every event (pull requests too) is caught" \
  || fail "CONTROL: fail-fast on every event passed"
yq '.jobs.wui-e2e.permissions.actions = "write"' "$W10" >"$T/c3.yml"
[[ -n "$(check_wf "$T/c3.yml")" ]] && pass "CONTROL: actions: write (breaks wf 11) is caught" \
  || fail "CONTROL: actions: write passed"
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$T/no-watch.sh"
[[ -n "$(check_script "$T/no-watch.sh")" ]] && pass "CONTROL: a wrapper that only runs the command is caught" \
  || fail "CONTROL: a wrapper that only runs the command passed"

echo "---"; (( fails == 0 )) && echo "PASS: all gate10-fail-fast.tst.sh assertions" || { echo "gate10-fail-fast: $fails failed"; exit 1; }
