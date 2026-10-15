#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-1947, dev always equals or leads prd. A prd apply of a step
#          plans dev for the same step first and is refused while dev has
#          pending changes (owner, t1 msg 15204547).
#   1. RED case: dev pending -> do_provision ENV=prd exits 3, terraform apply
#      never runs, the REFUSED line names the step.
#      CONTROL: the same run with the gate removed (env_order_gate stubbed to
#      a no-op) DOES apply: the assertion above can fail, so it proves the gate.
#   2. GREEN: dev clean -> the prd apply runs; dev applies are never gated.
#   3. dev plan fails -> refused (rc 1, fail closed).
#   4. ENV_ORDER_OVERRIDE=<owner msg id> -> applies, WARN + one log line;
#      a value that is not a msg id is refused.
#   5. a clean dev plan of the same tree sha is reused; another sha, a
#      dirty tree or ENV_ORDER_CACHE_MINUTES=0 plans again.
#   6. do_tf_plan_pending: plan -detailed-exitcode -lock=false, own run dir
#      (removed), verdicts clean/pending/error = rc 0/2/1, no apply.
#   7. static: the three apply actions call the gate; make passes the override.
#          No terraform, no GCP: terraform and do_tf_init are stubs.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RUN_DIR_SRC="$PROJ_ROOT/src/bash/run"
require_action "$RUN_DIR_SRC/check-dev-leads-prd.func.sh"
require_action "$RUN_DIR_SRC/tf-plan-pending.func.sh"

# terraform: plan exits STUB_PLAN_RC, apply is recorded
stub terraform 'echo "terraform $*" >>"$CALLS"
case " $* " in
  *" plan "*) [ "${STUB_PLAN_RC:-0}" = 2 ] && echo "Plan: 0 to add, 1 to change, 0 to destroy."
              [ "${STUB_PLAN_RC:-0}" = 0 ] && echo "No changes. Your infrastructure matches the configuration."
              [ "${STUB_PLAN_RC:-0}" = 1 ] && echo "Error: stub plan failed"
              exit "${STUB_PLAN_RC:-0}" ;;
esac; exit 0'
# the dev plan the gate runs (ENV_ORDER_PLAN_CMD): records its env, exits STUB_DEV_RC
stub devplan 'echo "devplan ENV=$ENV STEP=$STEP" >>"$CALLS"
echo "TF_PLAN $ENV $STEP stub"; exit "${STUB_DEV_RC:-0}"'

A="$T/app"; P="$A/csi-spl-iac"
mkdir -p "$P/dat/log" "$P/src/terraform" "$A/csi-spl-cnf"
git init -q "$A" && git -C "$A" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m t
SHA=$(git -C "$A" rev-parse HEAD)

# in_iac <env...> -- <snippet>: run a snippet with the iac actions sourced
in_iac() {
  local -a e=(); while [[ "$1" != -- ]]; do e+=("$1"); shift; done; shift
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" CALLS="$T/calls" PROJ_PATH="$P" APP_PATH="$A" \
    ORG=csi APP=spl ACTION=provision SKIP_CONTAINER_DNS_CHECK=1 RUN_DIR_SRC="$RUN_DIR_SRC" \
    ENV_ORDER_CACHE_DIR="$T/cache" "${e[@]}" bash -c '
    set -u
    do_log() { echo "$*"; }
    do_simple_log() { echo "$*"; }
    do_tf_init() { tf_proj="$STEP"; tf_run_path="$PROJ_PATH/bin/$ENV/$STEP${TF_RUN_DIR_SUFFIX:-}"
                   mkdir -p "$tf_run_path"; echo "init $ENV $tf_run_path" >>"$CALLS"; }
    for f in check-dev-leads-prd tf-plan-pending tf-apply tf-apply-target provision; do source "$RUN_DIR_SRC/$f.func.sh"; done
    '"$1"
}
provision() { in_iac STEP=030-x ENV_ORDER_PLAN_CMD="$T/bin/devplan" "$@" -- 'do_provision'; }

