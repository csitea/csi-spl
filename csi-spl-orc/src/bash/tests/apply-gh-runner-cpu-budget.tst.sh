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
#   6. gate floor (c-731): off by default (no gh call at all); with
#      CPU_BUDGET_GATE_FLOOR_PCT=500 a gate-10 master verdict >= 40 min old (or
#      none) while a run waits raises the floor to 500% (never above the
#      ceiling, never below the load quota); a fresh verdict, nothing waiting
#      or a failing gh: the plain floor; red control: a copy that drops the
#      raise is caught
#   7. CI reserve (HUM-10 msg 52474112, action 3): off by default; with
#      CPU_BUDGET_CI_RESERVE_PCT=950 a busy runner or a waiting gate run
#      raises the floor to 950% (clamped to the ceiling), which feeds 6 of 6
#      runners (a parked one comes back); CPU_BUDGET_CI_WEIGHT=400 sets the
#      slice weight while CI runs and sets the kept one back once it is idle;
#      red control: a copy that drops the raise is caught
#   8. CI overflow cap (HUM-10 msgs d4ba4b17, 70480eb3, 61cd35bc): cnf
#      cap_pct 25 of 16 cores -> 400% and MemoryMax 25% of MemTotal, after
#      every floor; a CPU count (hub per box > hub fleet > cnf, env first)
#      replaces the share, never above the cores; a cap_pct out of 20..30 is
#      refused; overflow off or SPOOL_CI_RUNNER on hosted parks EVERY idle
#      runner in one tick (gate file 0, no gate query); the variable on local
#      or unset keeps them; a failed read touches nothing; FORCE_MIN holds
#      them online across ticks; red control: a copy without the clamp
#   4. the cron script runs the action with DRY_RUN=0 and refuses a worktree,
#      passes CPU_BUDGET_GATE_* through;
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
    [[ "$1" == stop ]] && echo inactive >"$T/state-$2"
    [[ "$1" == set-property && "$*" == *CPUWeight=* ]] && { a="$*"; echo "${a##*CPUWeight=}" >"$T/weight"; }; exit 0 ;;
  show) case "$4" in
      ControlGroup) cat "$T/cgof-$2" 2>/dev/null ;;
      Slice) echo system.slice ;;
      CPUQuotaPerSecUSec) echo infinity ;;
      ActiveState) cat "$T/state-$2" 2>/dev/null || echo active ;;
      CPUWeight) cat "$T/weight" 2>/dev/null || echo '[not set]' ;;
    esac; exit 0 ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\n[[ "$*" == "-u ghrunner" ]] && echo 1500 || exit 1\n' >"$T/bin/id"
printf '#!/usr/bin/env bash\necho 16\n' >"$T/bin/nproc"
printf '#!/usr/bin/env bash\n[[ "$*" == "fleet-load get" && "${HUB_FAIL:-0}" == 0 ]] || exit 1\ncat "$T/hub.json"\n' >"$T/bin/hubstub"
printf '#!/usr/bin/env bash\necho "gh $*" >>"$T/gh.calls"\n[[ "${GH_FAIL:-0}" == 0 ]] || exit 1\n[[ "${GH_404:-0}" == 0 ]] || { echo "gh: Not Found (HTTP 404)"; exit 1; }\ncat "$T/gh.json"\n' >"$T/bin/gh"
chmod +x "$T/bin/"*

