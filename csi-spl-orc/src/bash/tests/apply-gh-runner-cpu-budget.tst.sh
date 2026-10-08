#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_apply_gh_runner_cpu_budget sizes the runner slice's CPUQuota to
#   cores * 80% minus what everything else used, and places the runner units in
#   that slice; do_setup_gh_runner_cpu_budget_cron installs its one cron line.
#   1. no runner unit: nothing to do, exit 0; bad settings are refused
#   2. sizing on 16 cores: 4 other cores -> 880%, the ceiling 1280% when idle,
#      the floor 100% when others take it all; DRY_RUN=1 sets nothing
#   2b. the ceiling: CPU_BUDGET_BOX_PCT beats the hub's runner_cpu_pct, the
#      box's value beats the fleet's; no fleet, a hub that fails or a bad
#      value: 80 (a WARN, never a stop)
#   3. placement: an idle runner gets the drop-in, a stop, its leftovers killed
#      and a start; a busy one
#      (a Runner.Worker in its cgroup) gets the drop-in and waits; a runner
#      already in the slice is left alone
#   5. concurrency (c-551): one idle runner over quota / 150% is parked, a busy
#      one never; a parked runner comes back once the quota feeds it + 50%,
#      not inside that band; a runner a person stopped is never started
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
  daemon-reload|stop|kill|start|set-property) echo "systemctl $*" >>"$SYSD_LOG"
    [[ "$1" == start ]] && echo "/user.slice/user-1500.slice/$2" >"$T/cgof-$2" && echo active >"$T/state-$2"
    [[ "$1" == stop ]] && echo inactive >"$T/state-$2"; exit 0 ;;
  show) case "$4" in
      ControlGroup) cat "$T/cgof-$2" 2>/dev/null ;;
      Slice) echo system.slice ;;
      CPUQuotaPerSecUSec) echo infinity ;;
      ActiveState) cat "$T/state-$2" 2>/dev/null || echo active ;;
    esac; exit 0 ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\n[[ "$*" == "-u ghrunner" ]] && echo 1500 || exit 1\n' >"$T/bin/id"
printf '#!/usr/bin/env bash\necho 16\n' >"$T/bin/nproc"
printf '#!/usr/bin/env bash\n[[ "$*" == "fleet-load get" && "${HUB_FAIL:-0}" == 0 ]] || exit 1\ncat "$T/hub.json"\n' >"$T/bin/hubstub"
chmod +x "$T/bin/"*

