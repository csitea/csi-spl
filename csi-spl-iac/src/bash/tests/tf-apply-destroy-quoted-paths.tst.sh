#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_tf_apply and do_tf_destroy pass every path to terraform as ONE
#          argument (refactor round 1, practice 22: quote variable expansions).
#          PROJ_PATH, APP_PATH and the run dir all carry a space; an unquoted
#          -chdir=$tf_run_path word-splits there and runs terraform against the
#          wrong dir. A stub terraform on PATH records one ARG<..> line per
#          argument; do_tf_init is stubbed (it only has to set tf_run_path).
#          CONTROL: an unquoted copy of the action splits the same path, so the
#          check is not blind to the quoting.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RUN_DIR_SRC="$PROJ_ROOT/src/bash/run"
require_action "$RUN_DIR_SRC/tf-apply.func.sh"
require_action "$RUN_DIR_SRC/tf-destroy.func.sh"
stub terraform 'for a in "$@"; do echo "ARG<$a>"; done >>"$STUB_TF_ARGV"; echo stub-terraform; exit 0'

P="$T/proj dir"; A="$T/app dir"; R="$T/run dir"
mkdir -p "$P/dat/log" "$P/src/bash/scripts" "$R"
ANSIBLE="$P/src/bash/scripts/run-ansible-csi-spl-dev-000-step.sh"
printf '#!/bin/bash\necho ANSIBLE-RAN >>"%s"\n' "$T/ansible.out" >"$ANSIBLE"; chmod +x "$ANSIBLE"

# run_action <file> <function> <argv-log> -> runs one action under the stubs
run_action() {
  env -i PATH="$T/bin:/usr/bin:/bin" STUB_TF_ARGV="$3" ACTION_FILE="$1" RUN_DIR="$R" \
      PROJ_PATH="$P" APP_PATH="$A" ORG=csi APP=spl ENV=dev STEP=000-step FN="$2" bash -c '
    set -u
    do_log() { echo "$*"; }
    do_simple_log() { echo "$*"; }
    sleep() { :; }
    do_tf_init() { tf_run_path="$RUN_DIR"; tf_proj=000-step; }
    source "$ACTION_FILE"
    "$FN"
  ' >/dev/null 2>&1
}

TFV="$A/csi-spl-cnf/csi-spl/dev/tf/000-step"

run_action "$RUN_DIR_SRC/tf-apply.func.sh" do_tf_apply "$T/apply.argv"
grep -c -xF "ARG<-chdir=$R>" "$T/apply.argv" | grep -qx 3 \
  && pass "apply: init, apply and output each get -chdir=<run dir> as one argument" \
  || fail "apply: -chdir split: $(head -5 "$T/apply.argv")"
grep -qxF "ARG<-var-file=$TFV.vars.tfvars>" "$T/apply.argv" \
  && pass "apply: -var-file is one argument" || fail "apply: -var-file split"
grep -qxF "ARG<-backend-config=$TFV.backend-config.tfvars>" "$T/apply.argv" \
  && pass "apply: -backend-config is one argument" || fail "apply: -backend-config split"
[[ -s "$P/dat/log/tf_apply.csi-spl-dev.000-step.log" ]] \
  && pass "apply: the log lands under the spaced PROJ_PATH" || fail "apply: no log under '$P'"
grep -qx ANSIBLE-RAN "$T/ansible.out" 2>/dev/null \
  && pass "apply: the run-ansible hook under the spaced PROJ_PATH runs" || fail "apply: the run-ansible hook did not run"

run_action "$RUN_DIR_SRC/tf-destroy.func.sh" do_tf_destroy "$T/destroy.argv"
grep -c -xF "ARG<-chdir=$R>" "$T/destroy.argv" | grep -qx 2 \
  && pass "destroy: init and destroy each get -chdir=<run dir> as one argument" \
  || fail "destroy: -chdir split: $(head -5 "$T/destroy.argv")"
grep -qxF "ARG<-var-file=$TFV.vars.tfvars>" "$T/destroy.argv" \
  && pass "destroy: -var-file is one argument" || fail "destroy: -var-file split"
grep -qxF "ARG<-backend-config=$TFV.backend-config.tfvars>" "$T/destroy.argv" \
  && pass "destroy: -backend-config is one argument" || fail "destroy: -backend-config split"
[[ -s "$P/dat/log/tf_destroy.csi-spl-dev.000-step.log" ]] \
  && pass "destroy: the log lands under the spaced PROJ_PATH" || fail "destroy: no log under '$P'"

sed -E 's/-chdir="([^"]*)"/-chdir=\1/g' "$RUN_DIR_SRC/tf-destroy.func.sh" >"$T/unquoted.func.sh"
run_action "$T/unquoted.func.sh" do_tf_destroy "$T/unquoted.argv"
! grep -qxF "ARG<-chdir=$R>" "$T/unquoted.argv" && grep -qxF "ARG<-chdir=$T/run>" "$T/unquoted.argv" \
  && pass "CONTROL: an unquoted -chdir splits the spaced run dir" \
  || fail "CONTROL: the unquoted copy did not split: $(head -3 "$T/unquoted.argv")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
