#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Per-part selection in workflow 10 (owner, t1 f67e3656, msg 52474112, CI
# action 1; spec 133 seat C), grown from the express docs lane (owner, t1
# a477c187, msgs 50a349f4 + 31e00aee). Three halves:
#   1. the classifier csi-spl-orc/src/bash/scripts/ci-doc-only.sh on a
#      throwaway repo, docs-only (parts= empty) vs code: doc-only, mixed, a .md
#      under csi-spl-wui/ and under .github/, a renamed .md, a .md renamed to
#      code, a deleted .md, an empty diff, a merge, a force-push base, an
#      all-zero base, an unreadable base -> each verdict asserted. Everything
#      it cannot prove is parts=all (the full gate).
#   2. the part map: a one-part push names that part's jobs and its readers
#      only (a wui push never names hub, an api push never names wui), a file
#      on the wui list adds wui, the shared infra and an unmapped path are
#      parts=all; and --select: each part from its OWN last green run (a red
#      hub does not hold back a wui skip), a failed or skipped job is no base,
#      no base or an empty list runs the part.
#   3. the wiring in .github/workflows/10_ci-quality.yml: the classify job
#      fails safe (a classifier error runs every part), takes its bases from
#      finished runs, never github.event.before (a superseded pending run's
#      code push was never gated), every code job skips ONLY on its own
#      run_<part> == 'false', and the jobs that must keep running for a doc
#      (distribution-hygiene, no-ysg-box-ref, pr-sec-scan) do not depend on it.
# CONTROLS: a copy of wf 10 with hub-suite's condition removed, one with
# wui-e2e keyed on the hub part, one with distribution-hygiene gated on
# classify, and one diffing from github.event.before are all red.
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
cls() { (cd "$R" && CI_WUI_EXTERNAL="${WUI_EXT-}" bash "$CLS" "$@" 2>/dev/null); }
expect_parts() {  # <want parts line> <label> <base> <head>
  local got; got=$(cls "$3" "$4")
  [[ "$got" == "$1" ]] && pass "$2 -> $got" || fail "$2: want '$1', got '$got'"
}

git init -q -b master "$R"
put README.md a; put csi-spl-doc/x.md a; put csi-spl-api/main.go a
put csi-spl-wui/README.md a; put .github/workflows/README.md a
base=$(commit base)

put csi-spl-doc/x.md b; put README.md b; h=$(commit doc)
expect_parts parts= "two .md outside wui/.github"          "$base" "$h"
g reset -q --hard "$base"
put csi-spl-doc/x.md c; put csi-spl-api/main.go c; h=$(commit mixed)
expect_parts "parts=hub iac orc" "mixed .md + .go"   "$base" "$h"
g reset -q --hard "$base"
put csi-spl-wui/README.md c; h=$(commit wui)
expect_parts "parts=iac orc wui" ".md under csi-spl-wui/" "$base" "$h"
g reset -q --hard "$base"
put .github/workflows/README.md c; h=$(commit gh)
expect_parts parts=all ".md under .github/"          "$base" "$h"
g reset -q --hard "$base"
g mv csi-spl-doc/x.md csi-spl-doc/y.md; h=$(commit ren)
expect_parts parts= "renamed .md -> .md"                   "$base" "$h"
g reset -q --hard "$base"
g mv csi-spl-doc/x.md csi-spl-doc/x.sh; h=$(commit ren2)
expect_parts "parts=iac orc" "renamed .md -> .sh (doc, not .md)" "$base" "$h"
g reset -q --hard "$base"
g mv csi-spl-doc/x.md csi-spl-wui/x.md; h=$(commit ren3)
expect_parts "parts=iac orc wui" "renamed .md into csi-spl-wui/" "$base" "$h"
g reset -q --hard "$base"
g rm -q csi-spl-doc/x.md; h=$(commit del)
expect_parts parts= "deleted .md"                          "$base" "$h"
g reset -q --hard "$base"
h=$(commit empty)
expect_parts parts=all "empty diff"                  "$base" "$h"

