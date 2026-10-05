#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: prove do_gcp_bkp_state_bucket_create RETURNS on every refusal
#          (refactor round 3, row 13): it is sourced into the ./run shell, so an
#          `exit` would kill the whole run and leave its caller no way to
#          recover. Each case calls the action inside `bash -c '...; echo after'`
#          against a stubbed gcloud (a function recording its argv) and the
#          project / account resolvers stubbed, so nothing reaches GCP.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
RUN="$PROJ_ROOT/src/bash/run"
F="$RUN/gcp-bkp-state-bucket-create.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fails=0

require_action "$F"
bash -n "$F" && pass "bash -n $(basename "$F")" || fail "bash -n $(basename "$F")"

# run_case <log> [VAR=value ...] - prints the action's output, then "rc=<n> after".
#   stub knobs: DESCRIBE absent (default) | opaque   NOGCLOUD 1: no gcloud at all
run_case() {
  local log="$1"; shift
  : >"$log"
  env -u PROJECT_ENV -u DRY_RUN F="$F" LOG="$log" "$@" bash -c '
    quit_on(){ rv=$?; if [ $rv -ne 0 ]; then echo "FATAL Failed to $1"; exit $rv; fi; }
    do_log(){ echo "$*"; }
    do_gcp_spl_proj_id(){ PROJ_ID="csi-spl-${ENV}"; }
    do_gcp_pin_account(){ GCP_ACCOUNT=stub-sa@example.com; }
    do_gcp_require_live_account(){ :; }
    if [[ "${NOGCLOUD:-}" == 1 ]]; then PATH=/nonexistent; else
      gcloud(){
        echo "gcloud $*" >>"$LOG"
        case "$*" in
          "storage buckets describe"*)
            if [[ "${DESCRIBE:-absent}" == opaque ]]; then echo "permission denied"; else echo "404 not found"; fi
            return 1 ;;
        esac
      }
    fi
    source "$F"
    do_gcp_bkp_state_bucket_create
    echo "rc=$? after"' 2>&1
}

log="$T/gcloud.log"

# --- control: the stubs reach the end of a dry run (so the refusals below mean something)
out=$(run_case "$log")
[[ "$out" == *"DRY_RUN would run: gcloud storage buckets create gs://csi-spl-bkp-tfstate"*"rc=0 after"* ]] && ! grep -q 'buckets create' "$log" \
  && pass "CONTROL: default PROJECT_ENV=bkp dry run reads, creates nothing, returns 0" || fail "control dry run: $out / $(cat "$log")"

# --- every refusal returns 1 and the caller runs on --------------------------
out=$(run_case "$log" PROJECT_ENV=bad)
[[ "$out" == *"PROJECT_ENV must be bkp or all, got: bad"*"rc=1 after"* && ! -s "$log" ]] \
  && pass "PROJECT_ENV=bad returns 1 before any gcloud call; the caller survives" || fail "PROJECT_ENV=bad: $out / $(cat "$log")"

out=$(run_case "$log" DRY_RUN=2)
[[ "$out" == *"DRY_RUN must be 0 or 1, got: 2"*"rc=1 after"* && ! -s "$log" ]] \
  && pass "DRY_RUN=2 returns 1 before any gcloud call; the caller survives" || fail "DRY_RUN=2: $out / $(cat "$log")"

out=$(run_case "$log" NOGCLOUD=1)
[[ "$out" == *"gcloud is not installed"*"rc=1 after"* ]] \
  && pass "no gcloud returns 1; the caller survives" || fail "no gcloud: $out"

out=$(run_case "$log" DESCRIBE=opaque DRY_RUN=0)
[[ "$out" == *"cannot tell whether gs://csi-spl-bkp-tfstate exists"*"rc=1 after"* ]] && ! grep -q 'buckets create' "$log" \
  && pass "an unreadable describe returns 1 and creates nothing; the caller survives" || fail "opaque describe: $out / $(cat "$log")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