# counters: the root and the slice; each "sleep" adds OTHER + CI cores of use
set_usage() { printf 'usage_usec %s\n' "$1" >"$T/cg/cpu.stat"; printf 'usage_usec %s\n' "$2" >"$T/cg/user.slice/user-1500.slice/cpu.stat"; }
run_budget() {
  env PATH="$T/bin:$PATH" CPU_BUDGET_CGROUP_ROOT="$T/cg" CPU_BUDGET_UNIT_DIR="$T/units" \
    CPU_BUDGET_SYSTEMCTL=systemctl CPU_BUDGET_SUDO=env CPU_BUDGET_SAMPLE_S=10 SPOOL_ROOT="$T/spool" \
    CPU_BUDGET_PER_RUNNER_PCT=0 CPU_BUDGET_STATE_DIR="$T/state" CPU_BUDGET_GH="$T/bin/gh" \
    CI_OVERFLOW_CAP_PCT=0 CI_OVERFLOW_ACTIVE=1 CI_OVERFLOW_CNF=/nonexistent "$@" bash -c '
    set -uo pipefail
    do_log() { printf "%s\n" "$*"; }
    spl_desk_box_default() { echo sat; }
    sleep() {
      local r s
      r="$(awk "{print \$2}" "$T/cg/cpu.stat")" s="$(awk "{print \$2}" "$T/cg/user.slice/user-1500.slice/cpu.stat")"
      set_usage $((r + (${OTHER:-0} + ${RUNNER_CORES:-0}) * $1 * 1000000)) $((s + ${RUNNER_CORES:-0} * $1 * 1000000))
    }
    set_usage() { printf "usage_usec %s\n" "$1" >"$T/cg/cpu.stat"; printf "usage_usec %s\n" "$2" >"$T/cg/user.slice/user-1500.slice/cpu.stat"; }
    source "'"$PROJ_ROOT/lib/bash/funcs/spl-ci-overflow.func.sh"'"
    source "'"$FUNC"'"
    do_apply_gh_runner_cpu_budget'
}

# 1. no runner / bad settings ----------------------------------------------------
set_usage 1000 500
out="$(run_budget DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$out" == *'nothing to budget'* && ! -s "$SYSD_LOG" ]] &&
  pass "no runner unit: exit 0, nothing touched" || fail "no runner (rc=$rc): $out"
for bad in "CPU_BUDGET_CI_RESERVE_PCT=x" "CPU_BUDGET_CI_WEIGHT=10001" "CPU_BUDGET_GATE_FLOOR_PCT=x" "CPU_BUDGET_GATE_STALE_MIN=0" "CPU_BUDGET_PER_RUNNER_PCT=x" "CPU_BUDGET_HYST_PCT=-1" "CPU_BUDGET_BOX_PCT=101" "CPU_BUDGET_BOX_PCT=0" "CPU_BUDGET_MIN_PCT=x" "CPU_BUDGET_SAMPLE_S=0" "DRY_RUN=2"; do
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

# 6. gate floor -----------------------------------------------------------------------
# gh_runs <verdict age in min | none> <runs waiting>: a runs page of gate 10,
# with cancelled (superseded) runs around the verdict
gh_runs() {
  local now v="" i w=""
  now=$(date +%s)
  [[ "$1" != none ]] && v="$(printf '{"status":"completed","conclusion":"failure","updated_at":"%s"},' "$(date -u -d "@$((now - $1 * 60))" +%Y-%m-%dT%H:%M:%SZ)")"
  for ((i = 0; i < $2; i++)); do w+='{"status":"in_progress","conclusion":null,"updated_at":"2026-01-01T00:00:00Z"},'; done
  printf '{"workflow_runs":[%s%s{"status":"completed","conclusion":"cancelled","updated_at":"%s"}]}\n' "$w" "$v" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$T/gh.json"
}
gate() { : >"$SYSD_LOG"; rm -f "$T/gh.calls"; run_budget DRY_RUN=0 OTHER=15 "$@"; }
calls() { [[ -s "$T/gh.calls" ]] && wc -l <"$T/gh.calls" || echo 0; }
gh_runs 60 1
out="$(gate)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=100%' && "$(calls)" == 0 ]] &&
  pass "gate floor off by default: starved gate, still 100%, 0 gh calls" || fail "gate default (rc=$rc, calls=$(calls)): $out"
out="$(gate CPU_BUDGET_GATE_FLOOR_PCT=500)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=500%' && "$out" == *'GATE STARVED 10_ci-quality.yml on master: last verdict 60 min ago (>= 40), 1 run(s) waiting -> floor 500%'* \
  && "$(calls)" == 1 && "$(cat "$T/gh.calls")" == *'actions/workflows/10_ci-quality.yml/runs?branch=master&event=push'* ]] &&
  pass "FLOOR=500: verdict 60 min old + a run waiting -> 500%, ONE gh call" || fail "gate starved (rc=$rc, calls=$(calls)): $out"
