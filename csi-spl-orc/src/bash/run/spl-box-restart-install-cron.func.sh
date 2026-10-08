#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the scheduled box restart: ONE
# @description line in the box user's crontab, tagged `# <org>-<app>:box-restart`
# @description (matched exactly at the end of the line; replaced in place,
# @description never appended), running src/bash/scripts/box-restart-cron.sh
# @description every 5 minutes with this box's slot. The script's tick
# @description (do_spl_box_restart_tick) restarts the box when the slot is due
# @description and runs the after-boot pass (do_spl_box_restart_after) once the
# @description box is back; every other tick prints nothing.
# @description The slot comes from cnf env.box.restart (all.env.yaml): the
# @description weekday, the zone and slots[BOX_RESTART_SLOT], never a literal;
# @description slot 0 is the first box, 1 the second (distinct times, so the
# @description leases always have a live box). It points at the self-updating
# @description checkout (<shared checkout>-desk-cron, DESK_CRON_SRC overrides;
# @description an agent worktree is refused). Dry run unless DRY_RUN=0.
# @param BOX_RESTART_CRON_ACTION (optional) - install (default) | remove | check
# @param CRON_REMOVE (optional) - 1 = BOX_RESTART_CRON_ACTION=remove
# @param BOX_RESTART_SLOT - install: this box's slot index in cnf env.box.restart.slots
# @param BOX_RESTART_CNF (optional) - default <checkout>/<org>-<app>-cnf/<org>-<app>/all.env.yaml
# @param BOX_RESTART_LOG_DIR (optional) - default /var/<org>/<org>-<app>/box-restart
# @param DESK_CRON_SRC / DESK_CRON_SELF_UPDATE / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @param DRY_RUN (optional) - 1 (default) or 0
# @example BOX_RESTART_SLOT=0 ./run -a do_spl_box_restart_install_cron
# @example BOX_RESTART_SLOT=1 DRY_RUN=0 ./run -a do_spl_box_restart_install_cron
# @example BOX_RESTART_CRON_ACTION=check ./run -a do_spl_box_restart_install_cron
#------------------------------------------------------------------------------
declare -F spl_desk_cron_render >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-desk-install-service.func.sh"
declare -F spl_brx_slot_parse >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-box-restart-schedule.func.sh"

do_spl_box_restart_install_cron() {
  local act="${BOX_RESTART_CRON_ACTION:-install}" tag current ran
  do_require_bin crontab || return 1
  [[ "${CRON_REMOVE:-0}" == 1 ]] && act=remove
  case "$act" in install|remove|check) ;; *) do_log "FATAL BOX_RESTART_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"
  tag="$SPL_ORG_APP:box-restart"
  current="$(spl_desk_cron_line "$tag")"
  if [[ "$act" == check ]]; then
    [[ -n "$current" ]] || { do_log "FAIL the box restart is NOT installed (no line tagged $tag)"; return 1; }
    spl_desk_cron_say "$current"
    ran="$(spl_desk_cron_script "$current")"
    [[ -n "$ran" && -x "$ran" ]] || { do_log "FAIL the line names a script that is gone or not executable: ${ran:-<none>}"; return 1; }
    do_log "OK the box restart is installed and its script is executable"
    return 0
  fi
  if [[ "$act" == remove ]]; then
    [[ "${DRY_RUN:-1}" == 1 ]] && { spl_desk_cron_diff "$tag" ""; do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."; return 0; }
    spl_desk_cron_write "$tag" "" || return 1
    do_log "OK the box restart is out of the crontab"
    return 0
  fi
  spl_brx_cron_build "$tag" || return 1
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    do_log "INFO slot ${BOX_RESTART_SLOT}: ${SPL_BRX_CRON_AT} (cnf ${SPL_BRX_CRON_CNF})"
    spl_desk_cron_diff "$tag" "$SPL_BRX_CRON_LINE"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi
  spl_brx_cron_apply "$tag"
}

