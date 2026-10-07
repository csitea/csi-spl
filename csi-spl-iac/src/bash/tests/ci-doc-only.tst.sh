#!/usr/bin/env bash
#------------------------------------------------------------------------------
# The express docs lane of workflow 10 (owner, t1 a477c187, msgs 50a349f4 +
# 31e00aee). Two halves:
#   1. the classifier csi-spl-orc/src/bash/scripts/ci-doc-only.sh on a
#      throwaway repo: doc-only, mixed, a .md under csi-spl-wui/ and under
#      .github/, a renamed .md, a .md renamed to code, a deleted .md, an empty
#      diff, a merge, a force-push base, an all-zero base, an unreadable base
#      -> each verdict asserted. Everything it cannot prove is false (code).
#   2. the wiring in .github/workflows/10_ci-quality.yml: the classify job
#      fails safe (a classifier error reads false), diffs from the LAST GREEN
#      run, never github.event.before (a superseded pending run's code push
#      was never gated), every code job skips ONLY
#      on doc_only == 'true', and the jobs that must keep running for a doc
#      (distribution-hygiene, no-ysg-box-ref, pr-sec-scan) do not depend on it.
# CONTROLS: a copy of wf 10 with hub-suite's condition removed, one with
# distribution-hygiene gated on doc_only, and one diffing from
# github.event.before are all red.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX
CLS="$APP_ROOT/csi-spl-orc/src/bash/scripts/ci-doc-only.sh"
W10="${W10:-$APP_ROOT/.github/workflows/10_ci-quality.yml}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v yq >/dev/null || { echo "FAIL: yq is required"; exit 1; }
[[ -f "$CLS" ]] || { echo "FAIL: no $CLS"; exit 1; }

R="$T/repo"
g() { git -C "$R" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }
put() { mkdir -p "$R/$(dirname "$1")"; echo "$2" >"$R/$1"; }
commit() { g add -A >/dev/null && g commit -q --allow-empty -m "$1" && g rev-parse HEAD; }
cls() { (cd "$R" && bash "$CLS" "$@" 2>/dev/null); }
expect() {  # <want true|false> <label> <base> <head>
  local got; got=$(cls "$3" "$4")
  [[ "$got" == "doc_only=$1" ]] && pass "$2 -> doc_only=$1" || fail "$2: want doc_only=$1, got '$got'"
}

git init -q -b master "$R"
put README.md a; put csi-spl-doc/x.md a; put csi-spl-api/main.go a
put csi-spl-wui/README.md a; put .github/workflows/README.md a
base=$(commit base)

put csi-spl-doc/x.md b; put README.md b; h=$(commit doc)
expect true  "two .md outside wui/.github"          "$base" "$h"
g reset -q --hard "$base"
put csi-spl-doc/x.md c; put csi-spl-api/main.go c; h=$(commit mixed)
expect false "mixed .md + .go"                      "$base" "$h"
g reset -q --hard "$base"
put csi-spl-wui/README.md c; h=$(commit wui)
expect false ".md under csi-spl-wui/"               "$base" "$h"
g reset -q --hard "$base"
put .github/workflows/README.md c; h=$(commit gh)
expect false ".md under .github/"                   "$base" "$h"
g reset -q --hard "$base"
g mv csi-spl-doc/x.md csi-spl-doc/y.md; h=$(commit ren)
expect true  "renamed .md -> .md"                   "$base" "$h"
g reset -q --hard "$base"
g mv csi-spl-doc/x.md csi-spl-doc/x.sh; h=$(commit ren2)
expect false "renamed .md -> .sh"                   "$base" "$h"
g reset -q --hard "$base"
g mv csi-spl-doc/x.md csi-spl-wui/x.md; h=$(commit ren3)
expect false "renamed .md into csi-spl-wui/"        "$base" "$h"
g reset -q --hard "$base"
g rm -q csi-spl-doc/x.md; h=$(commit del)
expect true  "deleted .md"                          "$base" "$h"
g reset -q --hard "$base"
h=$(commit empty)
expect false "empty diff"                           "$base" "$h"

# a merge in the range, though every path is a .md
g reset -q --hard "$base"
g checkout -q -b side; put csi-spl-doc/s.md s; commit side >/dev/null
g checkout -q master; put csi-spl-doc/m.md m; commit main >/dev/null
g merge -q --no-ff -m merge side >/dev/null 2>&1; h=$(g rev-parse HEAD)
expect false "merge commit (.md only)"              "$base" "$h"