# a merge in the range, though every path is a .md
g reset -q --hard "$base"
g checkout -q -b side; put csi-spl-doc/s.md s; commit side >/dev/null
g checkout -q master; put csi-spl-doc/m.md m; commit main >/dev/null
g merge -q --no-ff -m merge side >/dev/null 2>&1; h=$(g rev-parse HEAD)
expect_parts parts=all "merge commit (.md only)"              "$base" "$h"

# a force-push: the old tip is not an ancestor of the new one
g reset -q --hard "$base"; put csi-spl-doc/x.md old; old=$(commit old)
g reset -q --hard "$base"; put csi-spl-doc/x.md new; h=$(commit new)
expect_parts parts=all "force-push base not an ancestor"      "$old" "$h"
expect_parts parts=all "all-zero base (new branch)"           "0000000000000000000000000000000000000000" "$h"
expect_parts parts=all "empty base"                           "" "$h"
expect_parts parts=all "unreadable base"                      "1234567890abcdef1234567890abcdef12345678" "$h"
expect_parts parts=all "empty head"                           "$base" ""

# --- 2. the part map and the per-part base ------------------------------------
g reset -q --hard "$base"
put csi-spl-wui/src/a.ts a; put csi-spl-orc/src/bash/run/x.func.sh a; put csi-spl-iac/src/bash/run/y.func.sh a
put csi-spl-rdb/src/sql/0001_a.sql a; put csi-spl-doc/blog/posts/p.md a; put csi-spl-doc/doc/help/h.md a
put csi-spl-doc/specs/x/c.json a; put csi-spl-cnf/csi-spl/dev.env.yaml a; put csi-spl-orc/lib/bash/l.sh a
put csi-spl-orc/src/bash/scripts/gate-fail-fast.sh a; put csi-spl-orc/src/bash/tests/run-all-tests.sh a
put csi-spl-api/src/go/go.mod a; put csi-spl-wui/pnpm-lock.yaml a; put csi-spl-iac/run a; put Makefile a
put csi-spl-orc/src/bash/scripts/wui-e2e-mock-serve.sh a; put csi-spl-orc/src/bash/features/f/lib/x.inc.sh a
base2=$(commit base2)
one() {  # <want> <label> <path> - a push that changes only <path>
  g reset -q --hard "$base2"; echo b >>"$R/$3"; local h; h=$(commit "$2")
  expect_parts "$1" "$2" "$base2" "$h"
}
one "parts=iac orc wui"     "wui source only (no hub, no cnf)"          csi-spl-wui/src/a.ts
one "parts=hub iac orc"     "api source only (no wui)"                   csi-spl-api/main.go
one "parts=hub iac orc"     "rdb migration = the hub part"               csi-spl-rdb/src/sql/0001_a.sql
one "parts=cnf hub iac orc" "orc action only (no wui)"                   csi-spl-orc/src/bash/run/x.func.sh
one "parts=cnf iac orc"     "iac action only (no hub, no wui)"           csi-spl-iac/src/bash/run/y.func.sh
one "parts=iac orc"         "a non-.md doc file"                         csi-spl-doc/specs/x/c.json
one "parts=wui"             "a blog post .md (the wui build reads it)"   csi-spl-doc/blog/posts/p.md
one "parts=cnf hub iac orc wui" "an orc script the e2e job runs"         csi-spl-orc/src/bash/scripts/wui-e2e-mock-serve.sh
one "parts=cnf hub iac orc" "a feature's own lib/ is the orc part, not the full gate" csi-spl-orc/src/bash/features/f/lib/x.inc.sh
WUI_EXT="csi-spl-doc/doc/help"
one "parts=wui"             "a help .md on the wui list"                 csi-spl-doc/doc/help/h.md
WUI_EXT="csi-spl-api/*.go"
one "parts=hub iac orc wui" "an api file on the wui list (glob)"         csi-spl-api/main.go
WUI_EXT=""
for f in csi-spl-cnf/csi-spl/dev.env.yaml csi-spl-orc/lib/bash/l.sh csi-spl-orc/src/bash/scripts/gate-fail-fast.sh \
         csi-spl-orc/src/bash/tests/run-all-tests.sh csi-spl-api/src/go/go.mod csi-spl-wui/pnpm-lock.yaml \
         csi-spl-iac/run Makefile; do
  one parts=all "full gate: $f" "$f"
