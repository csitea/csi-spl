#!/usr/bin/env bash
#------------------------------------------------------------------------------
# The dependency-leg scope of workflow 15 (15_sec-deps-secrets.yml), which has
# cancel-in-progress: a deps push superseded within seconds by a non-deps push
# never ran its govulncheck / pnpm audit / trivy legs (c81ef0110, the
# govulncheck bump, superseded 42 s later by e3d3ec2a5 whose run read
# deps=false, 2026-10-10; n=1 of 5 deps pushes in the last 100 pushes).
# Three halves:
#   1. the script csi-spl-iac/src/bash/scripts/sec-deps-scope.sh on a
#      throwaway repo: each dependency input -> true, a doc -> false, and every
#      base it cannot use (empty, all-zero, unreadable, force-push) -> true.
#   2. the workflow's REAL scope step (extracted with yq) run against a
#      planted history: green run on B, a go.sum push X (its run cancelled),
#      then a .md push Y -> deps=true for Y. A stub gh plays the API (the last
#      green run is B); the API failing or finding none -> true; schedule and
#      a plain dispatch -> true without asking.
#   3. the wiring: cancel-in-progress, the nightly and the always-on gitleaks
#      legs are kept, every dependency leg is gated on the scope output, and
#      the base is never github.event.before.
# CONTROLS: the step as it was before this gate (diff from github.event.before)
# reads deps=false on the same planted history, and a copy of wf 15 with its
# scope env set back to github.event.before fails the wiring check.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX
SCOPE="$APP_ROOT/csi-spl-iac/src/bash/scripts/sec-deps-scope.sh"
W15="${W15:-$APP_ROOT/.github/workflows/15_sec-deps-secrets.yml}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v yq >/dev/null || { echo "FAIL: yq is required"; exit 1; }
[[ -f "$SCOPE" ]] || { echo "FAIL: no $SCOPE"; exit 1; }

R="$T/repo"
g() { git -C "$R" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }
put() { mkdir -p "$R/$(dirname "$1")"; echo "$2" >"$R/$1"; }
commit() { g add -A >/dev/null && g commit -q --allow-empty -m "$1" && g rev-parse HEAD; }
expect() {  # <want true|false> <label> <base> <head>
  local got; got=$(cd "$R" && bash "$SCOPE" "$3" "$4" 2>/dev/null)
  [[ "$got" == "deps=$1" ]] && pass "$2 -> deps=$1" || fail "$2: want deps=$1, got '$got'"
}

# --- 1. the script ---------------------------------------------------------
git init -q -b master "$R"
put csi-spl-doc/a.md a; put csi-spl-api/src/go/spool-hub-api/go.sum s0
put csi-spl-iac/src/bash/scripts/sec-deps-scope.sh "$(cat "$SCOPE")"
base=$(commit base)
case1() {  # <want> <path> [label]
  g reset -q --hard "$base"; put "$2" "x$RANDOM"; local h; h=$(commit "$2")
  expect "$1" "${3:-$2}" "$base" "$h"
}
case1 true  csi-spl-api/src/go/spool-hub-api/go.sum
case1 true  csi-spl-api/src/go/spool-hub-api/go.mod
case1 true  csi-spl-wui/pnpm-lock.yaml
case1 false csi-spl-wui/package.json "csi-spl-wui/package.json (the lockfile carries a dependency edit)"
case1 true  csi-spl-api/Dockerfile
case1 true  Dockerfile
case1 true  csi-spl-orc/src/docker/Dockerfile.runner
case1 true  csi-spl-iac/src/terraform/030-hub/main.tf
case1 true  .trivyignore.yaml
case1 true  csi-spl-iac/src/bash/run/sec-scan.func.sh
case1 true  .github/workflows/15_sec-deps-secrets.yml
case1 true  csi-spl-iac/src/bash/scripts/sec-deps-scope.sh
case1 false csi-spl-doc/a.md
case1 false csi-spl-api/src/go/spool-hub-api/main.go
g reset -q --hard "$base"
expect false "empty diff" "$base" "$base"
put csi-spl-doc/x.md old; old=$(commit old)
g reset -q --hard "$base"; put csi-spl-doc/x.md new; h=$(commit new)
expect true "force-push base not an ancestor"  "$old" "$h"
expect true "all-zero base"                    "0000000000000000000000000000000000000000" "$h"
expect true "empty base (no green run found)"  "" "$h"
expect true "unreadable base"                  "1234567890abcdef1234567890abcdef12345678" "$h"
expect true "empty head"                       "$base" ""

