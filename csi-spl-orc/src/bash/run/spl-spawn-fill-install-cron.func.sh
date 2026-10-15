#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the idle filler (do_spl_spawn_fill;
# @description owner HUM-10, t1 71dbbf15 msg 3c91b4c1): ONE line in the box
# @description user's crontab running `DRY_RUN=0 ./run -a do_spl_spawn_fill`
# @description every SPAWN_FILL_CRON_MIN minutes, with a PATH that has
# @description /usr/local/bin (yq) and under flock -n. The filler acts only on
# @description the orch holder's machine and only while its switch is on
# @description (SPAWN_FILL / cnf env.box.spawn_fill.enabled, absent = off), so
# @description the line can sit on every machine. Tagged
# @description `# <org>-<app>:spawn-fill`, matched EXACTLY at the end of the
# @description line; idempotent. It runs from the self-updating desk-cron
# @description checkout (<shared checkout>-desk-cron, DESK_CRON_SRC overrides;
# @description an agent worktree is refused). The orchestrator installs it, not
# @description a lane. Dry run unless DRY_RUN=0 (prints the crontab diff).
# @param SPAWN_FILL_CRON_ACTION (optional) - install (default) | remove | check
# @param SPAWN_FILL_CRON_MIN (optional) - minutes between two ticks, 1..59, default 10 (the placer's gap)
# @param SPAWN_FILL_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/spawn-fill
# @param DESK_CRON_SRC / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_spawn_fill_install_cron
# @example DRY_RUN=0 ./run -a do_spl_spawn_fill_install_cron
# @example SPAWN_FILL_CRON_ACTION=check ./run -a do_spl_spawn_fill_install_cron
#------------------------------------------------------------------------------
declare -F spl_desk_cron_checkout >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-cron-checkout.func.sh"

do_spl_spawn_fill_install_cron() {
  do_require_bin crontab || return 1
  local act="${SPAWN_FILL_CRON_ACTION:-install}" min="${SPAWN_FILL_CRON_MIN:-10}" tag src run logdir line current trunk="${DESK_CRON_TRUNK:-master}"
  case "$act" in install|remove|check) ;; *) do_log "FATAL SPAWN_FILL_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  [[ "$min" =~ ^[1-9][0-9]?$ ]] && ((min < 60)) || { do_log "FATAL SPAWN_FILL_CRON_MIN must be 1..59, got: '$min'"; return 1; }
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"
  tag="$SPL_ORG_APP:spawn-fill"
  DESK_CRON_SELF_UPDATE=0 spl_desk_cron_src || return 1
  src="$SPL_DESK_CRON_SRC"
  run="$src/$SPL_ORG_APP-orc/run"
  logdir="${SPAWN_FILL_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/spawn-fill}"
  # shellcheck disable=SC2016 # $HOME is for the cron shell, not this one
  line="$(printf '*/%s * * * * cd %s && PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin DRY_RUN=0 flock -n %s/spawn-fill.lock ./run -a do_spl_spawn_fill >> %s/cron.out 2>&1 # %s' "$min" "${run%/run}" "$logdir" "$logdir" "$tag")"
  current="$(spl_desk_cron_line "$tag")"
  [[ "$act" == check ]] && { spl_spawn_fill_cron_check "$tag" "$current" "$line" "$run"; return; }
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_desk_cron_diff "$tag" "$([[ "$act" == install ]] && printf '%s' "$line")"
    [[ "$act" == install ]] && spl_desk_cron_checkout_dry "$src" "$trunk"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi
  if [[ "$act" == remove ]]; then
    spl_desk_cron_write "$tag" "" || return 1
    do_log "OK the idle filler is out of the crontab"
    return 0
  fi
  spl_desk_cron_checkout "$src" "$trunk" || return 1
  [[ -x "$run" ]] || { do_log "FATAL $run is missing or not executable in $src"; return 1; }
  mkdir -p "$logdir" 2>/dev/null || { do_log "FATAL cannot create $logdir"; return 1; }
  spl_desk_cron_write "$tag" "$line" || return 1
  [[ "$(spl_desk_cron_line "$tag")" == "$line" ]] || { do_log "FATAL the crontab does not read back what was written"; return 1; }
  do_log "OK the idle filler runs every $min min as the box user (it queues only on the orch holder's machine, while its switch is on):"
  spl_desk_cron_say "$line"
}

spl_spawn_fill_cron_check() {  # TAG CURRENT LINE RUN
  if [[ -z "$2" ]]; then
    do_log "FAIL the idle filler is NOT installed (no line tagged $1): spare capacity is not filled from issues"
    return 1
  fi
  spl_desk_cron_say "$2"
  [[ -x "$4" ]] || { do_log "FAIL $4 is gone or not executable"; return 1; }
  [[ "$2" == "$3" ]] || do_log "INFO installed with other settings than this call would write - working"
  do_log "OK the idle filler is installed"
}
