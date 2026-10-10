#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the runner CPU budget cron: ONE
# @description line in the box user's crontab running
# @description src/bash/scripts/gh-runner-cpu-budget-cron.sh every minute,
# @description which runs do_apply_gh_runner_cpu_budget with DRY_RUN=0, so the
# @description runners' CPUQuota follows the box load. Tagged
# @description `# <org>-<app>:gh-runner-cpu-budget`, matched EXACTLY at the end
# @description of the line. Idempotent: the tagged line is replaced in place.
# @description It points at the self-updating checkout the desk reconcile uses
# @description (<shared checkout>-desk-cron). An agent worktree is refused.
# @description Install it only on a box that carries runners.
# @description The line carries CPU_BUDGET_GATE_FLOOR_PCT (default 500, owner
# @description HUM-10 2026-10-10: 5 cores while gate 10 has had no verdict for
# @description CPU_BUDGET_GATE_STALE_MIN and a run waits), so a re-run keeps it.
# @description Dry run unless DRY_RUN=0 (prints the crontab diff).
# @param CPU_BUDGET_CRON_ACTION (optional) - install (default) | remove | check
# @param CPU_BUDGET_GATE_FLOOR_PCT (optional) - default 500; 0 writes the floor off
# @param CPU_BUDGET_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/gh-runner-cpu-budget
# @param DESK_CRON_SRC / DESK_CRON_SELF_UPDATE / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_setup_gh_runner_cpu_budget_cron
# @example DRY_RUN=0 ./run -a do_setup_gh_runner_cpu_budget_cron
# @example CPU_BUDGET_GATE_FLOOR_PCT=0 DRY_RUN=0 ./run -a do_setup_gh_runner_cpu_budget_cron
# @example CPU_BUDGET_CRON_ACTION=check ./run -a do_setup_gh_runner_cpu_budget_cron
#------------------------------------------------------------------------------
declare -F spl_desk_cron_render >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-desk-install-service.func.sh"

do_setup_gh_runner_cpu_budget_cron() {
  do_require_bin crontab || return 1
  local act="${CPU_BUDGET_CRON_ACTION:-install}" trunk="${DESK_CRON_TRUNK:-master}"
  local tag src script logdir line current pre="" floor="${CPU_BUDGET_GATE_FLOOR_PCT:-500}"
  case "$act" in install|remove|check) ;; *) do_log "FATAL CPU_BUDGET_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  [[ "$floor" =~ ^(0|[1-9][0-9]{0,4})$ ]] || { do_log "FATAL CPU_BUDGET_GATE_FLOOR_PCT must be 0..99999, got: '$floor'"; return 1; }
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"
  tag="$SPL_ORG_APP:gh-runner-cpu-budget"
  spl_desk_cron_src || return 1
  src="$SPL_DESK_CRON_SRC"
  script="$src/$SPL_ORG_APP-orc/src/bash/scripts/gh-runner-cpu-budget-cron.sh"
  logdir="${CPU_BUDGET_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/gh-runner-cpu-budget}"
  [[ "$SPL_DESK_CRON_SELF_UPDATE" == 1 ]] &&
    pre="cd $src && git fetch -q origin $trunk && git checkout -q --detach origin/$trunk; "
  line="$(printf '* * * * * %sCPU_BUDGET_GATE_FLOOR_PCT=%s %s >> %s/cron.out 2>&1 # %s' "$pre" "$floor" "$script" "$logdir" "$tag")"
  current="$(spl_desk_cron_line "$tag")"

  if [[ "$act" == check ]]; then
    [[ -n "$current" ]] || { do_log "FAIL the runner CPU budget cron is NOT installed (no line tagged $tag)"; return 1; }
    spl_desk_cron_say "$current"
    local ran; ran="$(spl_desk_cron_script "$current")"
    [[ -n "$ran" && -x "$ran" ]] ||
      { do_log "FAIL the line names a script that is gone or not executable: ${ran:-<none>}"; return 1; }
    [[ "$current" == "$line" ]] || do_log "INFO installed with other settings than this call would write - working"
    do_log "OK the runner CPU budget cron is installed and its script is executable"
    return 0
  fi
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_desk_cron_diff "$tag" "$([[ "$act" == install ]] && printf '%s' "$line")"
    [[ "$act" == install && "$SPL_DESK_CRON_CREATE" == 1 ]] &&
      do_log "INFO DRY_RUN would: git worktree add --detach $src origin/$trunk (the self-updating checkout)"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi
  if [[ "$act" == remove ]]; then
    spl_desk_cron_write "$tag" "" || return 1
    do_log "OK the runner CPU budget cron is out of the crontab"
    return 0
  fi
  if [[ "$SPL_DESK_CRON_CREATE" == 1 ]]; then
    git -C "$SPL_DESK_CRON_REPO" fetch -q origin "$trunk" &&
      git -C "$SPL_DESK_CRON_REPO" worktree add -q --detach "$src" "origin/$trunk" ||
      { do_log "FATAL could not create the self-updating checkout $src"; return 1; }
  fi
  [[ -x "$script" ]] || { do_log "FATAL $script is missing or not executable in $src (is it on trunk yet?)"; return 1; }
  mkdir -p "$logdir" 2>/dev/null || { do_log "FATAL cannot create $logdir"; return 1; }
  spl_desk_cron_write "$tag" "$line" || return 1
  current="$(spl_desk_cron_line "$tag")"
  [[ "$current" == "$line" ]] || { do_log "FATAL the crontab does not read back what was written. Got: ${current:-<nothing>}"; return 1; }
  do_log "OK the runner CPU budget cron ticks every minute as the box user:"
  spl_desk_cron_say "$line"
}