# a force-push: the old tip is not an ancestor of the new one
g reset -q --hard "$base"; put csi-spl-doc/x.md old; old=$(commit old)
g reset -q --hard "$base"; put csi-spl-doc/x.md new; h=$(commit new)
expect false "force-push base not an ancestor"      "$old" "$h"
expect false "all-zero base (new branch)"           "0000000000000000000000000000000000000000" "$h"
expect false "empty base"                           "" "$h"
expect false "unreadable base"                      "1234567890abcdef1234567890abcdef12345678" "$h"
expect false "empty head"                           "$base" ""

# --- 2. the wiring in wf 10 ---------------------------------------------------
CODE_JOBS=(hub-suite wui-suite wui-generate wui-e2e iac-suite orc-suite cnf-suite)
KEEP_JOBS=(distribution-hygiene no-ysg-box-ref pr-sec-scan)
check10() {  # <wf 10 file> - prints the first violation, or nothing
  local f="$1" j ifc needs run
  [[ "$(yq '.jobs.classify.outputs.doc_only' "$f")" == *'steps.'*'.outputs.doc_only'* ]] \
    || { echo "classify job has no doc_only output"; return; }
  run=$(yq '.jobs.classify.steps[] | select(.id == "cls") | .run' "$f")
  [[ "$run" == *ci-doc-only.sh* && "$run" == *'doc_only=false'* ]] \
    || { echo "classify step does not run ci-doc-only.sh with a doc_only=false fallback"; return; }
  [[ "$run" == *'status=success'* && "$(yq '.jobs.classify.steps[] | select(.id == "cls") | .env.BASE' "$f")" != *event.before* ]] \
    || { echo "classify base is not the last GREEN run (github.event.before may be a superseded, never-gated code push)"; return; }
  [[ "$(yq '.jobs.classify.steps[] | select(.id == "cls") | .continue-on-error' "$f")" == true ]] \
    || { echo "classify step is not continue-on-error (a classifier crash must not red the gate)"; return; }
  for j in "${CODE_JOBS[@]}"; do
    needs=$(yq ".jobs.\"$j\".needs" "$f"); ifc=$(yq ".jobs.\"$j\".if" "$f")
    [[ "$needs" == *classify* ]] || { echo "$j does not need classify"; return; }
    [[ "$ifc" == *"!cancelled()"* && "$ifc" == *"needs.classify.outputs.doc_only != 'true'"* ]] \
      || { echo "$j if '$ifc' does not skip ONLY on doc_only == 'true' (fail safe: a failed classify must run it)"; return; }
  done
  for j in "${KEEP_JOBS[@]}"; do
    [[ "$(yq ".jobs.\"$j\"" "$f")" != null ]] || { echo "$j is gone"; return; }
    [[ "$(yq ".jobs.\"$j\" | (.if // \"\") + \" \" + ((.needs // []) | tostring)" "$f")" != *classify* ]] \
      || { echo "$j depends on classify: it must run for a doc-only push"; return; }
  done
}
v=$(check10 "$W10"); [[ -z "$v" ]] && pass "wf 10: code jobs skip only on doc_only, hygiene jobs always run" || fail "wf 10: $v"

yq 'del(.jobs."hub-suite".if)' "$W10" >"$T/c1.yml"
[[ -n "$(check10 "$T/c1.yml")" ]] && pass "CONTROL: hub-suite without the doc_only condition is caught" \
  || fail "CONTROL: hub-suite without the condition passed"
yq '(.jobs.classify.steps[] | select(.id == "cls") | .env.BASE) = "${{ github.event.before }}"' "$W10" >"$T/c3.yml"
[[ -n "$(check10 "$T/c3.yml")" ]] && pass "CONTROL: a base of github.event.before (a superseded push) is caught" \
  || fail "CONTROL: a github.event.before base passed"
yq '.jobs."distribution-hygiene".if = "needs.classify.outputs.doc_only != '"'true'"'"' "$W10" >"$T/c2.yml"
[[ -n "$(check10 "$T/c2.yml")" ]] && pass "CONTROL: distribution-hygiene gated on doc_only is caught" \
  || fail "CONTROL: distribution-hygiene gated on doc_only passed"

echo "---"; (( fails == 0 )) && echo "PASS: all ci-doc-only.tst.sh assertions" || { echo "ci-doc-only: $fails failed"; exit 1; }