# counters: the root and the slice; each "sleep" adds OTHER + CI cores of use
set_usage() { printf 'usage_usec %s\n' "$1" >"$T/cg/cpu.stat"; printf 'usage_usec %s\n' "$2" >"$T/cg/user.slice/user-1500.slice/cpu.stat"; }
run_budget() {
  env PATH="$T/bin:$PATH" CPU_BUDGET_CGROUP_ROOT="$T/cg" CPU_BUDGET_UNIT_DIR="$T/units" \
    CPU_BUDGET_SYSTEMCTL=systemctl CPU_BUDGET_SUDO=env CPU_BUDGET_SAMPLE_S=10 SPOOL_ROOT="$T/spool" \
    CPU_BUDGET_PER_RUNNER_PCT=0 CPU_BUDGET_STATE_DIR="$T/state" "$@" bash -c '
    set -uo pipefail
    do_log() { printf "%s\n" "$*"; }
    spl_desk_box_default() { echo sat; }
    sleep() {
      local r s
      r="$(awk "{print \$2}" "$T/cg/cpu.stat")" s="$(awk "{print \$2}" "$T/cg/user.slice/user-1500.slice/cpu.stat")"
      set_usage $((r + (${OTHER:-0} + ${RUNNER_CORES:-0}) * $1 * 1000000)) $((s + ${RUNNER_CORES:-0} * $1 * 1000000))
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
for bad in "CPU_BUDGET_PER_RUNNER_PCT=x" "CPU_BUDGET_HYST_PCT=-1" "CPU_BUDGET_BOX_PCT=101" "CPU_BUDGET_BOX_PCT=0" "CPU_BUDGET_MIN_PCT=x" "CPU_BUDGET_SAMPLE_S=0" "DRY_RUN=2"; do
  out="$(run_budget "$bad")"; rc=$?
  [[ $rc -ne 0 && "$out" == *FATAL* ]] && pass "$bad is refused" || fail "$bad (rc=$rc): $out"
done

# 2. sizing ----------------------------------------------------------------------
U1=actions.runner.o.box-spl-01.service U2=actions.runner.o.box-spl-02.service
printf '%s loaded active running GitHub Actions Runner\n' "$U1" "$U2" >"$T/units.list"
for u in "$U1" "$U2"; do echo "/user.slice/user-1500.slice/$u" >"$T/cgof-$u"; done
out="$(run_budget OTHER=4 RUNNER_CORES=6)"; rc=$?
[[ $rc -eq 0 && "$out" == *'others=4.00 cores over 10s -> user-1500.slice CPUQuota=880%'* && "$out" == *DRY_RUN* && ! -s "$SYSD_LOG" ]] &&
  pass "dry run: 16 cores * 80% - 4 other cores = 880%, nothing set" || fail "dry size (rc=$rc): $out / $(cat "$SYSD_LOG" 2>&1)"
out="$(run_budget DRY_RUN=0 OTHER=4 RUNNER_CORES=6)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == "systemctl set-property --runtime user-1500.slice CPUQuota=880%" ]] &&
  pass "apply: CPUQuota=880% set --runtime on the runner slice, units in it untouched" || fail "apply (rc=$rc): $out / $(cat "$SYSD_LOG" 2>&1)"
: >"$SYSD_LOG"
out="$(run_budget DRY_RUN=0 OTHER=0 RUNNER_CORES=15)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=1280%' ]] &&
  pass "only CI running: the ceiling 1280% (its own use never shrinks it)" || fail "ceiling (rc=$rc): $out"
: >"$SYSD_LOG"
out="$(run_budget DRY_RUN=0 OTHER=15 RUNNER_CORES=1)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=100%' ]] &&
  pass "others take it all: the floor 100%" || fail "floor (rc=$rc): $out"
: >"$SYSD_LOG"
out="$(run_budget DRY_RUN=0 OTHER=3 CPU_BUDGET_BOX_PCT=85)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=1060%' ]] &&
  pass "CPU_BUDGET_BOX_PCT=85: 1360 - 300 = 1060%" || fail "box pct (rc=$rc): $out"
: >"$SYSD_LOG"

# 2b. the ceiling from the hub --------------------------------------------------
hub() { run_budget LANE_FLEET=csi LANE_HUB_CMD="$T/bin/hubstub" DRY_RUN=0 OTHER=4 RUNNER_CORES=6 "$@"; }
echo '{"low":50,"high":75,"runner_cpu_pct":75,"boxes":{"sat":{"low":50,"high":70,"runner_cpu_pct":70},"other-box":{"low":50,"high":80,"runner_cpu_pct":60}}}' >"$T/hub.json"
out="$(hub)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=720%' && "$out" == *'ceiling=70% (hub, box sat)'* ]] &&
  pass "the hub's runner_cpu_pct for this box (70) wins over the fleet's (75): 1120 - 400 = 720%" || fail "hub box (rc=$rc): $out"
: >"$SYSD_LOG"
echo '{"low":50,"high":75,"runner_cpu_pct":75,"boxes":{"other-box":{"low":50,"high":80,"runner_cpu_pct":60}}}' >"$T/hub.json"
out="$(hub)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=800%' ]] &&
  pass "no value for this box: the fleet's 75 -> 800%" || fail "hub fleet (rc=$rc): $out"
: >"$SYSD_LOG"
out="$(hub CPU_BUDGET_BOX_PCT=85)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=960%' && "$out" == *'(env)'* ]] &&
  pass "CPU_BUDGET_BOX_PCT=85 beats the hub: 1360 - 400 = 960%" || fail "env over hub (rc=$rc): $out"
: >"$SYSD_LOG"
echo '{"low":50,"high":75}' >"$T/hub.json"
out="$(hub)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=880%' && "$out" == *'no runner_cpu_pct on the hub'* ]] &&
  pass "a hub without runner_cpu_pct: the default 80 -> 880%" || fail "hub unset (rc=$rc): $out"
: >"$SYSD_LOG"
out="$(hub HUB_FAIL=1)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=880%' && "$out" == *'WARN the hub did not answer'* ]] &&
  pass "a hub that fails: WARN, the default 80, the quota still set" || fail "hub fail (rc=$rc): $out"
: >"$SYSD_LOG"
echo '{"runner_cpu_pct":0}' >"$T/hub.json"
out="$(hub)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=880%' && "$out" == *"runner_cpu_pct is not 1..100 ('0')"* ]] &&
  pass "a hub value out of 1..100: WARN, the default 80" || fail "hub bad (rc=$rc): $out"
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
systemctl stop $U1
systemctl kill --kill-whom=all --signal=SIGKILL $U1
systemctl start $U1
systemctl set-property --runtime user-1500.slice CPUQuota=1180%"
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == "$want" && "$out" == *"MOVED $U1"* && "$out" == *"WAIT $U2 runs a job"* \
  && "$(cat "$T/units/$U1.d/50-slice.conf")" == $'[Service]\nSlice=user-1500.slice' && -s "$T/units/$U2.d/50-slice.conf" ]] &&
  pass "idle runner: drop-in, stop, leftovers killed, start; busy runner: drop-in, no restart" || fail "place (rc=$rc): $out / $(cat "$SYSD_LOG")"
