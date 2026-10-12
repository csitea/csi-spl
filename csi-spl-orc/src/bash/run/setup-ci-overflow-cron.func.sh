#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the CI overflow cron: ONE line in
# @description the box user's crontab running
# @description src/bash/scripts/ci-overflow-cron.sh every 5 minutes, which runs
# @description do_route_ci_overflow with DRY_RUN=0 (wf 10 to the local runners
# @description while the GitHub-hosted ones are overwhelmed, and back). Install
# @description it on ONE box only: two routers would race on one repo
# @description variable and double the gh calls. Tagged
# @description `# <org>-<app>:ci-overflow`, matched EXACTLY at the end of the
# @description line; idempotent. It points at the self-updating checkout the
# @description desk reconcile uses (<shared checkout>-desk-cron). An agent
# @description worktree is refused. Dry run unless DRY_RUN=0 (the crontab diff).
# @param CI_OVERFLOW_CRON_ACTION (optional) - install (default) | remove | check
# @param CI_OVERFLOW_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/ci-overflow
# @param DESK_CRON_SRC / DESK_CRON_SELF_UPDATE / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_setup_ci_overflow_cron
# @example DRY_RUN=0 ./run -a do_setup_ci_overflow_cron
# @example CI_OVERFLOW_CRON_ACTION=check ./run -a do_setup_ci_overflow_cron
#------------------------------------------------------------------------------
declare -F spl_desk_cron_render >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-desk-install-service.func.sh"
declare -F spl_desk_cron_checkout >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-cron-checkout.func.sh"

do_setup_ci_overflow_cron() {
  do_require_bin crontab || return 1
  local act="${CI_OVERFLOW_CRON_ACTION:-install}" trunk="${DESK_CRON_TRUNK:-master}"
  local tag src script logdir line current pre=""
  case "$act" in install|remove|check) ;; *) do_log "FATAL CI_OVERFLOW_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"
  tag="$SPL_ORG_APP:ci-overflow"
  spl_desk_cron_src || return 1
  src="$SPL_DESK_CRON_SRC"
  script="$src/$SPL_ORG_APP-orc/src/bash/scripts/ci-overflow-cron.sh"
  logdir="${CI_OVERFLOW_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/ci-overflow}"
  [[ "$SPL_DESK_CRON_SELF_UPDATE" == 1 ]] &&
    pre="cd $src && git fetch -q origin $trunk && git checkout -q --detach origin/$trunk; "
  line="$(printf '*/5 * * * * %s%s >> %s/cron.out 2>&1 # %s' "$pre" "$script" "$logdir" "$tag")"
  current="$(spl_desk_cron_line "$tag")"

  if [[ "$act" == check ]]; then
    [[ -n "$current" ]] || { do_log "FAIL the CI overflow cron is NOT installed (no line tagged $tag)"; return 1; }
    spl_desk_cron_say "$current"
    local ran; ran="$(spl_desk_cron_script "$current")"
    [[ -n "$ran" && -x "$ran" ]] ||
      { do_log "FAIL the line names a script that is gone or not executable: ${ran:-<none>}"; return 1; }
    [[ "$current" == "$line" ]] || do_log "INFO installed with other settings than this call would write - working"
    do_log "OK the CI overflow cron is installed and its script is executable"
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
    do_log "OK the CI overflow cron is out of the crontab"
    return 0
  fi
  spl_desk_cron_checkout "$src" "$trunk" || return 1
  [[ -x "$script" ]] || { do_log "FATAL $script is missing or not executable in $src (is it on trunk yet?)"; return 1; }
  mkdir -p "$logdir" 2>/dev/null || { do_log "FATAL cannot create $logdir"; return 1; }
  spl_desk_cron_write "$tag" "$line" || return 1
  current="$(spl_desk_cron_line "$tag")"
  [[ "$current" == "$line" ]] || { do_log "FATAL the crontab does not read back what was written. Got: ${current:-<nothing>}"; return 1; }
  do_log "OK the CI overflow cron ticks every 5 minutes as the box user:"
  spl_desk_cron_say "$line"
}
