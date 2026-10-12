#!/bin/bash
#------------------------------------------------------------------------------
# @description Size the CPU budget of THIS box's self-hosted GitHub runners to
# @description the box load (owner HUM-10, t1 b7917da5 + b3573121: CI and agents
# @description together leave 20% of the cores free). The budget is a systemd
# @description CPUQuota on the runner user's slice (user-<uid>.slice), which
# @description holds its rootless docker (the job containers) and, after this
# @description action, every actions.runner.*.service too (a drop-in
# @description Slice=user-<uid>.slice; an idle runner is stopped, the orphans a
# @description job left in its cgroup (KillMode=process keeps them, and they
# @description keep the old cgroup) are killed, and it is started in the slice;
# @description a busy one moves on a later tick). Size:
# @description   quota = cores * CPU_BUDGET_BOX_PCT - the CPU everything else
# @description   used over the sample, clamped to MIN_PCT .. cores * BOX_PCT,
# @description   rounded down to a multiple of 10 (% of one core, as CPUQuota).
# @description "Everything else" is the box's cpu usage minus the slice's, read
# @description from cgroup v2 cpu.stat twice CPU_BUDGET_SAMPLE_S apart.
# @description The quota is set --runtime (no /etc churn every minute): the
# @description cron of do_setup_gh_runner_cpu_budget_cron re-applies it.
# @description Concurrency (c-551): a quota split over more jobs than it can
# @description feed starves every wall-clock bound in the suites (2026-10-08:
# @description green runs had >= 1.6 cores per busy runner, the 5/5 red ones
# @description 1.1..1.2). So at most quota / CPU_BUDGET_PER_RUNNER_PCT runners
# @description stay online (at least 1): one idle runner over that is parked
# @description (stopped, never deregistered: GitHub hands the job to the next
# @description free runner), one parked runner is started again once the
# @description quota feeds it plus CPU_BUDGET_HYST_PCT. One step per tick, a
# @description busy runner is never touched, and only a runner this action
# @description parked (CPU_BUDGET_STATE_DIR/parked) is ever started again.
# @description Gate floor (c-731, 2026-10-10): the quota follows the agents, so
# @description on a busy box CI got 1..4 cores and 2 runners, and gate 10 on
# @description master went 57..100 min without a verdict (its e2e shards were cut
# @description at their 45 min timeout). While the newest gate-10 verdict on
# @description master (success or failure) is CPU_BUDGET_GATE_STALE_MIN old or
# @description older AND a gate run waits or runs, the floor is
# @description CPU_BUDGET_GATE_FLOOR_PCT (up to the ceiling); otherwise MIN_PCT.
# @description One `gh api` call a tick (the newest 100 push runs: ~30 superseded
# @description runs can sit between two verdicts; none in 100 counts as starved).
# @description A failing call is a WARN, never a boost. The tick's count of
# @description waiting runs goes to CPU_BUDGET_STATE_DIR/gate ("<epoch> <n>"):
# @description with runners parked, do_spl_box_pick counts them as CI busy and
# @description sends new lanes elsewhere (lib/bash/funcs/spl-box-ci.func.sh), so
# @description the agents yield back the cores this action gave them.
# @description CI reserve (owner HUM-10 t1 f67e3656 msg 52474112, action 3:
# @description "CI gets its CPU on satellite"; 2026-10-11 the agents' ~13 of 16
# @description cores left 3 of 6 runners online while gate runs waited). While
# @description CI runs or waits here (a runner busy, or a gate run not
# @description completed), the floor is CPU_BUDGET_CI_RESERVE_PCT (up to the
# @description ceiling; 950 = 6 runners at 150% + the 50% hysteresis, so 6 of 6
# @description stay online) and the slice's CPUWeight is CPU_BUDGET_CI_WEIGHT
# @description (--runtime), so under contention the agents' CPU goes to CI
# @description first: their processes are never stopped or reniced, the kernel
# @description just shares the cores by weight. The weight the slice had
# @description before (do_gh_runner_add's GH_RUNNER_CPU_WEIGHT, 25 on sat) is
# @description kept in CPU_BUDGET_STATE_DIR/weight and set back once CI is idle.
# @description OFF by default (0): it takes cores from the agents, which reverses
# @description HUM-10 (agents first), so switching it on is the owner's call.
# @description CI overflow cap (owner HUM-10, t1 f67e3656 msgs d4ba4b17,
# @description 70480eb3, 61cd35bc): the local runners together never take
# @description more than a share of the box, cnf env.box.ci_overflow.cap_pct
# @description (20..30, default 25) of its cores AND its memory, or the
# @description workspace admin's CPU count (hub fleet-load runner_cpus, per box
# @description boxes.<box>.runner_cpus; never above the cores). The quota is
# @description min(the load quota above, that cap) after every floor, the
# @description slice gets MemoryMax = MemTotal * cap / (cores * 100) beside it,
# @description and the online runners follow the capped quota (CAP below).
# @description Overflow only: while wf 10 does not target the local runners
# @description (repo variable SPOOL_CI_RUNNER, do_route_ci_overflow) or the
# @description admin switched overflow off (hub fleet-load ci_overflow, cnf
# @description enabled), every idle runner is parked in the same tick and the
# @description gate is not asked: nothing local runs for CI, nothing waits.
# @description A failed read of the variable changes nothing (no park, no
# @description start). CI_OVERFLOW_FORCE_MIN=<n> holds the runners online n
# @description minutes whatever the variable says (the throwaway-branch proof:
# @description a wf 10 dispatch with its runner input on the local runners).
# @description Settings: lib/bash/funcs/spl-ci-overflow.func.sh.
# @description A box with no runner unit: nothing to do, exit 0.
# @description Dry run unless DRY_RUN=0 (prints the plan). Needs sudo.
# @param GH_RUNNER_USER (optional) - the runners' OS user, default ghrunner
# @param CPU_BUDGET_BOX_PCT (optional) - 1..100: the box ceiling. Unset: the
# @param   hub's fleet-load setting runner_cpu_pct (owner HUM-10 t1 569c4846:
# @param   "permanent in the db"), this box's boxes.<box>.runner_cpu_pct over
# @param   the fleet's; no fleet, no answer or no value: 80
# @param CPU_BUDGET_MIN_PCT (optional) - the floor in % of one core, default 100
# @param CPU_BUDGET_SAMPLE_S (optional) - 1..120 seconds, default 20
# @param CPU_BUDGET_PER_RUNNER_PCT (optional) - % of one core one online runner
# @param   needs, default 150; 0 turns the concurrency cap off
# @param CPU_BUDGET_HYST_PCT (optional) - headroom before a parked runner comes
# @param   back, default 50 (no park/start flapping on a noisy minute)
# @param CPU_BUDGET_GATE_FLOOR_PCT (optional) - the floor while the gate is
# @param   starved, default 0 (off); 500 = 3 runners at 150% + the 50% hysteresis
# @param CPU_BUDGET_GATE_STALE_MIN (optional) - minutes without a verdict that
# @param   make the gate starved, default 40 (a fed gate takes ~36)
# @param CPU_BUDGET_CI_RESERVE_PCT (optional) - the floor while CI runs or
# @param   waits here, default 0 (off); 950 = 6 runners at 150% + 50%
# @param CPU_BUDGET_CI_WEIGHT (optional) - 1..10000: the slice's CPUWeight while
# @param   CI runs or waits here, default 0 (left as it is); 400 = four agent
# @param   user slices at the default 100
# @param CI_OVERFLOW_CNF (optional) - default <checkout>/<org>-<app>-cnf/<org>-<app>/all.env.yaml
# @param CI_OVERFLOW_ENABLED / CI_OVERFLOW_CPUS / CI_OVERFLOW_CAP_PCT (optional) -
# @param   override the hub and cnf (spl-ci-overflow.func.sh); CAP_PCT=0 = no cap
# @param CI_OVERFLOW_ACTIVE (optional) - 1 / 0: the runners are wanted or not,
# @param   instead of reading SPOOL_CI_RUNNER
# @param CI_OVERFLOW_FORCE_MIN (optional) - hold the runners online this many
# @param   minutes (kept in CPU_BUDGET_STATE_DIR/force-until), 0..240
# @param CI_OVERFLOW_MEMINFO (optional, tests) - default /proc/meminfo
# @param CPU_BUDGET_GATE_WORKFLOW (optional) - default 10_ci-quality.yml
# @param CPU_BUDGET_GATE_BRANCH (optional) - default master
# @param CPU_BUDGET_GH (optional, tests) - default gh
# @param CPU_BUDGET_STATE_DIR (optional) - default /var/tmp/gh-runner-cpu-budget
# @param CPU_BUDGET_CGROUP_ROOT (optional, tests) - default /sys/fs/cgroup
# @param CPU_BUDGET_UNIT_DIR (optional, tests) - drop-ins, default /etc/systemd/system
# @param CPU_BUDGET_SYSTEMCTL (optional, tests) - default "sudo systemctl"
# @param CPU_BUDGET_SUDO (optional, tests) - default sudo
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_apply_gh_runner_cpu_budget
# @example DRY_RUN=0 ./run -a do_apply_gh_runner_cpu_budget
# @example DRY_RUN=0 CPU_BUDGET_BOX_PCT=85 ./run -a do_apply_gh_runner_cpu_budget
# @example DRY_RUN=0 CI_OVERFLOW_FORCE_MIN=30 ./run -a do_apply_gh_runner_cpu_budget
#------------------------------------------------------------------------------
declare -F spl_ci_overflow_settings >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-ci-overflow.func.sh"

