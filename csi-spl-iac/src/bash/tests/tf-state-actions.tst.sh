#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the terraform state and step actions are dry runs unless DRY_RUN=0
#          and refuse to start without their required vars.
#   1. do_tf_remove_step: default lists what would go and removes nothing;
#      DRY_RUN=0 removes only <STEP>* under src/terraform and the tf tpl dir,
#      relative to the cwd. It runs in a SANDBOX cwd, never the real tree.
#   2. do_tf_replace_target: default `plan -replace=<t>` per target, no apply;
#      DRY_RUN=0 `apply -auto-approve -replace=<t>` per target
#   3. do_tf_state_push: default pushes nothing; DRY_RUN=0 runs
#      `state push -lock=false <file>` (the -lock=false is pinned); a missing
#      state file is refused before do_tf_init
#   4. do_tf_state_pull: read-only, so no DRY_RUN gate; it writes the pulled
#      state under dat/tmp and never pushes or applies
#   5. CONTROL: no ENV / STEP / TARGET / TFSTATE_FILE -> non-zero, and neither
#      do_tf_init, terraform nor rm ran
# terraform and gcloud are stubs on PATH; do_tf_init and sleep are stubbed;
# HOME is a temp dir. No network, no GCP, no state bucket. TF_STATE_ACTIONS_DIR
# points the test at another copy of the actions (the red control runs it on
# the unguarded ones).
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
RUN_DIR="${TF_STATE_ACTIONS_DIR:-$PROJ_ROOT/src/bash/run}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fails=0
for a in tf-remove-step tf-replace-target tf-state-push tf-state-pull; do
  require_action "$RUN_DIR/$a.func.sh"
done

stub terraform 'shift; echo "$*" >>"$TF_CALLS"; [[ "$*" == "state pull" ]] && echo "{\"serial\":7}"; exit 0'
stub gcloud 'echo "gcloud $*" >>"$TF_CALLS"; exit 1'

# sandbox: a fake iac tree with two steps; the cwd of every action run
sandbox() {
  rm -rf "$T/sbx"
  mkdir -p "$T/sbx/src/terraform/007-dns" "$T/sbx/src/terraform/008-keep" "$T/sbx/$tfdir"
  touch "$T/sbx/src/terraform/007-dns/main.tf" "$T/sbx/src/terraform/008-keep/main.tf" \
    "$T/sbx/$tfdir/007-dns.vars.tfvars.tpl" "$T/sbx/$tfdir/008-keep.vars.tfvars.tpl"
}

