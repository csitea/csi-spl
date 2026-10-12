#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: `make do-provision` exits non-zero when the step's playbook fails.
#          do_provision -> do_tf_apply runs the step's run-ansible script after
#          the apply; its status (the playbook's: failed>0 or unreachable>0 ->
#          non-zero) used to be dropped, and the action returned its last
#          do_log's 0 (dev, step 061, failed=1, exit 0). A stub ansible-playbook
#          on PATH prints a PLAY RECAP and exits STUB_ANSIBLE_RC; the run-ansible
#          script has the generated one's shape (pipe into tee, PIPESTATUS[0]).
#          CONTROL: the same stub exiting 0 -> do_provision exits 0.
#          No terraform, no playbook, no GCP: terraform and do_tf_init are stubs.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RUN_DIR_SRC="$PROJ_ROOT/src/bash/run"
require_action "$RUN_DIR_SRC/tf-apply.func.sh"
require_action "$RUN_DIR_SRC/provision.func.sh"
stub terraform 'case " $* " in *" apply "*) exit "${STUB_TF_APPLY_RC:-0}" ;; esac; echo stub-terraform; exit 0'
stub ansible-playbook 'case " $* " in *" --syntax-check "*) exit 0 ;; esac
echo "PLAY RECAP *********************************************************************"
echo "wine-box : ok=10 changed=0 unreachable=0 failed=$([ "${STUB_ANSIBLE_RC:-0}" -eq 0 ] && echo 0 || echo 1) skipped=0"
echo "ANSIBLE-RAN" >>"$STUB_ANSIBLE_MARK"
exit "${STUB_ANSIBLE_RC:-0}"'

P="$T/proj"; A="$T/app"; R="$T/run"
mkdir -p "$P/dat/log" "$P/src/bash/scripts" "$R"
cat >"$P/src/bash/scripts/run-ansible-csi-spl-dev-061-step.sh" <<EOF
#!/bin/bash
set -uo pipefail
ansible-playbook --syntax-check -i inv box-playbook.yaml || { echo "Syntax check failed, exiting..."; exit 1; }
timeout 60m ansible-playbook box-playbook.yaml -i inv "\$@" 2>&1 | tee -a "$P/dat/log/ansible.log"
exit "\${PIPESTATUS[0]}"
EOF
chmod +x "$P/src/bash/scripts/run-ansible-csi-spl-dev-061-step.sh"

# provision <ansible-rc> <tf-apply-rc> <out>: run do_provision under the stubs, print its exit status
provision() {
  rm -f "$T/mark"
  env -i PATH="$T/bin:/usr/bin:/bin" STUB_ANSIBLE_RC="$1" STUB_TF_APPLY_RC="$2" STUB_ANSIBLE_MARK="$T/mark" \
      RUN_DIR="$R" PROJ_PATH="$P" APP_PATH="$A" ORG=csi APP=spl ENV=dev STEP=061-step ACTION=provision \
      SKIP_CONTAINER_DNS_CHECK=1 RUN_DIR_SRC="$RUN_DIR_SRC" bash -c '
    set -u
    do_log() { echo "$*"; }
    do_simple_log() { echo "$*"; }
    do_tf_init() { tf_run_path="$RUN_DIR"; tf_proj=061-step; }
    source "$RUN_DIR_SRC/tf-apply.func.sh"
    source "$RUN_DIR_SRC/provision.func.sh"
    do_provision
  ' >"$3" 2>&1
  echo $?
}

rc=$(provision 2 0 "$T/fail.out")
[[ "$rc" -ne 0 ]] && pass "a playbook that exits 2 makes do_provision exit non-zero ($rc)" \
  || fail "a playbook that exits 2 left do_provision at exit 0"
[[ "$rc" -eq 2 ]] && pass "the playbook's own status (2) is the action's status" \
  || fail "do_provision exited $rc, not the playbook's 2"
grep -q '^PLAY RECAP' "$T/fail.out" && grep -q 'failed=1' "$T/fail.out" \
  && pass "the PLAY RECAP is in the action's output" || fail "no PLAY RECAP in the output: $(tail -5 "$T/fail.out")"
grep -q 'ERROR the playbook failed with status 2' "$T/fail.out" \
  && pass "the failure is named in the output" || fail "no ERROR line for the failed playbook"

rc=$(provision 0 1 "$T/tf.out")
[[ "$rc" -ne 0 ]] && pass "a failed terraform apply makes do_provision exit non-zero ($rc)" \
  || fail "a failed terraform apply left do_provision at exit 0"
[[ ! -s "$T/mark" ]] && pass "a failed apply does not run the playbook" || fail "the playbook ran after a failed apply"

rc=$(provision 0 0 "$T/ok.out")
[[ "$rc" -eq 0 ]] && pass "CONTROL: a playbook that exits 0 -> do_provision exits 0" \
  || fail "CONTROL: a green playbook made do_provision exit $rc: $(tail -5 "$T/ok.out")"
grep -qx ANSIBLE-RAN "$T/mark" 2>/dev/null && pass "CONTROL: the playbook ran after a good apply" \
  || fail "CONTROL: the playbook did not run"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