done

# --select: <run> TAB <sha> TAB <job> TAB <conclusion>, newest run first
g reset -q --hard "$base2"; s0=$base2
echo b >>"$R/csi-spl-api/main.go"; s1=$(commit hub-change)
echo b >>"$R/csi-spl-doc/x.md";    s2=$(commit doc)
echo b >>"$R/csi-spl-wui/src/a.ts"; s3=$(commit wui-change)
JOBS="$T/jobs.tsv"
printf '%s\n' \
  "30	$s1	hub: suite	failure" "30	$s1	wui: unit	success" "30	$s1	wui: e2e 1/3	success" \
  "30	$s1	iac: suite	success" "30	$s1	orc: hermetic 1/2	success" "30	$s1	orc: features	success" \
  "30	$s1	cnf: validator	success" "30	$s1	distribution-hygiene sweep	success" \
  "20	$s0	hub: suite	success" "20	$s0	wui: unit	success" "20	$s0	cnf: validator	skipped" \
  >"$JOBS"
sel() { (cd "$R" && CI_WUI_EXTERNAL="" bash "$CLS" --select "$1" "$2" 2>/dev/null) | paste -sd' ' -; }
want="run_cnf=false run_hub=true run_iac=false run_orc=false run_wui=false"
got=$(sel "$s2" "$JOBS")
[[ "$got" == "$want" ]] && pass "select at s2 (a doc push): red hub runs (base s0), green parts skip from their own base s1" \
  || fail "select at s2: want '$want', got '$got'"
want="run_cnf=false run_hub=true run_iac=true run_orc=true run_wui=true"
got=$(sel "$s3" "$JOBS")
[[ "$got" == "$want" ]] && pass "select at s3 (a wui change): wui, iac, orc and the red hub run; cnf skips" \
  || fail "select at s3: want '$want', got '$got'"
printf '%s\n' "40	$s3	hub: suite	success" "40	$s3	wui: e2e 2/3	success" "40	$s3	cnf: validator	success" \
  "40	$s3	iac: suite	success" "40	$s3	orc: features	success" >"$T/j2.tsv"
g reset -q --hard "$s3"; echo b >>"$R/csi-spl-wui/src/a.ts"; s4=$(commit wui-again)
want="run_cnf=false run_hub=false run_iac=true run_orc=true run_wui=true"
got=$(sel "$s4" "$T/j2.tsv")
[[ "$got" == "$want" ]] && pass "select: a wui-only push skips hub and cnf" || fail "select wui-only: want '$want', got '$got'"
printf '%s\n' "50	$s1	wui: e2e 1/3	success" "50	$s1	wui: e2e 2/3	cancelled" "50	$s1	cnf: validator	skipped" >"$T/j3.tsv"
[[ "$(sel "$s2" "$T/j3.tsv")" == *run_cnf=true*run_wui=true* ]] && pass "select: a cancelled shard or a skipped job = no green base for its part" \
  || fail "select: a cancelled shard or a skipped job counted as green: $(sel "$s2" "$T/j3.tsv")"
want="run_cnf=true run_hub=true run_iac=true run_orc=true run_wui=true"
[[ "$(sel "$s3" "$T/none.tsv")" == "$want" ]] && pass "select: no job list -> every part runs" || fail "select: no list did not run all"
printf '%s\n' "60	1234567890abcdef1234567890abcdef12345678	hub: suite	success" >"$T/j4.tsv"
[[ "$(sel "$s3" "$T/j4.tsv")" == *run_hub=true* ]] && pass "select: an unreadable base -> the part runs" || fail "select: unreadable base skipped"

# --- 3. the wiring in wf 10 ---------------------------------------------------
declare -A JOB_PART=([hub-suite]=hub [wui-suite]=wui [wui-generate]=wui [wui-e2e]=wui [iac-suite]=iac
  [orc-suite]=orc [orc-features]=orc [cnf-suite]=cnf)
