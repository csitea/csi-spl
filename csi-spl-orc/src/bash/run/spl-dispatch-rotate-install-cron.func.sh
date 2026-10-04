#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the hourly dispatcher rotation
# @description cron (SPEC-spool-fleet-roles.md 4.4, owner 2026-10-02): ONE line
# @description in the box user's crontab running
# @description src/bash/scripts/dispatch-rotate-cron.sh (do_spl_dispatch_rotate
# @description DRY_RUN=0) at minute ROTATE_CRON_MINUTE, default 15 - the
# @description orchestrator rotates at :05 (do_spl_orch_rotate), so the fresh
# @description orchestrator is in place before the dispatchers are replaced.
# @description Tagged `# <org>-<app>:dispatch-rotate`, matched EXACTLY at the end
# @description of the line; idempotent: the tagged line is replaced in place,
# @description never appended. It points at the self-updating checkout of the
# @description desk reconcile (<shared checkout>-desk-cron, DESK_CRON_SRC
# @description overrides; an agent worktree is refused). Every machine with
# @description dispatchers installs it (the satellite too); a box without
# @description lease.conf rotates nothing. A SECOND line, tagged
# @description `# <org>-<app>:dispatch-heal`, runs the same script with --heal
# @description (do_spl_dispatch_rotate ROTATE_CMD=heal) every
# @description ROTATE_HEAL_CRON_EVERY min, offset off the rotation's minute
# @description (both take one lock; the rotation must not find it held).
# @description Dry run unless DRY_RUN=0.
# @param ROTATE_CRON_ACTION (optional) - install (default) | remove | check
# @param CRON_REMOVE (optional) - 1 = ROTATE_CRON_ACTION=remove (spec 060 FR-092)
# @param ROTATE_CRON_MINUTE (optional) - minute of the hour, default 15
# @param ROTATE_HEAL_CRON_EVERY (optional) - the heal line every N min, 2..30, default 3; 0 = no heal line (removes it)
# @param ROTATE_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/dispatch-rotate
# @param DESK_CRON_SRC / DESK_CRON_SELF_UPDATE / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_dispatch_rotate_install_cron
# @example DRY_RUN=0 ./run -a do_spl_dispatch_rotate_install_cron
# @example ROTATE_CRON_ACTION=check ./run -a do_spl_dispatch_rotate_install_cron
#------------------------------------------------------------------------------
do_spl_dispatch_rotate_install_cron() {
  do_require_bin crontab || return 1
  local act="${ROTATE_CRON_ACTION:-install}" min="${ROTATE_CRON_MINUTE:-15}"
  [[ "${CRON_REMOVE:-0}" == 1 ]] && act=remove
  case "$act" in install|remove|check) ;; *) do_log "FATAL ROTATE_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  [[ "$min" =~ ^[0-9]+$ ]] && (( min <= 59 )) || { do_log "FATAL ROTATE_CRON_MINUTE must be 0..59, got: '$min'"; return 1; }
  local every="${ROTATE_HEAL_CRON_EVERY:-3}"
  [[ "$every" =~ ^[0-9]+$ ]] && (( every == 0 || (every >= 2 && every <= 30) )) ||
    { do_log "FATAL ROTATE_HEAL_CRON_EVERY must be 0 or 2..30, got: '$every'"; return 1; }
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"

  local tag htag src script logdir line hline="" current hcurrent pre="" trunk="${DESK_CRON_TRUNK:-master}"
  tag="$SPL_ORG_APP:dispatch-rotate"; htag="$SPL_ORG_APP:dispatch-heal"
  spl_desk_cron_src || return 1
  src="$SPL_DESK_CRON_SRC"
  script="$src/$SPL_ORG_APP-orc/src/bash/scripts/dispatch-rotate-cron.sh"
  logdir="${ROTATE_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/dispatch-rotate}"
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  [[ "$SPL_DESK_CRON_SELF_UPDATE" == 1 ]] &&
    pre="cd $src && git fetch -q origin $trunk && git checkout -q --detach origin/$trunk; "
  line="$(printf '%s * * * * %s%s >> %s/cron.out 2>&1 # %s' "$min" "$pre" "$script" "$logdir" "$tag")"
  # minutes o, o+every, ... never the rotation's own minute
  (( every )) && hline="$(printf '%s-59/%s * * * * %s%s --heal >> %s/heal.out 2>&1 # %s' \
    "$(( (min % every + 1) % every ))" "$every" "$pre" "$script" "$logdir" "$htag")"
  current="$(spl_desk_cron_line "$tag")"; hcurrent="$(spl_desk_cron_line "$htag")"

  if [[ "$act" == check ]]; then
    [[ -n "$current" ]] || { do_log "FAIL the dispatcher rotation is NOT installed (no line tagged $tag)"; return 1; }
    spl_desk_cron_say "$current"
    local ran; ran="$(spl_desk_cron_script "$current")"
    [[ -n "$ran" && -x "$ran" ]] || { do_log "FAIL the line names a script that is gone or not executable: ${ran:-<none>}"; return 1; }
    [[ "$current" == "$line" ]] || do_log "INFO installed with other settings than this call would write - working"
    if (( every )); then
      [[ -n "$hcurrent" ]] || { do_log "FAIL the dispatcher heal is NOT installed (no line tagged $htag)"; return 1; }
      spl_desk_cron_say "$hcurrent"
    fi
    do_log "OK the dispatcher rotation$( ((every)) && echo " and heal are" || echo " is") installed and its script is executable"
    return 0
  fi
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_desk_cron_diff "$tag" "$([[ "$act" == install ]] && printf '%s' "$line")"
    spl_desk_cron_diff "$htag" "$([[ "$act" == install ]] && printf '%s' "$hline")"
    [[ "$act" == install && "$SPL_DESK_CRON_CREATE" == 1 ]] &&
      do_log "INFO DRY_RUN would: git worktree add --detach $src origin/$trunk (the self-updating checkout)"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi
  if [[ "$act" == remove ]]; then
    spl_desk_cron_write "$tag" "" || return 1
    spl_desk_cron_write "$htag" "" || return 1
    do_log "OK the dispatcher rotation and heal are out of the crontab"
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
  spl_desk_cron_write "$htag" "$hline" || return 1
  current="$(spl_desk_cron_line "$tag")"; hcurrent="$(spl_desk_cron_line "$htag")"
  [[ "$current" == "$line" && "$hcurrent" == "$hline" ]] ||
    { do_log "FATAL the crontab does not read back what was written. Got: ${current:-<nothing>} / ${hcurrent:-<nothing>}"; return 1; }
  do_log "OK the dispatchers rotate hourly at :$(printf '%02d' "$min") as the box user:"
  spl_desk_cron_say "$line"
  if (( every )); then do_log "OK and heal every ${every} min:"; spl_desk_cron_say "$hline"
  else do_log "OK no heal line (ROTATE_HEAL_CRON_EVERY=0)"; fi
}
