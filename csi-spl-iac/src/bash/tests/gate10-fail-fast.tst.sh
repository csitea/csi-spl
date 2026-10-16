#!/usr/bin/env bash
# test-timeout: 240 -- 80..83 s in red CI runs 38190838689, 38197054999 (n=2) against the 120 s default; 77..86 s locally at load1 ~49 on 16 cores
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
#      off (GATE_FAIL_FAST unset), never queries;
#   5. as an e2e shard (GITHUB_JOB=wui-e2e, round 5 action 08): a red in
#      every hub, orc, iac and cnf job of wf 10 does NOT stop it (the shard
#      ends with its own status); a red wui-generate or wui-suite does. The
#      job names come from wf 10, so a renamed job breaks this.
#   6. as the orc or hub suite (round 8 action 01): a red while a job outside
#      them (an e2e shard) is still in progress does NOT stop it; once that
#      job ends it stops within one poll. Their own jobs never hold them, a
#      failing in-progress query holds, and any other job (orc-features)
#      still stops at once on a red while e2e runs.
# CONTROLS: a wf with the wrapper dropped (e2e, and orc alone), one with GATE_FAIL_FAST on every
# event, one asking actions: write, a script that only runs the command
# (no watcher), one whose e2e shards stop on any red, one whose orc and hub
# suites stop at once on a red (the old rule), and one where their own jobs
# hold them, are each red.
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
  [hub-pg]='csi-spl-api/src/bash/tests/run-all-tests.sh'
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
# The stub answers the two queries apart: the in-progress names (--jq
# selects .status == "in_progress") from $T/running, the red names from
# $T/red. $T/down fails every query, $T/down-running the in-progress one.
stub gh "echo called >>$T/gh.calls
case \"\$*\" in
  *in_progress*) [[ -e $T/down || -e $T/down-running ]] && { echo 'HTTP 502' >&2; exit 1; }; cat $T/running ;;
  *) [[ -e $T/down ]] && { echo 'HTTP 502' >&2; exit 1; }; cat $T/red ;;
esac"

# wf 10 job names as the jobs API prints them (matrix shard 1)
wf_name() { yq ".jobs.$1.name" "$W10" | sed 's/\${{ *matrix\.shard *}}/1/'; }
for j in hub-suite hub-pg orc-suite orc-features iac-suite cnf-suite; do wf_name "$j"; done >"$T/red-other"
wf_name wui-generate >"$T/red-generate"
wf_name wui-suite >"$T/red-unit"
wf_name iac-suite >"$T/red-iac"
wf_name wui-e2e >"$T/red-e2e"
{ wf_name orc-suite; wf_name orc-suite | sed 's#1/2#2/2#'; wf_name hub-suite; wf_name hub-pg; } >"$T/run-suites"
# gh_set <red names file|-> [<in-progress names file>] - what the stub answers
gh_set() {
  rm -f "$T/down" "$T/down-running"
  if [[ "$1" == - ]]; then : >"$T/red"; else cp "$T/$1" "$T/red"; fi
  cp "$T/${2:-run-suites}" "$T/running"
}
gh_red()   { gh_set red-e2e; }
gh_green() { gh_set -; }
gh_down()  { gh_set -; touch "$T/down"; }
gh_names() { gh_set "$1"; }

# held_then_stops <script> <GITHUB_JOB> - an iac red while e2e shard 1/3
# runs; the shard ends once the script prints its hold (30 s cap). Ordered
# by events, not by the clock: "the shard ended after 3 s" read a slow first
# poll of the old rule on a loaded CI runner as a hold (runs 38190838689,
# 38197054999, 38209222818). The command runs 20 s and exits 0, so rc 1
# is a stop. Prints a violation, or nothing.
held_then_stops() {
  local s="$1" job="$2" rc t0 secs ended bg
  gh_set red-iac; cat "$T/run-suites" "$T/red-e2e" >"$T/running"
  rm -f "$T/held.out" "$T/e2e.ended" "$T/held.done"
  ( for _ in $(seq 300); do
      [[ -e "$T/held.done" ]] && exit 0
      grep -q 'gate fail-fast: held' "$T/held.out" 2>/dev/null && break
      sleep 0.1
    done
    touch "$T/e2e.ended"; cp "$T/run-suites" "$T/running" ) &
  bg=$!
  t0=$SECONDS
  GATE_FAIL_FAST=1 GITHUB_JOB="$job" timeout 90 bash "$s" bash -c 'sleep 20; exit 0' >"$T/held.out" 2>&1; rc=$?
  secs=$((SECONDS - t0)); ended=0; [[ -e "$T/e2e.ended" ]] && ended=1
  touch "$T/held.done"; wait "$bg"
  (( rc != 1 || ended )) || { echo "$job: an iac red stopped it after ${secs}s while an e2e shard still ran"; return; }
  (( rc == 1 )) || { echo "$job: not stopped within one poll of the e2e shard's end (rc=$rc after ${secs}s)"; return; }
  grep -q 'gate fail-fast: held' "$T/held.out" || { echo "$job: the hold is not printed: $(cat "$T/held.out")"; return; }
  grep -q '::error::gate fail-fast: stopped, so the next gate run starts; red in this run: iac' "$T/held.out" \
    || { echo "$job: the stop line changed (report-ci-gate parses it): $(cat "$T/held.out")"; return; }
}