# --- 1. RED: dev pending refuses the prd apply ------------------------------
: >"$T/calls"; out=$(provision ENV=prd STUB_DEV_RC=2 2>&1); rc=$?
[[ $rc -eq 3 ]] && pass "dev pending -> prd do_provision exits 3" || fail "dev pending: rc=$rc out=$out"
grep -q ' apply ' "$T/calls" && fail "terraform apply ran on prd while dev was pending" || pass "no prd apply while dev is pending"
grep -q '^REFUSED: prd apply of STEP=030-x: dev has pending changes' <<<"$out" && pass "the refusal names the step" || fail "no REFUSED line naming the step: $out"
grep -q 'devplan ENV=dev STEP=030-x' "$T/calls" && pass "the gate planned DEV for the SAME step" || fail "dev plan not run for 030-x: $(cat "$T/calls")"
grep -q '^init prd' "$T/calls" && fail "prd was initialised before the gate refused" || pass "the gate runs before prd's tf init"

# CONTROL: the gate removed, the very same run applies prd -> the checks above are live
: >"$T/calls"; in_iac STEP=030-x ENV=prd STUB_DEV_RC=2 ENV_ORDER_PLAN_CMD="$T/bin/devplan" -- \
  'env_order_gate() { :; }; do_provision' >/dev/null 2>&1
grep -q ' apply ' "$T/calls" && pass "CONTROL: without the gate the prd apply runs (the RED case is real)" \
  || fail "CONTROL: no apply even without the gate: the test proves nothing"