KEEP_JOBS=(distribution-hygiene no-ysg-box-ref pr-sec-scan)
check10() {  # <wf 10 file> - prints the first violation, or nothing
  local f="$1" j p ifc needs run
  for p in cnf hub iac orc wui; do
    [[ "$(yq ".jobs.classify.outputs.run_$p" "$f")" == *"steps.cls.outputs.run_$p"* ]] \
      || { echo "classify job has no run_$p output"; return; }
  done
  run=$(yq '.jobs.classify.steps[] | select(.id == "cls") | .run' "$f")
  [[ "$run" == *ci-doc-only.sh* && "$run" == *'--select'* && "$run" == *'v=true'* && "$run" == *'run_$p=false'* ]] \
    || { echo "classify step does not run ci-doc-only.sh --select with a run-it default"; return; }
  [[ "$run" == *'status=$st'* && "$run" == *'for st in success failure'* \
     && "$(yq '.jobs.classify.steps[] | select(.id == "cls") | .env.BASE' "$f")" != *event.before* ]] \
    || { echo "classify bases are not finished runs (github.event.before may be a superseded, never-gated code push)"; return; }
  [[ "$(yq '.jobs.classify.steps[] | select(.id == "cls") | .continue-on-error' "$f")" == true ]] \
    || { echo "classify step is not continue-on-error (a classifier crash must not red the gate)"; return; }
  for j in "${!JOB_PART[@]}"; do
    p=${JOB_PART[$j]}
    needs=$(yq ".jobs.\"$j\".needs" "$f"); ifc=$(yq ".jobs.\"$j\".if" "$f")
    [[ "$needs" == *classify* ]] || { echo "$j does not need classify"; return; }
    [[ "$ifc" == *"!cancelled()"* && "$ifc" == *"needs.classify.outputs.run_$p != 'false'"* ]] \
      || { echo "$j if '$ifc' does not skip ONLY on run_$p == 'false' (fail safe: a failed classify must run it)"; return; }
  done
  for j in "${KEEP_JOBS[@]}"; do
    [[ "$(yq ".jobs.\"$j\"" "$f")" != null ]] || { echo "$j is gone"; return; }
    [[ "$(yq ".jobs.\"$j\" | (.if // \"\") + \" \" + ((.needs // []) | tostring)" "$f")" != *classify* ]] \
      || { echo "$j depends on classify: it must run for a doc-only push"; return; }
  done
}
v=$(check10 "$W10"); [[ -z "$v" ]] && pass "wf 10: each code job skips only on its own run_<part>, hygiene jobs always run" || fail "wf 10: $v"

yq 'del(.jobs."hub-suite".if)' "$W10" >"$T/c1.yml"
[[ -n "$(check10 "$T/c1.yml")" ]] && pass "CONTROL: hub-suite without its run_hub condition is caught" \
  || fail "CONTROL: hub-suite without the condition passed"
yq '.jobs."wui-e2e".if |= sub("run_wui", "run_hub")' "$W10" >"$T/c4.yml"
[[ -n "$(check10 "$T/c4.yml")" ]] && pass "CONTROL: wui-e2e keyed on the hub part is caught" \
  || fail "CONTROL: wui-e2e keyed on run_hub passed"
yq '(.jobs.classify.steps[] | select(.id == "cls") | .env.BASE) = "${{ github.event.before }}"' "$W10" >"$T/c3.yml"
[[ -n "$(check10 "$T/c3.yml")" ]] && pass "CONTROL: a base of github.event.before (a superseded push) is caught" \
  || fail "CONTROL: a github.event.before base passed"
yq '.jobs."distribution-hygiene".if = "needs.classify.outputs.run_hub != '"'false'"'"' "$W10" >"$T/c2.yml"
[[ -n "$(check10 "$T/c2.yml")" ]] && pass "CONTROL: distribution-hygiene gated on classify is caught" \
  || fail "CONTROL: distribution-hygiene gated on classify passed"

echo "---"; (( fails == 0 )) && echo "PASS: all ci-doc-only.tst.sh assertions" || { echo "ci-doc-only: $fails failed"; exit 1; }