# ghrb_init - the settings of one call, validated
ghrb_init() {
  GHRB_DRY="${DRY_RUN:-1}" GHRB_MIN="${CPU_BUDGET_MIN_PCT:-100}"
  GHRB_WAIT="${CPU_BUDGET_SAMPLE_S:-20}" GHRB_CG="${CPU_BUDGET_CGROUP_ROOT:-/sys/fs/cgroup}"
  GHRB_UNIT_DIR="${CPU_BUDGET_UNIT_DIR:-/etc/systemd/system}"
  GHRB_SYSTEMCTL="${CPU_BUDGET_SYSTEMCTL:-sudo systemctl}" GHRB_SUDO="${CPU_BUDGET_SUDO:-sudo}"
  GHRB_PER="${CPU_BUDGET_PER_RUNNER_PCT:-150}" GHRB_HYST="${CPU_BUDGET_HYST_PCT:-50}"
  GHRB_STATE="${CPU_BUDGET_STATE_DIR:-/var/tmp/gh-runner-cpu-budget}"
  GHRB_GATE_FLOOR="${CPU_BUDGET_GATE_FLOOR_PCT:-0}" GHRB_GATE_STALE="${CPU_BUDGET_GATE_STALE_MIN:-40}"
  GHRB_RESERVE="${CPU_BUDGET_CI_RESERVE_PCT:-0}" GHRB_CI_WEIGHT="${CPU_BUDGET_CI_WEIGHT:-0}" GHRB_GATE_WAIT=0
  [[ "$GHRB_RESERVE" =~ ^(0|[1-9][0-9]{0,4})$ ]] || { do_log "FATAL CPU_BUDGET_CI_RESERVE_PCT must be 0..99999, got: '$GHRB_RESERVE'"; return 1; }
  [[ "$GHRB_CI_WEIGHT" =~ ^(0|[1-9][0-9]{0,3}|10000)$ ]] || { do_log "FATAL CPU_BUDGET_CI_WEIGHT must be 0..10000, got: '$GHRB_CI_WEIGHT'"; return 1; }
  [[ "$GHRB_GATE_FLOOR" =~ ^(0|[1-9][0-9]{0,4})$ ]] || { do_log "FATAL CPU_BUDGET_GATE_FLOOR_PCT must be 0..99999, got: '$GHRB_GATE_FLOOR'"; return 1; }
  [[ "$GHRB_GATE_STALE" =~ ^[1-9][0-9]{0,3}$ ]] || { do_log "FATAL CPU_BUDGET_GATE_STALE_MIN must be 1..9999, got: '$GHRB_GATE_STALE'"; return 1; }
  [[ "$GHRB_DRY" == 0 || "$GHRB_DRY" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  [[ "$GHRB_PER" =~ ^(0|[1-9][0-9]{0,3})$ ]] || { do_log "FATAL CPU_BUDGET_PER_RUNNER_PCT must be 0..9999, got: '$GHRB_PER'"; return 1; }
  [[ "$GHRB_HYST" =~ ^(0|[1-9][0-9]{0,3})$ ]] || { do_log "FATAL CPU_BUDGET_HYST_PCT must be 0..9999, got: '$GHRB_HYST'"; return 1; }
  [[ "$GHRB_MIN" =~ ^[1-9][0-9]{0,4}$ ]] || { do_log "FATAL CPU_BUDGET_MIN_PCT must be a positive number, got: '$GHRB_MIN'"; return 1; }
  [[ "$GHRB_WAIT" =~ ^[1-9][0-9]?$ ]] || { do_log "FATAL CPU_BUDGET_SAMPLE_S must be 1..99, got: '$GHRB_WAIT'"; return 1; }
}

# ghrb_box_pct - GHRB_BOX (the ceiling, % of cores) and GHRB_SRC (where it came
# from): CPU_BUDGET_BOX_PCT, else the hub's runner_cpu_pct (per box over
# fleet), else 80. A hub that does not answer is a WARN, never a stop: the
# runners keep a budget either way
ghrb_box_pct() {
  local v
  ghrb_hub
  if [[ -n "${CPU_BUDGET_BOX_PCT:-}" ]]; then
    GHRB_BOX="$CPU_BUDGET_BOX_PCT" GHRB_SRC=env
    [[ "$GHRB_BOX" =~ ^([1-9][0-9]?|100)$ ]] || { do_log "FATAL CPU_BUDGET_BOX_PCT must be 1..100, got: '$GHRB_BOX'"; return 1; }
    return 0
  fi
  GHRB_BOX=80 GHRB_SRC=default
  [[ "$GHRB_HUB" == none ]] && { echo "WARN no hub fleet here: the default ceiling 80%"; GHRB_HUB=""; return 0; }
  [[ "$GHRB_HUB" == failed ]] && { echo "WARN the hub did not answer fleet-load get: the default ceiling 80%"; GHRB_HUB=""; return 0; }
  v="$(jq -r --arg b "$LANE_BOX" '(.boxes[$b].runner_cpu_pct // .runner_cpu_pct // "") | tostring' <<<"$GHRB_HUB")"
  [[ -z "$v" ]] && { GHRB_SRC="default, no runner_cpu_pct on the hub"; return 0; }
  [[ "$v" =~ ^([1-9][0-9]?|100)$ ]] || { echo "WARN the hub's runner_cpu_pct is not 1..100 ('$v'): the default ceiling 80%"; return 0; }
  GHRB_BOX="$v" GHRB_SRC="hub, box $LANE_BOX"
}

# ghrb_hub - GHRB_HUB: the hub's fleet-load answer (a JSON object; the
# ceiling above and the overflow settings read it), "none" with no hub fleet
# here, "failed" when it does not answer
ghrb_hub() {
  local got
  GHRB_HUB=none
  declare -F spl_lane_init >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-lane-map.func.sh"
  spl_lane_init >/dev/null 2>&1 && [[ "$LANE_MODE" == hub ]] || return 0
  got="$(LANE_TIMEOUT="${LANE_TIMEOUT:-15}" spl_lane_spool fleet-load get 2>/dev/null)"
  if jq -e 'type == "object"' >/dev/null 2>&1 <<<"$got"; then GHRB_HUB="$got"; else GHRB_HUB=failed; fi
}

# ghrb_overflow <cores> - the CI overflow rule (see the header): GHRB_CAPQ
# (the cap, % of one core; 0 = none), GHRB_MEMMAX (bytes; empty = untouched)
# and GHRB_LOCAL (1 the runners are wanted, 0 they are not, "" unknown)
ghrb_overflow() {
  local cores="$1" orc oa cnf force="${CI_OVERFLOW_FORCE_MIN:-}" until=0 val rc mem
  orc="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)" oa="$(basename "$orc")" oa="${oa%-orc}"
  cnf="${CI_OVERFLOW_CNF:-$(dirname "$orc")/$oa-cnf/$oa/all.env.yaml}"
  [[ "$GHRB_HUB" == none || "$GHRB_HUB" == failed ]] && GHRB_HUB=""
  spl_ci_overflow_settings "$cnf" "$GHRB_HUB" "${LANE_BOX:-}" || return 1
  [[ -z "$force" || "$force" =~ ^([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-3][0-9]|240)$ ]] ||
    { do_log "FATAL CI_OVERFLOW_FORCE_MIN must be 0..240, got: '$force'"; return 1; }
  [[ -z "${CI_OVERFLOW_ACTIVE:-}" || "$CI_OVERFLOW_ACTIVE" == 0 || "$CI_OVERFLOW_ACTIVE" == 1 ]] ||
    { do_log "FATAL CI_OVERFLOW_ACTIVE must be 0 or 1, got: '$CI_OVERFLOW_ACTIVE'"; return 1; }
  GHRB_CAPQ="$(spl_ci_overflow_cap "$cores")" GHRB_MEMMAX=""
  if ((GHRB_CAPQ > 0)); then
    mem="$(awk '$1 == "MemTotal:" {print $2}' "${CI_OVERFLOW_MEMINFO:-/proc/meminfo}" 2>/dev/null)"
    [[ "$mem" =~ ^[0-9]+$ ]] && GHRB_MEMMAX=$((mem * 1024 * GHRB_CAPQ / (cores * 100)))
  fi
  if [[ -n "$force" && "$force" != 0 && "$GHRB_DRY" == 0 ]]; then
    mkdir -p "$GHRB_STATE" && echo $(($(date +%s) + force * 60)) >"$GHRB_STATE/force-until" ||
      { do_log "FATAL cannot write $GHRB_STATE/force-until"; return 1; }
  fi
  [[ -r "$GHRB_STATE/force-until" ]] && until="$(head -1 "$GHRB_STATE/force-until")"
  [[ "$until" =~ ^[0-9]+$ ]] || until=0
  if ((CIO_ENABLED == 0)); then GHRB_LOCAL=0 val="overflow switched off"
  elif [[ -n "${CI_OVERFLOW_ACTIVE:-}" ]]; then GHRB_LOCAL="$CI_OVERFLOW_ACTIVE" val="CI_OVERFLOW_ACTIVE=$CI_OVERFLOW_ACTIVE"
  elif [[ -n "$force" && "$force" != 0 ]] || ((until > $(date +%s))); then
    GHRB_LOCAL=1 val="held online until $(date -u -d "@$until" +%H:%M:%SZ 2>/dev/null || echo "$until")"
  else
    val="$(cd "$(dirname "${BASH_SOURCE[0]}")" && spl_ci_overflow_var "${CPU_BUDGET_GH:-gh}")"; rc=$?
    case "$rc" in
      0) if spl_ci_overflow_is_local "$val"; then GHRB_LOCAL=1; else GHRB_LOCAL=0; fi; val="SPOOL_CI_RUNNER=$val" ;;
      2) GHRB_LOCAL=1 val="SPOOL_CI_RUNNER unset (wf 10 falls back to the local runners)" ;;
      *) GHRB_LOCAL="" val="WARN SPOOL_CI_RUNNER does not read: runners left as they are" ;;
    esac
  fi
  echo "OVERFLOW cap=${GHRB_CAPQ}% (cpus=$CIO_CPUS, share ${CIO_CAP_PCT}%; $CIO_SRC)${GHRB_MEMMAX:+ MemoryMax=$GHRB_MEMMAX} local=${GHRB_LOCAL:-unknown}: $val"
}

