#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: CI volume A5 (SPL-6385, specs/016-spool-testability/
#          ci-volume-2026-11-24.md section 3): wf 20's `test` job reuses wf
#          10's green hub verdict on the same sha instead of re-running
#          run-all-tests.sh, and runs the suite itself in every other case.
#   1. the shape (YAML parsed): the verdict step is the job's first step and
#      has no `if:`; every later step of `test` runs only on
#      `steps.verdict.outputs.reuse != 'true'`; each leg names the wf 10 job
#      that runs its HUB_SUITE_PART, by the exact name 10_ci-quality.yml
#      gives it; `test` may read actions; deploy still needs test green.
#   2. the behaviour: the step's REAL script is read out of the workflow with
#      yq and run against a stub `gh` serving fixture JSON through the real
#      jq filter. reuse=true ONLY when a wf 10 run on this exact sha has every
#      job of that name concluded success; cancelled, skipped, failed, still
#      running, absent, another sha, a half-green matrix or a failed lookup
#      run the suite; the step itself never fails the job.
#   CONTROL: a copy that also counts cancelled as green, and one whose suite
#   step lost its `if:`, are each caught by the same checks.
# Home: wf 20's other test (orc hub-image-key-wf20.tst.sh) covers the mint
# step only; this one reads both wf 10 and wf 20, as the iac workflow tests
# (tenant-host-workflow-40.tst.sh) do.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
WF20="$APP_ROOT/.github/workflows/20_hub-build-deploy.yml"
WF10="$APP_ROOT/.github/workflows/10_ci-quality.yml"
STEP="Reuse wf 10's green hub verdict on this sha"
command -v yq >/dev/null || { echo "SKIP: no yq"; exit 0; }
command -v jq >/dev/null || { echo "SKIP: no jq"; exit 0; }
tmp_dir

# shape <wf20> -> one line per violation
shape() {
  python3 - "$1" "$WF10" "$STEP" <<'PY'
import sys, yaml
w20, w10, step = (yaml.safe_load(open(sys.argv[1])), yaml.safe_load(open(sys.argv[2])), sys.argv[3])
bad = []
t = w20["jobs"]["test"]
steps = t["steps"]
gate = "steps.verdict.outputs.reuse != 'true'"
if steps[0].get("name") != step or steps[0].get("id") != "verdict": bad.append("the verdict step is not the first step of test")
if "if" in steps[0]: bad.append("the verdict step has an if:")
run = str(steps[0].get("run", ""))
for want in ("10_ci-quality.yml/runs?head_sha=$SHA", '"$head" == "$SHA"', "reuse=$reuse", "GITHUB_STEP_SUMMARY", "reused wf 10 run $id"):
    if want not in run: bad.append("the verdict step lacks " + want)
for s in steps[1:]:
    cond = str(s.get("if", ""))
    if not cond.startswith(gate) or "||" in cond: bad.append("step runs on a reused verdict: " + str(s.get("name", s.get("uses"))))
suite = [s for s in steps if "run-all-tests.sh" in str(s.get("run", ""))]
if len(suite) != 1: bad.append("not exactly one run-all-tests.sh step in test")
if (t.get("permissions") or {}).get("actions") != "read": bad.append("test cannot read actions")
inc = {i["part"]: i.get("wf10_job") for i in t["strategy"]["matrix"].get("include", [])}
if set(inc) != set(t["strategy"]["matrix"]["part"]): bad.append("a leg has no wf 10 job: %s" % inc)
for part, name in inc.items():
    jobs = [j for j in w10["jobs"].values() if j.get("name") == name]
    if len(jobs) != 1: bad.append("wf 10 has no single job named %r" % name); continue
    parts = {str((s.get("env") or {}).get("HUB_SUITE_PART")) for s in jobs[0]["steps"] if "run-all-tests.sh" in str(s.get("run", ""))}
    if parts != {part}: bad.append("wf 10 job %r runs HUB_SUITE_PART %s, not %s" % (name, parts, part))
d = w20["jobs"]["deploy"]
if "test" not in d.get("needs", []) or "needs.test.result == 'success'" not in str(d.get("if", "")): bad.append("deploy no longer needs test green")
print("\n".join(bad))
PY
}