: >"$SYSD_LOG"
kill "$WPID"; wait "$WPID" 2>/dev/null; WPID=""
out="$(run_budget DRY_RUN=0 OTHER=1)"; rc=$?
[[ $rc -eq 0 && "$(head -1 "$SYSD_LOG")" == "systemctl stop $U2" && "$(grep -c start "$SYSD_LOG")" == 1 && "$(grep -c daemon-reload "$SYSD_LOG")" == 0 ]] &&
  pass "the busy runner moves on the next tick once idle, with no second reload" || fail "later move (rc=$rc): $out / $(cat "$SYSD_LOG")"

# 5. concurrency ---------------------------------------------------------------------
: >"$SYSD_LOG"; rm -f "$T/state-"*
US=()
for i in 1 2 3 4 5 6; do US+=("actions.runner.o.box-spl-0$i.service"); done
printf '%s loaded active running GitHub Actions Runner\n' "${US[@]}" >"$T/units.list"
for u in "${US[@]}"; do echo "/user.slice/user-1500.slice/$u" >"$T/cgof-$u"; mkdir -p "$T/cg/user.slice/user-1500.slice/$u"; done
cap() { run_budget CPU_BUDGET_PER_RUNNER_PCT=150 "$@"; }
out="$(cap OTHER=6)"; rc=$?
[[ $rc -eq 0 && "$out" == *'CAP online=6 of 6 runner(s), the quota feeds 4 at 150% each'* && "$out" == *"PLAN park ${US[5]}"* && ! -s "$SYSD_LOG" && ! -e "$T/state/parked" ]] &&
  pass "dry run: 680% feeds 4 of 6 runners, names the park, touches nothing" || fail "cap dry (rc=$rc): $out"
out="$(cap DRY_RUN=0 OTHER=6)"; rc=$?
[[ $rc -eq 0 && "$(tail -1 "$SYSD_LOG")" == "systemctl stop ${US[5]}" && "$(grep -c stop "$SYSD_LOG")" == 1 && "$(cat "$T/state/parked")" == "${US[5]}" && "$out" == *"PARKED ${US[5]}"* ]] &&
  pass "apply: ONE idle runner parked per tick (stopped, listed as ours)" || fail "cap park (rc=$rc): $out / $(cat "$SYSD_LOG")"
: >"$SYSD_LOG"
"$T/Runner.Worker" 60 & WPID=$!
for u in "${US[@]:0:5}"; do echo "$WPID" >"$T/cg/user.slice/user-1500.slice/$u/cgroup.procs"; done
out="$(cap DRY_RUN=0 OTHER=6)"; rc=$?
[[ $rc -eq 0 && "$(grep -c stop "$SYSD_LOG")" == 0 && "$out" == *'CAP online=5 of 6'* ]] &&
  pass "every online runner busy: none is parked (a job is never stopped)" || fail "cap busy (rc=$rc): $out / $(cat "$SYSD_LOG")"
kill "$WPID"; wait "$WPID" 2>/dev/null; WPID=""
rm -f "$T/cg/user.slice/user-1500.slice/"*/cgroup.procs
: >"$SYSD_LOG"
out="$(cap DRY_RUN=0 OTHER=4)"; rc=$?
[[ $rc -eq 0 && "$(grep -c -e stop -e ' start' "$SYSD_LOG")" == 0 && "$(cat "$T/state/parked")" == "${US[5]}" ]] &&
  pass "880% < 6 * 150 + 50: the parked runner stays parked (no flapping)" || fail "cap hyst (rc=$rc): $out / $(cat "$SYSD_LOG")"
: >"$SYSD_LOG"
out="$(cap DRY_RUN=0 OTHER=0)"; rc=$?
[[ $rc -eq 0 && "$(tail -1 "$SYSD_LOG")" == "systemctl start ${US[5]}" && ! -s "$T/state/parked" && "$out" == *"UNPARKED ${US[5]}"* ]] &&
  pass "1280% >= 950%: the parked runner is started and unlisted" || fail "cap unpark (rc=$rc): $out / $(cat "$SYSD_LOG")"
: >"$SYSD_LOG"; echo inactive >"$T/state-${US[4]}"
out="$(cap DRY_RUN=0 OTHER=0)"; rc=$?
[[ $rc -eq 0 && "$(grep -c ' start' "$SYSD_LOG")" == 0 && "$out" == *'CAP online=5 of 6'* ]] &&
  pass "a runner a person stopped (not parked by us) is never started" || fail "cap foreign (rc=$rc): $out / $(cat "$SYSD_LOG")"

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