# ghrb_gate <cores> - raise GHRB_MIN to the gate floor (clamped to the
# ceiling) while gate 10 on master is starved (see the header). The repo is the
# one this checkout's origin names (gh resolves {owner}/{repo} from the cwd)
ghrb_gate() {
  local wf="${CPU_BUDGET_GATE_WORKFLOW:-10_ci-quality.yml}" br="${CPU_BUDGET_GATE_BRANCH:-master}"
  local got last wait age floor
  [[ "$GHRB_GATE_FLOOR" == 0 && "$GHRB_RESERVE" == 0 && "$GHRB_CI_WEIGHT" == 0 ]] && return 0
  got="$(cd "$(dirname "${BASH_SOURCE[0]}")" && timeout 20 ${CPU_BUDGET_GH:-gh} api \
    "repos/{owner}/{repo}/actions/workflows/$wf/runs?branch=$br&event=push&per_page=100" 2>/dev/null |
    jq -r '[.workflow_runs[]] | "\([.[] | select(.conclusion == "success" or .conclusion == "failure")
      | .updated_at | fromdate] | max // 0) \([.[] | select(.status != "completed")] | length)"' 2>/dev/null)"
  [[ "$got" =~ ^([0-9]+)\ ([0-9]+)$ ]] || { echo "WARN gate $wf on $br: the runs query failed, no gate floor"; return 0; }
  last="${BASH_REMATCH[1]}" wait="${BASH_REMATCH[2]}" GHRB_GATE_WAIT="${BASH_REMATCH[2]}"
  age=never
  ((last > 0)) && age=$((($(date +%s) - last) / 60))
  # for the box pick (lib/bash/funcs/spl-box-ci.func.sh): runs waiting while
  # runners are parked are CI waiting for this box's cores, so new agents yield
  { mkdir -p "$GHRB_STATE" && echo "$(date +%s) $wait" >"$GHRB_STATE/gate"; } 2>/dev/null
  if ((wait == 0 || GHRB_GATE_FLOOR == 0)) || { [[ "$age" != never ]] && ((age < GHRB_GATE_STALE)); }; then
    echo "GATE $wf on $br: last verdict $age min ago, $wait run(s) waiting -> floor ${GHRB_MIN}%"; return 0
  fi
  floor=$(($1 * GHRB_BOX)); ((GHRB_GATE_FLOOR < floor)) && floor="$GHRB_GATE_FLOOR"
  ((floor > GHRB_MIN)) && GHRB_MIN="$floor"
  echo "GATE STARVED $wf on $br: last verdict $age min ago (>= $GHRB_GATE_STALE), $wait run(s) waiting -> floor ${GHRB_MIN}%"
}

