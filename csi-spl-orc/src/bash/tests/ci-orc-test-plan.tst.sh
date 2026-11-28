#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: workflow 10's mapped orc hermetic run (SPL-6385 A3,
#          csi-spl-doc/specs/016-spool-testability/ci-volume-2026-11-24.md
#          section 3): csi-spl-orc/src/bash/scripts/ci-orc-test-plan.sh on a
#          throwaway repo, and its wiring in .github/workflows/10_ci-quality.yml.
#   1. an orc push changing one action runs only its mapped .tst.sh (plus
#      ORC_TEST_ALWAYS) on 1 shard; a changed helper also runs the tests of
#      the action that calls it (its dependent); a heavier pick packs 2 shards.
#   2. a lib/ change (csi-spl-orc/lib, a feature's lib), a test helper, the
#      shard weights or the plan itself runs all 4 shards (orc_plan=).
#   3. the C4 shape: an orc test that reads a pin of another tree by its dir
#      (csi-spl-iac/src/terraform/030-x) is picked when the pin changes; a
#      tfvars, cnf or compose/image pin change runs all 4.
#   4. a map error runs all: no or bad base, a base that is no ancestor, an
#      orc file no test names, changed-tests.sh failing, too many dependents,
#      a pick that needs 4 shards.
#   5. --base: the newest run whose every orc: job was green.
#   6. wf 10: classify writes orc_plan only in the exact shape, only on a
#      push or a dispatch with a 40-hex express_base; orc-suite takes its
#      matrix, name, ORC_TEST_SHARD and ORC_TEST_ONLY from it, 4 shards by
#      default.
#   Controls: the plan without its dependents step or its outside-dir step,
#   and a wf 10 with a literal matrix, each fail the check that names them.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ORC=$(cd "$TEST_DIR/../../.." && pwd)
TOP=$(cd "$ORC/.." && pwd)
PLAN="$ORC/src/bash/scripts/ci-orc-test-plan.sh"
W10="$TOP/.github/workflows/10_ci-quality.yml"
unset ORC_TEST_ALWAYS ORC_TEST_FILES ORC_TEST_BASE ORC_TEST_WEIGHTS ORC_PLAN_MAX_DEPS CI_WUI_EXTERNAL
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
R="$T/repo"
o=csi-spl-orc/src/bash
mkdir -p "$R/$o/scripts" "$R/$o/tests" "$R/$o/run" "$R/$o/features/x/lib" "$R/csi-spl-orc/lib/bash" \
  "$R/csi-spl-orc/src/docker" "$R/csi-spl-iac/src/terraform/030-x" "$R/csi-spl-cnf/csi-spl/dev/tf"
