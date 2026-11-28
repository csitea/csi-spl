#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: mapped WUI e2e in CI (SPL-6385, csi-spl-doc/specs/016-spool-testability/
#          ci-volume-2026-11-24.md section 3 A2). On a wf 10 PUSH the wui-e2e
#          shards run only the e2e files the change maps to (the pre-push
#          wui-e2e map, _ppe_ci_plan in check-pre-push-e2e.func.sh), on as few
#          shards as they need; the full run keeps 8. Hermetic: a throwaway
#          git tree, no browser.
#   1. RED CONTROL of the report's test column: a push touching one component
#      plans fewer than 8 shards and runs that component's mapped file, not
#      the others
#   2. a push to a shared layout, tests/e2e/lib, ci-skip.txt, the runner's
#      weights or the workflow plans all 8 with no file list
#   3. a selection error plans all 8: no base, a base that is not an
#      ancestor, a merge in the range, a failing selection, a selection of
#      nothing, a push of only unmapped files (a locale alone)
#   4. a locale rides with its component: component + locale is mapped
#   5. n: 300 mapped CI s over a 213 s shard -> 2 shards; never more shards
#      than files; a budget CUT is named and the rest still runs
#   6. _ppe_ci_base: the newest run whose every wui: job was green; a run
#      with a red or skipped wui job is passed over; none -> empty
#   7. the wiring in wf 10: classify outputs wui_base from _ppe_ci_base on a
#      push and express_base, only a 40-hex sha, on a dispatch that carries
#      one; wui-e2e-plan
#      plans only on those two (never schedule, never a bare dispatch), is
#      continue-on-error and
#      writes a plan only when all three lines are there; wui-e2e takes its
#      matrix, E2E_SHARD, file list and name from the plan with the 8-shard
#      default, and a mapped job is named "wui: mapped browser e2e"
#   CONTROLS: a wf 10 whose matrix is the literal 1..8, one whose plan runs
#      on every event, one that plans a dispatch without express_base, one
#      that writes express_base unchecked, and
#      one with no default when the plan is empty, are
#      each red in check 7
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="${FUNC:-$PROJ_ROOT/src/bash/run/check-pre-push-e2e.func.sh}"
W10="${W10:-$APP_ROOT/.github/workflows/10_ci-quality.yml}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
do_log() { echo "$*"; }
# shellcheck source=/dev/null
source "$FUNC"