[[ "$(cat "$T/state/gate" 2>/dev/null)" =~ ^[0-9]+\ 1$ ]] &&
  pass "...and the tick's waiting runs go to the state dir's gate file for the box pick (\"<epoch> 1\")" || fail "gate file: $(cat "$T/state/gate" 2>&1)"
gh_runs none 1
out="$(gate CPU_BUDGET_GATE_FLOOR_PCT=500)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=500%' && "$out" == *'last verdict never min ago'* ]] &&
  pass "FLOOR=500: no verdict among the last 100 runs + a run waiting -> 500%" || fail "gate never (rc=$rc): $out"
gh_runs 10 1
out="$(gate CPU_BUDGET_GATE_FLOOR_PCT=500)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=100%' && "$out" == *'GATE 10_ci-quality.yml on master: last verdict 10 min ago, 1 run(s) waiting -> floor 100%'* ]] &&
  pass "FLOOR=500: a verdict 10 min old -> the plain floor 100%" || fail "gate fresh (rc=$rc): $out"
gh_runs 60 0
out="$(gate CPU_BUDGET_GATE_FLOOR_PCT=500)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=100%' ]] &&
  pass "FLOOR=500: verdict 60 min old but no run waiting -> 100%" || fail "gate idle (rc=$rc): $out"
gh_runs 60 1
out="$(gate CPU_BUDGET_GATE_FLOOR_PCT=500 GH_FAIL=1)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=100%' && "$out" == *'WARN gate 10_ci-quality.yml on master: the runs query failed, no gate floor'* ]] &&
  pass "FLOOR=500: gh fails -> WARN, no boost, the quota still set" || fail "gate gh fail (rc=$rc): $out"
out="$(gate CPU_BUDGET_GATE_FLOOR_PCT=500 CPU_BUDGET_BOX_PCT=25)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=400%' ]] &&
  pass "FLOOR=500 over a 400% ceiling (16 cores * 25%): clamped to 400%" || fail "gate clamp (rc=$rc): $out"
out="$(: >"$SYSD_LOG"; run_budget DRY_RUN=0 OTHER=4 CPU_BUDGET_GATE_FLOOR_PCT=500)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=880%' ]] &&
  pass "FLOOR=500 under a load quota of 880%: 880% (a floor never lowers)" || fail "gate above (rc=$rc): $out"
mkdir -p "$T/red"; cp "$(dirname "$FUNC")/spl-lane-map.func.sh" "$T/red/"
sed 's/((floor > GHRB_MIN)) \&\& GHRB_MIN="$floor"/:/' "$FUNC" >"$T/red/apply-gh-runner-cpu-budget.func.sh"
grep -q 'GHRB_MIN="$floor"' "$T/red/apply-gh-runner-cpu-budget.func.sh" && fail "red control: the sed did not drop the raise"
out="$(FUNC="$T/red/apply-gh-runner-cpu-budget.func.sh" gate CPU_BUDGET_GATE_FLOOR_PCT=500)"; rc=$?
[[ $rc -eq 0 && "$out" == *'GATE STARVED'* && "$(cat "$SYSD_LOG")" == *'CPUQuota=100%' ]] &&
  pass "red control: a copy without the raise does not reach 500% (the check above catches it)" || fail "red control: the broken copy still reached 500%"