# --- 2. the workflow's scope step on a planted history ---------------------
# B: the last green run. X: a go.sum bump whose run was cancelled. Y: a .md
# push 42 s later, the run that has to scan X's dependencies.
g reset -q --hard "$base"; B=$base
put csi-spl-api/src/go/spool-hub-api/go.sum bumped; X=$(commit "deps: bump")
put csi-spl-doc/b.md b; Y=$(commit "doc only")

# gh: logs its args; prints $PLANT_BASE for a status=success query, exits $PLANT_RC
stub gh 'echo "$*" >>"$GH_LOG"; [[ "${PLANT_RC:-0}" == 0 ]] || exit "$PLANT_RC"
case "$*" in *status=success*) [[ -n "${PLANT_BASE:-}" ]] && echo "$PLANT_BASE" ;; esac; exit 0'

# run_step <step-script-file> <event> [env...] -> prints the deps output line
run_step() {
  local f="$1" ev="$2"; shift 2
  : >"$T/out"; : >"$T/sum"
  (cd "$R" && env PATH="$T/bin:$PATH" GH_LOG="$T/gh.log" GITHUB_OUTPUT="$T/out" GITHUB_STEP_SUMMARY="$T/sum" \
    EVENT="$ev" HEAD_SHA="$Y" GITHUB_SHA="$Y" REF_NAME=master REPO=o/r GH_TOKEN=x PUSH_SCOPE=false \
    BEFORE="$X" "$@" bash -e "$f" >/dev/null 2>&1)
  grep '^deps=' "$T/out"
}
yq '.jobs."sec-scan".steps[] | select(.id == "scope") | .run' "$W15" >"$T/step.sh"
[[ -s "$T/step.sh" && "$(cat "$T/step.sh")" != null ]] || { echo "FAIL: no scope step in $W15"; exit 1; }

step_expect() {  # <want> <label> <event> [env...]
  local want="$1" label="$2"; shift 2
  local got; got=$(run_step "$T/step.sh" "$@")
  [[ "$got" == "deps=$want" ]] && pass "scope step: $label -> deps=$want" || fail "scope step: $label: want deps=$want, got '$got'"
}
: >"$T/gh.log"
step_expect true "deps push X superseded by doc push Y (last green run = B)" push PLANT_BASE="$B"
grep -q 'workflows/15_sec-deps-secrets.yml/runs?branch=master&status=success' "$T/gh.log" \
  && pass "scope step asks for the last SUCCESSFUL run of wf 15 on the ref" \
  || fail "scope step did not query the last green wf 15 run: $(cat "$T/gh.log")"
step_expect false "doc push Y right after a green run on X" push PLANT_BASE="$X"
step_expect true "the API fails" push PLANT_BASE="$B" PLANT_RC=1
step_expect true "no green run found" push PLANT_BASE=""
step_expect true "green run sha not in the clone" push PLANT_BASE=1234567890abcdef1234567890abcdef12345678
: >"$T/gh.log"
step_expect true "schedule (nightly) runs every leg" schedule PLANT_BASE="$X"
step_expect true "plain dispatch runs every leg" workflow_dispatch PLANT_BASE="$X"
[[ ! -s "$T/gh.log" ]] && pass "schedule and a plain dispatch never ask the API" || fail "schedule/dispatch queried the API"
step_expect false "dispatch with push_scope (branch control) scopes as a push" workflow_dispatch PUSH_SCOPE=true PLANT_BASE="$X"
step_expect true "dispatch with push_scope sees X since B" workflow_dispatch PUSH_SCOPE=true PLANT_BASE="$B"
sed 's#bash csi-spl-iac/src/bash/scripts/sec-deps-scope.sh#false#' "$T/step.sh" >"$T/step-err.sh"
got=$(run_step "$T/step-err.sh" push PLANT_BASE="$X")
[[ "$got" == deps=true ]] && pass "scope step: a script error -> deps=true" || fail "scope step: a script error gave '$got'"