# --- the tree: 17 files of 100 CI s each (one shard = ceil(1700 / 8) = 213 s)
R="$T/repo"; W="$R/csi-spl-wui"
mkdir -p "$W/src/components" "$W/src/layouts" "$W/tests/e2e/lib" "$W/src/node/test" "$W/i18n/locales" "$R/.github/workflows"
g() { git -c user.name=t -c user.email=t@example.com -C "$R" "$@"; }
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
echo '<template><div data-testid="foo-panel" /></template>' >"$W/src/components/FooBar.vue"
echo '<template><i data-testid="big-a" /></template>' >"$W/src/components/BigPanel.vue"
echo '<template><i data-testid="lone-widget" /></template>' >"$W/src/components/LoneWidget.vue"
echo '<template><slot /><nav data-testid="shell-rail" /></template>' >"$W/src/layouts/default.vue"
echo "await page.click('[data-testid=\"foo-panel\"]')" >"$W/tests/e2e/foo.test.mjs"
for n in 1 2 3; do echo "await page.click('[data-testid=\"big-a\"]')" >"$W/tests/e2e/big-$n.test.mjs"; done
for n in $(seq -w 1 13); do echo "await page.click('[data-testid=\"other-$n\"]')" >"$W/tests/e2e/other-$n.test.mjs"; done
echo 'export const h = 1' >"$W/tests/e2e/lib/helper.mjs"
printf '# reasons\n' >"$W/tests/e2e/ci-skip.txt"
( cd "$W" && for t in tests/e2e/*.test.mjs; do echo "$t 100"; done ) >"$W/src/node/test/e2e-shard-weights.txt"
echo '{"a": "A"}' >"$W/i18n/locales/en.json"
echo 'name: wf' >"$R/.github/workflows/10_ci-quality.yml"
g init -q; g add -A; g commit -qm base; BASE=$(g rev-parse HEAD)

# change <path>... - a commit on BASE touching the paths; prints its sha
change() {
  g checkout -q -B c "$BASE"
  local p; for p in "$@"; do echo "// $RANDOM" >>"$R/$p"; done
  g add -A; g commit -qm change; g rev-parse HEAD
}
plan() { _ppe_ci_plan "$R" "$1" "$2" 2>"$T/why"; }
field() { sed -n "s/^$1=//p" <<<"$2"; }
FULL=$'n=8\nshards=[1,2,3,4,5,6,7,8]\nfiles='

# --- 1. one component: < 8 shards, its mapped file ---------------------------
h=$(change csi-spl-wui/src/components/FooBar.vue); got=$(plan "$BASE" "$h")
if [[ "$(field n "$got")" =~ ^[1-7]$ && "$(field files "$got")" == "tests/e2e/foo.test.mjs" && "$(field shards "$got")" == "[1]" ]]; then
  pass "1. a push touching FooBar.vue runs 1 of 8 shards, its mapped file only: $(field files "$got")"
else
  fail "1. FooBar.vue planned '$(tr '\n' ' ' <<<"$got")' ($(cat "$T/why")), want n=1 shards=[1] files=tests/e2e/foo.test.mjs"
fi

# --- 2. the shared paths: all 8 -------------------------------------------------
for p in csi-spl-wui/src/layouts/default.vue csi-spl-wui/tests/e2e/lib/helper.mjs csi-spl-wui/tests/e2e/ci-skip.txt \
         csi-spl-wui/src/node/test/e2e-shard-weights.txt .github/workflows/10_ci-quality.yml; do
  h=$(change csi-spl-wui/src/components/FooBar.vue "$p"); got=$(plan "$BASE" "$h")
  [[ "$got" == "$FULL" ]] && grep -qF "$p" "$T/why" && pass "2. FooBar.vue + $p runs all 8 shards, every file ($(cat "$T/why"))" \
    || fail "2. FooBar.vue + $p planned '$(tr '\n' ' ' <<<"$got")' ($(cat "$T/why")), want the full suite"
done

# --- 3. a selection error: all 8 -------------------------------------------------
h=$(change csi-spl-wui/src/components/FooBar.vue)
expect_full() {  # <case> <plan output>
  [[ "$2" == "$FULL" ]] && pass "3. $1: all 8 shards ($(cat "$T/why"))" || fail "3. $1 planned '$(tr '\n' ' ' <<<"$2")', want the full suite"
}
expect_full "no base" "$(plan "" "$h")"
expect_full "an all-zero base" "$(plan 0000000000000000000000000000000000000000 "$h")"
other=$(g checkout -q -B o "$BASE" && echo x >"$R/x.txt" && g add -A && g commit -qm o && g rev-parse HEAD)
expect_full "a base that is not an ancestor" "$(g checkout -q c && plan "$other" "$h")"
expect_full "a base git cannot read" "$(plan 1234567890123456789012345678901234567890 "$h")"
g checkout -q -B m "$h"; g merge -q --no-ff --no-edit o; mh=$(g rev-parse HEAD)
expect_full "a merge in the range" "$(plan "$BASE" "$mh")"
g checkout -q c
expect_full "a selection that fails" "$(_ppe_select() { return 1; }; plan "$BASE" "$h")"
h=$(change csi-spl-wui/src/components/LoneWidget.vue)
expect_full "a component no e2e file names (the selection is empty)" "$(plan "$BASE" "$h")"
h=$(change csi-spl-wui/i18n/locales/en.json)
expect_full "a locale alone (no file maps)" "$(plan "$BASE" "$h")"

# --- 4. a locale rides with its component ---------------------------------------
h=$(change csi-spl-wui/src/components/FooBar.vue csi-spl-wui/i18n/locales/en.json); got=$(plan "$BASE" "$h")
[[ "$(field files "$got")" == "tests/e2e/foo.test.mjs" ]] && pass "4. FooBar.vue + en.json is mapped: the locale rides with the component" \
  || fail "4. FooBar.vue + en.json planned '$(tr '\n' ' ' <<<"$got")' ($(cat "$T/why"))"

# --- 5. n ------------------------------------------------------------------------
h=$(change csi-spl-wui/src/components/BigPanel.vue); got=$(plan "$BASE" "$h")
[[ "$(field n "$got")" == 2 && "$(field shards "$got")" == "[1,2]" && "$(wc -w <<<"$(field files "$got")")" == 3 ]] \
  && pass "5. BigPanel.vue: 3 files, 300 of 1700 CI s over a 213 s shard -> 2 shards" \
  || fail "5. BigPanel.vue planned '$(tr '\n' ' ' <<<"$got")' ($(cat "$T/why")), want n=2 and 3 files"
got=$(PRE_PUSH_E2E_CI_BUDGET=150 plan "$BASE" "$h")
[[ "$(field n "$got")" == 1 && "$(wc -w <<<"$(field files "$got")")" == 1 ]] && grep -q '2 more past the budget' "$T/why" \
  && [[ "$(grep -c '^wui-e2e plan: CUT ' "$T/why")" == 2 ]] \
  && pass "5. a budget of 150 s runs the top file on 1 shard and names the 2 CUT files" \
  || fail "5. budget 150 planned '$(tr '\n' ' ' <<<"$got")' ($(cat "$T/why"))"
g checkout -q -B heavy "$BASE"; printf 'tests/e2e/foo.test.mjs 900\n' >>"$W/src/node/test/e2e-shard-weights.txt"
g commit -qam heavy; B2=$(g rev-parse HEAD); echo "// x" >>"$W/src/components/FooBar.vue"; g commit -qam x
got=$(PRE_PUSH_E2E_CI_BUDGET=5000 plan "$B2" "$(g rev-parse HEAD)")
[[ "$(field n "$got")" == 1 ]] && pass "5. one file heavier than a shard still runs on 1 shard (never more shards than files)" \
  || fail "5. one heavy file planned '$(tr '\n' ' ' <<<"$got")' ($(cat "$T/why"))"

# --- 6. _ppe_ci_base ----------------------------------------------------------------
printf '%s\n' $'30\tsha30\twui: unit tests + typecheck\tsuccess' $'30\tsha30\twui: browser e2e (mock, generated) 1/8\tfailure' \
  $'29\tsha29\thub: suite\tsuccess' $'28\tsha28\twui: unit tests + typecheck\tskipped' \
  $'27\tsha27\twui: unit tests + typecheck\tsuccess' $'27\tsha27\twui: mapped browser e2e (mock, generated) 1/1\tsuccess' \
  $'26\tsha26\twui: unit tests + typecheck\tsuccess' >"$T/jobs.tsv"
[[ "$(_ppe_ci_base "$T/jobs.tsv")" == sha27 ]] && pass "6. the base is the newest run with every wui job green (a red and a skipped one passed over)" \
  || fail "6. _ppe_ci_base read '$(_ppe_ci_base "$T/jobs.tsv")', want sha27"
grep -v 'sha2[67]' "$T/jobs.tsv" >"$T/none.tsv"
[[ -z "$(_ppe_ci_base "$T/none.tsv")" ]] && pass "6. no green wui run listed: no base" || fail "6. no green run gave '$(_ppe_ci_base "$T/none.tsv")'"
[[ -z "$(_ppe_ci_base "$T/missing.tsv")" ]] && pass "6. no list: no base" || fail "6. a missing list gave a base"

# --- 7. the wiring in wf 10 -----------------------------------------------------------
check_wiring() {  # <wf 10 file> - the first violation, or nothing
  local f="$1" cls plan e2e step
  [[ "$(yq '.jobs.classify.outputs.wui_base' "$f")" == *steps.cls.outputs.wui_base* ]] || { echo "classify has no wui_base output"; return; }
  cls=$(yq '.jobs.classify.steps[] | select(.id == "cls") | .run' "$f")
  [[ "$(awk '/EVENT" == push/,/elif/' <<<"$cls")" == *'_ppe_ci_base "$tsv"'*'wui_base='*'GITHUB_OUTPUT'* ]] \
    || { echo "classify's push branch does not write wui_base from _ppe_ci_base"; return; }
  [[ "$(awk '/EVENT" == workflow_dispatch && -n "\$BASE"/,/^ *else/' <<<"$cls")" == *'if [[ "$BASE" =~ ^[0-9a-f]{40}$ ]]; then echo "wui_base=$BASE" >>"$GITHUB_OUTPUT"; fi'* ]] \
    || { echo "classify's dispatch-with-express_base branch does not write wui_base=\$BASE only for a 40-hex sha"; return; }
  plan=$(yq '.jobs.wui-e2e-plan.steps[] | select(.id == "plan") | .run' "$f")
  [[ "$(yq '.jobs.wui-e2e-plan.needs' "$f")" == *classify* && "$(yq '.jobs.wui-e2e-plan.if' "$f")" == *"!cancelled()"*"run_wui != 'false'"* ]] \
    || { echo "wui-e2e-plan does not need classify or does not skip only on run_wui == 'false'"; return; }
  [[ "$(yq '.jobs.wui-e2e-plan.steps[] | select(.id == "plan") | .continue-on-error' "$f")" == true ]] \
    || { echo "the plan step is not continue-on-error"; return; }
  [[ "$(awk '/EVENT" == push/,/else/' <<<"$plan")" == *_ppe_ci_plan* && "$(sed -n '/^ *else/,/^ *fi/p' <<<"$plan")" != *_ppe_ci_plan* ]] \
    || { echo "the plan step plans on another event than push"; return; }
  [[ "$plan" == *'if [[ "$EVENT" == push || ( "$EVENT" == workflow_dispatch && -n "$BASE" ) ]]; then'* ]] \
    || { echo "the plan step plans on another event than a push or a dispatch with express_base"; return; }
  [[ "$plan" == *'!= 3'*'out=""'* ]] || { echo "the plan step writes a partial plan"; return; }
  for o in n shards files; do
    [[ "$(yq ".jobs.wui-e2e-plan.outputs.$o" "$f")" == *"steps.plan.outputs.$o"* ]] || { echo "wui-e2e-plan has no $o output"; return; }
  done
  e2e=$(yq '.jobs.wui-e2e' "$f")
  [[ "$(yq '.jobs.wui-e2e.needs' "$f")" == *wui-e2e-plan* ]] || { echo "wui-e2e does not need wui-e2e-plan"; return; }
  [[ "$(yq '.jobs.wui-e2e.strategy.matrix.shard' "$f")" == *"fromJSON(needs.wui-e2e-plan.outputs.shards || '[1, 2, 3, 4, 5, 6, 7, 8]')"* ]] \
    || { echo "the wui-e2e matrix is not the plan's shards with the 1..8 default"; return; }
  [[ "$(yq '.jobs.wui-e2e.name' "$f")" == *"needs.wui-e2e-plan.outputs.files && 'wui: mapped browser e2e' || 'wui: browser e2e'"*'needs.wui-e2e-plan.outputs.n || 8'* ]] \
    || { echo "the wui-e2e name does not tell a mapped run (and its n, default 8)"; return; }
  step=$(yq '.jobs.wui-e2e.steps[] | select(.env.E2E_SHARD != null)' "$f")
  [[ "$step" == *'E2E_SHARD: "${{ matrix.shard }}/${{ needs.wui-e2e-plan.outputs.n || 8 }}"'* \
     && "$step" == *'E2E_FILES: ${{ needs.wui-e2e-plan.outputs.files }}'* && "$step" == *'pnpm run test:e2e $E2E_FILES'* ]] \
    || { echo "the browser step does not shard by the plan's n (default 8) or does not pass E2E_FILES"; return; }
  [[ -n "$e2e" ]]
}
v=$(check_wiring "$W10"); [[ -z "$v" ]] && pass "7. wf 10: classify's wui_base -> wui-e2e-plan (push or dispatch with express_base, all-or-nothing) -> the wui-e2e matrix, 8 by default" \
  || fail "7. wf 10: $v"
mut() {  # <name> <python replace args> - a mutated copy of wf 10; check 7 must be red on it
  python3 - "$W10" "$T/$1.yml" "$2" "$3" 2>/dev/null <<'PY'
import sys
s = open(sys.argv[1]).read()
assert sys.argv[3] in s, sys.argv[3]
open(sys.argv[2], "w").write(s.replace(sys.argv[3], sys.argv[4], 1))
PY
  [[ -f "$T/$1.yml" ]] || { fail "CONTROL $1: the mutation does not apply to wf 10 (update the control)"; return; }
  [[ -n "$(check_wiring "$T/$1.yml")" ]] && pass "CONTROL $1: check 7 is red ($(check_wiring "$T/$1.yml"))" || fail "CONTROL $1: check 7 passed a broken wf 10"
}
mut literal-matrix "\${{ fromJSON(needs.wui-e2e-plan.outputs.shards || '[1, 2, 3, 4, 5, 6, 7, 8]') }}" "[1, 2, 3, 4, 5, 6, 7, 8]"
mut no-default "needs.wui-e2e-plan.outputs.shards || '[1, 2, 3, 4, 5, 6, 7, 8]'" "needs.wui-e2e-plan.outputs.shards"
mut every-event 'if [[ "$EVENT" == push || ( "$EVENT" == workflow_dispatch && -n "$BASE" ) ]]; then
            # shellcheck disable=SC2016' 'if true; then
            # shellcheck disable=SC2016'
mut base-unchecked 'if [[ "$BASE" =~ ^[0-9a-f]{40}$ ]]; then echo "wui_base=$BASE" >>"$GITHUB_OUTPUT"; fi' 'echo "wui_base=$BASE" >>"$GITHUB_OUTPUT"'
mut dispatch-no-base '( "$EVENT" == workflow_dispatch && -n "$BASE" )' '"$EVENT" == workflow_dispatch'

if [[ $fails -eq 0 ]]; then
  echo "PASS: all ci-wui-e2e-plan.tst.sh assertions"
else
  echo "FAIL: $fails assertion(s) in ci-wui-e2e-plan.tst.sh"
fi
[[ $fails -eq 0 ]]