# 7. CI reserve -------------------------------------------------------------------------
# every runner online and idle; busy <unit index> puts a Runner.Worker in it
rm -f "$T/state-"* "$T/state/parked" "$T/weight"
rm -f "$T/cg/user.slice/user-1500.slice/"*/cgroup.procs
busy() { "$T/Runner.Worker" 60 & WPID=$!; echo "$WPID" >"$T/cg/user.slice/user-1500.slice/${US[$1]}/cgroup.procs"; }
idle() { [[ -n "$WPID" ]] && { kill "$WPID"; wait "$WPID" 2>/dev/null; }; WPID=""; rm -f "$T/cg/user.slice/user-1500.slice/"*/cgroup.procs; }
ci() { : >"$SYSD_LOG"; rm -f "$T/gh.calls"; run_budget DRY_RUN=0 OTHER=15 "$@"; }
R=(CPU_BUDGET_CI_RESERVE_PCT=950 CPU_BUDGET_CI_WEIGHT=400)
gh_runs 5 0
busy 0
out="$(ci)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=100%' && "$(grep -c CPUWeight "$SYSD_LOG")" == 0 && "$(calls)" == 0 ]] &&
  pass "CI reserve off by default: a busy runner, still 100%, no weight, 0 gh calls" || fail "reserve default (rc=$rc): $out"
echo 25 >"$T/weight"
out="$(ci "${R[@]}")"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=950%'* && "$out" == *'CI RESERVE 1 runner(s) busy, 0 gate run(s) waiting -> floor 950%, CPUWeight 400'* \
  && "$(grep -c 'set-property --runtime user-1500.slice CPUWeight=400' "$SYSD_LOG")" == 1 && "$(cat "$T/state/weight")" == 25 ]] &&
  pass "RESERVE=950: a busy runner + agents on 15 cores -> 950%, CPUWeight 25 -> 400 (25 kept)" || fail "reserve busy (rc=$rc): $out / $(cat "$SYSD_LOG")"
out="$(ci "${R[@]}")"; rc=$?
[[ $rc -eq 0 && "$(grep -c CPUWeight "$SYSD_LOG")" == 0 && "$(cat "$T/state/weight")" == 25 ]] &&
  pass "the next CI tick: the weight is already 400, no systemctl call, 25 still kept" || fail "reserve again (rc=$rc): $out / $(cat "$SYSD_LOG")"
idle
gh_runs 5 1
out="$(ci "${R[@]}")"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=950%'* && "$out" == *'CI RESERVE 0 runner(s) busy, 1 gate run(s) waiting'* ]] &&
  pass "RESERVE=950: no runner busy but a gate run waits -> 950%" || fail "reserve wait (rc=$rc): $out"
gh_runs 5 0
out="$(ci "${R[@]}")"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=100%'* && "$out" == *'CI idle here: no reserve'* \
  && "$(grep -c 'CPUWeight=25' "$SYSD_LOG")" == 1 && "$(cat "$T/weight")" == 25 && ! -e "$T/state/weight" ]] &&
  pass "CI idle: the plain floor 100%, CPUWeight back to the kept 25, the kept file gone" || fail "reserve idle (rc=$rc): $out / $(cat "$SYSD_LOG")"
out="$(ci "${R[@]}")"; rc=$?
[[ $rc -eq 0 && "$(grep -c CPUWeight "$SYSD_LOG")" == 0 ]] &&
  pass "CI still idle: no weight call" || fail "reserve idle again (rc=$rc): $(cat "$SYSD_LOG")"
gh_runs 5 1
out="$(ci "${R[@]}" GH_FAIL=1)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=100%'* && "$out" == *'runs query failed'* ]] &&
  pass "gh fails and no runner busy: no reserve (never a boost on a failed call)" || fail "reserve gh fail (rc=$rc): $out"
out="$(ci "${R[@]}" CPU_BUDGET_BOX_PCT=25)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=400%'* ]] &&
  pass "RESERVE=950 over a 400% ceiling: clamped to 400%" || fail "reserve clamp (rc=$rc): $out"
rm -f "$T/weight"
echo "${US[5]}" >"$T/state/parked"; echo inactive >"$T/state-${US[5]}"
out="$(ci "${R[@]}" CPU_BUDGET_PER_RUNNER_PCT=150)"; rc=$?
[[ $rc -eq 0 && "$out" == *'CAP online=5 of 6 runner(s), the quota feeds 6 at 150% each'* && "$out" == *"UNPARKED ${US[5]}"* && "$(tail -1 "$SYSD_LOG")" == "systemctl start ${US[5]}" ]] &&
  pass "the axis: agents on 15 of 16 cores + a gate run waiting -> 950% feeds 6, the parked runner comes back (6 of 6)" || fail "reserve 6 of 6 (rc=$rc): $out / $(cat "$SYSD_LOG")"
