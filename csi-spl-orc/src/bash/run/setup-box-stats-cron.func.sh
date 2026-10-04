#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the box-stats cron (rdb 0117, owner
# @description t1 8c4fcc46): ONE line in the box user's crontab running
# @description src/bash/scripts/box-stats-cron.sh, i.e. do_post_box_stats, every
# @description BOX_STATS_CRON_EVERY minutes, so the hub's box history gets one
# @description sample per box per 5 min (the lane map, the first writer, runs
# @description only on spawns and checks). Tagged `# <org>-<app>:box-stats`,
# @description matched EXACTLY at the end of the line. Idempotent: the tagged
# @description line is replaced in place, never appended; every other line is
# @description kept byte for byte. It points at the self-updating checkout the
# @description desk reconcile uses (<shared checkout>-desk-cron, DESK_CRON_SRC
# @description overrides; an agent worktree is refused), so it never runs code
# @description older than trunk. The hub and tenant are lease.conf's, read at
# @description each tick, so nothing env-specific is baked into the line.
# @description Dry run unless DRY_RUN=0 (prints the crontab diff).
# @param BOX_STATS_CRON_ACTION (optional) - install (default) | remove | check
# @param BOX_STATS_CRON_EVERY (optional) - minutes between samples, default 5
# @param BOX_STATS_CRON_OFFSET (optional) - minute offset, default 0 (*/5)
# @param BOX_STATS_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/box-stats
# @param DESK_CRON_SRC / DESK_CRON_SELF_UPDATE / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_setup_box_stats_cron
# @example DRY_RUN=0 ./run -a do_setup_box_stats_cron
# @example BOX_STATS_CRON_ACTION=check ./run -a do_setup_box_stats_cron
#------------------------------------------------------------------------------
declare -F spl_desk_cron_render >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-desk-install-service.func.sh"

do_setup_box_stats_cron() {
  do_require_bin crontab || return 1
  local act="${BOX_STATS_CRON_ACTION:-install}" every="${BOX_STATS_CRON_EVERY:-5}" off="${BOX_STATS_CRON_OFFSET:-0}"
  case "$act" in install|remove|check) ;; *) do_log "FATAL BOX_STATS_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  [[ "$every" =~ ^[0-9]+$ ]] && (( every >= 1 && every <= 59 )) || { do_log "FATAL BOX_STATS_CRON_EVERY must be 1..59 minutes, got: '$every'"; return 1; }
  [[ "$off" =~ ^[0-9]+$ ]] && (( off < every )) || { do_log "FATAL BOX_STATS_CRON_OFFSET must be 0..$((every - 1)), got: '$off'"; return 1; }
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"

  local tag src script logdir line current sched pre="" trunk="${DESK_CRON_TRUNK:-master}"
  tag="$SPL_ORG_APP:box-stats"
  spl_desk_cron_src || return 1
  src="$SPL_DESK_CRON_SRC"
  script="$src/$SPL_ORG_APP-orc/src/bash/scripts/box-stats-cron.sh"
  logdir="${BOX_STATS_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/box-stats}"
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  if (( off == 0 )); then sched="*/$every"; else sched="$off-59/$every"; fi
  [[ "$SPL_DESK_CRON_SELF_UPDATE" == 1 ]] &&
    pre="cd $src && git fetch -q origin $trunk && git checkout -q --detach origin/$trunk; "
  line="$(printf '%s * * * * %s%s >> %s/cron.out 2>&1 # %s' "$sched" "$pre" "$script" "$logdir" "$tag")"
  current="$(spl_desk_cron_line "$tag")"

  if [[ "$act" == check ]]; then
    if [[ -z "$current" ]]; then
      do_log "FAIL the box-stats cron is NOT installed (no line tagged $tag): the hub gets no regular samples of this box"
      return 1
    fi
    spl_desk_cron_say "$current"
    local ran; ran="$(spl_desk_cron_script "$current")"
    [[ -n "$ran" && -x "$ran" ]] ||
      { do_log "FAIL the line names a script that is gone or not executable: ${ran:-<none>}"; return 1; }
    [[ "$current" == "$line" ]] || do_log "INFO installed with other settings than this call would write - working"
    do_log "OK the box-stats cron is installed and its script is executable"
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
    do_log "OK the box-stats cron is out of the crontab"
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
  do_log "OK the box-stats cron posts a sample every ${every}m as the box user:"
  spl_desk_cron_say "$line"
}
