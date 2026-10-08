#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_apply_gh_runner_cpu_budget sizes the runner slice's CPUQuota to
#   cores * 90% minus what everything else used, and places the runner units in
#   that slice; do_setup_gh_runner_cpu_budget_cron installs its one cron line.
#   1. no runner unit: nothing to do, exit 0; bad settings are refused
#   2. sizing on 16 cores: 4 other cores -> 1040%, the ceiling 1440% when idle,
#      the floor 100% when others take it all; DRY_RUN=1 sets nothing
#   3. placement: an idle runner gets the drop-in and one restart; a busy one
#      (a Runner.Worker in its cgroup) gets the drop-in and waits; a runner
#      already in the slice is left alone
#   4. the cron script runs the action with DRY_RUN=0 and refuses a worktree;
#      the installer writes ONE tagged line, keeps the others, removes its own
#   No real cgroup, systemd, crontab or sudo: a fixture cgroup tree and stubs.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/apply-gh-runner-cpu-budget.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
bash -n "$FUNC" || { echo "FAIL: bash -n"; exit 1; }
T=$(mktemp -d)
WPID=""
trap '[[ -n "$WPID" ]] && kill "$WPID" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/units" "$T/cg/user.slice/user-1500.slice"
export T SYSD_LOG="$T/sysd.log"

cat >"$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list-units) cat "$T/units.list" 2>/dev/null; exit 0 ;;
  daemon-reload|restart|set-property) echo "systemctl $*" >>"$SYSD_LOG"
    [[ "$1" == restart ]] && echo "/user.slice/user-1500.slice/$2" >"$T/cgof-$2"; exit 0 ;;
  show) case "$4" in
      ControlGroup) cat "$T/cgof-$2" 2>/dev/null ;;
      Slice) echo system.slice ;;
      CPUQuotaPerSecUSec) echo infinity ;;
    esac; exit 0 ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\n[[ "$*" == "-u ghrunner" ]] && echo 1500 || exit 1\n' >"$T/bin/id"
printf '#!/usr/bin/env bash\necho 16\n' >"$T/bin/nproc"
chmod +x "$T/bin/"*

# counters: the root and the slice; each "sleep" adds OTHER + CI cores of use
set_usage() { printf 'usage_usec %s\n' "$1" >"$T/cg/cpu.stat"; printf 'usage_usec %s\n' "$2" >"$T/cg/user.slice/user-1500.slice/cpu.stat"; }
run_budget() {
  env PATH="$T/bin:$PATH" CPU_BUDGET_CGROUP_ROOT="$T/cg" CPU_BUDGET_UNIT_DIR="$T/units" \
    CPU_BUDGET_SYSTEMCTL=systemctl CPU_BUDGET_SUDO=env CPU_BUDGET_SAMPLE_S=10 "$@" bash -c '
    set -uo pipefail
    do_log() { printf "%s\n" "$*"; }
    sleep() {
      local r s
      r="$(awk "{print \$2}" "$T/cg/cpu.stat")" s="$(awk "{print \$2}" "$T/cg/user.slice/user-1500.slice/cpu.stat")"
      set_usage $((r + (${OTHER:-0} + ${CI:-0}) * $1 * 1000000)) $((s + ${CI:-0} * $1 * 1000000))
    }
    set_usage() { printf "usage_usec %s\n" "$1" >"$T/cg/cpu.stat"; printf "usage_usec %s\n" "$2" >"$T/cg/user.slice/user-1500.slice/cpu.stat"; }
    source "'"$FUNC"'"
    do_apply_gh_runner_cpu_budget'
}

# 1. no runner / bad settings ----------------------------------------------------
set_usage 1000 500
out="$(run_budget DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$out" == *'nothing to budget'* && ! -s "$SYSD_LOG" ]] &&
  pass "no runner unit: exit 0, nothing touched" || fail "no runner (rc=$rc): $out"
for bad in "CPU_BUDGET_BOX_PCT=101" "CPU_BUDGET_BOX_PCT=0" "CPU_BUDGET_MIN_PCT=x" "CPU_BUDGET_SAMPLE_S=0" "DRY_RUN=2"; do
  out="$(run_budget "$bad")"; rc=$?
  [[ $rc -ne 0 && "$out" == *FATAL* ]] && pass "$bad is refused" || fail "$bad (rc=$rc): $out"
done