# run_action <func> <env assignments...> -> rc; calls in $T/calls.log, output in $T/out.log
run_action() {
  local fn="$1" file; shift
  file="$RUN_DIR/$(echo "${fn#do_}" | tr _ -).func.sh"
  : >"$T/calls.log"
  mkdir -p "$T/sbx"
  (cd "$T/sbx" && env -u DRY_RUN -u GOOGLE_APPLICATION_CREDENTIALS HOME="$T/home" \
    PATH="$T/bin:$PATH" TF_CALLS="$T/calls.log" ACTION="$file" FN="$fn" \
    ORG=o APP=a ENV=dev STEP=007-dns APP_PATH="$T/app" PROJ_PATH="$T/proj" \
    TARGET="x.a,x.b" TFSTATE_FILE=state/in.tfstate "$@" \
    bash -c 'do_log(){ echo "$*"; }; do_simple_log(){ echo "$*"; }; sleep(){ :; }
      rm(){ echo "rm $*" >>"$TF_CALLS"; command rm "$@"; }
      do_tf_init(){ echo "do_tf_init" >>"$TF_CALLS"; tf_proj="$STEP"; tf_run_path="$PROJ_PATH/bin/$ENV/$tf_proj"; mkdir -p "$tf_run_path" "$PROJ_PATH/dat/log"; }
      source "$ACTION"; "$FN"') >"$T/out.log" 2>&1
}
calls() { tr '\n' '|' <"$T/calls.log"; }
vars="-var-file=$T/app/o-a-cnf/o-a/dev/tf/007-dns.vars.tfvars"
tfdir="src/tpl/cnf/env/%org%/%app%/%env%/tf"

# --- 1. tf-remove-step: dry run by default, sandbox cwd only ------------------------
sandbox; run_action do_tf_remove_step; rc=$?
[[ $rc -eq 0 && -f "$T/sbx/src/terraform/007-dns/main.tf" && -f "$T/sbx/$tfdir/007-dns.vars.tfvars.tpl" ]] \
  && ! grep -q '^rm ' "$T/calls.log" && pass "remove-step default: nothing removed, no rm" \
  || fail "remove-step default: rc=$rc calls=$(calls) out=$(cat "$T/out.log")"
grep -q 'src/terraform/007-dns' "$T/out.log" && grep -q 'DRY_RUN: nothing removed; DRY_RUN=0 removes' "$T/out.log" \
  && pass "remove-step default: lists the step's paths and says nothing was removed" || fail "remove-step log: $(cat "$T/out.log")"
sandbox; run_action do_tf_remove_step DRY_RUN=0; rc=$?
[[ $rc -eq 0 && ! -e "$T/sbx/src/terraform/007-dns" && ! -e "$T/sbx/$tfdir/007-dns.vars.tfvars.tpl" ]] \
  && pass "remove-step DRY_RUN=0: the step's terraform dir and tpl go" || fail "remove-step DRY_RUN=0: rc=$rc calls=$(calls) out=$(cat "$T/out.log")"
[[ -f "$T/sbx/src/terraform/008-keep/main.tf" && -f "$T/sbx/$tfdir/008-keep.vars.tfvars.tpl" ]] \
  && pass "remove-step DRY_RUN=0: the other step stays" || fail "remove-step removed another step: $(find "$T/sbx" | tr '\n' ' ')"
[[ -z "$(grep -v '^rm ' "$T/calls.log")" ]] \
  && pass "remove-step: no do_tf_init, terraform or gcloud" || fail "remove-step called out: $(calls)"

# --- 2. tf-replace-target -----------------------------------------------------------
run_action do_tf_replace_target; rc=$?
plans=$(grep '^plan' "$T/calls.log")
[[ $rc -eq 0 && "$plans" == "plan $vars -lock=false -replace=x.a"$'\n'"plan $vars -lock=false -replace=x.b" ]] \
  && pass "replace default: plan -replace=<t> once per target" || fail "replace default: rc=$rc calls=$(calls) out=$(cat "$T/out.log")"
! grep -q '^apply' "$T/calls.log" && grep -q 'DRY_RUN: nothing replaced; DRY_RUN=0 replaces' "$T/out.log" \
  && pass "replace default: no apply, the log says nothing was replaced" || fail "replace default applied: $(calls) out=$(cat "$T/out.log")"
run_action do_tf_replace_target DRY_RUN=0; rc=$?
applies=$(grep '^apply' "$T/calls.log")
[[ $rc -eq 0 && "$applies" == "apply $vars -auto-approve -lock=false -replace=x.a"$'\n'"apply $vars -auto-approve -lock=false -replace=x.b" ]] \
  && pass "replace DRY_RUN=0: apply -replace=<t> once per target" || fail "replace DRY_RUN=0: rc=$rc calls=$(calls)"
init_at=$(grep -n '^init -backend-config=.*/007-dns.backend-config.tfvars ' "$T/calls.log" | cut -d: -f1)
[[ -n "$init_at" && "$init_at" -lt "$(grep -n '^apply' "$T/calls.log" | sed -n 1p | cut -d: -f1)" ]] \
  && pass "replace DRY_RUN=0: the init with the step's backend config comes first" || fail "replace init order: $(calls)"

# --- 3. tf-state-push ---------------------------------------------------------------
mkdir -p "$T/proj/state"; echo '{"serial":9}' >"$T/proj/state/in.tfstate"
run_action do_tf_state_push; rc=$?
[[ $rc -eq 0 ]] && ! grep -q '^state push' "$T/calls.log" && grep -q 'DRY_RUN: nothing pushed; DRY_RUN=0 pushes' "$T/out.log" \
  && pass "state-push default: no state push, the log says nothing was pushed" || fail "state-push default: rc=$rc calls=$(calls) out=$(cat "$T/out.log")"
run_action do_tf_state_push DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(grep '^state push' "$T/calls.log")" == "state push -lock=false $T/proj/state/in.tfstate" ]] \
  && pass "state-push DRY_RUN=0: state push -lock=false <PROJ_PATH>/<TFSTATE_FILE>, once" || fail "state-push DRY_RUN=0: rc=$rc calls=$(calls)"
run_action do_tf_state_push DRY_RUN=0 TFSTATE_FILE=state/missing.tfstate; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q 'no state file' "$T/out.log" \
  && pass "state-push: a missing state file is refused before do_tf_init" || fail "state-push missing file: rc=$rc calls=$(calls) out=$(cat "$T/out.log")"

# --- 4. tf-state-pull (read-only) ---------------------------------------------------
run_action do_tf_state_pull; rc=$?
out_state="$T/proj/dat/tmp/o-a-dev-007-dns-terraform.tfstate"
[[ $rc -eq 0 && "$(cat "$out_state" 2>/dev/null)" == '{"serial":7}' ]] \
  && pass "state-pull: the pulled state lands in dat/tmp" || fail "state-pull: rc=$rc calls=$(calls) out=$(cat "$T/out.log")"
! grep -qE '^(state push|apply|plan|state rm)' "$T/calls.log" \
  && pass "state-pull: no push, apply, plan or state rm" || fail "state-pull mutated: $(calls)"

# --- 5. CONTROL: a missing required var refuses before anything runs -----------------
for fv in do_tf_remove_step:STEP do_tf_replace_target:ENV do_tf_replace_target:STEP do_tf_replace_target:TARGET \
  do_tf_state_push:ENV do_tf_state_push:STEP do_tf_state_push:TFSTATE_FILE do_tf_state_pull:ENV do_tf_state_pull:STEP; do
  fn="${fv%%:*}" v="${fv##*:}"
  sandbox; run_action "$fn" DRY_RUN=0 "$v="; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" && -f "$T/sbx/src/terraform/008-keep/main.tf" ]] && grep -q "$v must be set" "$T/out.log" \
    && pass "CONTROL: $fn with no $v -> refused, no do_tf_init, no terraform, no rm" \
    || fail "CONTROL $fn $v: rc=$rc calls=$(calls) out=$(cat "$T/out.log")"
done

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
