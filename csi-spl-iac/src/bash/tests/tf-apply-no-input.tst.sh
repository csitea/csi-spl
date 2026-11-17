#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: terraform apply / destroy never wait on a hidden prompt, and their
#          logs are not world-readable (bug round 12 row 02, SPL-5822; the
#          SPL-5797 follow-ups). Since SPL-5797 the five actions pipe terraform
#          through do_tf_log_mask (sed -u, a line filter): a missing variable
#          makes terraform print `Enter a value: ` with no newline, the filter
#          holds it, and the run waits on a question nobody sees. Their `tee -a`
#          also created dat/log/tf_*.log with the caller's umask (0664).
#          A stub terraform logs its args and, for apply / destroy / plan
#          without -input=false, prints `Enter a value: ` and fails on EOF.
#          stdin is /dev/null, umask 0002. For each of do_tf_apply,
#          do_tf_apply_target, do_tf_destroy, do_tf_destroy_target and
#          do_tf_destroy_local_step_bucket (the last two also with DRY_RUN=1,
#          their `plan -destroy` verb):
#   1. 0 apply / destroy / plan calls without -input=false
#   2. the tf_*.log is mode 640
#   3. a log that already exists at 0664 is 640 after the run
#   4. do_tf_apply still returns terraform's exit status
#          TF_NOINPUT_RUN_DIR points the test at another run dir: on the
#          origin/master tree before SPL-5822 every action case fails.
#          No terraform, no GCP: terraform, sleep and do_tf_init are stubs.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

tmp_dir
RUN_DIR_SRC="${TF_NOINPUT_RUN_DIR:-$PROJ_ROOT/src/bash/run}"
MASK_LIB="${TF_NOINPUT_MASK_LIB:-$PROJ_ROOT/lib/bash/funcs/tf-log-mask.func.sh}"
require_action "$MASK_LIB"
TF_VERB_RX='(^| )(apply|destroy|plan)( |$)'
stub terraform 'echo "$*" >>"$STUB_CALLS"
case " $* " in *" apply "*|*" destroy "*|*" plan "*) ;; *) exit 0 ;; esac
case " $* " in *" -input=false "*) echo "Apply complete!"; exit 0 ;; esac
printf "var.x\n  Enter a value: "; read -r _v || { echo; echo "Error: No value for required variable"; exit 1; }
exit 1'
stub sleep 'exit 0'

# run_action <file> <function> <pre-log|-> [env...] -> rc; calls in $T/calls
run_action() {
  local file="$1" fn="$2" pre="$3"; shift 3
  rm -rf "$T/proj" "$T/work" "$T/calls"; mkdir -p "$T/proj/dat/log" "$T/work"; : >"$T/calls"
  if [[ "$pre" != - ]]; then : >"$T/proj/dat/log/$pre"; chmod 0664 "$T/proj/dat/log/$pre"; fi
  (cd "$T/work" && umask 0002 && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" \
    STUB_CALLS="$T/calls" PROJ_PATH="$T/proj" APP_PATH="$T/app" ORG=o APP=a ENV=dev STEP=s1 \
    TARGET=x.a DRY_RUN=0 ACTION_FILE="$file" FN="$fn" MASK_LIB="$MASK_LIB" "$@" bash -c '
      set -u
      do_log() { echo "$*"; }; do_simple_log() { echo "$*"; }
      env_order_gate() { return 0; }; _provision_052_entry_check() { return 0; }
      do_export_json_section_vars() { return 0; }
      do_tf_init() { tf_proj="$STEP"; tf_run_path="$PROJ_PATH/bin/$tf_proj"; mkdir -p "$tf_run_path"; }
      # shellcheck source=/dev/null
      source "$MASK_LIB"
      # shellcheck source=/dev/null
      source "$ACTION_FILE"
      "$FN"') </dev/null >"$T/out" 2>&1
}

# check <label> <function> <file> <log name> <pre-log|-> [env...]
check() {
  local name="$1" fn="$2" file="$3" logname="$4" pre="$5"; shift 5
  run_action "$RUN_DIR_SRC/$file.func.sh" "$fn" "$pre" "$@"
  local n mode
  [[ "$(grep -cE "$TF_VERB_RX" "$T/calls")" -gt 0 ]] \
    || { fail "$name: made no apply/destroy call: $(tr '\n' '|' <"$T/out")"; return; }
  n=$(grep -E "$TF_VERB_RX" "$T/calls" | grep -vcE -- '(^| )-input=false( |$)')
  [[ "$n" -eq 0 ]] && pass "$name: 0 apply/destroy calls without -input=false" \
    || fail "$name: $n apply/destroy call(s) without -input=false"
  mode=$(stat -c %a "$T/proj/dat/log/$logname" 2>/dev/null || echo none)
  [[ "$mode" == 640 ]] && pass "$name: its log is mode 640" \
    || fail "$name: its log is mode $mode, not 640"
}

for row in tf-apply:do_tf_apply:tf_apply tf-apply-target:do_tf_apply_target:tf_apply \
  tf-destroy:do_tf_destroy:tf_destroy tf-destroy-target:do_tf_destroy_target:tf_destroy \
  tf-destroy-local-step-bucket:do_tf_destroy_local_step_bucket:tf_destroy; do
  IFS=: read -r file fn base <<<"$row"
  [[ -f "$RUN_DIR_SRC/$file.func.sh" ]] || { fail "$fn: no $RUN_DIR_SRC/$file.func.sh"; continue; }
  logname="$base.o-a-dev.s1.log"
  check "$fn" "$fn" "$file" "$logname" -
  check "$fn (log was 0664)" "$fn" "$file" "$logname" "$logname"
  case "$fn" in do_tf_destroy_target | do_tf_destroy_local_step_bucket)
    check "$fn DRY_RUN=1 (plan -destroy)" "$fn" "$file" "$logname" - DRY_RUN=1 ;;
  esac
done

# 3b. the helper itself lowers an existing 0664 log and keeps its text
mkdir -p "$T/h"; echo kept >"$T/h/x.log"; chmod 0664 "$T/h/x.log"
# shellcheck source=/dev/null
(umask 0002; source "$MASK_LIB"; do_tf_log_open "$T/h/x.log" && do_tf_log_open "$T/h/new/y.log")
[[ "$(stat -c %a "$T/h/x.log")" == 640 && "$(cat "$T/h/x.log")" == kept ]] \
  && pass "do_tf_log_open lowers an existing 0664 log to 640, its text kept" \
  || fail "do_tf_log_open: existing log is $(stat -c %a "$T/h/x.log"): $(cat "$T/h/x.log")"
[[ "$(stat -c %a "$T/h/new/y.log" 2>/dev/null)" == 640 ]] \
  && pass "do_tf_log_open creates a new log (and its dir) at 640" \
  || fail "do_tf_log_open: new log is $(stat -c %a "$T/h/new/y.log" 2>&1)"

# 4. terraform's status still comes through the mask and the log helper
stub terraform 'echo "$*" >>"$STUB_CALLS"; case " $* " in *" apply "*) exit 3 ;; esac; exit 0'
run_action "$RUN_DIR_SRC/tf-apply.func.sh" do_tf_apply -; rc=$?
[[ "$rc" -eq 3 ]] && pass "do_tf_apply returns terraform's status (3)" \
  || fail "do_tf_apply returned $rc, not terraform's 3"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
