#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the @reboot agent restore: ONE
# @description line in the box user's crontab running
# @description src/bash/scripts/agent-boot-restore-cron.sh (do_spl_agent_boot_restore
# @description DRY_RUN=0), so after a reboot every agent comes back as the AGENT
# @description user. Tagged `# <org>-<app>:agent-boot-restore`, matched EXACTLY
# @description at the end of the line; idempotent: the tagged line is replaced
# @description in place, never appended. It points at the self-updating checkout
# @description of the desk reconcile (<shared checkout>-desk-cron, DESK_CRON_SRC
# @description overrides; an agent worktree is refused). For a box with no other
# @description boot restore (the satellite); a box engine whose boot job already
# @description runs do_spl_agent_identity_restore does not install it.
# @description Spec 102 10.1 (T014): once the reboot drill passed, `retire`
# @description removes the line for good: the watchdog's reboot path brings
# @description the agents back (a new session, never a --resume), and two
# @description automatic boot paths race. It leaves <log dir>/retired; from
# @description then on `install` (a re-provision) skips (BOOT_CRON_FORCE=1
# @description installs anyway) and `check` passes while the line is absent.
# @description retire needs the drill's PASS: the watchdog's <wd dir>/boot.result
# @description (spl_wd_boot_result) with back >= 1 and failed=0; any other
# @description result refuses it and removes a stale marker. A boot result
# @description with failed ids removes the marker on install / check too, so
# @description the fallback line goes back in (sat drill 3, 2026-10-09: a
# @description marker left by a failed drill refused the reinstall). `remove`
# @description leaves <log dir>/removed (when, who, the calling command): a
# @description line gone with no marker cannot be traced (a box, 2026-10-09).
# @description Dry run unless DRY_RUN=0.
# @param BOOT_CRON_ACTION (optional) - install (default) | remove | check | retire
# @param BOOT_CRON_FORCE (optional) - 1: install even after a retire
# @param BOOT_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/agent-boot-restore
# @param BOOT_CRON_RESULT (optional) - the drill's boot result, default <SPOOL_ROOT>/dispatch/wd/boot.result
# @param DESK_CRON_SRC / DESK_CRON_SELF_UPDATE / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_agent_boot_restore_install_cron
# @example DRY_RUN=0 ./run -a do_spl_agent_boot_restore_install_cron
# @example BOOT_CRON_ACTION=check ./run -a do_spl_agent_boot_restore_install_cron
# @example BOOT_CRON_ACTION=retire DRY_RUN=0 ./run -a do_spl_agent_boot_restore_install_cron
#------------------------------------------------------------------------------
do_spl_agent_boot_restore_install_cron() {
  do_require_bin crontab || return 1
  local act="${BOOT_CRON_ACTION:-install}"
  case "$act" in install|remove|check|retire) ;; *) do_log "FATAL BOOT_CRON_ACTION must be install, remove, check or retire, got: '$act'"; return 1 ;; esac
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"

  local tag src script logdir line current pre="" trunk="${DESK_CRON_TRUNK:-master}"
  tag="$SPL_ORG_APP:agent-boot-restore"
  spl_desk_cron_src || return 1
  src="$SPL_DESK_CRON_SRC"
  script="$src/$SPL_ORG_APP-orc/src/bash/scripts/agent-boot-restore-cron.sh"
  logdir="${BOOT_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/agent-boot-restore}"
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  [[ "$SPL_DESK_CRON_SELF_UPDATE" == 1 ]] &&
    pre="cd $src && git fetch -q origin $trunk && git checkout -q --detach origin/$trunk; "
  local gate; gate="$(spl_cron_boot_gate "$logdir/cron.out" "$script" "$tag")" || return 1
  line="$(printf '@reboot %s%s%s >> %s/cron.out 2>&1 # %s' "$gate" "$pre" "$script" "$logdir" "$tag")"
  current="$(spl_desk_cron_line "$tag")"
  local retired="$logdir/retired" res
  res="$(spl_agent_boot_restore_result)"
  if [[ -f "$retired" && "$act" != retire && "$act" != remove && "$res" == failed* ]]; then
    do_log "WARN the last reboot drill failed (${res#failed }): the retired marker $retired is stale"
    if [[ "${DRY_RUN:-1}" == 1 ]]; then do_log "INFO DRY_RUN would remove $retired"
    else rm -f "$retired" || { do_log "FATAL cannot remove $retired"; return 1; }; fi
  fi
  if [[ -f "$retired" && "$act" != retire && "$act" != remove ]]; then
    spl_agent_boot_restore_retired "$act" "$retired" "$current"; return
  fi
  if [[ "$act" == retire ]]; then spl_agent_boot_restore_retire "$tag" "$retired" "$current"; return; fi

  if [[ "$act" == check ]]; then
    [[ -n "$current" ]] || { do_log "FAIL the agent boot restore is NOT installed (no line tagged $tag)"; return 1; }
    spl_desk_cron_say "$current"
    local ran; ran="$(spl_desk_cron_script "$current")"
    [[ -n "$ran" && -x "$ran" ]] || { do_log "FAIL the line names a script that is gone or not executable: ${ran:-<none>}"; return 1; }
    [[ "$current" == "$line" ]] || do_log "INFO installed with other settings than this call would write - working"
    do_log "OK the agent boot restore is installed and its script is executable"
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
    spl_agent_boot_restore_removed "$logdir/removed"
    do_log "OK the agent boot restore is out of the crontab"
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
  do_log "OK the agents come back as the agent user after a reboot:"
  spl_desk_cron_say "$line"
}