# 2. sizing ----------------------------------------------------------------------
U1=actions.runner.o.box-spl-01.service U2=actions.runner.o.box-spl-02.service
printf '%s loaded active running GitHub Actions Runner\n' "$U1" "$U2" >"$T/units.list"
for u in "$U1" "$U2"; do echo "/user.slice/user-1500.slice/$u" >"$T/cgof-$u"; done
out="$(run_budget OTHER=4 CI=6)"; rc=$?
[[ $rc -eq 0 && "$out" == *'others=4.00 cores over 10s -> user-1500.slice CPUQuota=1040%'* && "$out" == *DRY_RUN* && ! -s "$SYSD_LOG" ]] &&
  pass "dry run: 16 cores * 90% - 4 other cores = 1040%, nothing set" || fail "dry size (rc=$rc): $out / $(cat "$SYSD_LOG" 2>&1)"
out="$(run_budget DRY_RUN=0 OTHER=4 CI=6)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == "systemctl set-property --runtime user-1500.slice CPUQuota=1040%" ]] &&
  pass "apply: CPUQuota=1040% set --runtime on the runner slice, units in it untouched" || fail "apply (rc=$rc): $out / $(cat "$SYSD_LOG" 2>&1)"
: >"$SYSD_LOG"
out="$(run_budget DRY_RUN=0 OTHER=0 CI=15)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=1440%' ]] &&
  pass "only CI running: the ceiling 1440% (its own use never shrinks it)" || fail "ceiling (rc=$rc): $out"
: >"$SYSD_LOG"
out="$(run_budget DRY_RUN=0 OTHER=15 CI=1)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=100%' ]] &&
  pass "others take it all: the floor 100%" || fail "floor (rc=$rc): $out"
: >"$SYSD_LOG"
out="$(run_budget DRY_RUN=0 OTHER=3 CPU_BUDGET_BOX_PCT=85)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=1060%' ]] &&
  pass "CPU_BUDGET_BOX_PCT=85: 1360 - 300 = 1060%" || fail "box pct (rc=$rc): $out"
: >"$SYSD_LOG"

# 3. placement -------------------------------------------------------------------
cp "$(command -v sleep)" "$T/Runner.Worker"
"$T/Runner.Worker" 60 & WPID=$!
echo "/system.slice/$U1" >"$T/cgof-$U1"; echo "/system.slice/$U2" >"$T/cgof-$U2"
mkdir -p "$T/cg/system.slice/$U1" "$T/cg/system.slice/$U2"
echo $$ >"$T/cg/system.slice/$U1/cgroup.procs"
echo "$WPID" >"$T/cg/system.slice/$U2/cgroup.procs"
out="$(run_budget OTHER=1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"PLAN move $U1 into user-1500.slice"* && ! -e "$T/units/$U1.d" && ! -s "$SYSD_LOG" ]] &&
  pass "dry run: names the move, writes no drop-in" || fail "dry place (rc=$rc): $out"
out="$(run_budget DRY_RUN=0 OTHER=1)"; rc=$?
want="systemctl daemon-reload
systemctl restart $U1
systemctl set-property --runtime user-1500.slice CPUQuota=1340%"
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == "$want" && "$out" == *"MOVED $U1"* && "$out" == *"WAIT $U2 runs a job"* \
  && "$(cat "$T/units/$U1.d/50-slice.conf")" == $'[Service]\nSlice=user-1500.slice' && -s "$T/units/$U2.d/50-slice.conf" ]] &&
  pass "idle runner: drop-in + one restart; busy runner: drop-in, no restart" || fail "place (rc=$rc): $out / $(cat "$SYSD_LOG")"
: >"$SYSD_LOG"
kill "$WPID"; wait "$WPID" 2>/dev/null; WPID=""
out="$(run_budget DRY_RUN=0 OTHER=1)"; rc=$?
[[ $rc -eq 0 && "$(head -1 "$SYSD_LOG")" == "systemctl restart $U2" && "$(grep -c restart "$SYSD_LOG")" == 1 ]] &&
  pass "the busy runner moves on the next tick once idle, with no second reload" || fail "later move (rc=$rc): $out / $(cat "$SYSD_LOG")"

