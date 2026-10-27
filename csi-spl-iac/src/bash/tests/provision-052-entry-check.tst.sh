#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-3651 (dispatch 5f0839c6, R7 finding msg 30c115c2): a step 052
#          apply refuses a cnf whose steps.052 workspaces hold a workspace that
#          is not in env.dns.mapped_tenants. The check is the tenant-host
#          reconcile's own spl_th_entry_check (csi-spl-orc, sourced, never
#          copied), run in do_provision: every 052 apply passes there (make
#          do-provision; do_tf_sweep_steps and spl_th_apply both call it).
#          1. RED: an unmapped workspace in 052 -> do_provision refuses,
#             terraform never runs, the refusal names the workspace.
#             CONTROL: the same workspace mapped -> the 052 apply runs.
#          2. other steps unchanged: a 040 and a 070 apply on the SAME bad cnf
#             run, and their output names no entry check.
#          3. fail closed: an orc file without spl_th_entry_check refuses 052.
#          4. static: the sweep and the tenant-host apply reach 052 only via
#             make do-provision, and that target runs do_provision.
#          5. SPL-3775: do_tf_apply_target (make do-tf-apply-target) applies
#             without do_provision, so it runs the same check itself: cases
#             1-3 again for a targeted apply.
#          No terraform, no GCP: terraform and do_tf_init are stubs.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RUN_DIR_SRC="$PROJ_ROOT/src/bash/run"
ORC="$APP_ROOT/csi-spl-orc"
ORC_FN_REL=csi-spl-orc/src/bash/run/spl-tenant-host-reconcile.func.sh
require_action "$RUN_DIR_SRC/provision.func.sh"
command -v yq >/dev/null || { echo "FAIL: no yq (mikefarah v4)"; exit 1; }
PLANT=zz-unmapped-spl3651
W052='.env.steps."052-gcs-workspace-docs".workspaces'

stub terraform 'echo "terraform $*" >>"$CALLS"; exit 0'

# a scratch app tree: the live cnf yaml files + the real orc reconcile file
A="$T/app"; P="$A/csi-spl-iac"; C="$A/csi-spl-cnf/csi-spl"
mkdir -p "$P/dat/log" "$C" "$(dirname "$A/$ORC_FN_REL")"
cp "$APP_ROOT"/csi-spl-cnf/csi-spl/{all,dev}.env.yaml "$C/"
cp "$APP_ROOT/$ORC_FN_REL" "$A/$ORC_FN_REL"
yq -i "$W052 += [\"$PLANT\"]" "$C/dev.env.yaml"

# provision <STEP> -> do_provision on dev, output on stdout, terraform calls in $T/calls
provision() {
  : >"$T/calls"
  env -i PATH="$T/bin:/usr/bin:/bin:/usr/local/bin" HOME="$T" CALLS="$T/calls" PROJ_PATH="$P" APP_PATH="$A" \
    ORG=csi APP=spl ENV=dev STEP="$1" ACTION=provision SKIP_CONTAINER_DNS_CHECK=1 RUN_DIR_SRC="$RUN_DIR_SRC" bash -c '
    set -u
    do_log() { echo "$*"; }
    do_simple_log() { echo "$*"; }
    do_tf_init() { tf_proj="$STEP"; tf_run_path="$PROJ_PATH/bin/$ENV/$STEP"; mkdir -p "$tf_run_path"; }
    for f in check-dev-leads-prd tf-apply provision; do source "$RUN_DIR_SRC/$f.func.sh"; done
    do_provision' 2>&1
}

# --- 1. RED: an unmapped 052 workspace refuses the 052 apply ----------------
out=$(provision 052-gcs-workspace-docs); rc=$?
[[ $rc -ne 0 ]] && pass "unmapped 052 workspace -> do_provision refuses (rc=$rc)" || fail "052 apply was not refused: rc=$rc out=$out"
grep -q 'terraform' "$T/calls" && fail "terraform ran for 052 with an unmapped workspace: $(cat "$T/calls")" || pass "terraform never ran for the refused 052 apply"
grep -q "$PLANT" <<<"$out" && pass "the refusal names the unmapped workspace" || fail "the refusal does not name $PLANT: $out"
grep -q 'REFUSED' <<<"$out" && pass "the refusal says REFUSED" || fail "no REFUSED line: $out"

# CONTROL: the very same workspace mapped -> the 052 apply runs
cp "$C/dev.env.yaml" "$T/dev.bad.yaml"
yq -i ".env.dns.mapped_tenants += [\"$PLANT\"]" "$C/dev.env.yaml"
out=$(provision 052-gcs-workspace-docs); rc=$?
[[ $rc -eq 0 ]] && grep -q ' apply ' "$T/calls" && pass "CONTROL: mapped -> the 052 apply runs (the RED case is real)" \
  || fail "CONTROL: mapped 052 did not apply: rc=$rc out=$out calls=$(cat "$T/calls")"
cp "$T/dev.bad.yaml" "$C/dev.env.yaml"

# --- 2. other steps are unchanged on the same bad cnf -----------------------
for s in 040-cloud-sql-postgres 070-x; do
  out=$(provision "$s"); rc=$?
  [[ $rc -eq 0 ]] && grep -q ' apply ' "$T/calls" && pass "$s applies on the cnf that refuses 052" || fail "$s: rc=$rc out=$out"
  grep -qiE 'entry (point|check)|mapped_tenants' <<<"$out" && fail "$s ran the entry check: $out" || pass "$s names no entry check"