# CONTROL: the step as it was before this gate, verbatim (BEFORE..GITHUB_SHA).
cat >"$T/old-step.sh" <<'OLD'
set -euo pipefail
deps=true
if [[ "$EVENT" == push && -n "$BEFORE" && "$BEFORE" != 0000000000000000000000000000000000000000 ]] \
   && git cat-file -e "$BEFORE^{commit}" 2>/dev/null; then
  deps=false
  while IFS= read -r f; do
    case "$f" in
      csi-spl-api/src/go/spool-hub-api/go.mod|csi-spl-api/src/go/spool-hub-api/go.sum) deps=true ;;
      csi-spl-wui/pnpm-lock.yaml) deps=true ;;
      */Dockerfile|Dockerfile|*/Dockerfile.*|*.dockerfile) deps=true ;;
      csi-spl-iac/src/terraform/*|.trivyignore.yaml) deps=true ;;
      csi-spl-iac/src/bash/run/sec-scan.func.sh|.github/workflows/15_sec-deps-secrets.yml) deps=true ;;
    esac
  done < <(git diff --name-only "$BEFORE" "$GITHUB_SHA")
fi
echo "deps=$deps" >> "$GITHUB_OUTPUT"
OLD
got=$(run_step "$T/old-step.sh" push PLANT_BASE="$B")
[[ "$got" == deps=false ]] && pass "CONTROL: the old step (github.event.before) reads deps=false for Y: X's legs never ran" \
  || fail "CONTROL: the old step gave '$got' on the planted history (the plant proves nothing)"

# --- 3. the wiring ---------------------------------------------------------
check15() {  # <wf file> -> prints the first problem, nothing when it is right
  local f="$1" s
  [[ "$(yq '.concurrency."cancel-in-progress"' "$f")" == true ]] || { echo "cancel-in-progress is gone"; return; }
  [[ "$(yq '.on.schedule[0].cron' "$f")" == '17 3 * * *' ]] || { echo "the nightly is gone"; return; }
  [[ "$(yq '.on.push.branches[0]' "$f")" == master ]] || { echo "the push trigger on master is gone"; return; }
  [[ "$(yq '.jobs."sec-scan".outputs // "" | tostring' "$f")" != *event.before* ]] || { echo "event.before in outputs"; return; }
  s=$(yq '.jobs."sec-scan".steps[] | select(.id == "scope") | (.env | tostring) + " " + .run' "$f")
  [[ "$s" != *event.before* && "$s" != *'$BEFORE'* ]] || { echo "the scope base is github.event.before (a superseded run's push)"; return; }
  [[ "$s" == *status=success* && "$s" == *sec-deps-scope.sh* ]] || { echo "the scope step does not diff from the last green run"; return; }
  [[ "$(yq '.jobs."sec-scan".permissions.actions' "$f")" == read ]] || { echo "the job lacks actions: read"; return; }
  local n i name ifc
  n=$(yq '.jobs."sec-scan".steps | length' "$f")
  for ((i = 0; i < n; i++)); do
    name=$(yq ".jobs.\"sec-scan\".steps[$i].name // \"\"" "$f")
    ifc=$(yq ".jobs.\"sec-scan\".steps[$i].if // \"\"" "$f")
    case "$name" in
      *gitleaks*) [[ -z "$ifc" ]] || { echo "'$name' is gated ($ifc): gitleaks must always run"; return; } ;;
      *govulncheck*|*"Go modules"*|"Set up Go"*|*pnpm*|"Set up Node"*|*trivy*)
        [[ "$ifc" == "steps.scope.outputs.deps == 'true'" ]] || { echo "'$name' is not gated on the scope ($ifc)"; return; } ;;
    esac
  done
}
v=$(check15 "$W15"); [[ -z "$v" ]] && pass "wf 15: nightly, cancel-in-progress and gitleaks kept, deps legs gated on the green-run scope" || fail "wf 15: $v"
yq '(.jobs."sec-scan".steps[] | select(.id == "scope") | .env.BASE) = "${{ github.event.before }}"' "$W15" >"$T/c1.yml"
[[ -n "$(check15 "$T/c1.yml")" ]] && pass "CONTROL: a scope base of github.event.before is caught" \
  || fail "CONTROL: a github.event.before base passed"
yq '(.jobs."sec-scan".steps[] | select(.name == "gitleaks (full history)") | .if) = "steps.scope.outputs.deps == '"'true'"'"' "$W15" >"$T/c2.yml"
[[ -n "$(check15 "$T/c2.yml")" ]] && pass "CONTROL: gitleaks gated on the deps scope is caught" \
  || fail "CONTROL: a gated gitleaks passed"

echo "---"; (( fails == 0 )) && echo "PASS: all sec-deps-scope.tst.sh assertions" || { echo "sec-deps-scope: $fails failed"; exit 1; }