out="$(ci CPU_BUDGET_PER_RUNNER_PCT=150)"; rc=$?
[[ $rc -eq 0 && "$out" == *'CAP online=6 of 6 runner(s), the quota feeds 1 at 150% each'* && "$out" == *PARKED* ]] &&
  pass "...and without the reserve the same load feeds 1 runner (the baseline it fixes)" || fail "reserve baseline (rc=$rc): $out"
rm -f "$T/state/parked" "$T/state-"* "$T/state/weight" "$T/weight"
sed 's/((floor > GHRB_MIN)) \&\& GHRB_MIN="$floor"$/:/' "$FUNC" >"$T/red/apply-gh-runner-cpu-budget.func.sh"
[[ "$(grep -c 'GHRB_MIN="$floor"' "$T/red/apply-gh-runner-cpu-budget.func.sh")" == 0 ]] || fail "red control: the sed did not drop the reserve raise"
out="$(FUNC="$T/red/apply-gh-runner-cpu-budget.func.sh" ci "${R[@]}")"; rc=$?
[[ $rc -eq 0 && "$out" == *'CI RESERVE'* && "$(cat "$SYSD_LOG")" == *'CPUQuota=100%'* ]] &&
  pass "red control: a copy without the reserve raise stays at 100% (the checks above catch it)" || fail "red control: the broken copy still reached the reserve"
rm -f "$T/gh.json" "$T/state/weight" "$T/weight"

# 8. CI overflow cap -------------------------------------------------------------------
printf 'env:\n  box:\n    ci_overflow:\n      enabled: true\n      cap_pct: 25\n      cpus: 0\n' >"$T/cnf.yaml"
echo 'MemTotal:       33554432 kB' >"$T/meminfo"
rm -f "$T/state/parked" "$T/state-"* "$T/state/force-until" "$T/hub.json"
ov() { : >"$SYSD_LOG"; rm -f "$T/gh.calls"; run_budget DRY_RUN=0 CI_OVERFLOW_CNF="$T/cnf.yaml" CI_OVERFLOW_MEMINFO="$T/meminfo" CI_OVERFLOW_CAP_PCT= "$@"; }
out="$(ov OTHER=0)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == "systemctl set-property --runtime user-1500.slice CPUQuota=400% MemoryMax=8589934592" && "$out" == *'OVERFLOW cap=400% (cpus=0, share 25%; enabled from cnf, cpus from cnf)'* ]] &&
  pass "cnf cap_pct 25 on 16 cores, idle box: CPUQuota 400% (not 1280%), MemoryMax 8 GiB of 32" || fail "cap 25 (rc=$rc): $out / $(cat "$SYSD_LOG")"
gh_runs 60 1
out="$(ov OTHER=15 CPU_BUDGET_GATE_FLOOR_PCT=500 CPU_BUDGET_CI_RESERVE_PCT=950)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=400% MemoryMax=8589934592'* ]] &&
  pass "the gate floor and the CI reserve never lift the quota over the cap" || fail "cap over floors (rc=$rc): $out / $(cat "$SYSD_LOG")"
hubov() { ov LANE_FLEET=csi LANE_HUB_CMD="$T/bin/hubstub" OTHER=0 "$@"; }
echo '{"runner_cpus":3,"boxes":{"sat":{"low":50,"high":70,"runner_cpus":6},"other-box":{"runner_cpus":1}}}' >"$T/hub.json"
out="$(hubov)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=600% MemoryMax=12884901888' && "$out" == *'cpus from hub'* ]] &&
  pass "the admin's runner_cpus for this box (6) replaces the share: 600%, MemoryMax 6/16 of 32 GiB" || fail "hub box cpus (rc=$rc): $out / $(cat "$SYSD_LOG")"
