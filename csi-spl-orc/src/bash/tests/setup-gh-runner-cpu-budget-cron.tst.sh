#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_setup_gh_runner_cpu_budget_cron writes the gate CPU floor
#   (CPU_BUDGET_GATE_FLOOR_PCT, owner HUM-10 2026-10-10: 500 = 5 cores) into
#   the cron line it builds, so a re-run keeps it.
#   1. default: the rendered line carries CPU_BUDGET_GATE_FLOOR_PCT=500 and
#      runs the job behind cron-no-stack.sh on <logdir>/cron.lock (SPL-4495)
#   2. a second install keeps exactly one tagged line and the same floor
#   3. CPU_BUDGET_GATE_FLOOR_PCT=0 renders the floor off; a bad value is refused
#   4. red control: the action without the floor (git HEAD~ copy or a copy with
#      the floor stripped) fails check 1
#   The rest of the installer (keep other lines, check, remove) is covered in
#   apply-gh-runner-cpu-budget.tst.sh section 4. No real crontab: a stub.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/setup-gh-runner-cpu-budget-cron.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
bash -n "$FUNC" || { echo "FAIL: bash -n"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
SH="$T/shared"
mkdir -p "$T/bin" "$SH/csi-spl-orc/src/bash/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' >"$SH/csi-spl-orc/src/bash/scripts/gh-runner-cpu-budget-cron.sh"
chmod +x "$SH/csi-spl-orc/src/bash/scripts/gh-runner-cpu-budget-cron.sh"
printf '#!/usr/bin/env bash\nif [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi\ncp "$1" "$FAKE_CRONTAB"\n' >"$T/bin/crontab"
chmod +x "$T/bin/crontab"
printf '%s\n' '# keep me' >"$T/crontab"

# setup <func file> [VAR=v ...]: run the installer against the stub crontab
setup() {
  local f="$1"; shift
  env -u CPU_BUDGET_GATE_FLOOR_PCT -u CPU_BUDGET_CI_RESERVE_PCT -u CPU_BUDGET_CI_WEIGHT PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" \
    FAKE_CRONTAB="$T/crontab" SPL_ORG_APP=csi-spl DESK_CRON_SRC="$SH" CPU_BUDGET_CRON_LOG_DIR="$T/log" "$@" bash -c '
    set -uo pipefail
    do_log() { printf "%s\n" "$*"; }
    do_require_bin() { return 0; }
    source "'"$PROJ_ROOT"'/src/bash/run/spl-desk-install-service.func.sh"
    source "'"$f"'"
    do_setup_gh_runner_cpu_budget_cron'
}
script="$SH/csi-spl-orc/src/bash/scripts/gh-runner-cpu-budget-cron.sh"
# the job runs behind its own no-stack lock (SPL-4495)
want() { printf '* * * * * CPU_BUDGET_GATE_FLOOR_PCT=%s CPU_BUDGET_CI_RESERVE_PCT=950 CPU_BUDGET_CI_WEIGHT=400 %s/csi-spl-orc/src/bash/scripts/cron-no-stack.sh %s/log/cron.lock %s >> %s/log/cron.out 2>&1 # csi-spl:gh-runner-cpu-budget' "$1" "$SH" "$T" "$script" "$T"; }
tagged() { grep -c 'csi-spl:gh-runner-cpu-budget$' "$T/crontab"; }

# check_default <func file>: 0 when the default install writes the 500 floor
check_default() {
  local out
  out="$(setup "$1" DRY_RUN=0)" || return 1
  [[ "$(tagged)" -eq 1 && "$(grep -F -x -c "$(want 500)" "$T/crontab")" -eq 1 ]]
}

# 1. default
out="$(setup "$FUNC")"; rc=$?
[[ $rc -eq 0 && "$out" == *"+$(want 500)"* ]] &&
  pass "dry run: the rendered line carries CPU_BUDGET_GATE_FLOOR_PCT=500" || fail "dry default (rc=$rc): $out"
# 1b. no override: the log dir derives from SPL_VAR_APP_DIR (r75-01)
out="$(setup "$FUNC" CPU_BUDGET_CRON_LOG_DIR= SPL_VAR_APP_DIR="$T/var" DRY_RUN=1 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"cron-no-stack.sh $T/var/gh-runner-cpu-budget/cron.lock "* && "$out" == *">> $T/var/gh-runner-cpu-budget/cron.out 2>&1"* && ! -e "$T/var" ]] &&
  pass "no override: the lock and cron.out sit under \$SPL_VAR_APP_DIR/gh-runner-cpu-budget, a dry run creates nothing" || fail "derived log dir (rc=$rc): $out"
check_default "$FUNC" && pass "install: the tagged line carries the 500 floor" || fail "install default: $(cat "$T/crontab")"

# 2. re-run keeps one line, same floor
out="$(setup "$FUNC" DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(tagged)" -eq 1 && "$(grep -F -x -c "$(want 500)" "$T/crontab")" -eq 1 && "$(head -1 "$T/crontab")" == '# keep me' ]] &&
  pass "a second install: exactly one line, the same floor" || fail "reinstall (rc=$rc): $(cat "$T/crontab")"