cp "$PLAN" "$ORC/src/bash/scripts/ci-doc-only.sh" "$R/$o/scripts/"
cp "$ORC/src/bash/tests/changed-tests.sh" "$R/$o/tests/"
printf 'do_log() { :; }\n' >"$R/$o/run/run.sh"
printf 'do_foo_bar() {\n  helper_thing\n}\n' >"$R/$o/run/foo-bar.func.sh"
printf 'helper_thing() {\n  :\n}\n' >"$R/$o/scripts/helper-thing.sh"
printf 'do_lonely_act() {\n  :\n}\n' >"$R/$o/run/lonely-act.func.sh"
printf 'do_heavy_one() {\n  :\n}\n' >"$R/$o/run/heavy-one.func.sh"
printf 'do_medium_one() {\n  :\n}\n' >"$R/$o/run/medium-one.func.sh"
printf 'lib_fn() { :; }\n' >"$R/csi-spl-orc/lib/bash/shared.func.sh"
printf 'feat_fn() { :; }\n' >"$R/$o/features/x/lib/feat.inc.sh"
printf 'services: {}\n' >"$R/csi-spl-orc/src/docker/docker-compose-x.yaml"
printf 'image = "reg/x:1"\n' >"$R/csi-spl-iac/src/terraform/030-x/main.tf"
printf 'image = "reg/x:1"\n' >"$R/csi-spl-cnf/csi-spl/dev/tf/030-x.vars.tfvars"
printf 'x: 1\n' >"$R/csi-spl-cnf/csi-spl/dev.env.yaml"
printf 'helper() { :; }\n' >"$R/$o/tests/test-lib.inc.sh"
printf 'helper2() { :; }\n' >"$R/$o/tests/wait-thing.inc.sh"
mk() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$R/$o/tests/$1"; }
mk foo-bar.tst.sh 'cd "$ORC" && ./run -a do_foo_bar'
mk helper.tst.sh 'bash "$ORC/src/bash/scripts/helper-thing.sh"'
mk img-pin.tst.sh 'tf="$TOP/csi-spl-iac/src/terraform/030-x"; grep -h image "$tf"/*.tf'
mk heavy.tst.sh './run -a do_heavy_one'
mk medium.tst.sh './run -a do_medium_one'
mk require-cloud-env.tst.sh 'true'
mk run-eager-files.tst.sh 'true'
for i in 1 2 3; do mk "filler-$i.tst.sh" 'true'; done
# total 10 x 10 + 400 + 150 - 20 = 630 s; one full-run shard = 158 s
printf '* 10\nheavy.tst.sh 400\nmedium.tst.sh 150\n' >"$R/$o/tests/orc-shard-weights.txt"
git -C "$R" init -q -b master && printf 'nodeps.sh\nnodir.sh\n' >>"$R/.git/info/exclude"
git -C "$R" add -A && git -C "$R" commit -qm base
B=$(git -C "$R" rev-parse HEAD)