# spl_brx_cron_slot: SPL_BRX_CRON_AT = "<weekday> <HH:MM> <tz>" of slot
# BOX_RESTART_SLOT, from cnf; refuses a cnf whose slots repeat a time.
spl_brx_cron_slot() {
  local cnf="${BOX_RESTART_CNF:-$APP_PATH/$SPL_ORG_APP-cnf/$SPL_ORG_APP/all.env.yaml}" n="${BOX_RESTART_SLOT:-}" tz dow hm dup
  SPL_BRX_CRON_CNF="$cnf"
  [[ "$n" =~ ^[0-9]+$ ]] || { do_log "FATAL BOX_RESTART_SLOT must be set (no default): this box's slot index (0 = the first box, 1 = the second)"; return 1; }
  [[ -f "$cnf" ]] || { do_log "FATAL no cnf at $cnf"; return 1; }
  tz="$(yq -r '.env.box.restart.timezone // ""' "$cnf")"; dow="$(yq -r '.env.box.restart.weekday // ""' "$cnf")"
  hm="$(yq -r ".env.box.restart.slots[$n] // \"\"" "$cnf")"
  dup="$(yq -r '.env.box.restart.slots[]' "$cnf" | sort | uniq -d)"
  [[ -z "$dup" ]] || { do_log "FATAL cnf env.box.restart.slots repeats ${dup//$'\n'/ }: two boxes would restart at once"; return 1; }
  [[ -n "$hm" ]] || { do_log "FATAL cnf env.box.restart.slots has no slot $n"; return 1; }
  SPL_BRX_CRON_AT="$dow $hm $tz"
  BOX_RESTART_AT="$SPL_BRX_CRON_AT" spl_brx_slot_parse
}

# spl_brx_cron_build TAG: SPL_BRX_CRON_LINE / _SCRIPT / _LOGDIR.
spl_brx_cron_build() {
  local tag="$1" pre="" trunk="${DESK_CRON_TRUNK:-master}"
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  spl_brx_cron_slot || return 1
  spl_desk_cron_src || return 1
  SPL_BRX_CRON_SCRIPT="$SPL_DESK_CRON_SRC/$SPL_ORG_APP-orc/src/bash/scripts/box-restart-cron.sh"
  SPL_BRX_CRON_LOGDIR="${BOX_RESTART_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/box-restart}"
  [[ "$SPL_DESK_CRON_SELF_UPDATE" == 1 ]] &&
    pre="cd $SPL_DESK_CRON_SRC && git fetch -q origin $trunk && git checkout -q --detach origin/$trunk; "
  SPL_BRX_CRON_LINE="*/5 * * * * $pre$SPL_BRX_CRON_SCRIPT --at '$SPL_BRX_CRON_AT' >> $SPL_BRX_CRON_LOGDIR/box-restart.out 2>&1 # $tag"
}

# spl_brx_cron_apply TAG: write the line and read it back.
spl_brx_cron_apply() {
  local tag="$1" current
  if [[ "$SPL_DESK_CRON_CREATE" == 1 ]]; then
    git -C "$SPL_DESK_CRON_REPO" fetch -q origin "${DESK_CRON_TRUNK:-master}" &&
      git -C "$SPL_DESK_CRON_REPO" worktree add -q --detach "$SPL_DESK_CRON_SRC" "origin/${DESK_CRON_TRUNK:-master}" ||
      { do_log "FATAL could not create the self-updating checkout $SPL_DESK_CRON_SRC"; return 1; }
  fi
  [[ -x "$SPL_BRX_CRON_SCRIPT" ]] || { do_log "FATAL $SPL_BRX_CRON_SCRIPT is missing or not executable (is it on trunk yet?)"; return 1; }
  mkdir -p "$SPL_BRX_CRON_LOGDIR" 2>/dev/null || { do_log "FATAL cannot create $SPL_BRX_CRON_LOGDIR"; return 1; }
  spl_desk_cron_write "$tag" "$SPL_BRX_CRON_LINE" || return 1
  current="$(spl_desk_cron_line "$tag")"
  [[ "$current" == "$SPL_BRX_CRON_LINE" ]] || { do_log "FATAL the crontab does not read back what was written. Got: ${current:-<nothing>}"; return 1; }
  do_log "OK the box restart is installed as the box user (slot ${BOX_RESTART_SLOT}: ${SPL_BRX_CRON_AT}):"
  spl_desk_cron_say "$SPL_BRX_CRON_LINE"
}