# behave <wf20> <case> <fixture-dir> [WAIT_S POLL_S] -> rc; $T/out, $T/sum, $T/log
behave() {
  yq -r ".jobs.test.steps[] | select(.name == \"$STEP\") | .run" "$1" >"$T/step.sh"
  : >"$T/out"; : >"$T/sum"; : >"$T/calls"
  env PATH="$T/bin:$PATH" FIX="$3" CALLS="$T/calls" GITHUB_OUTPUT="$T/out" GITHUB_STEP_SUMMARY="$T/sum" \
    GH_REPO=o/r SHA=aaaa WF10_JOB="hub: one" PART=plain WAIT_S="${4:-0}" POLL_S="${5:-30}" \
    bash "$T/step.sh" >"$T/log" 2>&1
}
# stub gh: `gh api <path> --jq <filter>` -> $FIX/runs.json or $FIX/jobs-<id>[.<n>].json
# through the real jq (the n-th call of a run's jobs reads .<n> when it exists);
# $FIX/fail makes every call fail.
mkdir -p "$T/bin"
cat >"$T/bin/gh" <<'SH'
#!/bin/bash
[[ -e "$FIX/fail" ]] && { echo "HTTP 502" >&2; exit 1; }
path=$2 filter=$4
case "$path" in
  */workflows/10_ci-quality.yml/runs\?head_sha=*) f="$FIX/runs.json" ;;
  */actions/runs/*/jobs*) id=${path#*/actions/runs/}; id=${id%%/*}
    echo "$id" >>"$CALLS"; n=$(grep -cx "$id" "$CALLS")
    f="$FIX/jobs-$id.json"; [[ -f "$FIX/jobs-$id.$n.json" ]] && f="$FIX/jobs-$id.$n.json" ;;
  *) echo "unexpected gh api $path" >&2; exit 9 ;;
esac
[[ -f "$f" ]] || f=/dev/null
jq -r "$filter" "$f"
SH
chmod +x "$T/bin/gh"

runs() { local d=$T/fx/$1; shift; mkdir -p "$d"; printf '{"workflow_runs":[%s]}' "$(IFS=,; echo "$*")" >"$d/runs.json"; }
run() { printf '{"id":%s,"head_sha":"%s","status":"%s"}' "$1" "$2" "${3:-completed}"; }
jobs() { local f=$1; shift; printf '{"jobs":[%s]}' "$(IFS=,; echo "$*")" >"$f"; }
job() { printf '{"name":"%s","status":"%s","conclusion":%s}' "$1" "$2" "$3"; }

runs green "$(run 11 aaaa)";        jobs "$T/fx/green/jobs-11.json" "$(job 'hub: one' completed '"success"')" "$(job 'hub: two' completed '"failure"')"
runs none;                          # no wf 10 run on the sha
runs cancelled "$(run 12 aaaa)";    jobs "$T/fx/cancelled/jobs-12.json" "$(job 'hub: one' completed '"cancelled"')"
runs skipped "$(run 13 aaaa)";      jobs "$T/fx/skipped/jobs-13.json" "$(job 'hub: one' completed '"skipped"')"
runs failed "$(run 14 aaaa)";       jobs "$T/fx/failed/jobs-14.json" "$(job 'hub: one' completed '"failure"')"
runs going "$(run 15 aaaa)";        jobs "$T/fx/going/jobs-15.json" "$(job 'hub: one' in_progress null)"
runs nojob "$(run 16 aaaa)";        jobs "$T/fx/nojob/jobs-16.json" "$(job 'hub: two' completed '"success"')"
runs early "$(run 22 aaaa in_progress)"; jobs "$T/fx/early/jobs-22.json" "$(job 'classify' in_progress null)"
runs othersha "$(run 17 bbbb)";     jobs "$T/fx/othersha/jobs-17.json" "$(job 'hub: one' completed '"success"')"
runs half "$(run 18 aaaa)";         jobs "$T/fx/half/jobs-18.json" "$(job 'hub: one' completed '"success"')" "$(job 'hub: one' completed '"failure"')"
runs fail;                          touch "$T/fx/fail/fail"
runs second "$(run 19 aaaa)" "$(run 20 aaaa)"
jobs "$T/fx/second/jobs-19.json" "$(job 'hub: one' completed '"cancelled"')"
jobs "$T/fx/second/jobs-20.json" "$(job 'hub: one' completed '"success"')"
runs later "$(run 21 aaaa)"
jobs "$T/fx/later/jobs-21.json" "$(job 'hub: one' completed '"success"')"
jobs "$T/fx/later/jobs-21.1.json" "$(job 'hub: one' in_progress null)"

# expect <wf20> <case> <reuse> [WAIT_S POLL_S] -> one PASS or FAIL line
expect() {
  local wf=$1 c=$2 want=$3 rc got
  behave "$wf" "$c" "$T/fx/$c" "${4:-0}" "${5:-30}"; rc=$?
  got=$(sed -n 's/^reuse=//p' "$T/out")
  if [[ $rc -eq 0 && "$got" == "$want" ]] && { [[ $want == false ]] || grep -q 'reused wf 10 run ' "$T/sum"; }; then
    pass "$c: reuse=$want ($(head -1 "$T/sum"))"
  else
    fail "$c: want reuse=$want rc 0, got reuse='$got' rc $rc: $(tr '\n' ' ' <"$T/log")"
  fi
}

out=$(shape "$WF20")
[[ -z "$out" ]] && pass "wf 20 test: verdict step first, every later step gated on reuse != 'true', legs mapped to wf 10's hub-suite/hub-pg, deploy needs test" ||
  fail "wf 20 shape: $out"

expect "$WF20" green true
for c in none cancelled skipped failed going nojob early othersha half fail; do expect "$WF20" "$c" false; done
expect "$WF20" second true
expect "$WF20" later false
expect "$WF20" later true 3 1
grep -q 'wf 10 run 21' "$T/log" && [[ $(grep -cx 21 "$T/calls") -eq 2 ]] &&
  pass "later: WAIT_S polls again until wf 10's job is done (2 lookups)" || fail "later: no second lookup ($(tr '\n' ' ' <"$T/calls"))"

# CONTROL: the same checks catch a copy that counts cancelled as green, and a
# copy whose suite step lost its gate.
python3 - "$WF20" "$T/bad1.yml" "$T/bad2.yml" <<'PY'
import sys
s = open(sys.argv[1]).read()
open(sys.argv[2], "w").write(s.replace('all(.conclusion == "success")', 'all(.conclusion == "success" or .conclusion == "cancelled")', 1))
i = s.index("      - name: run-all-tests.sh\n")
open(sys.argv[3], "w").write(s[:i] + s[i:].replace("        if: steps.verdict.outputs.reuse != 'true'\n", "", 1))
PY
behave "$T/bad1.yml" cancelled "$T/fx/cancelled"
grep -qx 'reuse=true' "$T/out" && pass "control: counting cancelled as green is caught by the cancelled case" ||
  fail "control: the cancelled case did not catch a cancelled-as-green copy"
[[ "$(shape "$T/bad2.yml")" == *"step runs on a reused verdict: run-all-tests.sh"* ]] &&
  pass "control: a suite step without the gate is caught" || fail "control: an ungated suite step was not caught"

echo
[[ $fails -eq 0 ]] && echo "ALL PASSED" || echo "$fails FAILED"
exit $((fails > 0))
