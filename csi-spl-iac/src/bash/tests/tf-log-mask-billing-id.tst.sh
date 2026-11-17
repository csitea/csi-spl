#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: terraform apply / destroy write no billing account id in clear text
#          (SPL-5797). A step-002 apply left the full id 9 times in its
#          dat/log/tf_apply.<org>-<app>-<env>.<step>.log: every tee wrote the
#          raw terraform output. A stub terraform prints a billing-shaped id on
#          stdout and stderr; for each of do_tf_apply, do_tf_apply_target,
#          do_tf_destroy, do_tf_destroy_target and
#          do_tf_destroy_local_step_bucket:
#   1. the action's log and its output count 0 full ids, and keep the masked
#      form with the last 4 chars (XXXXXX-XXXXXX-XX<last 4>)
#   2. do_tf_apply still returns terraform's exit status (PIPESTATUS[0])
#   3. CONTROL: the same action with its `do_tf_log_mask |` cut out leaves the
#      id in the log, so the count is not blind.
#          TF_MASK_RUN_DIR points the test at another run dir: on the
#          origin/master tree before SPL-5797 every action case fails.
#          No terraform, no GCP: terraform, sleep and do_tf_init are stubs.
#          The bare `terraform init` of the target actions is not piped: under
#          their `set -e` a pipe would hide a failed init, and init reads no
#          tfvars, so it prints no billing id.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RUN_DIR_SRC="${TF_MASK_RUN_DIR:-$PROJ_ROOT/src/bash/run}"
MASK_LIB="$PROJ_ROOT/lib/bash/funcs/tf-log-mask.func.sh"
require_action "$MASK_LIB"
# a made-up id, built at run time so no billing-shaped literal sits in the tree
ID=$(printf '%s-%s-%s' 0A1B2C 3D4E5F 6A7B8C)
RX='[0-9A-Fa-f]{6}-[0-9A-Fa-f]{6}-[0-9A-Fa-f]{6}'
# init reads no tfvars, so only the verbs that do (plan, apply, destroy, output)
# print the id; the target actions run their init bare under set -e.
stub terraform 'case " $* " in *" init "*) echo "Terraform has been initialized"; exit 0 ;; esac
echo "billing_account = \"billingAccounts/$STUB_ID\""
echo "Error: account $STUB_ID" >&2
case " $* " in *" apply "*|*" destroy "*) exit "${STUB_TF_RC:-0}" ;; esac; exit 0'
stub sleep 'exit 0'

# run_action <file> <function> <out> [env...] -> rc; the log is $T/proj/dat/log/*
run_action() {
  local file="$1" fn="$2" out="$3"; shift 3
  rm -rf "$T/proj" "$T/work"; mkdir -p "$T/proj/dat/log" "$T/work"
  (cd "$T/work" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" STUB_ID="$ID" \
    PROJ_PATH="$T/proj" APP_PATH="$T/app" ORG=o APP=a ENV=dev STEP=s1 TARGET=x.a DRY_RUN=0 \
    ACTION_FILE="$file" FN="$fn" MASK_LIB="$MASK_LIB" "$@" bash -c '
      set -u
      do_log() { echo "$*"; }; do_simple_log() { echo "$*"; }
      env_order_gate() { return 0; }; _provision_052_entry_check() { return 0; }
      do_export_json_section_vars() { return 0; }
      do_tf_init() { tf_proj="$STEP"; tf_run_path="$PROJ_PATH/bin/$tf_proj"; mkdir -p "$tf_run_path"; }
      source "$MASK_LIB"
      source "$ACTION_FILE"
      "$FN"') >"$out" 2>&1
}
# count <file> -> lines holding a full id (numbers only, never the match)
count() { grep -cE "$RX" "$1" 2>/dev/null || true; }

for pair in tf-apply:do_tf_apply tf-apply-target:do_tf_apply_target tf-destroy:do_tf_destroy \
  tf-destroy-target:do_tf_destroy_target tf-destroy-local-step-bucket:do_tf_destroy_local_step_bucket; do
  f="$RUN_DIR_SRC/${pair%%:*}.func.sh" fn="${pair##*:}"
  [[ -f "$f" ]] || { fail "$fn: no $f"; continue; }
  run_action "$f" "$fn" "$T/out"
  log=$(ls "$T"/proj/dat/log/tf_*.log 2>/dev/null | sed -n 1p)
  [[ -n "$log" ]] || { fail "$fn wrote no tf_*.log"; continue; }
  n_log=$(count "$log") n_out=$(count "$T/out")
  [[ "$n_log" -eq 0 ]] && pass "$fn: its log counts 0 full billing ids" \
    || fail "$fn: its log holds $n_log line(s) with a full billing id"
  [[ "$n_out" -eq 0 ]] && pass "$fn: its output counts 0 full billing ids" \
    || fail "$fn: its output holds $n_out line(s) with a full billing id"
  grep -q 'XXXXXX-XXXXXX-XX7B8C' "$log" && pass "$fn: the log keeps the masked id, last 4 chars" \
    || fail "$fn: no masked id in the log"

  # 3. CONTROL: the same action without the mask leaves the id in the log
  sed 's/do_tf_log_mask | //' "$f" >"$T/nomask.func.sh"
  run_action "$T/nomask.func.sh" "$fn" "$T/out.nomask"
  n_ctl=$(count "$(ls "$T"/proj/dat/log/tf_*.log | sed -n 1p)")
  [[ "$n_ctl" -gt 0 ]] && pass "CONTROL $fn: without the mask the log holds $n_ctl full id line(s)" \
    || fail "CONTROL $fn: the unmasked copy logged no id: the count is blind"
done

# 2. do_tf_apply keeps terraform's exit status through the mask
run_action "$RUN_DIR_SRC/tf-apply.func.sh" do_tf_apply "$T/out.rc" STUB_TF_RC=3; rc=$?
[[ "$rc" -eq 3 ]] && pass "do_tf_apply returns terraform's status (3) through the mask" \
  || fail "do_tf_apply returned $rc, not terraform's 3"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
