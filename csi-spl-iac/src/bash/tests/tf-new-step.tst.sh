#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_tf_new_step's "this step already exists" check (refactor round 4,
#          row 13: a glob test, not `ls | grep`). A name that CONTAINS the step
#          counts, as it did under `ls | grep`. Run in a throwaway tree with
#          minimal lib/tpl fixtures; nothing outside $T is touched.
#   1. the step already under src/terraform: the terraform FATAL line
#   2. the step only under the tf template dir: the template FATAL line
#   3. a name that merely contains the step (<step>-remote-bucket): FATAL too
#   4. CONTROL: a new step logs no FATAL and gets its step dir, its bucket dir
#      and its three tfvars templates, so the FATALs above are the check's
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
ACTION="$PROJ_ROOT/src/bash/run/tf-new-step.func.sh"
require_action "$ACTION"
TPL_DIR='src/tpl/cnf/env/%org%/%app%/%env%/tf'

# new_tree <name>: an empty project tree with the templates the action copies
new_tree() {
  local w="$T/$1" b="$T/$1/lib/tpl/terraform/step-remote-bucket"
  mkdir -p "$w/src/terraform" "$w/$TPL_DIR" "$b/tpl" "$w/lib/tpl/terraform/step"
  echo 'bucket = "step-name"' >"$b/03-s3-bucket.tf"
  for f in step-name-remote-bucket.vars.tfvars.tpl step-name.backend-config.tfvars.tpl step-name.vars.tfvars.tpl; do
    echo "x = \"step-name\"" >"$b/tpl/$f"
  done
  echo '# main' >"$w/lib/tpl/terraform/step/main.tf"
}
# run_step <tree> <step>: the action in that tree, do_log to stdout
# shellcheck source=../run/tf-new-step.func.sh
run_step() {
  (cd "$T/$1" && do_log() { echo "$*"; } && source "$ACTION" && STEP="$2" do_tf_new_step) >"$T/$1.out" 2>&1
}

new_tree a; mkdir "$T/a/src/terraform/014-foo"
run_step a 014-foo
grep -q 'FATAL there already exists terraform files' "$T/a.out" &&
  pass "a step under src/terraform is reported" || fail "src/terraform/014-foo not reported: $(head -n 2 "$T/a.out")"

new_tree b; touch "$T/b/$TPL_DIR/014-foo.vars.tfvars.tpl"
run_step b 014-foo
grep -q 'FATAL there already exists template files' "$T/b.out" &&
  pass "a step under the tf template dir is reported" || fail "the template not reported: $(head -n 2 "$T/b.out")"

new_tree c; mkdir "$T/c/src/terraform/014-foo-remote-bucket"
run_step c 014-foo
grep -q 'FATAL there already exists terraform files' "$T/c.out" &&
  pass "a name containing the step counts, as under ls | grep" || fail "014-foo-remote-bucket not reported"

new_tree d; mkdir "$T/d/src/terraform/013-bar"
run_step d 014-foo
if grep -q FATAL "$T/d.out"; then
  fail "a new step logged a FATAL: $(grep FATAL "$T/d.out")"
elif [[ -f "$T/d/src/terraform/014-foo/main.tf" && -f "$T/d/src/terraform/014-foo-remote-bucket/03-s3-bucket.tf" &&
        -f "$T/d/$TPL_DIR/014-foo.vars.tfvars.tpl" && -f "$T/d/$TPL_DIR/014-foo.backend-config.tfvars.tpl" &&
        -f "$T/d/$TPL_DIR/014-foo-remote-bucket.vars.tfvars.tpl" ]] &&
     grep -q '"014-foo"' "$T/d/src/terraform/014-foo-remote-bucket/03-s3-bucket.tf"; then
  pass "a new step gets no FATAL, its dirs and its three tfvars templates"
else
  fail "a new step was not laid out: $(tail -n 3 "$T/d.out")"
fi

echo "---- $(basename "$0"): $fails failed"
[ "$fails" -eq 0 ]
