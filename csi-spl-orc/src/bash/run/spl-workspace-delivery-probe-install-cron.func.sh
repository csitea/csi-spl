#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the per-workspace delivery probe
# @description cron: ONE line in the box user's crontab running
# @description src/bash/scripts/workspace-delivery-probe-cron.sh, i.e.
# @description do_spl_workspace_delivery_probe DRY_RUN=0, every PROBE_CRON_EVERY
# @description minutes. Tagged `# <org>-<app>:delivery-probe-<env>`, matched
# @description EXACTLY at the end of the line, so one env never touches the
# @description other. Idempotent: the tagged line is replaced in place. It
# @description points at the same self-updating checkout as the desk reconcile
# @description and the unanswered sweep (<shared checkout>-desk-cron,
# @description DESK_CRON_SRC overrides; an agent worktree is refused).
# @description dev first: installing the prd line is refused unless
# @description PROBE_PRD_GO=1, the orchestrator's go for it.
# @description Dry run unless DRY_RUN=0 (prints the crontab diff).
# @param PROBE_CRON_ACTION (optional) - install (default) | remove | check
# @param ENV (optional) - the hub probed, default dev
# @param PROBE_PRD_GO (optional) - 1 = the orchestrator said go for prd
# @param PROBE_CRON_EVERY (optional) - minutes between probes, default 10
# @param PROBE_CRON_OFFSET (optional) - minute offset, default 4 (off the desk and sweep ticks)
# @param PROBE_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/delivery-probe
# @param DESK_CRON_SRC / DESK_CRON_SELF_UPDATE / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev ./run -a do_spl_workspace_delivery_probe_install_cron
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_workspace_delivery_probe_install_cron
# @example ENV=dev PROBE_CRON_ACTION=check ./run -a do_spl_workspace_delivery_probe_install_cron
#------------------------------------------------------------------------------
declare -F spl_desk_cron_update_pre >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-cron-lock.func.sh"
declare -F spl_desk_cron_checkout >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-cron-checkout.func.sh"

do_spl_workspace_delivery_probe_install_cron() {
  do_require_bin crontab || return 1
  local env_name="${ENV:-dev}" act="${PROBE_CRON_ACTION:-install}" every="${PROBE_CRON_EVERY:-10}" off="${PROBE_CRON_OFFSET:-4}"
  [[ "$env_name" =~ ^(dev|prd)$ ]] || { do_log "FATAL ENV must be dev or prd"; return 1; }
  case "$act" in install|remove|check) ;; *) do_log "FATAL PROBE_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  [[ "$every" =~ ^[0-9]+$ ]] && (( every >= 1 && every <= 59 )) || { do_log "FATAL PROBE_CRON_EVERY must be 1..59 minutes, got: '$every'"; return 1; }
  (( every == 1 )) && off=0
  [[ "$off" =~ ^[0-9]+$ ]] && (( off < every )) || { do_log "FATAL PROBE_CRON_OFFSET must be 0..$((every - 1)), got: '$off'"; return 1; }
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  if [[ "$act" == install && "$env_name" == prd && "${PROBE_PRD_GO:-0}" != 1 ]]; then
    do_log "FATAL the prd delivery probe needs the orchestrator's go: prove it on dev, then PROBE_PRD_GO=1"
    return 1
  fi
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"

  local tag src script logdir line ns current sched pre="" trunk="${DESK_CRON_TRUNK:-master}"
  tag="$SPL_ORG_APP:delivery-probe-$env_name"
  spl_desk_cron_src || return 1
  src="$SPL_DESK_CRON_SRC"
  script="$src/$SPL_ORG_APP-orc/src/bash/scripts/workspace-delivery-probe-cron.sh"
  logdir="${PROBE_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/delivery-probe}"
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  if (( off == 0 )); then sched="*/$every"; else sched="$off-59/$every"; fi
  [[ "$SPL_DESK_CRON_SELF_UPDATE" == 1 ]] &&
    pre="$(spl_desk_cron_update_pre "$src" "$trunk")"
  ns="$(spl_cron_no_stack_pre "$src/$SPL_ORG_APP-orc" "$logdir/cron-$env_name.lock")" || return 1
  line="$(printf '%s * * * * %sENV=%s %s%s >> %s/cron-%s.out 2>&1 # %s' "$sched" "$pre" "$env_name" "$ns" "$script" "$logdir" "$env_name" "$tag")"
  current="$(spl_desk_cron_line "$tag")"

  if [[ "$act" == check ]]; then
    [[ -n "$current" ]] || { do_log "FAIL the delivery probe is NOT installed (no line tagged $tag)"; return 1; }
    spl_desk_cron_say "$current"
    local ran; ran="$(spl_desk_cron_script "$current")"
    [[ -n "$ran" && -x "$ran" ]] ||
      { do_log "FAIL the line names a script that is gone or not executable: ${ran:-<none>}"; return 1; }
    [[ "$current" == "$line" ]] || do_log "INFO installed with other settings than this call would write - working"
    do_log "OK the delivery probe is installed and its script is executable"
    return 0
  fi
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_desk_cron_diff "$tag" "$([[ "$act" == install ]] && printf '%s' "$line")"
    [[ "$act" == install ]] && spl_desk_cron_checkout_dry "$src" "$trunk"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi
  if [[ "$act" == remove ]]; then
    spl_desk_cron_write "$tag" "" || return 1
    do_log "OK the delivery probe is out of the crontab"
    return 0
  fi
  spl_desk_cron_checkout "$src" "$trunk" || return 1
  [[ -x "$script" ]] || { do_log "FATAL $script is missing or not executable in $src (is it on trunk yet?)"; return 1; }
  mkdir -p "$logdir" 2>/dev/null || { do_log "FATAL cannot create $logdir"; return 1; }
  spl_desk_cron_write "$tag" "$line" || return 1
  current="$(spl_desk_cron_line "$tag")"
  [[ "$current" == "$line" ]] || { do_log "FATAL the crontab does not read back what was written. Got: ${current:-<nothing>}"; return 1; }
  do_log "OK the delivery probe runs every ${every}m as the box user:"
  spl_desk_cron_say "$line"
}
