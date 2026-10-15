#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the daily env order cron
# @description (SPL-1947): ONE line in the box user's crontab running
# @description src/bash/scripts/check-env-order.sh (do_check_env_order, read
# @description only) with DRY_RUN=0 once a day at ENV_ORDER_CRON_AT, appending
# @description to <log dir>/cron.out. Tagged `# <org>-<app>:env-order`, matched
# @description EXACTLY at the end of the line, so no other job is touched;
# @description idempotent. It points at the self-updating checkout the desk
# @description reconcile uses (<shared checkout>-desk-cron); an agent worktree
# @description is refused. ONE box only: the one whose tf-runner stack is up
# @description (make do-setup-app-inf). Dry run unless DRY_RUN=0.
# @param ENV_ORDER_CRON_ACTION (optional) - install (default) | remove | check
# @param ENV_ORDER_CRON_AT (optional) - HH:MM box time, default 05:23
# @param ENV_ORDER_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/env-order
# @param DESK_CRON_SRC / DESK_CRON_SELF_UPDATE / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_check_env_order_install_cron
# @example DRY_RUN=0 ./run -a do_check_env_order_install_cron
# @example ENV_ORDER_CRON_ACTION=check ./run -a do_check_env_order_install_cron
#------------------------------------------------------------------------------
declare -F spl_desk_cron_render >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-desk-install-service.func.sh"
declare -F spl_desk_cron_checkout >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-cron-checkout.func.sh"

do_check_env_order_install_cron() {
  do_require_bin crontab || return 1
  local act="${ENV_ORDER_CRON_ACTION:-install}" at="${ENV_ORDER_CRON_AT:-05:23}"
  case "$act" in install|remove|check) ;; *) do_log "FATAL ENV_ORDER_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  [[ "$at" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]] || { do_log "FATAL ENV_ORDER_CRON_AT must be HH:MM, got: '$at'"; return 1; }
  local hh="$((10#${BASH_REMATCH[1]}))" mm="$((10#${BASH_REMATCH[2]}))"
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"

  local tag src script logdir line current pre="" trunk="${DESK_CRON_TRUNK:-master}"
  tag="$SPL_ORG_APP:env-order"
  spl_desk_cron_src || return 1
  src="$SPL_DESK_CRON_SRC"
  script="$src/$SPL_ORG_APP-orc/src/bash/scripts/check-env-order.sh"
  logdir="${ENV_ORDER_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/env-order}"
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  [[ "$SPL_DESK_CRON_SELF_UPDATE" == 1 ]] &&
    pre="cd $src && git fetch -q origin $trunk && git checkout -q --detach origin/$trunk; "
  line="$(printf '%s %s * * * %sDRY_RUN=0 %s >> %s/cron.out 2>&1 # %s' "$mm" "$hh" "$pre" "$script" "$logdir" "$tag")"
  current="$(spl_desk_cron_line "$tag")"

  if [[ "$act" == check ]]; then
    [[ -n "$current" ]] || { do_log "FAIL the env order cron is NOT installed (no line tagged $tag): prd ahead of dev warns nobody"; return 1; }
    spl_desk_cron_say "$current"
    local ran; ran="$(spl_desk_cron_script "$current")"
    [[ -n "$ran" && -x "$ran" ]] || { do_log "FAIL the line names a script that is gone or not executable: ${ran:-<none>}"; return 1; }
    [[ "$current" == "$line" ]] || do_log "INFO installed with other settings than this call would write - working"
    do_log "OK the env order cron is installed and its script is executable"
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
    do_log "OK the env order cron is out of the crontab"
    return 0
  fi
  spl_desk_cron_checkout "$src" "$trunk" || return 1
  [[ -x "$script" ]] || { do_log "FATAL $script is missing or not executable in $src (is it on trunk yet?)"; return 1; }
  mkdir -p "$logdir" 2>/dev/null || { do_log "FATAL cannot create $logdir"; return 1; }
  spl_desk_cron_write "$tag" "$line" || return 1
  current="$(spl_desk_cron_line "$tag")"
  [[ "$current" == "$line" ]] || { do_log "FATAL the crontab does not read back what was written. Got: ${current:-<nothing>}"; return 1; }
  do_log "OK the env order cron runs daily at $at as the box user:"
  spl_desk_cron_say "$line"
}
