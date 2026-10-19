#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_tf_destroy_local_step_bucket is a dry run unless DRY_RUN=0, and
#          refuses to start without ENV or STEP.
#   1. default: `plan -destroy` with the step's var file, no `destroy` runs,
#      the saved local state is left as it was and no backup is written
#   2. DRY_RUN=0: `destroy -auto-approve` after the init; the old saved state
#      goes to a backup and the state the destroy left is saved
#   3. CONTROL: no ENV, no STEP -> non-zero, and neither do_tf_init nor
#      terraform ran
# terraform and gcloud are stubs on PATH; do_tf_init and
# do_export_json_section_vars are stubbed; HOME and the cwd are a temp dir.
# No network, no GCP, no state bucket. TF_DESTROY_ACTION points the test at
# another copy of the action (the red control runs it on a broken one).
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="${TF_DESTROY_ACTION:-$PROJ_ROOT/src/bash/run/tf-destroy-local-step-bucket.func.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fails=0
require_action "$ACTION"

# the destroy stub leaves a new state behind, as the real one does
stub terraform 'run="${1#-chdir=}"; shift; echo "$*" >>"$TF_CALLS"
[[ "$1" == destroy ]] && echo "after-destroy" >"$run/terraform.tfstate"; exit 0'
stub gcloud 'echo "gcloud $*" >>"$TF_CALLS"; exit 1'

saved="$T/proj/cnf/terraform/s1-remote-bucket/o.a.dev.tfstate"
# run_action <env assignments...> -> rc; calls in $T/calls.log, output in $T/out.log
run_action() {
  : >"$T/calls.log"
  rm -rf "$T/proj"; mkdir -p "${saved%/*}"; echo "before" >"$saved"
  (cd "$T/proj" && env -u DRY_RUN -u GOOGLE_APPLICATION_CREDENTIALS HOME="$T/home" \
    PATH="$T/bin:$PATH" TF_CALLS="$T/calls.log" ACTION="$ACTION" \
    ORG=o APP=a ENV=dev STEP=s1-remote-bucket APP_PATH="$T/app" PROJ_PATH="$T/proj" "$@" \
    bash -c 'do_log(){ echo "$*"; }; do_simple_log(){ echo "$*"; }
      do_export_json_section_vars(){ echo "export $2" >>"$TF_CALLS"; }
      do_tf_init(){ echo "do_tf_init" >>"$TF_CALLS"; tf_proj="$STEP"; tf_run_path="$PROJ_PATH/bin/$ENV/$tf_proj"; mkdir -p "$tf_run_path" "$PROJ_PATH/dat/log"; }
      source "$ACTION"; do_tf_destroy_local_step_bucket') >"$T/out.log" 2>&1
}
calls() { tr '\n' '|' <"$T/calls.log"; }
vars="-var-file=$T/app/o-a-cnf/o-a/dev/tf/s1-remote-bucket.vars.tfvars"
baks() { ls "$T"/proj/dat/terraform/s1-remote-bucket/terraform.*.bak.tfstate 2>/dev/null | wc -l; }

# --- 1. default = dry run -----------------------------------------------------------
run_action; rc=$?
[[ $rc -eq 0 ]] && grep -qx "plan -destroy $vars" "$T/calls.log" \
  && pass "default: plan -destroy with the step's var file" || fail "default: rc=$rc calls=$(calls) out=$(cat "$T/out.log")"
! grep -q '^destroy' "$T/calls.log" && pass "default: no destroy runs" || fail "default destroyed: $(calls)"
[[ "$(cat "$saved")" == before && "$(baks)" -eq 0 ]] \
  && pass "default: the saved local state is untouched, no backup written" || fail "default state: '$(cat "$saved")' baks=$(baks)"
grep -q 'DRY_RUN: nothing destroyed' "$T/out.log" \
  && pass "default: the log says nothing was destroyed" || fail "default log: $(cat "$T/out.log")"
run_action DRY_RUN=1
! grep -q '^destroy' "$T/calls.log" && pass "DRY_RUN=1: no destroy runs" || fail "DRY_RUN=1 destroyed: $(calls)"

# --- 2. DRY_RUN=0 destroys and saves the state ---------------------------------------
run_action DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qx "destroy -auto-approve $vars" "$T/calls.log" \
  && pass "DRY_RUN=0: destroy -auto-approve with the step's var file" || fail "DRY_RUN=0: rc=$rc calls=$(calls)"
init_at=$(grep -n '^init -upgrade$' "$T/calls.log" | cut -d: -f1); d_at=$(grep -n '^destroy' "$T/calls.log" | cut -d: -f1)
[[ -n "$init_at" && -n "$d_at" && "$init_at" -lt "$d_at" ]] && pass "DRY_RUN=0: the init comes first" || fail "order: $(calls)"
bak=$(ls "$T"/proj/dat/terraform/s1-remote-bucket/terraform.*.bak.tfstate 2>/dev/null | sed -n 1p)
[[ "$(cat "$saved")" == after-destroy && -n "$bak" && "$(cat "$bak")" == before ]] \
  && pass "DRY_RUN=0: the old state is backed up, the new one saved" || fail "DRY_RUN=0 state: '$(cat "$saved")' bak='$bak'"
! grep -q '^gcloud' "$T/calls.log" && pass "no gcloud call" || fail "gcloud called: $(calls)"

# --- 3. CONTROL: a missing required var refuses before anything runs -----------------
for v in ENV STEP; do
  run_action DRY_RUN=0 "$v="; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q "$v must be set" "$T/out.log" \
    && pass "CONTROL: no $v -> refused, no do_tf_init, no terraform" \
    || fail "CONTROL $v: rc=$rc calls=$(calls) out=$(cat "$T/out.log")"
done

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
