#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the disk headroom cron: ONE line
# @description in the box user's crontab running
# @description src/bash/scripts/check-disk-headroom.sh with DRY_RUN=0 every
# @description DISK_HEADROOM_CRON_EVERY minutes (default 15), appending to
# @description <log dir>/cron.out. Tagged `# <org>-<app>:disk-headroom`,
# @description matched EXACTLY at the end of the line, so no other job is
# @description touched; idempotent (the tagged line is replaced in place). It
# @description points at the self-updating checkout the desk reconcile uses
# @description (<shared checkout>-desk-cron); an agent worktree is refused.
# @description Install it on every box (each box measures its own disks).
# @description Dry run unless DRY_RUN=0 (prints the crontab diff).
# @param DISK_HEADROOM_CRON_ACTION (optional) - install (default) | remove | check
# @param DISK_HEADROOM_CRON_EVERY (optional) - minutes between ticks, default 15
# @param DISK_HEADROOM_CRON_OFFSET (optional) - minute offset, default 7
# @param DISK_HEADROOM_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/disk-headroom
# @param DESK_CRON_SRC / DESK_CRON_SELF_UPDATE / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_check_disk_headroom_install_cron
# @example DRY_RUN=0 ./run -a do_check_disk_headroom_install_cron
# @example DISK_HEADROOM_CRON_ACTION=check ./run -a do_check_disk_headroom_install_cron
#------------------------------------------------------------------------------
declare -F spl_desk_cron_render >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-desk-install-service.func.sh"

do_check_disk_headroom_install_cron() {
  do_require_bin crontab || return 1
  local act="${DISK_HEADROOM_CRON_ACTION:-install}" every="${DISK_HEADROOM_CRON_EVERY:-15}" off="${DISK_HEADROOM_CRON_OFFSET:-7}"
  case "$act" in install|remove|check) ;; *) do_log "FATAL DISK_HEADROOM_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  [[ "$every" =~ ^[0-9]+$ ]] && (( every >= 1 && every <= 59 )) || { do_log "FATAL DISK_HEADROOM_CRON_EVERY must be 1..59 minutes, got: '$every'"; return 1; }
  (( every == 1 )) && off=0
  [[ "$off" =~ ^[0-9]+$ ]] && (( off < every )) || { do_log "FATAL DISK_HEADROOM_CRON_OFFSET must be 0..$((every - 1)), got: '$off'"; return 1; }
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"

  local tag src script logdir line current sched pre="" trunk="${DESK_CRON_TRUNK:-master}"
  tag="$SPL_ORG_APP:disk-headroom"
  spl_desk_cron_src || return 1
  src="$SPL_DESK_CRON_SRC"
  script="$src/$SPL_ORG_APP-orc/src/bash/scripts/check-disk-headroom.sh"
  logdir="${DISK_HEADROOM_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/disk-headroom}"
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  if (( off == 0 )); then sched="*/$every"; else sched="$off-59/$every"; fi
  [[ "$SPL_DESK_CRON_SELF_UPDATE" == 1 ]] &&
    pre="cd $src && git fetch -q origin $trunk && git checkout -q --detach origin/$trunk; "
  line="$(printf '%s * * * * %sDRY_RUN=0 %s >> %s/cron.out 2>&1 # %s' "$sched" "$pre" "$script" "$logdir" "$tag")"
  current="$(spl_desk_cron_line "$tag")"

  if [[ "$act" == check ]]; then
    if [[ -z "$current" ]]; then
      do_log "FAIL the disk headroom cron is NOT installed (no line tagged $tag): a filling disk warns nobody"
      return 1
    fi
    spl_desk_cron_say "$current"
    local ran; ran="$(spl_desk_cron_script "$current")"
    [[ -n "$ran" && -x "$ran" ]] ||
      { do_log "FAIL the line names a script that is gone or not executable: ${ran:-<none>}"; return 1; }
    [[ "$current" == "$line" ]] || do_log "INFO installed with other settings than this call would write - working"
    do_log "OK the disk headroom cron is installed and its script is executable"
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
    do_log "OK the disk headroom cron is out of the crontab"
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
  do_log "OK the disk headroom cron ticks every ${every}m as the box user:"
  spl_desk_cron_say "$line"
}
