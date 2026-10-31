#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the unanswered-post sweep cron
# @description (SPEC-spool-fleet-roles.md 3.2): ONE line in the box user's
# @description crontab running src/bash/scripts/unanswered-sweep-cron.sh, i.e.
# @description do_spl_unanswered_sweep DELIVER=1, every SWEEP_CRON_EVERY
# @description minutes (default every minute), with SWEEP_MIN_AGE=3 and
# @description SWEEP_ESCALATE_AGE=5 on the line: a human post no agent answered
# @description reaches the dispatcher at 3 min and the orchestrator at 5 (M3,
# @description 2026-10-11, after a burst was held "fresh" for hours). Tagged `# <org>-<app>:unanswered-sweep` for prd (the
# @description box's dispatchers answer the prd hub) and
# @description `# <org>-<app>:unanswered-sweep-<env>` elsewhere, matched EXACTLY
# @description at the end of the line, so installing one env never touches
# @description another (the desk-reconcile lesson of 2026-10-01). Idempotent:
# @description the tagged line is replaced in place, never appended. It points
# @description at the same self-updating checkout as the desk reconcile
# @description (<shared checkout>-desk-cron, DESK_CRON_SRC overrides; an agent
# @description worktree is refused), so it never runs code older than trunk.
# @description Dry run unless DRY_RUN=0 (prints the crontab diff).
# @param SWEEP_CRON_ACTION (optional) - install (default) | remove | check
# @param ENV (optional) - the hub swept, default prd
# @param SWEEP_CRON_EVERY (optional) - minutes between sweeps, default 1
# @param SWEEP_CRON_MIN_AGE (optional) - the line's SWEEP_MIN_AGE, minutes, default 3
# @param SWEEP_CRON_ESCALATE_AGE (optional) - the line's SWEEP_ESCALATE_AGE, minutes, default 5
# @param SWEEP_CRON_OFFSET (optional) - minute offset, default 2 (off the desk ticks)
# @param SWEEP_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/unanswered-sweep
# @param DESK_CRON_SRC / DESK_CRON_SELF_UPDATE / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_unanswered_sweep_install_cron
# @example DRY_RUN=0 ./run -a do_spl_unanswered_sweep_install_cron
# @example SWEEP_CRON_ACTION=check ./run -a do_spl_unanswered_sweep_install_cron
#------------------------------------------------------------------------------
declare -F spl_desk_cron_update_pre >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-cron-lock.func.sh"
declare -F spl_desk_cron_checkout >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-cron-checkout.func.sh"

do_spl_unanswered_sweep_install_cron() {
  do_require_bin crontab || return 1
  local env_name="${ENV:-prd}" act="${SWEEP_CRON_ACTION:-install}" every="${SWEEP_CRON_EVERY:-1}"
  [[ "$env_name" =~ ^(dev|prd)$ ]] || { do_log "FATAL ENV must be dev or prd"; return 1; }
  case "$act" in install|remove|check) ;; *) do_log "FATAL SWEEP_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  [[ "$every" =~ ^[0-9]+$ ]] && (( every >= 1 && every <= 59 )) || { do_log "FATAL SWEEP_CRON_EVERY must be 1..59 minutes, got: '$every'"; return 1; }
  local off="${SWEEP_CRON_OFFSET:-2}" min_age="${SWEEP_CRON_MIN_AGE:-3}" esc_age="${SWEEP_CRON_ESCALATE_AGE:-5}"
  [[ "$min_age" =~ ^[1-9][0-9]*$ && "$esc_age" =~ ^[1-9][0-9]*$ ]] && (( esc_age >= min_age )) ||
    { do_log "FATAL SWEEP_CRON_MIN_AGE / SWEEP_CRON_ESCALATE_AGE must be minutes, escalation >= min age, got: '$min_age' / '$esc_age'"; return 1; }
  (( every == 1 )) && off=0
  [[ "$off" =~ ^[0-9]+$ ]] && (( off < every )) || { do_log "FATAL SWEEP_CRON_OFFSET must be 0..$((every - 1)), got: '$off'"; return 1; }
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"

  local tag src script logdir line ns lock current sched pre="" out="cron.out" trunk="${DESK_CRON_TRUNK:-master}"
  tag="$SPL_ORG_APP:unanswered-sweep$([[ "$env_name" == prd ]] || printf -- '-%s' "$env_name")"
  spl_desk_cron_src || return 1
  src="$SPL_DESK_CRON_SRC"
  script="$src/$SPL_ORG_APP-orc/src/bash/scripts/unanswered-sweep-cron.sh"
  logdir="${SWEEP_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/unanswered-sweep}"
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  if (( every == 1 )); then sched="*"; elif (( off == 0 )); then sched="*/$every"; else sched="$off-59/$every"; fi
  [[ "$SPL_DESK_CRON_SELF_UPDATE" == 1 ]] &&
    pre="$(spl_desk_cron_update_pre "$src" "$trunk")"
  [[ "$env_name" == prd ]] || out="cron-$env_name.out"
  lock="$logdir/${out%.out}.lock"
  ns="$(spl_cron_no_stack_pre "$src/$SPL_ORG_APP-orc" "$lock")" || return 1
  line="$(printf '%s * * * * %sENV=%s SWEEP_MIN_AGE=%s SWEEP_ESCALATE_AGE=%s %s%s >> %s/%s 2>&1 # %s' \
    "$sched" "$pre" "$env_name" "$min_age" "$esc_age" "$ns" "$script" "$logdir" "$out" "$tag")"
  current="$(spl_desk_cron_line "$tag")"

  if [[ "$act" == check ]]; then
    if [[ -z "$current" ]]; then
      do_log "FAIL the unanswered sweep is NOT installed (no line tagged $tag): a missed human post is never looked at again"
      return 1
    fi
    spl_desk_cron_say "$current"
    local ran; ran="$(spl_desk_cron_script "$current")"
    [[ -n "$ran" && -x "$ran" ]] ||
      { do_log "FAIL the line names a script that is gone or not executable: ${ran:-<none>}"; return 1; }
    [[ "$current" == "$line" ]] || do_log "INFO installed with other settings than this call would write - working"
    do_log "OK the unanswered sweep is installed and its script is executable"
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
    do_log "OK the unanswered sweep is out of the crontab"
    return 0
  fi
  spl_desk_cron_checkout "$src" "$trunk" || return 1
  [[ -x "$script" ]] || { do_log "FATAL $script is missing or not executable in $src (is it on trunk yet?)"; return 1; }
  mkdir -p "$logdir" 2>/dev/null || { do_log "FATAL cannot create $logdir"; return 1; }
  spl_desk_cron_write "$tag" "$line" || return 1
  current="$(spl_desk_cron_line "$tag")"
  [[ "$current" == "$line" ]] || { do_log "FATAL the crontab does not read back what was written. Got: ${current:-<nothing>}"; return 1; }
  do_log "OK the unanswered sweep runs every ${every}m as the box user:"
  spl_desk_cron_say "$line"
}