# ghrb_reserve <cores> <unit...> - while CI runs (a busy runner) or waits (a
# gate run not completed, from ghrb_gate): raise GHRB_MIN to the CI reserve
# (clamped to the ceiling) and set GHRB_WEIGHT to the CI weight; else
# GHRB_WEIGHT is empty (the weight goes back, see ghrb_weight)
ghrb_reserve() {
  local cores="$1" u busy=0 floor; shift
  GHRB_WEIGHT=""
  [[ "$GHRB_RESERVE" == 0 && "$GHRB_CI_WEIGHT" == 0 ]] && return 0
  for u in "$@"; do ghrb_busy "$u" && busy=$((busy + 1)); done
  if ((busy == 0 && GHRB_GATE_WAIT == 0)); then echo "CI idle here: no reserve"; return 0; fi
  ((GHRB_CI_WEIGHT > 0)) && GHRB_WEIGHT="$GHRB_CI_WEIGHT"
  floor=$((cores * GHRB_BOX)); ((GHRB_RESERVE < floor)) && floor="$GHRB_RESERVE"
  ((floor > GHRB_MIN)) && GHRB_MIN="$floor"
  echo "CI RESERVE $busy runner(s) busy, $GHRB_GATE_WAIT gate run(s) waiting -> floor ${GHRB_MIN}%${GHRB_WEIGHT:+, CPUWeight $GHRB_WEIGHT}"
}

