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
# @description A box with no runner unit: nothing to do, exit 0.
# @description Dry run unless DRY_RUN=0 (prints the plan). Needs sudo.
# @param GH_RUNNER_USER (optional) - the runners' OS user, default ghrunner
# @param CPU_BUDGET_BOX_PCT (optional) - 1..100: the box ceiling, default 80
# @param CPU_BUDGET_MIN_PCT (optional) - the floor in % of one core, default 100
# @param CPU_BUDGET_SAMPLE_S (optional) - 1..120 seconds, default 20
# @param CPU_BUDGET_CGROUP_ROOT (optional, tests) - default /sys/fs/cgroup
# @param CPU_BUDGET_UNIT_DIR (optional, tests) - drop-ins, default /etc/systemd/system
# @param CPU_BUDGET_SYSTEMCTL (optional, tests) - default "sudo systemctl"
# @param CPU_BUDGET_SUDO (optional, tests) - default sudo
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_apply_gh_runner_cpu_budget
# @example DRY_RUN=0 ./run -a do_apply_gh_runner_cpu_budget
# @example DRY_RUN=0 CPU_BUDGET_BOX_PCT=85 ./run -a do_apply_gh_runner_cpu_budget
#------------------------------------------------------------------------------

# ghrb_init - the settings of one call, validated
ghrb_init() {
  GHRB_DRY="${DRY_RUN:-1}" GHRB_BOX="${CPU_BUDGET_BOX_PCT:-80}" GHRB_MIN="${CPU_BUDGET_MIN_PCT:-100}"
  GHRB_WAIT="${CPU_BUDGET_SAMPLE_S:-20}" GHRB_CG="${CPU_BUDGET_CGROUP_ROOT:-/sys/fs/cgroup}"
  GHRB_UNIT_DIR="${CPU_BUDGET_UNIT_DIR:-/etc/systemd/system}"
  GHRB_SYSTEMCTL="${CPU_BUDGET_SYSTEMCTL:-sudo systemctl}" GHRB_SUDO="${CPU_BUDGET_SUDO:-sudo}"
  [[ "$GHRB_DRY" == 0 || "$GHRB_DRY" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  [[ "$GHRB_BOX" =~ ^([1-9][0-9]?|100)$ ]] || { do_log "FATAL CPU_BUDGET_BOX_PCT must be 1..100, got: '$GHRB_BOX'"; return 1; }
  [[ "$GHRB_MIN" =~ ^[1-9][0-9]{0,4}$ ]] || { do_log "FATAL CPU_BUDGET_MIN_PCT must be a positive number, got: '$GHRB_MIN'"; return 1; }
  [[ "$GHRB_WAIT" =~ ^[1-9][0-9]?$ ]] || { do_log "FATAL CPU_BUDGET_SAMPLE_S must be 1..99, got: '$GHRB_WAIT'"; return 1; }
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
  awk -v c="$1" -v o="$2" -v w="$3" -v box="$GHRB_BOX" -v min="$GHRB_MIN" 'BEGIN {
    top = c * box; q = top - (o / w) * 100
    if (q > top) q = top
    if (q < min) q = min
    printf "%d", int(q / 10) * 10 }'
}

do_apply_gh_runner_cpu_budget() {
  local user="${GH_RUNNER_USER:-ghrunner}" uid slice cores r0 s0 r1 s1 other quota cur
  local -a units
  ghrb_init || return 1
  mapfile -t units < <(ghrb_units)
  ((${#units[@]})) || { do_log "OK no actions.runner.* unit on this box: nothing to budget"; return 0; }
  uid="$(id -u "$user" 2>/dev/null)" || { do_log "FATAL runner units exist but user $user does not"; return 1; }
  slice="user-$uid.slice"
  ghrb_place "$slice" "${units[@]}" || return 1
  cores="$(nproc)"
  r0="$(ghrb_usage "$GHRB_CG")" s0="$(ghrb_usage "$GHRB_CG/user.slice/$slice")"
  sleep "$GHRB_WAIT"
  r1="$(ghrb_usage "$GHRB_CG")" s1="$(ghrb_usage "$GHRB_CG/user.slice/$slice")"
  [[ "$r0$r1$s0$s1" =~ ^[0-9]+$ && -n "$r0" && -n "$r1" && -n "$s0" && -n "$s1" ]] ||
    { do_log "FATAL cannot read cpu.stat of $GHRB_CG or of $slice"; return 1; }
  other=$(((r1 - r0) - (s1 - s0)))
  ((other < 0)) && other=0
  quota="$(ghrb_size "$cores" "$other" "$((GHRB_WAIT * 1000000))")"
  cur="$($GHRB_SYSTEMCTL show "$slice" -p CPUQuotaPerSecUSec --value 2>/dev/null)"
  echo "BUDGET cores=$cores ceiling=${GHRB_BOX}% others=$(awk -v o="$other" -v w="$GHRB_WAIT" 'BEGIN {printf "%.2f", o / w / 1e6}') cores over ${GHRB_WAIT}s -> $slice CPUQuota=${quota}% (was ${cur:-unknown})"
  if [[ "$GHRB_DRY" == 1 ]]; then do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."; return 0; fi
  $GHRB_SYSTEMCTL set-property --runtime "$slice" CPUQuota="${quota}%" ||
    { do_log "FATAL cannot set CPUQuota on $slice"; return 1; }
  do_log "OK $slice CPUQuota=${quota}% ($($GHRB_SYSTEMCTL show "$slice" -p CPUQuotaPerSecUSec --value 2>/dev/null))"
}