echo '{"runner_cpus":3}' >"$T/hub.json"
out="$(hubov)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=300% '* ]] && pass "the fleet runner_cpus 3: 300%" || fail "hub fleet cpus (rc=$rc): $out"
out="$(hubov CI_OVERFLOW_CPUS=2)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=200% '* ]] && pass "env CI_OVERFLOW_CPUS=2 beats the hub: 200%" || fail "env cpus (rc=$rc): $out"
echo '{"runner_cpus":99}' >"$T/hub.json"
out="$(hubov CPU_BUDGET_BOX_PCT=100)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=1600% MemoryMax=34359738368' ]] &&
  pass "a count over the cores: the cores (1600%, all the memory)" || fail "cpus over cores (rc=$rc): $out"
echo '{}' >"$T/hub.json"
out="$(hubov)"; rc=$?
[[ $rc -eq 0 && "$(cat "$SYSD_LOG")" == *'CPUQuota=400% '* ]] && pass "a hub with no setting stored: the cnf share 25% (400%)" || fail "hub empty (rc=$rc): $out"
for bad in 35 19 0 x; do
  sed "s/cap_pct: 25/cap_pct: $bad/" "$T/cnf.yaml" >"$T/cnf-bad.yaml"
  out="$(ov CI_OVERFLOW_CNF="$T/cnf-bad.yaml")"; rc=$?
  [[ $rc -ne 0 && "$out" == *'FATAL ci_overflow cap_pct must be 20..30'* && ! -s "$SYSD_LOG" ]] &&
    pass "cnf cap_pct $bad is refused, nothing set" || fail "cap_pct $bad (rc=$rc): $out"
done
out="$(ov CI_OVERFLOW_CPUS=x)"; rc=$?
[[ $rc -ne 0 && "$out" == *FATAL* ]] && pass "CI_OVERFLOW_CPUS=x is refused" || fail "cpus x (rc=$rc): $out"
# overflow on / off: six runners online and idle
park() { ov CPU_BUDGET_PER_RUNNER_PCT=150 CPU_BUDGET_GATE_FLOOR_PCT=500 OTHER=0 CI_OVERFLOW_ACTIVE= "$@"; }
reset_runners() { rm -f "$T/state/parked" "$T/state-"* "$T/state/gate"; }
reset_runners
out="$(park CI_OVERFLOW_ENABLED=false)"; rc=$?
[[ $rc -eq 0 && "$(grep -c '^systemctl stop' "$SYSD_LOG")" == 6 && "$(grep -c . "$T/state/parked")" == 6 && "$(calls)" == 0 \
  && "$(cat "$T/state/gate")" =~ ^[0-9]+\ 0$ && "$out" == *'local=0: overflow switched off'* ]] &&
  pass "overflow switched off: all 6 idle runners parked in ONE tick, gate file 0, no gh call" || fail "off (rc=$rc, calls=$(calls)): $out / $(cat "$SYSD_LOG")"
sed -i 's/enabled: true/enabled: false/' "$T/cnf.yaml"; reset_runners
out="$(park)"; rc=$?
[[ $rc -eq 0 && "$(grep -c '^systemctl stop' "$SYSD_LOG")" == 6 ]] && pass "cnf enabled: false switches it off too" || fail "cnf off (rc=$rc): $out"
echo '{"ci_overflow":true}' >"$T/hub.json"; reset_runners
echo '"ubuntu-latest"' >"$T/gh.json"
out="$(park LANE_FLEET=csi LANE_HUB_CMD="$T/bin/hubstub")"; rc=$?
[[ $rc -eq 0 && "$out" == *'enabled from hub'* && "$out" == *'local=0: SPOOL_CI_RUNNER="ubuntu-latest"'* && "$(grep -c '^systemctl stop' "$SYSD_LOG")" == 6 \
  && "$(calls)" == 1 && "$(cat "$T/gh.calls")" == *'actions/variables/SPOOL_CI_RUNNER'* ]] &&
  pass "the admin's ci_overflow true beats cnf false; wf 10 on hosted: every idle runner parks, ONE gh call (the variable)" || fail "hosted (rc=$rc): $out"