# spl_agent_boot_restore_retired ACT FILE CURRENT: install or check after a
# retire (spec 102 T014): install skips unless BOOT_CRON_FORCE=1; check passes
# while the line stays out.
spl_agent_boot_restore_retired() {
  local act="$1" retired="$2" current="$3" since
  since="$(head -c 200 "$retired" 2>/dev/null || true)"
  if [[ "$act" == check ]]; then
    [[ -z "$current" ]] || { do_log "FAIL the boot restore was retired ($since) but its line is back: $current"; return 1; }
    do_log "OK the boot restore is retired ($since): the watchdog's reboot path brings the agents back (spec 102 10.1)"
    return 0
  fi
  if [[ "${BOOT_CRON_FORCE:-0}" != 1 ]]; then
    do_log "SKIP the boot restore was retired ($since, $retired): not installed (BOOT_CRON_FORCE=1 installs it anyway)"
    return 0
  fi
  do_log "WARN BOOT_CRON_FORCE=1: installing the retired boot restore; $retired removed"
  [[ "${DRY_RUN:-1}" == 1 ]] || rm -f "$retired"
  BOOT_CRON_FORCE=0 do_spl_agent_boot_restore_install_cron
}

# The last boot's drill verdict from BOOT_CRON_RESULT (spl_wd_boot_result):
# "pass <line>" (back >= 1, failed=0), "failed <line>", or "none".
spl_agent_boot_restore_result() {
  local f="${BOOT_CRON_RESULT:-${SPOOL_ROOT:-/var/spool-hub}/dispatch/wd/boot.result}" l b k
  l="$(head -n 1 "$f" 2>/dev/null || true)"
  [[ -n "$l" ]] || { echo none; return 0; }
  b="$(grep -oE 'back=[0-9]+' <<<"$l" || true)"; b="${b#back=}"
  k="$(grep -oE 'failed=[0-9]+' <<<"$l" || true)"; k="${k#failed=}"
  if [[ "$k" == 0 && "${b:-0}" -ge 1 ]]; then echo "pass $l"; else echo "failed $l"; fi
}

# spl_agent_boot_restore_removed FILE: who took the line out, and when.
spl_agent_boot_restore_removed() {
  local by cmd
  by="${SUDO_USER:+$SUDO_USER as }$(id -un)"
  cmd="$(ps -o args= -p "$PPID" 2>/dev/null | cut -c1-200)"
  mkdir -p "${1%/*}" 2>/dev/null &&
    printf '%s removed by %s (agent %s; called from: %s)\n' "$(date -u +%FT%TZ)" "$by" "${SPOOL_AGENT_ID:--}" "${cmd:--}" >> "$1" ||
    { do_log "WARN cannot write $1"; return 0; }
  do_log "INFO the removal is recorded in $1"
}

# spl_agent_boot_restore_retire TAG FILE CURRENT: the line out of the crontab
# and the marker <log dir>/retired written (spec 102 T014, after the drill).
# Only after a PASSED drill (spl_agent_boot_restore_result); else refused and a
# stale marker removed.
spl_agent_boot_restore_retire() {
  local tag="$1" retired="$2" current="$3" res
  res="$(spl_agent_boot_restore_result)"
  if [[ "$res" != pass* ]]; then
    do_log "FAIL the reboot drill did not pass (${res}): the boot restore is NOT retired"
    if [[ -f "$retired" && "${DRY_RUN:-1}" != 1 ]]; then rm -f "$retired" && do_log "INFO the stale marker $retired removed"; fi
    return 1
  fi
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_desk_cron_diff "$tag" ""
    do_log "INFO DRY_RUN would write $retired (install then skips)"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi
  if [[ -n "$current" ]]; then spl_desk_cron_write "$tag" "" || return 1; fi
  [[ -z "$(spl_desk_cron_line "$tag")" ]] || { do_log "FATAL the line tagged $tag is still in the crontab"; return 1; }
  mkdir -p "${retired%/*}" 2>/dev/null &&
    printf '%s retired by spec 102 T014 (the reboot drill passed: %s)\n' "$(date -u +%FT%TZ)" "${res#pass }" > "$retired" ||
    { do_log "FATAL cannot write $retired"; return 1; }
  do_log "OK the boot restore is retired: no @reboot line ($tag), marker $retired; the watchdog's reboot path brings the agents back"
}