check_script() {  # <script> - prints the first violation, or nothing
  local s="$1" out rc t0 secs need
  rm -f "$T/gh.calls" "$T/child.pid"
  gh_red; t0=$SECONDS
  out=$(GATE_FAIL_FAST=1 GITHUB_JOB=orc-suite timeout 60 bash "$s" bash -c "echo \$\$ >$T/child.pid; sleep 20; exit 0" 2>&1); rc=$?
  secs=$((SECONDS - t0))
  (( rc == 1 && secs < 10 )) || { echo "a red job did not stop the command (rc=$rc after ${secs}s)"; return; }
  [[ "$out" == *"::error::gate fail-fast"*"$(cat "$T/red-e2e")"* ]] || { echo "the stop does not name the red job: $out"; return; }
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
  gh_names red-other; rm -f "$T/gh.calls"
  GATE_FAIL_FAST=1 GITHUB_JOB=wui-e2e bash "$s" bash -c 'sleep 3; exit 3' >/dev/null 2>&1; rc=$?
  (( rc == 3 )) && [[ -s "$T/gh.calls" ]] || { echo "an e2e shard was stopped by a red it does not need (hub/orc/iac/cnf), rc=$rc"; return; }
  for need in red-generate red-unit; do
    gh_names "$need"; t0=$SECONDS
    GATE_FAIL_FAST=1 GITHUB_JOB=wui-e2e timeout 60 bash "$s" bash -c 'sleep 20; exit 0' >/dev/null 2>&1; rc=$?
    secs=$((SECONDS - t0))
    (( rc == 1 && secs < 10 )) || { echo "an e2e shard was not stopped by $(cat "$T/$need") (rc=$rc after ${secs}s)"; return; }
  done
  check_spares "$s"
}

check_spares() {  # <script> - the orc and hub suites' rule; prints the first violation, or nothing
  local s="$1" v rc t0 secs job
  for job in orc-suite hub-suite hub-pg; do
    v=$(held_then_stops "$s" "$job"); [[ -z "$v" ]] || { echo "$v"; return; }
  done
  gh_set red-iac; touch "$T/down-running"
  GATE_FAIL_FAST=1 GITHUB_JOB=orc-suite bash "$s" bash -c 'sleep 2; exit 3' >/dev/null 2>&1; rc=$?
  (( rc == 3 )) || { echo "orc-suite was stopped on a failing in-progress query (rc=$rc)"; return; }
  gh_set red-iac; cat "$T/run-suites" "$T/red-e2e" >"$T/running"; t0=$SECONDS
  GATE_FAIL_FAST=1 GITHUB_JOB=orc-features timeout 60 bash "$s" bash -c 'sleep 12; exit 0' >/dev/null 2>&1; rc=$?
  secs=$((SECONDS - t0))
  (( rc == 1 && secs < 10 )) || { echo "orc-features was not stopped at once by a red while e2e ran (rc=$rc after ${secs}s)"; return; }
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
sed "s/^\( *wui-e2e) *needs=\).*/\1'.' ;;/" "$FF" >"$T/no-filter.sh"
cmp -s "$FF" "$T/no-filter.sh" && fail "CONTROL setup: no-filter.sh is the script unchanged"
[[ -n "$(check_script "$T/no-filter.sh")" ]] && pass "CONTROL: e2e shards that stop on any red are caught" \
  || fail "CONTROL: e2e shards that stop on any red passed"
sed "s/^\( *orc-suite|hub-suite|hub-pg) needs='.'\);.*/\1 ;;/" "$FF" >"$T/no-spare.sh"
cmp -s "$FF" "$T/no-spare.sh" && fail "CONTROL setup: no-spare.sh is the script unchanged"
v=$(check_spares "$T/no-spare.sh")
[[ "$v" == *"stopped it after"*"while an e2e shard still ran"* ]] && pass "CONTROL: orc and hub suites that stop at once on a red (the old rule) are caught" \
  || fail "CONTROL: orc and hub suites that stop at once on a red: '$v'"
sed 's/grep -vE -- "\$spares" <<<"\$names" | grep \./grep . <<<"$names"/' "$FF" >"$T/self-hold.sh"
cmp -s "$FF" "$T/self-hold.sh" && fail "CONTROL setup: self-hold.sh is the script unchanged"
v=$(check_spares "$T/self-hold.sh")
[[ "$v" == *"not stopped within one poll"* ]] && pass "CONTROL: orc and hub suites held by their own jobs are caught" \
  || fail "CONTROL: orc and hub suites held by their own jobs: '$v'"

echo "---"; (( fails == 0 )) && echo "PASS: all gate10-fail-fast.tst.sh assertions" || { echo "gate10-fail-fast: $fails failed"; exit 1; }
