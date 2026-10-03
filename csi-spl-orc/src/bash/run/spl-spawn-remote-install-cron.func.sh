#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the cross-box spawn receiver
# @description (HOWTO-satellite-work §2.2, gap row 6): ONE line in the box
# @description user's crontab running
# @description features/spawn-agents/scripts/spawn-remote.sh --serve every
# @description minute. Each tick spawns the windows the fleet's orch lease
# @description holder asked for through the spool (spawn-remote.sh --box
# @description <this box> on any machine) and replies with "<id>@<box> <pane>";
# @description a request from anyone else is refused and logged in
# @description <spool root>/spawn-remote/serve.log. Tagged
# @description `# <org>-<app>:spawn-remote`, matched EXACTLY at the end of the
# @description line; idempotent. It points at the same self-updating checkout
# @description as the desk reconcile (<shared checkout>-desk-cron,
# @description DESK_CRON_SRC overrides; an agent worktree is refused). One line
# @description per machine that should accept remote spawns.
# @description Dry run unless DRY_RUN=0 (prints the crontab diff).
# @param SPAWN_REMOTE_CRON_ACTION (optional) - install (default) | remove | check
# @param CRON_REMOVE (optional) - 1 = SPAWN_REMOTE_CRON_ACTION=remove
# @param SPAWN_REMOTE_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/spawn-remote
# @param DESK_CRON_SRC / DESK_CRON_SELF_UPDATE / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_spawn_remote_install_cron
# @example DRY_RUN=0 ./run -a do_spl_spawn_remote_install_cron
# @example SPAWN_REMOTE_CRON_ACTION=check ./run -a do_spl_spawn_remote_install_cron
#------------------------------------------------------------------------------
do_spl_spawn_remote_install_cron() {
  do_require_bin crontab || return 1
  local act="${SPAWN_REMOTE_CRON_ACTION:-install}"
  [[ "${CRON_REMOVE:-0}" == 1 ]] && act=remove
  case "$act" in install|remove|check) ;; *) do_log "FATAL SPAWN_REMOTE_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"

  local tag src script logdir line current pre="" trunk="${DESK_CRON_TRUNK:-master}"
  tag="$SPL_ORG_APP:spawn-remote"
  spl_desk_cron_src || return 1
  src="$SPL_DESK_CRON_SRC"
  script="$src/$SPL_ORG_APP-orc/src/bash/features/spawn-agents/scripts/spawn-remote.sh"
  logdir="${SPAWN_REMOTE_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/spawn-remote}"
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  [[ "$SPL_DESK_CRON_SELF_UPDATE" == 1 ]] &&
    pre="cd $src && git fetch -q origin $trunk && git checkout -q --detach origin/$trunk; "
  line="$(printf '* * * * * %s%s --serve >> %s/cron.out 2>&1 # %s' "$pre" "$script" "$logdir" "$tag")"
  current="$(spl_desk_cron_line "$tag")"

  if [[ "$act" == check ]]; then
    if [[ -z "$current" ]]; then
      do_log "FAIL the spawn receiver is NOT installed (no line tagged $tag): spawn requests to this box wait for ever"
      return 1
    fi
    spl_desk_cron_say "$current"
    local ran; ran="$(spl_desk_cron_script "$current")"
    [[ -n "$ran" && -x "$ran" ]] ||
      { do_log "FAIL the line names a script that is gone or not executable: ${ran:-<none>}"; return 1; }
    [[ "$current" == "$line" ]] || do_log "INFO installed with other settings than this call would write - working"
    do_log "OK the spawn receiver is installed and its script is executable"
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
    do_log "OK the spawn receiver is out of the crontab"
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
  do_log "OK the spawn receiver runs every minute as the box user:"
  spl_desk_cron_say "$line"
}