# ghrb_weight <slice> - the slice's CPUWeight follows GHRB_WEIGHT: set (the
# weight before is kept in GHRB_STATE/weight) while CI runs or waits, set back
# to the kept one once it is idle. Only a change calls systemctl
ghrb_weight() {
  local cur kept="$GHRB_STATE/weight" want
  cur="$($GHRB_SYSTEMCTL show "$1" -p CPUWeight --value 2>/dev/null)"
  [[ "$cur" =~ ^[0-9]+$ ]] || cur=100
  if [[ -n "$GHRB_WEIGHT" ]]; then
    want="$GHRB_WEIGHT"
    [[ -s "$kept" || "$cur" == "$want" ]] || { mkdir -p "$GHRB_STATE" && echo "$cur" >"$kept"; } ||
      { do_log "FATAL cannot write $kept"; return 1; }
  else
    [[ -s "$kept" ]] || return 0
    want="$(head -1 "$kept")"; [[ "$want" =~ ^[0-9]+$ ]] || want=100
  fi
  if [[ "$cur" != "$want" ]]; then
    $GHRB_SYSTEMCTL set-property --runtime "$1" CPUWeight="$want" || { do_log "FATAL cannot set CPUWeight on $1"; return 1; }
    echo "WEIGHT $1 CPUWeight=$want (was $cur)"
  fi
  [[ -z "$GHRB_WEIGHT" ]] && rm -f "$kept"
  return 0
}