out="$(setup "$FUNC" CPU_BUDGET_CRON_ACTION=check)"; rc=$?
[[ $rc -eq 0 && "$out" != *'other settings'* ]] && pass "check: the installed line matches what a re-run writes" || fail "check (rc=$rc): $out"

# 3. off, bad value
out="$(setup "$FUNC" DRY_RUN=0 CPU_BUDGET_GATE_FLOOR_PCT=0)"; rc=$?
[[ $rc -eq 0 && "$(tagged)" -eq 1 && "$(grep -F -x -c "$(want 0)" "$T/crontab")" -eq 1 ]] &&
  pass "CPU_BUDGET_GATE_FLOOR_PCT=0 renders the floor off (one line)" || fail "floor 0 (rc=$rc): $(cat "$T/crontab")"
cp "$T/crontab" "$T/crontab.before"
out="$(setup "$FUNC" DRY_RUN=0 CPU_BUDGET_GATE_FLOOR_PCT=5x)"; rc=$?
[[ $rc -ne 0 && "$out" == *'must be 0..99999'* ]] && cmp -s "$T/crontab" "$T/crontab.before" &&
  pass "a bad floor is refused, the crontab untouched" || fail "bad floor (rc=$rc): $out"

# 4. red control: the installer without the floor
sed -e 's/%sCPU_BUDGET_GATE_FLOOR_PCT=%s CPU/%sCPU/' -e 's/"\$pre" "\$floor" "\$reserve"/"$pre" "$reserve"/' "$FUNC" >"$T/nofloor.func.sh"
if grep -q 'CPU_BUDGET_GATE_FLOOR_PCT=%s' "$T/nofloor.func.sh"; then
  fail "red control: could not strip the floor from the copy"
elif check_default "$T/nofloor.func.sh"; then
  fail "red control: a copy without the floor still passed check 1"
else
  pass "red control: an installer without the floor fails check 1"
fi

# 5. _spl_simple_cron_apply delegation (r03-02 one copy) -----------------------
eo_f="$PROJ_ROOT/src/bash/run/check-env-order-install-cron.func.sh"
co_f="$PROJ_ROOT/src/bash/run/setup-ci-overflow-cron.func.sh"
for sib in "$eo_f" "$co_f" "$FUNC"; do
  own="$(grep -nE "the crontab does not read back what was written|is installed and its script is executable|OK DRY_RUN nothing was touched" "$sib" || true)"
  [[ -z "$own" ]] && grep -q "_spl_simple_cron_apply " "$sib" &&
    pass "5. one copy: $(basename "$sib") delegates apply to _spl_simple_cron_apply" || fail "5. one copy $(basename "$sib"): own=[$own]"
