#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the spawn queue's placer (owner
# @description HUM-10, t1 c9beaa77; rdb 0180): ONE line in the box user's
# @description crontab running `./run -a do_spl_spawn_place` every minute. On
# @description every machine but the orch holder's the tick only logs that the
# @description role is held elsewhere, so the line can sit on every machine and
# @description the placer follows the orch role. Tagged
# @description `# <org>-<app>:spawn-place`, matched EXACTLY at the end of the
# @description line; idempotent. It runs from the same self-updating checkout as
# @description the desk reconcile (<shared checkout>-desk-cron, DESK_CRON_SRC
# @description overrides; an agent worktree is refused), which moves to trunk
# @description every 3 minutes, so the line itself does not self-update. Dry run
# @description unless DRY_RUN=0 (prints the crontab diff).
# @param SPAWN_PLACE_CRON_ACTION (optional) - install (default) | remove | check
# @param SPAWN_PLACE_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/spawn-place
# @param DESK_CRON_SRC / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_spawn_place_install_cron
# @example DRY_RUN=0 ./run -a do_spl_spawn_place_install_cron
# @example SPAWN_PLACE_CRON_ACTION=check ./run -a do_spl_spawn_place_install_cron
#------------------------------------------------------------------------------
declare -F spl_desk_cron_checkout >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-cron-checkout.func.sh"

do_spl_spawn_place_install_cron() {
  do_require_bin crontab || return 1
  local act="${SPAWN_PLACE_CRON_ACTION:-install}" tag src run logdir line current trunk="${DESK_CRON_TRUNK:-master}"
  case "$act" in install|remove|check) ;; *) do_log "FATAL SPAWN_PLACE_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"
  tag="$SPL_ORG_APP:spawn-place"
  DESK_CRON_SELF_UPDATE=0 spl_desk_cron_src || return 1
  src="$SPL_DESK_CRON_SRC"
  run="$src/$SPL_ORG_APP-orc/run"
  logdir="${SPAWN_PLACE_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/spawn-place}"
  line="$(printf '* * * * * cd %s && ./run -a do_spl_spawn_place >> %s/cron.out 2>&1 # %s' "${run%/run}" "$logdir" "$tag")"
  current="$(spl_desk_cron_line "$tag")"
  case "$act" in
    check) spl_spawn_place_cron_check "$tag" "$current" "$line" "$run"; return ;;
  esac
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_desk_cron_diff "$tag" "$([[ "$act" == install ]] && printf '%s' "$line")"
    [[ "$act" == install ]] && spl_desk_cron_checkout_dry "$src" "$trunk"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi
  if [[ "$act" == remove ]]; then
    spl_desk_cron_write "$tag" "" || return 1
    do_log "OK the spawn placer is out of the crontab"
    return 0
  fi
  spl_desk_cron_checkout "$src" "$trunk" || return 1
  [[ -x "$run" ]] || { do_log "FATAL $run is missing or not executable in $src"; return 1; }
  mkdir -p "$logdir" 2>/dev/null || { do_log "FATAL cannot create $logdir"; return 1; }
  spl_desk_cron_write "$tag" "$line" || return 1
  [[ "$(spl_desk_cron_line "$tag")" == "$line" ]] || { do_log "FATAL the crontab does not read back what was written"; return 1; }
  do_log "OK the spawn placer runs every minute as the box user (it acts only while this machine holds the orch role):"
  spl_desk_cron_say "$line"
}

spl_spawn_place_cron_check() {  # TAG CURRENT LINE RUN
  if [[ -z "$2" ]]; then
    do_log "FAIL the spawn placer is NOT installed (no line tagged $1): queued spawn requests wait for a hand placement"
    return 1
  fi
  spl_desk_cron_say "$2"
  [[ -x "$4" ]] || { do_log "FAIL $4 is gone or not executable"; return 1; }
  [[ "$2" == "$3" ]] || do_log "INFO installed with other settings than this call would write - working"
  do_log "OK the spawn placer is installed"
}
