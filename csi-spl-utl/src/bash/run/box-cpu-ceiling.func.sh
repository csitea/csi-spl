#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description A CPU ceiling on the two cgroups that carry this box's load
# @description (SPL-5698 step 2, spec 175 task 5.9; owner HUM-10 t1 64ca0e0c msg
# @description b7f0aa31: "A — CPU ceiling 85 % via systemd on cron + agent
# @description sessions, both boxes"). Measured with do_box_proc_sample, 24 h
# @description per box (2026-11-17): load1 p95 68 and 84 on the two 16
# @description CPU boxes; by cgroup since boot cron.service 42 % and the agent user's
# @description user-<uid>.slice 47 % of all CPU. cron.service holds the agents'
# @description tmux server (started from cron), its panes and the watchdogs;
# @description the slice holds the agent sessions and everything they start.
# @description Each unit gets CPUQuota = cores * cap_pct (% of one core), set
# @description with `systemctl set-property` (persistent: a drop-in under
# @description /etc/systemd/system.control, so it holds past a reboot and needs
# @description no cron). Nothing is restarted, stopped, killed or reniced: the
# @description kernel only throttles the unit once it uses more. Each unit is
# @description capped on its own, so the two together can still use more than
# @description cap_pct of the box; what is left over for the rest (sshd, the
# @description hub beat, postgres, docker, the desktop) is guaranteed only
# @description while one of them runs under its ceiling.
# @description BOX_CPU_CMD:
# @description   check (default)  read-only: each unit's CPUQuota, its throttled
# @description                    time from cpu.stat; exit 1 when one differs
# @description   apply            set the ceiling where it differs (DRY_RUN=0)
# @description   remove           take the ceiling off again (DRY_RUN=0)
# @param BOX_CPU_CMD (optional) - check (default) | apply | remove
# @param BOX_CPU_CAP_PCT (optional) - 50..100 % of the cores; default cnf
# @param   env.box.agent_load.cap_pct
# @param BOX_CPU_CNF (optional) - default <checkout>/<org>-<app>-cnf/<org>-<app>/all.env.yaml
# @param BOX_CPU_AGENT_USER (optional) - the agents' OS user, default
# @param   SPOOL_AGENT_USER, else that line of $SPOOL_ROOT/box.env
# @param BOX_CPU_UNITS (optional) - the units, space separated, in place of
# @param   cron.service and user-<uid of the agent user>.slice
# @param BOX_CPU_NPROC (optional, tests) - default nproc
# @param BOX_CPU_SYSTEMCTL (optional, tests) - default "sudo systemctl"
# @param BOX_CPU_CGROUP_ROOT (optional, tests) - default /sys/fs/cgroup
# @param DRY_RUN (optional) - 1 (default) prints the plan; 0 changes the units
# @example ./run -a do_box_cpu_ceiling
# @example BOX_CPU_CMD=apply ./run -a do_box_cpu_ceiling
# @example BOX_CPU_CMD=apply DRY_RUN=0 ./run -a do_box_cpu_ceiling
# @example BOX_CPU_CMD=remove DRY_RUN=0 ./run -a do_box_cpu_ceiling
#------------------------------------------------------------------------------
type do_log &>/dev/null || do_log() { echo "$*"; }

# box_cpu_cap <cnf> - BOX_CPU_CAP: the ceiling in % of the cores, env over cnf
box_cpu_cap() {
  BOX_CPU_CAP="${BOX_CPU_CAP_PCT:-}"
  if [[ -z "$BOX_CPU_CAP" ]]; then
    command -v yq >/dev/null 2>&1 || { do_log "FATAL yq is not on PATH and BOX_CPU_CAP_PCT is unset"; return 1; }
    BOX_CPU_CAP="$(yq '.env.box.agent_load.cap_pct' "$1" 2>/dev/null)"
  fi
  [[ "$BOX_CPU_CAP" =~ ^([5-9][0-9]|100)$ ]] ||
    { do_log "FATAL the ceiling must be 50..100 (% of the cores; cnf env.box.agent_load.cap_pct in $1), got: '$BOX_CPU_CAP'"; return 1; }
}

# box_cpu_units - the units, one per line: BOX_CPU_UNITS, else cron.service and
# the agent user's slice
box_cpu_units() {
  local u uid
  if [[ -n "${BOX_CPU_UNITS:-}" ]]; then tr ' ' '\n' <<<"$BOX_CPU_UNITS" | awk 'NF'; return 0; fi
  u="${BOX_CPU_AGENT_USER:-${SPOOL_AGENT_USER:-$(sed -n 's/^SPOOL_AGENT_USER=//p' "${SPOOL_ROOT:-/var/spool-hub}/box.env" 2>/dev/null | sed -n 1p)}}"
  [[ -n "$u" ]] || { do_log "FATAL no agent user: set BOX_CPU_AGENT_USER or SPOOL_AGENT_USER"; return 1; }
  uid="$(id -u "$u" 2>/dev/null)" || { do_log "FATAL the agent user '$u' does not exist on this box"; return 1; }
  printf 'cron.service\nuser-%s.slice\n' "$uid"
}