done
printf '#!/bin/sh\n' >"$SH/csi-spl-orc/src/bash/scripts/check-env-order.sh"
printf '#!/bin/sh\n' >"$SH/csi-spl-orc/src/bash/scripts/ci-overflow-cron.sh"
chmod +x "$SH/csi-spl-orc/src/bash/scripts/check-env-order.sh" "$SH/csi-spl-orc/src/bash/scripts/ci-overflow-cron.sh"
printf '%s\n' '# keep me' >"$T/crontab.s5"
out="$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s5" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SH" ENV_ORDER_CRON_LOG_DIR="$T/log-eo" ENV_ORDER_CRON_ACTION=check bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/check-env-order-install-cron.func.sh"
  do_check_env_order_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the env order cron is NOT installed (no line tagged csi-spl:env-order): prd ahead of dev warns nobody"* && "$out" != *"command not found"* ]] &&
  pass "5. lazy load: check-env-order-install-cron.func.sh loads _spl_simple_cron_apply standalone" || fail "5. lazy eo (rc=$rc): $out"
out="$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s5" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SH" ENV_ORDER_CRON_LOG_DIR="$T/log-eo" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/check-env-order-install-cron.func.sh"
  do_check_env_order_install_cron' 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK the env order cron runs daily at 05:23 as the box user:"* ]] &&
  pass "5. env order install keeps exact ok_msg" || fail "5. eo ok (rc=$rc): $out"
out="$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s5" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SH" CI_OVERFLOW_CRON_LOG_DIR="$T/log-co" CI_OVERFLOW_CRON_ACTION=check bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/setup-ci-overflow-cron.func.sh"
  do_setup_ci_overflow_cron' 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the CI overflow cron is NOT installed (no line tagged csi-spl:ci-overflow)"* && "$out" != *"command not found"* ]] &&
  pass "5. lazy load: setup-ci-overflow-cron.func.sh loads _spl_simple_cron_apply standalone" || fail "5. lazy co (rc=$rc): $out"
out="$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s5" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SH" CI_OVERFLOW_CRON_LOG_DIR="$T/log-co" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/setup-ci-overflow-cron.func.sh"
  do_setup_ci_overflow_cron' 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK the CI overflow cron ticks every 5 minutes as the box user:"* ]] &&
  pass "5. CI overflow install keeps exact ok_msg" || fail "5. co ok (rc=$rc): $out"
out="$(env -u CPU_BUDGET_GATE_FLOOR_PCT -u CPU_BUDGET_CI_RESERVE_PCT -u CPU_BUDGET_CI_WEIGHT PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s5" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SH" CPU_BUDGET_CRON_LOG_DIR="$T/log-cb" CPU_BUDGET_CRON_ACTION=check bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/setup-gh-runner-cpu-budget-cron.func.sh"
  do_setup_gh_runner_cpu_budget_cron' 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL the runner CPU budget cron is NOT installed (no line tagged csi-spl:gh-runner-cpu-budget)"* && "$out" != *"command not found"* ]] &&
  pass "5. lazy load: setup-gh-runner-cpu-budget-cron.func.sh loads _spl_simple_cron_apply standalone" || fail "5. lazy cb (rc=$rc): $out"
out="$(env -u CPU_BUDGET_GATE_FLOOR_PCT -u CPU_BUDGET_CI_RESERVE_PCT -u CPU_BUDGET_CI_WEIGHT PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab.s5" SPL_ORG_APP=csi-spl \
  DESK_CRON_SRC="$SH" CPU_BUDGET_CRON_LOG_DIR="$T/log-cb" DRY_RUN=0 bash -c '
  set -uo pipefail; do_log(){ printf "%s\n" "$*"; }; do_require_bin(){ return 0; }
  source "$PROJ_PATH/src/bash/run/setup-gh-runner-cpu-budget-cron.func.sh"
  do_setup_gh_runner_cpu_budget_cron' 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK the runner CPU budget cron ticks every minute as the box user:"* ]] &&
  pass "5. runner CPU budget install keeps exact ok_msg" || fail "5. cb ok (rc=$rc): $out"

echo
if [ "$fails" -eq 0 ]; then echo "setup-gh-runner-cpu-budget-cron: all passed"; exit 0; fi
echo "setup-gh-runner-cpu-budget-cron: $fails FAILED"; exit 1