# ghrb_units - the runner units of this box, one per line
ghrb_units() {
  $GHRB_SYSTEMCTL list-units 'actions.runner.*.service' --all --plain --no-legend 2>/dev/null |
    awk '$1 ~ /^actions\.runner\..*\.service$/ {print $1}'
}

# ghrb_in <unit> <slice> - 0 when the unit RUNS in the slice: by its cgroup,
# not its Slice= (a daemon-reload shows the new Slice= before a restart moves
# it); a stopped unit (no cgroup) by its Slice=
ghrb_in() {
  local cg
  cg="$($GHRB_SYSTEMCTL show "$1" -p ControlGroup --value 2>/dev/null)"
  [[ -n "$cg" ]] && { [[ "$cg" == */"$2"/"$1" ]]; return; }
  [[ "$($GHRB_SYSTEMCTL show "$1" -p Slice --value 2>/dev/null)" == "$2" ]]
}

# ghrb_usage <cgroup dir> - its cpu.stat usage_usec
ghrb_usage() { awk '$1 == "usage_usec" {print $2}' "$1/cpu.stat" 2>/dev/null; }

# ghrb_busy <unit> - 0 when a Runner.Worker (a job) runs in the unit's cgroup
ghrb_busy() {
  local cg pid
  cg="$($GHRB_SYSTEMCTL show "$1" -p ControlGroup --value 2>/dev/null)"
  [[ -n "$cg" && -r "$GHRB_CG$cg/cgroup.procs" ]] || return 1
  while read -r pid; do
    [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == Runner.Worker ]] && return 0
  done <"$GHRB_CG$cg/cgroup.procs"
  return 1
}

