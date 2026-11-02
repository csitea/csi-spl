#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a branch dispatch of wf 10 or 11 can go green (SPL-4668) and neither
#          gate it was red on got weaker. Every dispatch was red on two things:
#          no origin/master in the orc-suite checkout, so
#          spl-spawn-place-supply SKIPs and "Nothing skipped" fails; and wf 11
#          (no secret) failing the hygiene sweep's required private overlay.
#   1. orc-suite fetches origin/master, off master only, before its tests
#   2. that step's own script, in a checkout of a branch: the ref was missing
#      and is there after; a fetch that cannot work fails, never a skip
#   3. "Nothing skipped" still fails on the noon-bytes SKIP line
#   4. SPL_PRIVATE_REQUIRED, evaluated from the workflow's own expression per
#      caller and event: only wf 11 and pull requests are not required
#   5. only wf 11 passes private_overlay_optional, and it holds no secret;
#      wf 13 passes none and keeps secrets: inherit
#   CONTROLS: a copy of the workflows with each defect planted is refused
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
WF_DIR="$APP_ROOT/.github/workflows"
W10="$WF_DIR/10_ci-quality.yml"; W11="$WF_DIR/11_ci-public.yml"; W13="$WF_DIR/13_ci-next-image.yml"
REFSPEC='+refs/heads/master:refs/remotes/origin/master'
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v yq >/dev/null || { echo "FAIL: yq is required"; exit 1; }

# step_run <workflow> <job> <step name prefix> - that step's run script
step_run() { J="$2" N="$3" yq -r '.jobs[strenv(J)].steps[] | select((.name // "") | test("^" + strenv(N))) | .run' "$1"; }

# ref_step_problem <workflow> - why orc-suite would lack the ref, or nothing
ref_step_problem() {
  local names fetch run
  names=$(REFSPEC="$REFSPEC" yq -r '.jobs."orc-suite".steps | to_entries[] | select((.value.run // "") | contains(strenv(REFSPEC))) | .key' "$1")
  fetch=${names%%$'\n'*}
  [[ -n "$fetch" ]] || { echo "no step fetches origin/master"; return; }
  run=$(yq -r '.jobs."orc-suite".steps | to_entries[] | select(.value.name == "run-all-tests.sh") | .key' "$1")
  (( fetch < run )) || { echo "the fetch (step $fetch) comes after the tests (step $run)"; return; }
  [[ "$(F="$fetch" yq -r '.jobs."orc-suite".steps[env(F)].if' "$1")" == "\${{ github.ref != 'refs/heads/master' }}" ]] \
    || echo "the fetch is not limited to refs other than master"
}

# required_problems <w10> <w11> <w13> - each caller + event against its verdict
required_problems() {
  local opt11 opt13
  opt11=$(yq -r '.jobs.gate.with.private_overlay_optional // false' "$2")
  opt13=$(yq -r '.jobs.gate.with.private_overlay_optional // false' "$3")
  yq -r '.jobs."distribution-hygiene".steps[] | select(.name == "Sweep") | .env.SPL_PRIVATE_REQUIRED' "$1" |
    OPT11="$opt11" OPT13="$opt13" python3 -c '
import os, re, sys
e = sys.stdin.read().strip()
m = re.fullmatch(r"\$\{\{(.*)\}\}", e)
if not m: sys.exit("not an expression: " + e)
py = m.group(1).replace("&&", " and ").replace("||", " or ")
py = re.sub(r"!(?!=)", " not ", py).replace("github.", "github_").replace("inputs.", "inputs_")
R = "csitea/csi-spl"
o11, o13 = os.environ["OPT11"] == "true", os.environ["OPT13"] == "true"
for who, repo, event, opt, want in (
    ("wf 10 push", R, "push", False, "1"), ("wf 10 schedule", R, "schedule", False, "1"),
    ("wf 10 branch dispatch", R, "workflow_dispatch", False, "1"),
    ("wf 13 push", R, "push", o13, "1"), ("wf 13 schedule", R, "schedule", o13, "1"),
    ("wf 13 dispatch", R, "workflow_dispatch", o13, "1"),
    ("wf 11 branch dispatch", R, "workflow_dispatch", o11, "0"),
    ("wf 11 pull request", R, "pull_request", o11, "0"),
    ("a fork, wf 10 push", "someone/fork", "push", False, "0")):
    got = eval(py, {"__builtins__": {}}, {"github_repository": repo, "github_event_name": event,
                                          "inputs_private_overlay_optional": opt})
    if got != want: print(f"{who}: required={got}, want {want}")
'
}