# 4. cron script + installer -------------------------------------------------------
SH="$T/shared"
mkdir -p "$SH/csi-spl-orc/src/bash/scripts"
cp "$PROJ_ROOT/src/bash/scripts/gh-runner-cpu-budget-cron.sh" "$SH/csi-spl-orc/src/bash/scripts/"
printf '#!/usr/bin/env bash\nprintf "DRY_RUN=%%s args=%%s\\n" "${DRY_RUN:-}" "$*" >>"%s/calls"\nexit "${RUN_RC:-0}"\n' "$T" >"$SH/csi-spl-orc/run"
chmod +x "$SH/csi-spl-orc/run" "$SH/csi-spl-orc/src/bash/scripts/gh-runner-cpu-budget-cron.sh"
out="$(bash "$SH/csi-spl-orc/src/bash/scripts/gh-runner-cpu-budget-cron.sh" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/calls")" == "DRY_RUN=0 args=-a do_apply_gh_runner_cpu_budget" ]] &&
  pass "the cron script runs the action with DRY_RUN=0" || fail "cron run (rc=$rc): $out / $(cat "$T/calls" 2>&1)"
out="$(RUN_RC=1 bash "$SH/csi-spl-orc/src/bash/scripts/gh-runner-cpu-budget-cron.sh" 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *'FAIL runner CPU budget rc=1'* ]] &&
  pass "a failed apply: exit 1, one FAIL line" || fail "cron fail (rc=$rc): $out"
WT="$T/csi-spl-wt/c-9"; mkdir -p "$WT"
cp -a "$SH/csi-spl-orc" "$WT/"
out="$(bash "$WT/csi-spl-orc/src/bash/scripts/gh-runner-cpu-budget-cron.sh" 2>&1)"; rc=$?
[[ $rc -eq 2 && "$out" == *'agent worktree'* ]] && pass "an agent worktree is refused" || fail "worktree (rc=$rc): $out"

printf '#!/usr/bin/env bash\nif [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi\ncp "$1" "$FAKE_CRONTAB"\n' >"$T/bin/crontab"
chmod +x "$T/bin/crontab"
printf '%s\n' '# keep me' '*/5 * * * * /x/box-stats-cron.sh >> /l/cron.out 2>&1 # csi-spl:box-stats' >"$T/crontab"
cp "$T/crontab" "$T/crontab.orig"
setup() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab" SPL_ORG_APP=csi-spl \
    DESK_CRON_SRC="$SH" CPU_BUDGET_CRON_LOG_DIR="$T/log" "$@" bash -c '
    set -uo pipefail
    do_log() { printf "%s\n" "$*"; }
    do_require_bin() { return 0; }
    source "'"$PROJ_ROOT"'/src/bash/run/setup-gh-runner-cpu-budget-cron.func.sh"
    do_setup_gh_runner_cpu_budget_cron'
}
want="* * * * * $SH/csi-spl-orc/src/bash/scripts/gh-runner-cpu-budget-cron.sh >> $T/log/cron.out 2>&1 # csi-spl:gh-runner-cpu-budget"
out="$(setup)"; rc=$?
[[ $rc -eq 0 && "$out" == *'DRY_RUN nothing was touched'* && "$out" == *"+$want"* ]] && cmp -s "$T/crontab" "$T/crontab.orig" &&
  pass "dry run: prints the every-minute line, writes nothing" || fail "install dry (rc=$rc): $out"
out="$(setup DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(grep -c 'csi-spl:gh-runner-cpu-budget$' "$T/crontab")" -eq 1 && "$(grep -F -x -c "$want" "$T/crontab")" -eq 1 \
  && "$(head -2 "$T/crontab")" == "$(cat "$T/crontab.orig")" ]] &&
  pass "install: ONE tagged line, every other line kept" || fail "install (rc=$rc): $out / $(cat "$T/crontab")"
out="$(setup DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(grep -c 'csi-spl:gh-runner-cpu-budget$' "$T/crontab")" -eq 1 ]] &&
  pass "install twice = one line" || fail "reinstall (rc=$rc): $(cat "$T/crontab")"
out="$(setup CPU_BUDGET_CRON_ACTION=check)"; rc=$?
[[ $rc -eq 0 && "$out" == *'is installed'* ]] && pass "check: installed, script executable" || fail "check (rc=$rc): $out"
out="$(setup DRY_RUN=0 CPU_BUDGET_CRON_ACTION=remove)"; rc=$?
cmp -s "$T/crontab" "$T/crontab.orig" && [[ $rc -eq 0 ]] && pass "remove takes only its own line" || fail "remove (rc=$rc): $(cat "$T/crontab")"

echo
if [ "$fails" -eq 0 ]; then echo "apply-gh-runner-cpu-budget: all passed"; exit 0; fi
echo "apply-gh-runner-cpu-budget: $fails FAILED"; exit 1