done

# --- 3. fail closed: the orc file lost the function -------------------------
yq -i ".env.dns.mapped_tenants += [\"$PLANT\"]" "$C/dev.env.yaml"
sed 's/^spl_th_entry_check()/renamed_entry_check()/' "$APP_ROOT/$ORC_FN_REL" >"$A/$ORC_FN_REL"
out=$(provision 052-gcs-workspace-docs); rc=$?
[[ $rc -ne 0 ]] && ! grep -q terraform "$T/calls" && pass "no spl_th_entry_check in the orc file -> 052 refused (fail closed)" \
  || fail "052 applied without the check function: rc=$rc out=$out"
rm -f "$A/$ORC_FN_REL"
out=$(provision 052-gcs-workspace-docs); rc=$?
[[ $rc -ne 0 ]] && ! grep -q terraform "$T/calls" && pass "no orc file -> 052 refused (fail closed)" || fail "052 applied with no orc file: rc=$rc out=$out"

# --- 5. SPL-3775: make do-tf-apply-target runs do_tf_apply_target, which ----
# applies by itself, never through do_provision. Only tf-apply-target.func.sh
# is sourced here, so it must reach the check on its own.
cp "$APP_ROOT/$ORC_FN_REL" "$A/$ORC_FN_REL"
cp "$T/dev.bad.yaml" "$C/dev.env.yaml"
apply_target() {
  : >"$T/calls"
  env -i PATH="$T/bin:/usr/bin:/bin:/usr/local/bin" HOME="$T" CALLS="$T/calls" PROJ_PATH="$P" APP_PATH="$A" \
    ORG=csi APP=spl ENV=dev STEP="$1" TARGET=module.x SKIP_CONTAINER_DNS_CHECK=1 RUN_DIR_SRC="$RUN_DIR_SRC" bash -c '
    set -u
    do_log() { echo "$*"; }
    do_simple_log() { echo "$*"; }
    do_tf_init() { tf_proj="$STEP"; tf_run_path="$PROJ_PATH/bin/$ENV/$STEP"; mkdir -p "$tf_run_path"; }
    source "$RUN_DIR_SRC/tf-apply-target.func.sh"
    do_tf_apply_target' 2>&1
}
out=$(apply_target 052-gcs-workspace-docs); rc=$?
[[ $rc -ne 0 ]] && ! grep -q terraform "$T/calls" && pass "apply-target: unmapped 052 workspace -> refused, terraform never ran (rc=$rc)" \
  || fail "apply-target: unmapped 052 ran: rc=$rc calls=$(cat "$T/calls")"
grep -q "$PLANT" <<<"$out" && grep -q REFUSED <<<"$out" && pass "apply-target: the refusal says REFUSED and names the workspace" \
  || fail "apply-target: refusal lacks REFUSED/$PLANT: $out"
for s in 040-cloud-sql-postgres 070-x; do
  out=$(apply_target "$s"); rc=$?
  [[ $rc -eq 0 ]] && grep -q ' apply .*-target=module.x' "$T/calls" && pass "apply-target: $s applies on the cnf that refuses 052" \
    || fail "apply-target: $s: rc=$rc out=$out"
done
yq -i ".env.dns.mapped_tenants += [\"$PLANT\"]" "$C/dev.env.yaml"
out=$(apply_target 052-gcs-workspace-docs); rc=$?
[[ $rc -eq 0 ]] && grep -q ' apply .*-target=module.x' "$T/calls" && pass "apply-target CONTROL: mapped -> the 052 targeted apply runs" \
  || fail "apply-target CONTROL: mapped 052 did not apply: rc=$rc out=$out calls=$(cat "$T/calls")"
sed 's/^spl_th_entry_check()/renamed_entry_check()/' "$APP_ROOT/$ORC_FN_REL" >"$A/$ORC_FN_REL"
out=$(apply_target 052-gcs-workspace-docs); rc=$?
[[ $rc -ne 0 ]] && ! grep -q terraform "$T/calls" && pass "apply-target: no spl_th_entry_check -> 052 refused (fail closed)" \
  || fail "apply-target: 052 applied without the check function: rc=$rc out=$out"
rm -f "$A/$ORC_FN_REL"
out=$(apply_target 052-gcs-workspace-docs); rc=$?
[[ $rc -ne 0 ]] && ! grep -q terraform "$T/calls" && pass "apply-target: no orc file -> 052 refused (fail closed)" \
  || fail "apply-target: 052 applied with no orc file: rc=$rc out=$out"

# --- 4. static: every 052 apply path reaches do_provision -------------------
grep -qE '_tf_sweep_make do-provision ' "$ORC/src/bash/run/tf-sweep-steps.func.sh" \
  && pass "do_tf_sweep_steps applies through make do-provision" || fail "do_tf_sweep_steps no longer applies through make do-provision"
grep -qE 'spl_th_make do-provision ' "$ORC/src/bash/run/spl-tenant-host-provision.func.sh" \
  && pass "spl_th_apply applies through make do-provision" || fail "spl_th_apply no longer applies through make do-provision"
awk '/^do-provision:/{on=1; next} on && /^\.PHONY/{exit} on && /\.\/run -a do_provision /{f=1} END{exit !f}' \
  "$ORC/src/make/tf-tasks.func.mk" && pass "make do-provision runs do_provision" || fail "make do-provision no longer runs do_provision"

echo "fails=$fails"
[[ $fails -eq 0 ]]
