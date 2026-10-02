#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the hourly orchestrator rotation
# @description cron (spec 060 FR-050, CLE-77939): ONE line in the
# @description box user's crontab running src/bash/scripts/orch-rotate-cron.sh,
# @description i.e. do_spl_orch_rotate DRY_RUN=0, at minute ROTATE_CRON_MINUTE
# @description (default 5; the dispatcher rotation owns :15). Tagged
# @description `# <org>-<app>:orch-rotate`, matched EXACTLY at the end of the
# @description line; idempotent (the tagged line is replaced in place, never
# @description appended). It points at the same self-updating checkout as the
# @description desk reconcile (<shared checkout>-desk-cron, DESK_CRON_SRC
# @description overrides; an agent worktree is refused), so it never runs code
# @description older than trunk. One line per machine: each machine rotates
# @description its own orchestrator (LEASE_ORCH in its lease.conf).
# @description Dry run unless DRY_RUN=0 (prints the crontab diff).
# @param ROTATE_CRON_ACTION (optional) - install (default) | remove | check
# @param CRON_REMOVE (optional) - 1 = ROTATE_CRON_ACTION=remove (spec 060 FR-050, FR-092)
# @param ROTATE_CRON_MINUTE (optional) - the minute of every hour, default 5
# @param ROTATE_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/orch-rotate
# @param DESK_CRON_SRC / DESK_CRON_SELF_UPDATE / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_orch_rotate_install_cron
# @example DRY_RUN=0 ./run -a do_spl_orch_rotate_install_cron
# @example ROTATE_CRON_ACTION=check ./run -a do_spl_orch_rotate_install_cron
#------------------------------------------------------------------------------
do_spl_orch_rotate_install_cron() {
  do_require_bin crontab || return 1
  local act="${ROTATE_CRON_ACTION:-install}" min="${ROTATE_CRON_MINUTE:-5}"
  [[ "${CRON_REMOVE:-0}" == 1 ]] && act=remove
  case "$act" in install|remove|check) ;; *) do_log "FATAL ROTATE_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  [[ "$min" =~ ^[0-9]+$ ]] && (( min <= 59 )) || { do_log "FATAL ROTATE_CRON_MINUTE must be 0..59, got: '$min'"; return 1; }
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"

  local tag src script logdir line current pre="" trunk="${DESK_CRON_TRUNK:-master}"
  tag="$SPL_ORG_APP:orch-rotate"
  spl_desk_cron_src || return 1
  src="$SPL_DESK_CRON_SRC"
  script="$src/$SPL_ORG_APP-orc/src/bash/scripts/orch-rotate-cron.sh"
  logdir="${ROTATE_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/orch-rotate}"
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  [[ "$SPL_DESK_CRON_SELF_UPDATE" == 1 ]] &&
    pre="cd $src && git fetch -q origin $trunk && git checkout -q --detach origin/$trunk; "
  line="$(printf '%s * * * * %s%s >> %s/cron.out 2>&1 # %s' "$min" "$pre" "$script" "$logdir" "$tag")"
  current="$(spl_desk_cron_line "$tag")"

  if [[ "$act" == check ]]; then
    if [[ -z "$current" ]]; then
      do_log "FAIL the orchestrator rotation is NOT installed (no line tagged $tag): the orchestrator session is never renewed"
      return 1
    fi
    spl_desk_cron_say "$current"
    local ran; ran="$(spl_desk_cron_script "$current")"
    [[ -n "$ran" && -x "$ran" ]] ||
      { do_log "FAIL the line names a script that is gone or not executable: ${ran:-<none>}"; return 1; }
    [[ "$current" == "$line" ]] || do_log "INFO installed with other settings than this call would write - working"
    do_log "OK the orchestrator rotation is installed and its script is executable"
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
    do_log "OK the orchestrator rotation is out of the crontab"
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
  do_log "OK the orchestrator rotation runs hourly at :$(printf '%02d' "$min") as the box user:"
  spl_desk_cron_say "$line"
}
