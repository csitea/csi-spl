#!/usr/bin/env bash
#------------------------------------------------------------------------------
# One gate for push and pull request (spec 072 A35): 10_ci-quality.yml is the
# reusable gate (push + workflow_call), and 11_ci-public.yml, the pull-request
# entry, carries no job of its own -- it calls 10 on a GitHub-hosted runner.
# So a contributor's pull request and a master push run the same job set.
#
# What it asserts:
#   1. wf 10 is callable (on.workflow_call, input runner) and every runs-on
#      reads inputs.runner first;
#   2. wf 11 runs on pull_request, has exactly one job, and that job calls
#      ./.github/workflows/10_ci-quality.yml with runner '"ubuntu-latest"'
#      (a pull request never reaches the self-hosted runners);
#   3. the job set a pull request gets lists iac, orc, cnf and hygiene.
# CONTROL: a wf 11 that grows a job of its own beside the call is red.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
WF_DIR="${WF_DIR:-$APP_ROOT/.github/workflows}"
W10="$WF_DIR/10_ci-quality.yml"
W11="$WF_DIR/11_ci-public.yml"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v yq >/dev/null || { echo "FAIL: yq is required"; exit 1; }

# --- 1. wf 10 is the reusable gate --------------------------------------------
[[ "$(yq '.on | has("workflow_call")' "$W10")" == true ]] \
  && pass "wf 10 has on.workflow_call" || fail "wf 10 is not callable (no on.workflow_call)"
[[ "$(yq '.on.workflow_call.inputs.runner.type' "$W10")" == string ]] \
  && pass "wf 10 takes a runner input" || fail "wf 10 has no string input 'runner'"
n_ro=$(yq '[.jobs[] | select(has("runs-on"))] | length' "$W10")
n_in=$(yq '.jobs[]."runs-on" | select(. != null)' "$W10" | grep -cF '${{ inputs.runner && fromJSON(inputs.runner) || ')
(( n_ro > 0 && n_ro == n_in )) && pass "wf 10: all $n_ro runs-on read inputs.runner first" \
  || fail "wf 10: $n_in of $n_ro runs-on read inputs.runner first"

# --- 2. wf 11 holds only the call ---------------------------------------------
check11() {  # <wf 11 file> - prints the first violation, or nothing
  local f="$1"
  [[ "$(yq '.on | has("pull_request")' "$f")" == true ]] || { echo "no pull_request trigger"; return; }
  [[ "$(yq '.jobs | length' "$f")" == 1 ]] || { echo "jobs: $(yq '.jobs | keys | join(",")' "$f") (want only the call of wf 10)"; return; }
  [[ "$(yq '.jobs[].uses' "$f")" == ./.github/workflows/10_ci-quality.yml ]] || { echo "the one job does not call ./.github/workflows/10_ci-quality.yml"; return; }
  [[ "$(yq '.jobs[].with.runner' "$f")" == '"ubuntu-latest"' ]] || { echo "runner is not '\"ubuntu-latest\"' (a pull request must stay on hosted runners)"; return; }
}
v=$(check11 "$W11"); [[ -z "$v" ]] && pass "wf 11: pull_request, one job, calls wf 10 on ubuntu-latest" || fail "wf 11: $v"
yq '.jobs.extra = {"runs-on": "ubuntu-latest", "steps": [{"run": "true"}]}' "$W11" >"$T/ctl.yml"
[[ -n "$(check11 "$T/ctl.yml")" ]] && pass "CONTROL: a wf 11 with a job of its own is caught" \
  || fail "CONTROL: a wf 11 with a job of its own passed"

# --- 3. the job set a pull request gets ---------------------------------------
jobs=$(yq '.jobs | keys | .[]' "$W10")
for j in iac-suite orc-suite cnf-suite distribution-hygiene pr-sec-scan; do
  grep -qx "$j" <<<"$jobs" && pass "the gate (push and pull request) has $j" || fail "the gate lacks $j"
done

echo "---"; (( fails == 0 )) && echo "PASS: all ci-one-gate.tst.sh assertions" || { echo "ci-one-gate: $fails failed"; exit 1; }