# caller_problems <dir> - who passes the input, who holds the secret
caller_problems() {
  local f
  for f in "$1"/*.yml; do
    case "$(basename "$f")" in 10_ci-quality.yml|11_ci-public.yml) continue ;; esac
    grep -q 'private_overlay_optional' "$f" && echo "$(basename "$f") passes private_overlay_optional"
  done
  [[ "$(yq -r '.jobs.gate.with.private_overlay_optional' "$1/11_ci-public.yml")" == true ]] || echo "wf 11 does not pass it"
  grep -qE '^[[:space:]]+secrets:' "$1/11_ci-public.yml" && echo "wf 11 holds a secret"
  [[ "$(yq -r '.jobs.gate.secrets' "$1/13_ci-next-image.yml")" == inherit ]] || echo "wf 13 lost secrets: inherit"
  grep -q 'private_overlay_optional' "$1/10_ci-quality.yml" || echo "wf 10 has no such input"
  [[ "$(yq -r '.on.workflow_call.inputs.private_overlay_optional.default' "$1/10_ci-quality.yml")" == false ]] || echo "the input does not default to false"
}

# --- 1. the step -----------------------------------------------------------------
p=$(ref_step_problem "$W10")
[[ -z "$p" ]] && pass "1. orc-suite fetches origin/master off master, before its tests" || fail "1. $p"

# --- 2. its own script, in a checkout like the job's ------------------------------
git init -q -b master "$T/o"
git -C "$T/o" -c user.name=t -c user.email=t@example.test commit -q --allow-empty -m one
mkdir -p "$T/o/d"; echo noon >"$T/o/d/f"; git -C "$T/o" add d/f
git -C "$T/o" -c user.name=t -c user.email=t@example.test commit -q -m two
git -C "$T/o" branch review/x
step_run "$W10" orc-suite 'origin/master beside' >"$T/step.sh"
git clone -q --depth 1 --branch review/x "file://$T/o" "$T/c"
if git -C "$T/c" cat-file -e origin/master:d/f 2>/dev/null; then
  fail "2. the branch checkout already has origin/master: this proves nothing"
else pass "2. RED CONTROL: a branch checkout has no origin/master (the SKIP's condition)"; fi
( cd "$T/c" && bash "$T/step.sh" ) >"$T/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && git -C "$T/c" cat-file -e origin/master:d/f 2>/dev/null &&
  pass "2. the step gives it origin/master" || { fail "2. step rc=$rc"; sed 's/^/    | /' "$T/out"; }
git -C "$T/c" remote set-url origin "file://$T/gone"
git -C "$T/c" update-ref -d refs/remotes/origin/master
( cd "$T/c" && bash "$T/step.sh" ) >"$T/out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q '::error::no origin/master' "$T/out" &&
  pass "2. no remote: the step fails the job, never a quiet skip" || { fail "2. no remote rc=$rc"; sed 's/^/    | /' "$T/out"; }

# --- 3. the gate that refuses a CI skip stays --------------------------------------
step_run "$W10" orc-suite 'Nothing skipped' >"$T/gate.sh"
gate() { printf '%s\n' "$1" >"$T/orc-suite.log"; RUNNER_TEMP="$T" bash "$T/gate.sh" >"$T/out" 2>&1; }
gate 'SKIP: 2 no origin/master to compare the noon bytes with'
[[ $? -ne 0 ]] && grep -q 'an orc check skipped in CI' "$T/out" &&
  pass "3. the noon-bytes SKIP still fails Nothing skipped" || fail "3. the SKIP passed the gate"
gate 'PASS: 2 noon: the same bytes as origin/master'"'"'s placer sends'
[[ $? -eq 0 ]] && pass "3. the comparison having run passes it" || fail "3. a clean log failed the gate"

# --- 4 + 5. who must hold the overlay ----------------------------------------------
p=$(required_problems "$W10" "$W11" "$W13")
[[ -z "$p" ]] && pass "4. required on wf 10 and wf 13, every event; not on wf 11 or a pull request" || fail "4. $p"
p=$(caller_problems "$WF_DIR")
[[ -z "$p" ]] && pass "5. only wf 11 passes it, with no secret; wf 13 inherits" || fail "5. $p"

# --- CONTROLS ----------------------------------------------------------------------
mkdir -p "$T/p"; cp "$WF_DIR"/*.yml "$T/p/"
# plant <what the check must say> <file> <sed> <check...>
plant() {
  local want=$1 f=$2 ex=$3 out; shift 3
  sed -E "$ex" "$WF_DIR/$f" >"$T/p/$f"
  cmp -s "$WF_DIR/$f" "$T/p/$f" && { fail "CONTROL $want: the plant changed nothing"; return; }
  out=$("$@" 2>&1)
  [[ "$out" == *"$want"* ]] && pass "CONTROL: $want" || fail "CONTROL $want: got '$out'"
  cp "$WF_DIR/$f" "$T/p/$f"
}
PW10="$T/p/10_ci-quality.yml"; PW11="$T/p/11_ci-public.yml"; PW13="$T/p/13_ci-next-image.yml"
plant "no step fetches origin/master" 10_ci-quality.yml 's#\+refs/heads/master:refs/remotes/origin/master#refs/heads/master#' ref_step_problem "$PW10"
plant "the fetch is not limited" 10_ci-quality.yml "/^        if: \\$\\{\\{ github.ref != 'refs\\/heads\\/master' \\}\\}/d" ref_step_problem "$PW10"
plant "wf 11 branch dispatch: required=1" 11_ci-public.yml '/^      private_overlay_optional: true/d' required_problems "$PW10" "$PW11" "$PW13"
plant "wf 11 branch dispatch: required=1" 10_ci-quality.yml 's/ && !inputs\.private_overlay_optional//' required_problems "$PW10" "$PW11" "$PW13"
plant "wf 10 branch dispatch: required=0" 10_ci-quality.yml "s/ && github\.event_name != 'pull_request' && !inputs\.private_overlay_optional && '1'/ \&\& github.event_name == 'push' \&\& '1'/" required_problems "$PW10" "$PW11" "$PW13"
plant "wf 13 schedule: required=0" 13_ci-next-image.yml 's/^(    with:)$/\1\n      private_overlay_optional: true/' required_problems "$PW10" "$PW11" "$PW13"
plant "13_ci-next-image.yml passes" 13_ci-next-image.yml 's/^(    with:)$/\1\n      private_overlay_optional: true/' caller_problems "$T/p"
plant "wf 13 lost secrets" 13_ci-next-image.yml '/^    secrets: inherit/d' caller_problems "$T/p"
plant "wf 11 holds a secret" 11_ci-public.yml 's/^(    uses: .*10_ci-quality.yml)$/\1\n    secrets: inherit/' caller_problems "$T/p"

if [[ $fails -eq 0 ]]; then
  echo "PASS: all gate10-branch-dispatch.tst.sh assertions"
else
  echo "FAIL: $fails assertion(s) in gate10-branch-dispatch.tst.sh"
fi
[[ $fails -eq 0 ]]