sed -i 's/enabled: false/enabled: true/' "$T/cnf.yaml"; reset_runners
printf '%s\n' "${US[@]:1}" >"$T/state/parked"; for u in "${US[@]:1}"; do echo inactive >"$T/state-$u"; done
echo '["self-hosted","spool-ci"]' >"$T/gh.json"
out="$(park)"; rc=$?
[[ $rc -eq 0 && "$out" == *'local=1: SPOOL_CI_RUNNER=["self-hosted","spool-ci"]'* && "$out" == *'the quota feeds 2 at 150% each'* && "$out" == *UNPARKED* ]] &&
  pass "wf 10 on the local runners: they come back, at most 400 / 150 = 2 online" || fail "local (rc=$rc): $out"
reset_runners
out="$(park GH_404=1)"; rc=$?
[[ $rc -eq 0 && "$out" == *'local=1: SPOOL_CI_RUNNER unset'* && "$(grep -c '^systemctl stop' "$SYSD_LOG")" == 1 ]] &&
  pass "variable unset (wf 10 falls back to local): runners wanted, 6 online > 2 -> one parks" || fail "unset (rc=$rc): $out"
reset_runners
out="$(park GH_FAIL=1)"; rc=$?
[[ $rc -eq 0 && "$out" == *'local=unknown: WARN SPOOL_CI_RUNNER does not read'* && "$(grep -c '^systemctl stop' "$SYSD_LOG")" == 1 ]] &&
  pass "a failed read: no park-all (the plain cap only)" || fail "read fail (rc=$rc): $out"
reset_runners; echo '"ubuntu-latest"' >"$T/gh.json"
out="$(park CI_OVERFLOW_FORCE_MIN=30)"; rc=$?
[[ $rc -eq 0 && "$out" == *'local=1: held online until'* && -s "$T/state/force-until" && "$(grep -c '^systemctl stop' "$SYSD_LOG")" == 1 ]] &&
  pass "FORCE_MIN=30: runners held online although wf 10 is on hosted (force-until kept)" || fail "force (rc=$rc): $out"
out="$(park)"; rc=$?
[[ $rc -eq 0 && "$out" == *'local=1: held online until'* ]] && pass "...and the next tick without it still holds them" || fail "force kept (rc=$rc): $out"
echo 1 >"$T/state/force-until"; reset_runners
out="$(park)"; rc=$?
[[ $rc -eq 0 && "$out" == *'local=0'* && "$(grep -c '^systemctl stop' "$SYSD_LOG")" == 6 ]] && pass "an expired hold: back to park-all" || fail "force expired (rc=$rc): $out"
rm -f "$T/state/force-until"; reset_runners
sed 's/    if (cap > 0 \&\& q > cap) q = cap/    cap = 0/' "$FUNC" >"$T/red/apply-gh-runner-cpu-budget.func.sh"
grep -q 'q > cap' "$T/red/apply-gh-runner-cpu-budget.func.sh" && fail "red control: the sed did not drop the clamp"
out="$(FUNC="$T/red/apply-gh-runner-cpu-budget.func.sh" ov OTHER=0)"; rc=$?
[[ "$(cat "$SYSD_LOG")" != *'CPUQuota=400%'* ]] &&
  pass "red control: a copy without the cap clamp does not set 400% (the first check catches it)" || fail "red control: the broken copy still set 400%"
rm -f "$T/gh.json" "$T/hub.json"

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
printf '#!/usr/bin/env bash\necho "floor=${CPU_BUDGET_GATE_FLOOR_PCT:-unset}" >"%s/env"\n' "$T" >"$SH/csi-spl-orc/run"
out="$(CPU_BUDGET_GATE_FLOOR_PCT=500 bash "$SH/csi-spl-orc/src/bash/scripts/gh-runner-cpu-budget-cron.sh" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/env")" == floor=500 ]] &&
  pass "the cron script passes CPU_BUDGET_GATE_FLOOR_PCT to the action (the switch-on path)" || fail "cron env (rc=$rc): $out / $(cat "$T/env" 2>&1)"
