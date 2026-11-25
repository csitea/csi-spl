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
# @description The job runs under its own lock (cron-no-stack.sh,
# @description <logdir>/cron.lock, SPL-4495): a start while the last run still
# @description goes exits 0 with one SKIP line, so slow runs never stack.
# @description The line carries CPU_BUDGET_GATE_FLOOR_PCT (default 500, owner
# @description HUM-10 2026-10-10: 5 cores while gate 10 has had no verdict for
# @description CPU_BUDGET_GATE_STALE_MIN and a run waits), so a re-run keeps it,
# @description and the CI reserve: CPU_BUDGET_CI_RESERVE_PCT (default 950, 6
# @description runners online) and CPU_BUDGET_CI_WEIGHT (default 400) while CI
# @description runs or waits on the box (owner HUM-10, t1 f67e3656 msg 52474112).
# @description Dry run unless DRY_RUN=0 (prints the crontab diff).
# @param CPU_BUDGET_CRON_ACTION (optional) - install (default) | remove | check
# @param CPU_BUDGET_GATE_FLOOR_PCT (optional) - default 500; 0 writes the floor off
# @param CPU_BUDGET_CI_RESERVE_PCT (optional) - default 950; 0 writes the reserve off
# @param CPU_BUDGET_CI_WEIGHT (optional) - default 400; 0 leaves the weight as it is
# @param CPU_BUDGET_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/gh-runner-cpu-budget
# @param DESK_CRON_SRC / DESK_CRON_SELF_UPDATE / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_setup_gh_runner_cpu_budget_cron
# @example DRY_RUN=0 ./run -a do_setup_gh_runner_cpu_budget_cron
# @example CPU_BUDGET_GATE_FLOOR_PCT=0 DRY_RUN=0 ./run -a do_setup_gh_runner_cpu_budget_cron
# @example CPU_BUDGET_CRON_ACTION=check ./run -a do_setup_gh_runner_cpu_budget_cron
#------------------------------------------------------------------------------
declare -F spl_desk_cron_update_pre >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-cron-lock.func.sh"
declare -F spl_desk_cron_render >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-desk-install-service.func.sh"
declare -F spl_desk_cron_checkout >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-cron-checkout.func.sh"

do_setup_gh_runner_cpu_budget_cron() {
  do_require_bin crontab || return 1
  local act="${CPU_BUDGET_CRON_ACTION:-install}" trunk="${DESK_CRON_TRUNK:-master}"
  local tag src script logdir line pre="" ns floor="${CPU_BUDGET_GATE_FLOOR_PCT:-500}"
  local reserve="${CPU_BUDGET_CI_RESERVE_PCT:-950}" weight="${CPU_BUDGET_CI_WEIGHT:-400}"
  case "$act" in install|remove|check) ;; *) do_log "FATAL CPU_BUDGET_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  [[ "$floor" =~ ^(0|[1-9][0-9]{0,4})$ ]] || { do_log "FATAL CPU_BUDGET_GATE_FLOOR_PCT must be 0..99999, got: '$floor'"; return 1; }
  [[ "$reserve" =~ ^(0|[1-9][0-9]{0,4})$ ]] || { do_log "FATAL CPU_BUDGET_CI_RESERVE_PCT must be 0..99999, got: '$reserve'"; return 1; }
  [[ "$weight" =~ ^(0|[1-9][0-9]{0,3}|10000)$ ]] || { do_log "FATAL CPU_BUDGET_CI_WEIGHT must be 0..10000, got: '$weight'"; return 1; }
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"
  tag="$SPL_ORG_APP:gh-runner-cpu-budget"
  spl_desk_cron_src || return 1
  src="$SPL_DESK_CRON_SRC"
  script="$src/$SPL_ORG_APP-orc/src/bash/scripts/gh-runner-cpu-budget-cron.sh"
  logdir="${CPU_BUDGET_CRON_LOG_DIR:-}"
  if [[ -z "$logdir" ]]; then
    declare -F spl_var_app_subdir >/dev/null || source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../lib/bash/funcs/spl-run-paths.func.sh"
    spl_var_app_subdir logdir gh-runner-cpu-budget || { do_log "FATAL cannot derive the runner CPU budget cron log dir (no tree for spl_run_paths): set CPU_BUDGET_CRON_LOG_DIR"; return 1; }
  fi
  [[ "$SPL_DESK_CRON_SELF_UPDATE" == 1 ]] &&
    pre="$(spl_desk_cron_update_pre "$src" "$trunk")"
  ns="$(spl_cron_no_stack_pre "$src/$SPL_ORG_APP-orc" "$logdir/cron.lock")" || return 1
  line="$(printf '* * * * * %sCPU_BUDGET_GATE_FLOOR_PCT=%s CPU_BUDGET_CI_RESERVE_PCT=%s CPU_BUDGET_CI_WEIGHT=%s %s%s >> %s/cron.out 2>&1 # %s' \
    "$pre" "$floor" "$reserve" "$weight" "$ns" "$script" "$logdir" "$tag")"
  # shellcheck source=setup-box-stats-cron.func.sh
  declare -F _spl_simple_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/setup-box-stats-cron.func.sh"
  _spl_simple_cron_apply "$act" "$tag" "$src" "$trunk" "$script" "$logdir" "$line" \
    "runner CPU budget" "ticks every minute as the box user"
}