# ghrb_place <slice> <unit...> - every unit in <slice>: its drop-in, then an
# idle unit is stopped, its leftover processes killed (they would hold the old
# cgroup) and started in it; a busy one is left for a later tick
ghrb_place() {
  local slice="$1" u want reload=0; shift
  want="$(printf '[Service]\nSlice=%s' "$slice")"
  for u in "$@"; do
    ghrb_in "$u" "$slice" && continue
    if [[ "$GHRB_DRY" == 1 ]]; then echo "PLAN move $u into $slice"; continue; fi
    [[ "$($GHRB_SUDO cat "$GHRB_UNIT_DIR/$u.d/50-slice.conf" 2>/dev/null)" == "$want" ]] && continue
    $GHRB_SUDO mkdir -p "$GHRB_UNIT_DIR/$u.d" &&
      $GHRB_SUDO tee "$GHRB_UNIT_DIR/$u.d/50-slice.conf" >/dev/null <<<"$want" ||
      { do_log "FATAL cannot write the slice drop-in of $u"; return 1; }
    reload=1
  done
  [[ "$GHRB_DRY" == 1 ]] && return 0
  if [[ "$reload" == 1 ]]; then $GHRB_SYSTEMCTL daemon-reload || { do_log "FATAL daemon-reload failed"; return 1; }; fi
  for u in "$@"; do
    ghrb_in "$u" "$slice" && continue
    if ghrb_busy "$u"; then echo "WAIT $u runs a job: it moves into $slice on a later tick"; continue; fi
    $GHRB_SYSTEMCTL stop "$u" || { do_log "FATAL cannot stop $u"; return 1; }
    $GHRB_SYSTEMCTL kill --kill-whom=all --signal=SIGKILL "$u" 2>/dev/null
    $GHRB_SYSTEMCTL start "$u" || { do_log "FATAL cannot start $u in $slice"; return 1; }
    if ghrb_in "$u" "$slice"; then echo "MOVED $u into $slice"; else echo "WARN $u restarted but is not in $slice yet"; fi
  done
}

# ghrb_size <cores> <other usec> <window usec> - the quota, % of one core
ghrb_size() {
  awk -v c="$1" -v o="$2" -v w="$3" -v box="$GHRB_BOX" -v min="$GHRB_MIN" -v cap="${GHRB_CAPQ:-0}" 'BEGIN {
    top = c * box; q = top - (o / w) * 100
    if (q > top) q = top
    if (q < min) q = min
    if (cap > 0 && q > cap) q = cap
    printf "%d", int(q / 10) * 10 }'
}

# ghrb_cap <quota> <unit...> - the online runners fit the quota: park one idle
# runner over quota / GHRB_PER, or start one parked runner once the quota feeds
# it plus GHRB_HYST (see the header). A runner a person stopped is not ours
ghrb_cap() {
  local quota="$1" u on=0 cap last="" first="" parked="$GHRB_STATE/parked"; shift
  local -a idle=()
  [[ "$GHRB_PER" == 0 && "${GHRB_LOCAL-1}" != 0 ]] && return 0
  for u in "$@"; do
    [[ "$($GHRB_SYSTEMCTL show "$u" -p ActiveState --value 2>/dev/null)" == active ]] || continue
    on=$((on + 1)); ghrb_busy "$u" || { last="$u"; idle+=("$u"); }
  done
  if [[ "${GHRB_LOCAL-1}" == 0 ]]; then
    echo "CAP online=$on of $# runner(s), CI is not on the local runners: every idle one parks"
    for u in "${idle[@]}"; do
      [[ "$GHRB_DRY" == 1 ]] && { echo "PLAN park $u"; continue; }
      mkdir -p "$GHRB_STATE" && echo "$u" >>"$parked" || { do_log "FATAL cannot write $parked"; return 1; }
      $GHRB_SYSTEMCTL stop "$u" || { do_log "FATAL cannot park $u"; return 1; }
      echo "PARKED $u (idle; no overflow)"
    done
    return 0
  fi
  cap=$((quota / GHRB_PER)); ((cap < 1)) && cap=1
  [[ -r "$parked" ]] && first="$(head -1 "$parked")"
  echo "CAP online=$on of $# runner(s), the quota feeds $cap at ${GHRB_PER}% each"
  if ((on > cap)) && [[ -n "$last" ]]; then
    [[ "$GHRB_DRY" == 1 ]] && { echo "PLAN park $last"; return 0; }
    mkdir -p "$GHRB_STATE" && echo "$last" >>"$parked" || { do_log "FATAL cannot write $parked"; return 1; }
    $GHRB_SYSTEMCTL stop "$last" || { do_log "FATAL cannot park $last"; return 1; }
    echo "PARKED $last (idle; $on online > $cap)"
  elif [[ -n "$first" ]] && ((quota >= (on + 1) * GHRB_PER + GHRB_HYST)); then
    [[ "$GHRB_DRY" == 1 ]] && { echo "PLAN start parked $first"; return 0; }
    $GHRB_SYSTEMCTL start "$first" || { do_log "FATAL cannot start parked $first"; return 1; }
    grep -vxF "$first" "$parked" >"$parked.new"; mv "$parked.new" "$parked"
    echo "UNPARKED $first (the quota feeds $((on + 1)))"
  fi
}

