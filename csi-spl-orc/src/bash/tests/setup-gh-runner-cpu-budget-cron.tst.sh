#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_setup_gh_runner_cpu_budget_cron writes the gate CPU floor
#   (CPU_BUDGET_GATE_FLOOR_PCT, owner HUM-10 2026-10-10: 500 = 5 cores) into
#   the cron line it builds, so a re-run keeps it.
#   1. default: the rendered line carries CPU_BUDGET_GATE_FLOOR_PCT=500
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
  env -u CPU_BUDGET_GATE_FLOOR_PCT PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" \
    FAKE_CRONTAB="$T/crontab" SPL_ORG_APP=csi-spl DESK_CRON_SRC="$SH" CPU_BUDGET_CRON_LOG_DIR="$T/log" "$@" bash -c '
    set -uo pipefail
    do_log() { printf "%s\n" "$*"; }
    do_require_bin() { return 0; }
    source "'"$PROJ_ROOT"'/src/bash/run/spl-desk-install-service.func.sh"
    source "'"$f"'"
    do_setup_gh_runner_cpu_budget_cron'
}
script="$SH/csi-spl-orc/src/bash/scripts/gh-runner-cpu-budget-cron.sh"
want() { printf '* * * * * CPU_BUDGET_GATE_FLOOR_PCT=%s %s >> %s/log/cron.out 2>&1 # csi-spl:gh-runner-cpu-budget' "$1" "$script" "$T"; }
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
sed -e 's/%sCPU_BUDGET_GATE_FLOOR_PCT=%s %s >>/%s%s >>/' -e 's/"\$pre" "\$floor" "\$script"/"$pre" "$script"/' "$FUNC" >"$T/nofloor.func.sh"
if grep -q 'CPU_BUDGET_GATE_FLOOR_PCT=%s' "$T/nofloor.func.sh"; then
  fail "red control: could not strip the floor from the copy"
elif check_default "$T/nofloor.func.sh"; then
  fail "red control: a copy without the floor still passed check 1"
else
  pass "red control: an installer without the floor fails check 1"
fi

echo
if [ "$fails" -eq 0 ]; then echo "setup-gh-runner-cpu-budget-cron: all passed"; exit 0; fi
echo "setup-gh-runner-cpu-budget-cron: $fails FAILED"; exit 1