# change <path> <text> [<path>...]: one commit on top of the base that
# appends <text> to each path; prints its sha
change() {
  local t="$2" f
  git -C "$R" checkout -q --detach "$B"
  for f in "$1" "${@:3}"; do mkdir -p "$(dirname "$R/$f")"; printf '%s\n' "$t" >>"$R/$f"; done
  git -C "$R" add -A && git -C "$R" commit -qm "change $1" && git -C "$R" rev-parse HEAD
}
# plan [<plan script>] <base> <head>: the orc_plan value ('' = the full suite)
plan() {
  local p="$R/$o/scripts/ci-orc-test-plan.sh"
  (( $# == 3 )) && { p=$1; shift; }
  (cd "$R" && bash "$p" "$1" "$2" 2>"$T/why") | sed -n 's/^orc_plan=//p'
}
files_of() { sed -n 's/.*"files":"\([^"]*\)".*/\1/p' <<<"$1"; }
ALW="require-cloud-env.tst.sh run-eager-files.tst.sh"

# --- 1. one action -> its test ------------------------------------------------
h=$(change "$o/run/foo-bar.func.sh" '# a comment')
got=$(plan "$B" "$h")
want='{"n":1,"shards":[1],"files":"foo-bar.tst.sh '"$ALW"'"}'
[[ "$got" == "$want" ]] && pass "1. an orc push changing one action runs only its .tst.sh (+ the always-run) on 1 shard" \
  || fail "1. one action" "want '$want', got '$got' ($(cat "$T/why"))"
h=$(change "$o/scripts/helper-thing.sh" '# a comment')
got=$(files_of "$(plan "$B" "$h")")
[[ "$got" == "foo-bar.tst.sh helper.tst.sh $ALW" ]] && pass "1. a changed helper runs its own test and its dependent's (foo-bar calls helper_thing)" \
  || fail "1. dependents" "got '$got' ($(cat "$T/why"))"
sed '/ct "" "\$d"/d' "$R/$o/scripts/ci-orc-test-plan.sh" >"$R/$o/scripts/nodeps.sh"
got=$(files_of "$(plan "$R/$o/scripts/nodeps.sh" "$B" "$h")")
[[ "$got" != *foo-bar.tst.sh* ]] && pass "CONTROL: a plan without its dependents step misses foo-bar.tst.sh (caught above)" \
  || fail "CONTROL: the dependents control did not bite" "got '$got'"
h=$(change "$o/run/medium-one.func.sh" '# a comment')
got=$(plan "$B" "$h")
[[ "$got" == '{"n":2,"shards":[1,2],"files":"medium.tst.sh '"$ALW"'"}' ]] && pass "1. a 170 s pick (shard = 158 s) packs 2 shards" \
  || fail "1. two shards" "got '$got' ($(cat "$T/why"))"
h=$(change "$o/tests/helper.tst.sh" '# a comment')
[[ "$(files_of "$(plan "$B" "$h")")" == "helper.tst.sh $ALW" ]] && pass "1. a changed test runs itself" \
  || fail "1. a changed test" "$(plan "$B" "$h") ($(cat "$T/why"))"

# --- 2. a shared lib, a test helper, the weights, the plan: all 4 shards -----
for p in csi-spl-orc/lib/bash/shared.func.sh "$o/features/x/lib/feat.inc.sh" "$o/tests/wait-thing.inc.sh" \
         "$o/tests/orc-shard-weights.txt" "$o/scripts/ci-orc-test-plan.sh" "$o/tests/test-lib.inc.sh"; do
  h=$(change "$p" '# a comment')
  got=$(plan "$B" "$h")
  [[ -z "$got" ]] && pass "2. a change to $p runs all 4 shards ($(sed -n '1s/^ci-orc-test-plan: //p' "$T/why"))" \
    || fail "2. $p ran a mapped plan" "got '$got'"
done

# --- 3. the C4 shape ------------------------------------------------------------
h=$(change csi-spl-iac/src/terraform/030-x/main.tf 'image = "reg/x:2"')
got=$(files_of "$(plan "$B" "$h")")
[[ " $got " == *" img-pin.tst.sh "* ]] && pass "3. C4: a pin change in another tree picks the orc test that reads it by dir (img-pin.tst.sh)" \
  || fail "3. C4 pin not picked" "got '$got' ($(cat "$T/why"))"
awk '/# 3\. an outside path no orc test names/ { skip = 1 } /# 2\. dependents: the orc source files/ { skip = 0 } !skip' \
  "$R/$o/scripts/ci-orc-test-plan.sh" >"$R/$o/scripts/nodir.sh"
got=$(files_of "$(plan "$R/$o/scripts/nodir.sh" "$B" "$h")")
[[ " $got " != *" img-pin.tst.sh "* ]] && pass "CONTROL: a plan without its outside-dir step misses img-pin.tst.sh (caught above)" \
  || fail "CONTROL: the outside-dir control did not bite" "got '$got'"
for p in csi-spl-cnf/csi-spl/dev/tf/030-x.vars.tfvars csi-spl-cnf/csi-spl/dev.env.yaml \
         csi-spl-orc/src/docker/docker-compose-x.yaml csi-spl-iac/src/terraform/030-x/x.auto.tfvars; do
  h=$(change "$p" 'image = "reg/x:2"')
  got=$(plan "$B" "$h")
  [[ -z "$got" ]] && pass "3. a pin change in $p runs all 4 shards" || fail "3. $p ran a mapped plan" "got '$got'"
done

# --- 4. a map error runs all ------------------------------------------------------
h=$(change "$o/run/foo-bar.func.sh" '# a comment')
for b in "" "HEAD" "${B:0:12}" "$(printf '%040d' 0)"; do
  got=$(plan "$b" "$h")
  [[ -z "$got" ]] && pass "4. base '${b:-<none>}' runs all 4 shards" || fail "4. base '$b' mapped" "got '$got'"
done
git -C "$R" checkout -q --detach "$B"; printf 'x\n' >"$R/side.txt"; git -C "$R" add -A; git -C "$R" commit -qm side
side=$(git -C "$R" rev-parse HEAD)
[[ -z "$(plan "$side" "$h")" ]] && pass "4. a base that is not an ancestor runs all 4 shards" || fail "4. a non-ancestor base mapped"
h=$(change "$o/run/lonely-act.func.sh" '# a comment')
[[ -z "$(plan "$B" "$h")" ]] && grep -q 'no test names' "$T/why" && pass "4. an orc file no test names runs all 4 shards" \
  || fail "4. an unnamed orc file mapped" "$(cat "$T/why")"
h=$(change "$o/run/foo-bar.func.sh" '# a comment')
cp "$R/$o/tests/changed-tests.sh" "$T/ct.keep"; printf '#!/usr/bin/env bash\nexit 3\n' >"$R/$o/tests/changed-tests.sh"
got=$(plan "$B" "$h"); cp "$T/ct.keep" "$R/$o/tests/changed-tests.sh"
[[ -z "$got" ]] && pass "4. a changed-tests.sh that fails runs all 4 shards" || fail "4. a failing map still mapped" "got '$got'"
h=$(change "$o/scripts/helper-thing.sh" '# a comment')
got=$(cd "$R" && ORC_PLAN_MAX_DEPS=0 bash "$o/scripts/ci-orc-test-plan.sh" "$B" "$h" 2>"$T/why" | sed -n 's/^orc_plan=//p')
[[ -z "$got" ]] && grep -q 'dependents' "$T/why" && pass "4. more dependents than ORC_PLAN_MAX_DEPS runs all 4 shards" \
  || fail "4. too many dependents mapped" "got '$got'"
h=$(change "$o/run/heavy-one.func.sh" '# a comment' "$o/run/medium-one.func.sh")
[[ -z "$(plan "$B" "$h")" ]] && grep -q 'need all 4 shards' "$T/why" && pass "4. a pick that needs 4 shards (570 s, shard = 158 s) runs the full suite" \
  || fail "4. a 4-shard pick mapped" "$(cat "$T/why")"

# --- 5. --base ---------------------------------------------------------------------
printf '%s\n' "9	s9	orc: hermetic action tests 1/4	failure" "9	s9	hub: suite	success" \
  "8	s8	orc: feature tests	success" "8	s8	orc: hermetic (mapped) action tests 1/1	success" \
  "7	s7	orc: hermetic action tests 1/4	success" >"$T/jobs.tsv"
got=$(bash "$PLAN" --base "$T/jobs.tsv")
[[ "$got" == s8 ]] && pass "5. --base: the newest run whose every orc: job was green (s8, past the red s9)" \
  || fail "5. --base" "got '$got'"
[[ -z "$(bash "$PLAN" --base "$T/none.tsv")" ]] && pass "5. --base: no list -> no base (the full suite)" || fail "5. --base on no list"

# --- 6. the wiring in wf 10 ----------------------------------------------------------
check10() {  # <wf 10 file>: prints the first violation, or nothing
  local f="$1" run
  [[ "$(yq '.jobs.classify.outputs.orc_plan' "$f")" == *"steps.cls.outputs.orc_plan"* ]] || { echo "classify has no orc_plan output"; return; }
  [[ "$(yq '.jobs.orc-suite.strategy.matrix.shard' "$f")" == *"fromJSON(needs.classify.outputs.orc_plan || '{\"shards\":[1,2,3,4]}').shards"* ]] \
    || { echo "orc-suite matrix is not the plan's shards with a 4-shard default"; return; }
  [[ "$(yq '.jobs.orc-suite.name' "$f")" == "orc: hermetic \${{ needs.classify.outputs.orc_plan && '(mapped) ' || '' }}action tests (stubbed gcloud/curl/docker) \${{ matrix.shard }}/\${{ needs.classify.outputs.orc_plan && fromJSON(needs.classify.outputs.orc_plan).n || 4 }}" ]] \
    || { echo "orc-suite name does not mark a mapped run"; return; }
  run=$(yq '.jobs.orc-suite.steps[] | select(.name == "run-all-tests.sh") | .env' "$f")
  [[ "$run" == *"ORC_TEST_SHARD: \${{ matrix.shard }}/\${{ needs.classify.outputs.orc_plan && fromJSON(needs.classify.outputs.orc_plan).n || 4 }}"* \
     && "$run" == *"ORC_TEST_ONLY: \${{ needs.classify.outputs.orc_plan && fromJSON(needs.classify.outputs.orc_plan).files || '' }}"* ]] \
    || { echo "run-all-tests.sh does not get ORC_TEST_SHARD and ORC_TEST_ONLY from the plan"; return; }
  run=$(yq '.jobs.classify.steps[] | select(.id == "cls") | .run' "$f")
  [[ "$(grep -cE 'orc_base=' <<<"$run")" == 3 ]] && grep -qF 'out="" orc_base=""' <<<"$run" \
     && grep -qF 'orc_base=$(bash "$plan" --base "$tsv")' <<<"$run" \
     && grep -qE '^ *if \[\[ "\$BASE" =~ \^\[0-9a-f\]\{40\}\$ \]\]; then .*orc_base=\$BASE; fi$' <<<"$run" \
    || { echo "classify sets orc_base outside the push and 40-hex dispatch arms"; return; }
}
v=$(check10 "$W10")
[[ -z "$v" ]] && pass "6. wf 10 wires orc_plan into the orc-suite matrix, name, shard and file list (4-shard default)" || fail "6. wf 10 wiring" "$v"
sed "s|shard: \${{ fromJSON(needs.classify.outputs.orc_plan .*|shard: [1, 2, 3, 4]|" "$W10" >"$T/literal.yml"
[[ -n "$(check10 "$T/literal.yml")" ]] && pass "CONTROL: a wf 10 with a literal 4-shard matrix fails the wiring check" \
  || fail "CONTROL: the literal-matrix control did not bite"
# classify's own guard: only an exact plan is written, every other line = full
snip=$(yq '.jobs.classify.steps[] | select(.id == "cls") | .run' "$W10" | awk '/^orc_plan=""$/ { on = 1 } /^sum=/ { on = 0 } on')
guard() {  # <plan line>: the orc_plan output classify writes for it
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\n' "$1" >"$T/stub.sh"
  # shellcheck disable=SC2034 # read by the eval'd classify snippet
  ( plan="$T/stub.sh" orc_base=$B HEAD_SHA=$B GITHUB_OUTPUT="$T/gho" GITHUB_STEP_SUMMARY=/dev/null
    : >"$GITHUB_OUTPUT"; eval "$snip"; sed -n 's/^orc_plan=//p' "$GITHUB_OUTPUT" )
}
ok='{"n":2,"shards":[1,2],"files":"a.tst.sh b-c.tst.sh"}'
[[ "$(guard "orc_plan=$ok")" == "$ok" ]] && pass "6. classify writes an exact plan" || fail "6. classify dropped a good plan" "$(guard "orc_plan=$ok")"
for bad in '{"n":2,"shards":[1],"files":"a.tst.sh"}' '{"n":4,"shards":[1,2,3,4],"files":"a.tst.sh"}' \
           '{"n":1,"shards":[1],"files":"a$(id).tst.sh"}' '{"n":1,"shards":[1],"files":""}' 'garbage'; do
  [[ -z "$(guard "orc_plan=$bad")" ]] && pass "6. classify drops an odd plan: $bad" || fail "6. classify wrote an odd plan" "$bad"
done
[[ -z "$(cd "$T" && plan="$T/stub.sh" orc_base="" HEAD_SHA=$B GITHUB_OUTPUT="$T/gho2" GITHUB_STEP_SUMMARY=/dev/null bash -c ": >\"\$GITHUB_OUTPUT\"; $snip"; sed -n 's/^orc_plan=//p' "$T/gho2")" ]] \
  && pass "6. no orc_base (schedule, wf 11, wf 13, a bare dispatch): no plan, the full suite" || fail "6. a plan without a base"

echo "-- ci-orc-test-plan.tst.sh: $fails failed"
[ "$fails" -eq 0 ]