do_apply_gh_runner_cpu_budget() {
  local user="${GH_RUNNER_USER:-ghrunner}" uid slice cores r0 s0 r1 s1 other quota cur
  local -a units
  ghrb_init && ghrb_box_pct || return 1
  mapfile -t units < <(ghrb_units)
  ((${#units[@]})) || { do_log "OK no actions.runner.* unit on this box: nothing to budget"; return 0; }
  uid="$(id -u "$user" 2>/dev/null)" || { do_log "FATAL runner units exist but user $user does not"; return 1; }
  slice="user-$uid.slice"
  ghrb_place "$slice" "${units[@]}" || return 1
  cores="$(nproc)"
  ghrb_overflow "$cores" || return 1
  if [[ "$GHRB_LOCAL" == 0 ]]; then
    GHRB_WEIGHT=""
    { mkdir -p "$GHRB_STATE" && echo "$(date +%s) 0" >"$GHRB_STATE/gate"; } 2>/dev/null
  else
    ghrb_gate "$cores"
    ghrb_reserve "$cores" "${units[@]}"
  fi
  r0="$(ghrb_usage "$GHRB_CG")" s0="$(ghrb_usage "$GHRB_CG/user.slice/$slice")"
  sleep "$GHRB_WAIT"
  r1="$(ghrb_usage "$GHRB_CG")" s1="$(ghrb_usage "$GHRB_CG/user.slice/$slice")"
  [[ "$r0$r1$s0$s1" =~ ^[0-9]+$ && -n "$r0" && -n "$r1" && -n "$s0" && -n "$s1" ]] ||
    { do_log "FATAL cannot read cpu.stat of $GHRB_CG or of $slice"; return 1; }
  other=$(((r1 - r0) - (s1 - s0)))
  ((other < 0)) && other=0
  quota="$(ghrb_size "$cores" "$other" "$((GHRB_WAIT * 1000000))")"
  cur="$($GHRB_SYSTEMCTL show "$slice" -p CPUQuotaPerSecUSec --value 2>/dev/null)"
  echo "BUDGET cores=$cores ceiling=${GHRB_BOX}% ($GHRB_SRC) others=$(awk -v o="$other" -v w="$GHRB_WAIT" 'BEGIN {printf "%.2f", o / w / 1e6}') cores over ${GHRB_WAIT}s -> $slice CPUQuota=${quota}% (was ${cur:-unknown})"
  if [[ "$GHRB_DRY" == 1 ]]; then ghrb_cap "$quota" "${units[@]}"; do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."; return 0; fi
  $GHRB_SYSTEMCTL set-property --runtime "$slice" CPUQuota="${quota}%" ${GHRB_MEMMAX:+MemoryMax=$GHRB_MEMMAX} ||
    { do_log "FATAL cannot set CPUQuota on $slice"; return 1; }
  do_log "OK $slice CPUQuota=${quota}% ($($GHRB_SYSTEMCTL show "$slice" -p CPUQuotaPerSecUSec --value 2>/dev/null))${GHRB_MEMMAX:+ MemoryMax=$($GHRB_SYSTEMCTL show "$slice" -p MemoryMax --value 2>/dev/null)}"
  ghrb_weight "$slice" || return 1
  ghrb_cap "$quota" "${units[@]}"
}