# --- 2. GREEN ---------------------------------------------------------------
: >"$T/calls"; out=$(provision ENV=prd STUB_DEV_RC=0 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q ' apply ' "$T/calls" && pass "dev clean -> the prd apply runs" || fail "dev clean: rc=$rc out=$out"
[[ $(grep -c devplan "$T/calls") -eq 1 ]] && pass "do_provision -> do_tf_apply plans dev once" || fail "dev planned $(grep -c devplan "$T/calls") times"
: >"$T/calls"; provision ENV=dev STUB_DEV_RC=2 >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ! grep -q devplan "$T/calls" && pass "a dev apply is not gated" || fail "dev apply gated (rc=$rc)"
: >"$T/calls"; provision ENV=prd STUB_DEV_RC=2 ACTION=divest >/dev/null 2>&1
grep -q devplan "$T/calls" && fail "divest was gated" || pass "divest is not gated"
: >"$T/calls"; out=$(in_iac STEP=030-x ENV=prd STUB_DEV_RC=2 TARGET=a.b ENV_ORDER_PLAN_CMD="$T/bin/devplan" -- 'do_tf_apply_target' 2>&1); rc=$?
[[ $rc -eq 3 ]] && ! grep -q ' apply ' "$T/calls" && pass "do_tf_apply_target on prd is gated too" || fail "apply-target: rc=$rc"

# --- 3. dev plan fails: fail closed -----------------------------------------
: >"$T/calls"; out=$(provision ENV=prd STUB_DEV_RC=1 2>&1); rc=$?
[[ $rc -eq 1 ]] && ! grep -q ' apply ' "$T/calls" && pass "a failed dev plan refuses (rc 1)" || fail "failed dev plan: rc=$rc"
grep -q "dev's state is unknown" <<<"$out" && pass "the refusal says dev is unknown" || fail "no unknown reason: $out"

# --- 4. the override --------------------------------------------------------
: >"$T/calls"; out=$(provision ENV=prd STUB_DEV_RC=2 ENV_ORDER_OVERRIDE=15204547 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q ' apply ' "$T/calls" && pass "ENV_ORDER_OVERRIDE=<msg id> lets the prd apply run" || fail "override: rc=$rc out=$out"
grep -q 'WARN ENV_ORDER_OVERRIDE=15204547' <<<"$out" && pass "the override is a WARN line" || fail "no WARN for the override"
grep -q "step=030-x sha=$SHA dev=pending override=15204547" "$P/dat/log/env-order-override.log" 2>/dev/null \
  && pass "the override is logged with step, sha and dev's verdict" || fail "override log: $(cat "$P/dat/log/env-order-override.log" 2>&1)"
: >"$T/calls"; provision ENV=prd STUB_DEV_RC=2 ENV_ORDER_OVERRIDE=yes >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ! grep -q ' apply ' "$T/calls" && pass "ENV_ORDER_OVERRIDE=yes (no msg id) is refused" || fail "override 'yes' accepted"

# --- 5. the cache -----------------------------------------------------------
gate() { in_iac STEP=030-x ENV=prd STUB_PLAN_RC="$1" "${@:2}" -- 'do_check_dev_leads_prd'; }
rm -rf "$T/cache"; : >"$T/calls"
gate 0 >/dev/null 2>&1; gate 2 >"$T/o2" 2>&1; rc=$?
[[ $(grep -c '^init dev' "$T/calls") -eq 1 && $rc -eq 0 ]] && grep -q 'cached dev plan' "$T/o2" \
  && pass "a clean dev plan of this sha is reused (one plan, two gates)" || fail "cache: rc=$rc $(cat "$T/o2")"
: >"$T/calls"; gate 2 ENV_ORDER_CACHE_MINUTES=0 >/dev/null 2>&1; rc=$?
[[ $rc -eq 3 && $(grep -c '^init dev' "$T/calls") -eq 1 ]] && pass "ENV_ORDER_CACHE_MINUTES=0 plans again" || fail "cache 0: rc=$rc"
git -C "$A" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m t2
: >"$T/calls"; gate 2 >/dev/null 2>&1; rc=$?
[[ $rc -eq 3 ]] && pass "a new tree sha does not reuse the old clean plan" || fail "stale-sha cache used: rc=$rc"
gate 0 >/dev/null 2>&1; echo x >"$A/csi-spl-cnf/edit"
: >"$T/calls"; gate 2 >/dev/null 2>&1; rc=$?
[[ $rc -eq 3 ]] && pass "a dirty cnf tree never reuses a cached plan" || fail "dirty tree used the cache: rc=$rc"
rm -f "$A/csi-spl-cnf/edit"

# --- 6. do_tf_plan_pending ---------------------------------------------------
for c in "0 clean" "2 pending" "1 error"; do
  read -r want word <<<"$c"; : >"$T/calls"
  out=$(in_iac STEP=030-x ENV=dev STUB_PLAN_RC="$want" -- 'do_tf_plan_pending' 2>&1); rc=$?
  [[ $rc -eq $want && "$out" == "TF_PLAN dev 030-x $word sha="* ]] && pass "plan rc $want -> $word (rc $rc)" || fail "plan rc $want: rc=$rc out=$out"
done
grep -q 'plan -input=false -detailed-exitcode -lock=false' "$T/calls" && pass "plan uses -detailed-exitcode -lock=false" || fail "plan args: $(cat "$T/calls")"
grep -q ' apply' "$T/calls" && fail "do_tf_plan_pending applied" || pass "do_tf_plan_pending never applies"
grep -q '030-x.plan-pending.[0-9]' "$T/calls" && pass "the plan runs in its own run dir" || fail "plan ran in the shared run dir"
compgen -G "$P/bin/dev/030-x.plan-pending.*" >/dev/null && fail "the plan dir was left behind" || pass "the plan dir is removed"

# --- 7. static --------------------------------------------------------------
for f in provision tf-apply tf-apply-target; do
  grep -qE '^[[:space:]]*env_order_gate \|\| return' "$RUN_DIR_SRC/$f.func.sh" && pass "$f calls the gate" || fail "$f does not call env_order_gate"
done
grep -qF 'tf_proj}${TF_RUN_DIR_SUFFIX:-}' "$RUN_DIR_SRC/tf-init.func.sh" && pass "tf-init honours TF_RUN_DIR_SUFFIX" || fail "tf-init has no TF_RUN_DIR_SUFFIX"
MK="$APP_ROOT/csi-spl-orc/src/make/tf-tasks.func.mk"
n=$(grep -c -- '-e ENV_ORDER_OVERRIDE=' "$MK")
[[ $n -eq 2 ]] && pass "make passes ENV_ORDER_OVERRIDE to do-provision and do-tf-apply-target" || fail "make passes the override $n times, want 2"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
