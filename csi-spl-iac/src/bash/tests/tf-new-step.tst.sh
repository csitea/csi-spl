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
#   5. an existing step STOPS it: non-zero and nothing laid out (SPL-4764; the
#      FATAL was logged, then the copy went on and returned 0)
#   6. a tree without the templates (the real iac tree has none): one FATAL
#      line naming them, non-zero, nothing created (SPL-4764; was a
#      `cp: cannot stat` half-way through, the 'tf' dirs left behind)
#   7. `make -n tf-new-step` in csi-spl-orc runs ./run in a dir whose
#      src/bash/run defines do_tf_new_step (SPL-4764; orc's own ./run has no
#      such action: "do_tf_new_step NOT found")
#   8. the template dir is the one the real tree keeps its step templates in,
#      src/tpl/%org%-%app%/%env%/tf, the same one do_tf_remove_step reads
#      (SPL-5243; it wrote and checked csi-rel's src/tpl/cnf/env/%org%/%app%/
#      %env%/tf, which holds no file here), and a new step writes nothing under
#      the csi-rel path
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
ACTION="$PROJ_ROOT/src/bash/run/tf-new-step.func.sh"
require_action "$ACTION"
TPL_DIR='src/tpl/%org%-%app%/%env%/tf'
OLD_TPL_DIR='src/tpl/cnf/env/%org%/%app%/%env%/tf'

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

# 5. an existing step stops the action: rc != 0, no bucket dir, no tfvars
new_tree e; mkdir "$T/e/src/terraform/014-foo"
run_step e 014-foo; rc=$?
if [[ $rc -ne 0 && ! -e "$T/e/src/terraform/014-foo-remote-bucket" ]] && ! compgen -G "$T/e/$TPL_DIR/*" >/dev/null; then
  pass "an existing step is refused: rc $rc, nothing laid out"
else
  fail "an existing step was not stopped: rc $rc, $(ls "$T/e/src/terraform" | tr '\n' ' ')"
fi

# 6. no templates on the tree: one FATAL naming them, rc != 0, nothing created
mkdir -p "$T/f/src/terraform"
run_step f 014-foo; rc=$?
nfatal=$(grep -c FATAL "$T/f.out")
if [[ $rc -ne 0 && $nfatal -eq 1 ]] && grep -q 'FATAL missing template.*lib/tpl/terraform/step-remote-bucket' "$T/f.out" &&
   [[ -z "$(ls -A "$T/f/src/terraform")" ]] && ! grep -q 'cannot stat' "$T/f.out"; then
  pass "a tree without the templates: one FATAL naming them, rc $rc, nothing created"
else
  fail "a tree without the templates: rc $rc, $nfatal FATAL, out: $(head -n 3 "$T/f.out" | tr '\n' ' ')"
fi

# 7. the orc make target reaches a ./run that can find do_tf_new_step
ORC="$APP_ROOT/csi-spl-orc"
mk=$(cd "$ORC" && STEP=014-foo GITHUB_TOKEN=x make --no-print-directory -n tf-new-step 2>&1 | grep -- '-a do_tf_new_step')
dir=$(sed -n 's/^cd \([^ ]*\) && .*/\1/p' <<<"$mk"); dir=${dir:-.}
if [[ -n "$mk" && -d "$ORC/$dir/src/bash/run" ]] && grep -qs '^do_tf_new_step()' "$ORC/$dir/src/bash/run/"*.func.sh &&
   grep -q 'STEP=014-foo' <<<"$mk"; then
  pass "make -n tf-new-step runs ./run in $dir, which defines do_tf_new_step, with STEP"
else
  fail "make -n tf-new-step cannot reach do_tf_new_step: '${mk}' (run dir $dir)"
fi

# 8. one template dir: the real tree's, shared with do_tf_remove_step; nothing
#    under the csi-rel path
compgen -G "$PROJ_ROOT/$TPL_DIR/*.tfvars.tpl" >/dev/null &&
  pass "$TPL_DIR holds the real tree's step templates" || fail "no *.tfvars.tpl under $PROJ_ROOT/$TPL_DIR"
shared=$(source "$PROJ_ROOT/src/bash/run/tf-remove-step.func.sh" 2>/dev/null && tf_step_tpl_dir 2>/dev/null)
[[ "$shared" == "$TPL_DIR" ]] && grep -q 'tf_step_tpl_dir' "$ACTION" &&
  pass "tf-new-step reads the one template dir, tf_step_tpl_dir of tf-remove-step" ||
  fail "no shared template dir: tf_step_tpl_dir='$shared', tf-new-step uses it: $(grep -c tf_step_tpl_dir "$ACTION")"
[[ ! -e "$T/d/src/tpl/cnf" ]] && pass "a new step writes nothing under the csi-rel $OLD_TPL_DIR" ||
  fail "a new step wrote under the csi-rel path: $(find "$T/d/src/tpl/cnf" | tr '\n' ' ')"

echo "---- $(basename "$0"): $fails failed"
[ "$fails" -eq 0 ]
