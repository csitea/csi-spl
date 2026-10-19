#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_tf_destroy_target is a dry run unless DRY_RUN=0, destroys only
#          the named targets, and refuses to start without ENV, STEP or TARGET.
#   1. default: each comma separated target gets `plan -destroy -target=<t>`,
#      no `apply` runs, the log says nothing was destroyed
#   2. DRY_RUN=0: `apply -destroy -auto-approve -target=<t>` once per target,
#      with the step's var file, after the init with the backend config
#   3. CONTROL: no ENV, no STEP, no TARGET -> non-zero, and neither do_tf_init
#      nor terraform ran
# terraform and gcloud are stubs on PATH; do_tf_init is stubbed; HOME is a temp
# dir. No network, no GCP, no state bucket. TF_DESTROY_ACTION points the test
# at another copy of the action (the red control runs it on a broken one).
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="${TF_DESTROY_ACTION:-$PROJ_ROOT/src/bash/run/tf-destroy-target.func.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fails=0
require_action "$ACTION"

stub terraform 'shift; echo "$*" >>"$TF_CALLS"'
stub gcloud 'echo "gcloud $*" >>"$TF_CALLS"; exit 1'

# run_action <env assignments...> -> rc; calls in $T/calls.log, output in $T/out.log
run_action() {
  : >"$T/calls.log"
  (cd "$T" && env -u DRY_RUN -u GOOGLE_APPLICATION_CREDENTIALS HOME="$T/home" \
    PATH="$T/bin:$PATH" TF_CALLS="$T/calls.log" ACTION="$ACTION" \
    ORG=o APP=a ENV=dev STEP=s1 APP_PATH="$T/app" PROJ_PATH="$T/proj" \
    TARGET="x.a,x.b" "$@" \
    bash -c 'do_log(){ echo "$*"; }; do_simple_log(){ echo "$*"; }
      do_tf_init(){ echo "do_tf_init" >>"$TF_CALLS"; tf_proj="$STEP"; tf_run_path="$PROJ_PATH/bin/$ENV/$tf_proj"; mkdir -p "$tf_run_path" "$PROJ_PATH/dat/log"; }
      source "$ACTION"; do_tf_destroy_target') >"$T/out.log" 2>&1
}
calls() { tr '\n' '|' <"$T/calls.log"; }
vars="-var-file=$T/app/o-a-cnf/o-a/dev/tf/s1.vars.tfvars"

# --- 1. default = dry run -----------------------------------------------------------
run_action; rc=$?
plans=$(grep '^plan -destroy' "$T/calls.log")
[[ $rc -eq 0 && "$plans" == "plan -destroy $vars -lock=false -target=x.a"$'\n'"plan -destroy $vars -lock=false -target=x.b" ]] \
  && pass "default: plan -destroy -target=<t> once per target" || fail "default: rc=$rc calls=$(calls) out=$(cat "$T/out.log")"
! grep -q '^apply' "$T/calls.log" && pass "default: no apply runs" || fail "default applied: $(calls)"
grep -q 'DRY_RUN: nothing destroyed; DRY_RUN=0 destroys' "$T/out.log" \
  && pass "default: the log says nothing was destroyed" || fail "default log: $(cat "$T/out.log")"
run_action DRY_RUN=1
! grep -q '^apply' "$T/calls.log" && pass "DRY_RUN=1: no apply runs" || fail "DRY_RUN=1 applied: $(calls)"

# --- 2. DRY_RUN=0 destroys each target, nothing else ----------------------------------
run_action DRY_RUN=0; rc=$?
applies=$(grep '^apply' "$T/calls.log")
[[ $rc -eq 0 && "$applies" == "apply -destroy -auto-approve $vars -lock=false -target=x.a"$'\n'"apply -destroy -auto-approve $vars -lock=false -target=x.b" ]] \
  && pass "DRY_RUN=0: apply -destroy -target=<t> once per target, nothing untargeted" || fail "DRY_RUN=0: rc=$rc calls=$(calls)"
init_at=$(grep -n '^init -backend-config=.*/s1.backend-config.tfvars ' "$T/calls.log" | cut -d: -f1)
[[ -n "$init_at" && "$init_at" -lt "$(grep -n '^apply' "$T/calls.log" | sed -n 1p | cut -d: -f1)" ]] \
  && pass "DRY_RUN=0: the init with the step's backend config comes first" || fail "init order: $(calls)"
! grep -q '^gcloud' "$T/calls.log" && pass "no gcloud call" || fail "gcloud called: $(calls)"

# --- 3. CONTROL: a missing required var refuses before anything runs -----------------
for v in ENV STEP TARGET; do
  run_action DRY_RUN=0 "$v="; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q "$v must be set" "$T/out.log" \
    && pass "CONTROL: no $v -> refused, no do_tf_init, no terraform" \
    || fail "CONTROL $v: rc=$rc calls=$(calls) out=$(cat "$T/out.log")"
done

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
