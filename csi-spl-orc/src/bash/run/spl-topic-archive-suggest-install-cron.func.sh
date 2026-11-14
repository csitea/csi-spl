#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the archive suggestion cron
# @description (spec 041 section 7, SPL-5520): ONE line in the running user's
# @description crontab running topic-archive-suggest-cron.sh at minute 17 of
# @description every hour, under flock -n. The script runs
# @description do_spl_topic_archive_suggest, which acts only on the box of the
# @description dispatch lease holder, so the line can sit on every machine. It
# @description stays dry (default off) until the dispatch lease.conf says
# @description ARCHIVE_SUGGEST_DRY_RUN=0. Run it as the user that owns the
# @description desks. Tagged `# <org>-<app>:topic-archive-suggest`, matched
# @description EXACTLY at the end of the line; idempotent. It runs from the
# @description same self-updating checkout as the desk reconcile (<shared
# @description checkout>-desk-cron, DESK_CRON_SRC overrides; an agent worktree
# @description is refused). Dry run unless DRY_RUN=0 (prints the crontab diff).
# @param ARCHIVE_SUGGEST_CRON_ACTION (optional) - install (default) | remove | check
# @param ARCHIVE_SUGGEST_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/topic-archive-suggest
# @param DESK_CRON_SRC / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_topic_archive_suggest_install_cron
# @example DRY_RUN=0 ./run -a do_spl_topic_archive_suggest_install_cron
# @example ARCHIVE_SUGGEST_CRON_ACTION=check ./run -a do_spl_topic_archive_suggest_install_cron
#------------------------------------------------------------------------------
declare -F spl_desk_cron_checkout >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-cron-checkout.func.sh"

do_spl_topic_archive_suggest_install_cron() {
  do_require_bin crontab || return 1
  local act="${ARCHIVE_SUGGEST_CRON_ACTION:-install}" tag src script logdir line current trunk="${DESK_CRON_TRUNK:-master}"
  case "$act" in install|remove|check) ;; *) do_log "FATAL ARCHIVE_SUGGEST_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"
  tag="$SPL_ORG_APP:topic-archive-suggest"
  DESK_CRON_SELF_UPDATE=0 spl_desk_cron_src || return 1
  src="$SPL_DESK_CRON_SRC"
  script="$src/$SPL_ORG_APP-orc/src/bash/scripts/topic-archive-suggest-cron.sh"
  logdir="${ARCHIVE_SUGGEST_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/topic-archive-suggest}"
  line="$(printf '17 * * * * flock -n %s/topic-archive-suggest.cron.lock /bin/bash %s >> %s/cron.log 2>&1 # %s' "$logdir" "$script" "$logdir" "$tag")"
  current="$(spl_desk_cron_line "$tag")"
  if [[ "$act" == check ]]; then
    spl_archive_suggest_cron_check "$tag" "$current" "$line" "$script"; return
  fi
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_desk_cron_diff "$tag" "$([[ "$act" == install ]] && printf '%s' "$line")"
    [[ "$act" == install ]] && spl_desk_cron_checkout_dry "$src" "$trunk"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi
  if [[ "$act" == remove ]]; then
    spl_desk_cron_write "$tag" "" || return 1
    do_log "OK the archive suggestion is out of the crontab"
    return 0
  fi
  spl_desk_cron_checkout "$src" "$trunk" || return 1
  [[ -r "$script" ]] || { do_log "FATAL $script is missing in $src"; return 1; }
  mkdir -p "$logdir" 2>/dev/null || { do_log "FATAL cannot create $logdir"; return 1; }
  spl_desk_cron_write "$tag" "$line" || return 1
  [[ "$(spl_desk_cron_line "$tag")" == "$line" ]] || { do_log "FATAL the crontab does not read back what was written"; return 1; }
  do_log "OK the archive suggestion runs hourly as $(id -un) (dry until lease.conf says ARCHIVE_SUGGEST_DRY_RUN=0):"
  spl_desk_cron_say "$line"
}

spl_archive_suggest_cron_check() {  # TAG CURRENT LINE SCRIPT
  if [[ -z "$2" ]]; then
    do_log "FAIL the archive suggestion is NOT installed (no line tagged $1)"
    return 1
  fi
  spl_desk_cron_say "$2"
  [[ -r "$4" ]] || { do_log "FAIL $4 is gone"; return 1; }
  [[ "$2" == "$3" ]] || do_log "INFO installed with other settings than this call would write - working"
  do_log "OK the archive suggestion is installed"
}