# box_cpu_pct <CPUQuotaPerSecUSec> - the quota in % of one core, "" for none
box_cpu_pct() {
  awk -v v="$1" 'BEGIN {
    if (v ~ /^[0-9.]+s$/) { sub(/s$/, "", v); printf "%d", v * 100 + 0.5 }
    else if (v ~ /^[0-9.]+ms$/) { sub(/ms$/, "", v); printf "%d", v / 10 + 0.5 } }'
}

# box_cpu_throttled <unit> - "<n> throttles, <s> s throttled" from its cpu.stat
box_cpu_throttled() {
  local cg
  cg="$($BOX_CPU_SYSTEMCTL show "$1" -p ControlGroup --value 2>/dev/null)"
  [[ -n "$cg" && -r "$BOX_CPU_CG$cg/cpu.stat" ]] || { echo "no cgroup"; return 0; }
  awk '$1 == "nr_throttled" {n = $2} $1 == "throttled_usec" {t = $2}
    END {printf "%d throttles, %.0f s throttled", n, t / 1e6}' "$BOX_CPU_CG$cg/cpu.stat"
}

do_box_cpu_ceiling() {
  local cmd="${BOX_CPU_CMD:-check}" app cnf cores want u cur have units_txt bad=0
  local -a units
  case "$cmd" in check|apply|remove) ;; *) do_log "FATAL BOX_CPU_CMD must be check, apply or remove, got: '$cmd'"; return 1 ;; esac
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  BOX_CPU_SYSTEMCTL="${BOX_CPU_SYSTEMCTL:-sudo systemctl}" BOX_CPU_CG="${BOX_CPU_CGROUP_ROOT:-/sys/fs/cgroup}"
  app="$(basename "$PROJ_PATH")"; app="${app%-utl}"
  cnf="${BOX_CPU_CNF:-$(dirname "$PROJ_PATH")/$app-cnf/$app/all.env.yaml}"
  cores="${BOX_CPU_NPROC:-$(nproc)}"
  [[ "$cores" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL cannot count the cores, got: '$cores'"; return 1; }
  if [[ "$cmd" == remove ]]; then want=""; else box_cpu_cap "$cnf" || return 1; want=$((cores * BOX_CPU_CAP)); fi
  # captured first: a FATAL from box_cpu_units is on stdout and must not become a unit
  units_txt="$(box_cpu_units)" || { [[ -n "$units_txt" ]] && echo "$units_txt"; return 1; }
  mapfile -t units <<<"$units_txt"
  ((${#units[@]})) || return 1
  if [[ -n "$want" ]]; then echo "CEILING cores=$cores cap=${BOX_CPU_CAP}% -> CPUQuota=${want}% per unit"; else echo "CEILING cores=$cores remove: no CPUQuota"; fi
  for u in "${units[@]}"; do
    cur="$($BOX_CPU_SYSTEMCTL show "$u" -p CPUQuotaPerSecUSec --value 2>/dev/null)"
    have="$(box_cpu_pct "$cur")"
    [[ -n "$have" || -z "$cur" || "$cur" == infinity ]] || { do_log "FATAL $u: cannot read CPUQuotaPerSecUSec '$cur'"; return 1; }
    echo "UNIT $u CPUQuota=$([[ -n "$have" ]] && echo "$have%" || echo none) ($(box_cpu_throttled "$u"))"
    [[ "$have" == "$want" ]] && continue
    bad=$((bad + 1))
    [[ "$cmd" == check ]] && continue
    if [[ "${DRY_RUN:-1}" == 1 ]]; then echo "PLAN $u CPUQuota=${want:+$want%}"; continue; fi
    $BOX_CPU_SYSTEMCTL set-property "$u" "CPUQuota=${want:+$want%}" || { do_log "FATAL cannot set CPUQuota on $u"; return 1; }
    have="$(box_cpu_pct "$($BOX_CPU_SYSTEMCTL show "$u" -p CPUQuotaPerSecUSec --value 2>/dev/null)")"
    [[ "$have" == "$want" ]] || { do_log "FATAL $u reads CPUQuota=${have:-none} after the set, not ${want:-none}"; return 1; }
    echo "SET $u CPUQuota=$([[ -n "$want" ]] && echo "$want%" || echo none)"
  done
  if [[ "$cmd" == check ]]; then
    ((bad == 0)) || { do_log "FAIL $bad unit(s) without the ceiling of ${want}%: BOX_CPU_CMD=apply DRY_RUN=0 ./run -a do_box_cpu_ceiling"; return 1; }
    do_log "OK every unit has the ceiling of ${want}%"; return 0
  fi
  ((bad == 0)) && { do_log "OK nothing to change"; return 0; }
  [[ "${DRY_RUN:-1}" == 1 ]] && { do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."; return 0; }
  do_log "OK $bad unit(s) changed ($cmd)"
}