printf '#!/usr/bin/env bash\necho "token=${GH_TOKEN:-unset}" >"%s/tok"\n' "$T" >"$SH/csi-spl-orc/run"
echo tok-from-file >"$T/token"
out="$(env -u GH_TOKEN GH_CONFIG_DIR="$T/nogh" CPU_BUDGET_GH_TOKEN_FILE="$T/token" bash "$SH/csi-spl-orc/src/bash/scripts/gh-runner-cpu-budget-cron.sh" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/tok")" == token=tok-from-file ]] &&
  pass "gh not logged in: the cron script gives the action GH_TOKEN from the token file" || fail "token file (rc=$rc): $out / $(cat "$T/tok" 2>&1)"
out="$(GH_TOKEN=set-before GH_CONFIG_DIR="$T/nogh" CPU_BUDGET_GH_TOKEN_FILE="$T/token" bash "$SH/csi-spl-orc/src/bash/scripts/gh-runner-cpu-budget-cron.sh" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/tok")" == token=set-before ]] &&
  pass "a GH_TOKEN already set is kept" || fail "token kept (rc=$rc): $out / $(cat "$T/tok" 2>&1)"
WT="$T/csi-spl-wt/c-9"; mkdir -p "$WT"
cp -a "$SH/csi-spl-orc" "$WT/"
out="$(bash "$WT/csi-spl-orc/src/bash/scripts/gh-runner-cpu-budget-cron.sh" 2>&1)"; rc=$?
[[ $rc -eq 2 && "$out" == *'agent worktree'* ]] && pass "an agent worktree is refused" || fail "worktree (rc=$rc): $out"

printf '#!/usr/bin/env bash\nif [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi\ncp "$1" "$FAKE_CRONTAB"\n' >"$T/bin/crontab"
chmod +x "$T/bin/crontab"
printf '%s\n' '# keep me' '*/5 * * * * /x/box-stats-cron.sh >> /l/cron.out 2>&1 # csi-spl:box-stats' >"$T/crontab"
cp "$T/crontab" "$T/crontab.orig"
setup() {
  env -u CPU_BUDGET_GATE_FLOOR_PCT -u CPU_BUDGET_CI_RESERVE_PCT -u CPU_BUDGET_CI_WEIGHT PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab" SPL_ORG_APP=csi-spl \
    DESK_CRON_SRC="$SH" CPU_BUDGET_CRON_LOG_DIR="$T/log" "$@" bash -c '
    set -uo pipefail
    do_log() { printf "%s\n" "$*"; }
    do_require_bin() { return 0; }
    source "'"$PROJ_ROOT"'/src/bash/run/setup-gh-runner-cpu-budget-cron.func.sh"
    do_setup_gh_runner_cpu_budget_cron'
}
want="* * * * * CPU_BUDGET_GATE_FLOOR_PCT=500 CPU_BUDGET_CI_RESERVE_PCT=950 CPU_BUDGET_CI_WEIGHT=400 $SH/csi-spl-orc/src/bash/scripts/gh-runner-cpu-budget-cron.sh >> $T/log/cron.out 2>&1 # csi-spl:gh-runner-cpu-budget"
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
out="$(setup CPU_BUDGET_CI_RESERVE_PCT=0 CPU_BUDGET_CI_WEIGHT=0)"; rc=$?
[[ $rc -eq 0 && "$out" == *'CPU_BUDGET_CI_RESERVE_PCT=0 CPU_BUDGET_CI_WEIGHT=0 '* ]] &&
  pass "CPU_BUDGET_CI_RESERVE_PCT=0 CPU_BUDGET_CI_WEIGHT=0: the line writes the reserve off" || fail "install reserve off (rc=$rc): $out"
for bad in CPU_BUDGET_CI_RESERVE_PCT=x CPU_BUDGET_CI_WEIGHT=10001; do
  out="$(setup "$bad")"; rc=$?
  [[ $rc -ne 0 && "$out" == *FATAL* ]] && pass "installer: $bad is refused" || fail "installer $bad (rc=$rc): $out"
done

echo
if [ "$fails" -eq 0 ]; then echo "apply-gh-runner-cpu-budget: all passed"; exit 0; fi
echo "apply-gh-runner-cpu-budget: $fails FAILED"; exit 1
