#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the poll acknowledgement cron
# @description (spec 157 Rule 5, row B3, SPL-4093): ONE line in the running
# @description user's crontab running `DRY_RUN=0 ./run -a do_spl_desk_poll_ack`
# @description every minute, with a PATH that has /usr/local/bin (yq) and under
# @description flock -n. On every machine but the dispatch lease holder's the
# @description tick only logs that the lease is held elsewhere, so the line can
# @description sit on every machine and follows the dispatch role. The lease is
# @description read, never written. Run it as the user that owns the desks
# @description (the user that runs do_spl_desk_up): the action reads the
# @description holder's desk spools under that user's state dir. Tagged
# @description `# <org>-<app>:poll-ack`, matched EXACTLY at the end of the line;
# @description idempotent. It runs from the same self-updating checkout as the
# @description desk reconcile (<shared checkout>-desk-cron, DESK_CRON_SRC
# @description overrides; an agent worktree is refused). Dry run unless
# @description DRY_RUN=0 (prints the crontab diff).
# @param POLL_ACK_CRON_ACTION (optional) - install (default) | remove | check
# @param POLL_ACK_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/poll-ack
# @param DESK_CRON_SRC / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_desk_poll_ack_install_cron
# @example DRY_RUN=0 ./run -a do_spl_desk_poll_ack_install_cron
# @example POLL_ACK_CRON_ACTION=check ./run -a do_spl_desk_poll_ack_install_cron
#------------------------------------------------------------------------------
declare -F spl_desk_cron_checkout >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-cron-checkout.func.sh"

do_spl_desk_poll_ack_install_cron() {
  do_require_bin crontab || return 1
  local act="${POLL_ACK_CRON_ACTION:-install}" tag src run logdir line current trunk="${DESK_CRON_TRUNK:-master}"
  case "$act" in install|remove|check) ;; *) do_log "FATAL POLL_ACK_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"
  tag="$SPL_ORG_APP:poll-ack"
  DESK_CRON_SELF_UPDATE=0 spl_desk_cron_src || return 1
  src="$SPL_DESK_CRON_SRC"
  run="$src/$SPL_ORG_APP-orc/run"
  logdir="${POLL_ACK_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/poll-ack}"
  # cron's own PATH (/usr/bin:/bin) has no yq, and do_spl_desk_cnf reads the cnf with it
  # shellcheck disable=SC2016 # $HOME is for the cron shell, not this one
  line="$(printf '* * * * * cd %s && PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin flock -n %s/poll-ack.cron.lock env DRY_RUN=0 ./run -a do_spl_desk_poll_ack >> %s/cron.out 2>&1 # %s' "${run%/run}" "$logdir" "$logdir" "$tag")"
  current="$(spl_desk_cron_line "$tag")"
  if [[ "$act" == check ]]; then
    spl_poll_ack_cron_check "$tag" "$current" "$line" "$run"; return
  fi
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_desk_cron_diff "$tag" "$([[ "$act" == install ]] && printf '%s' "$line")"
    [[ "$act" == install ]] && spl_desk_cron_checkout_dry "$src" "$trunk"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi
  if [[ "$act" == remove ]]; then
    spl_desk_cron_write "$tag" "" || return 1
    do_log "OK the poll acknowledgement is out of the crontab"
    return 0
  fi
  spl_desk_cron_checkout "$src" "$trunk" || return 1
  [[ -x "$run" ]] || { do_log "FATAL $run is missing or not executable in $src"; return 1; }
  mkdir -p "$logdir" 2>/dev/null || { do_log "FATAL cannot create $logdir"; return 1; }
  spl_desk_cron_write "$tag" "$line" || return 1
  [[ "$(spl_desk_cron_line "$tag")" == "$line" ]] || { do_log "FATAL the crontab does not read back what was written"; return 1; }
  do_log "OK the poll acknowledgement runs every minute as $(id -un) (it acts only while this machine holds the dispatch lease):"
  spl_desk_cron_say "$line"
}

spl_poll_ack_cron_check() {  # TAG CURRENT LINE RUN
  if [[ -z "$2" ]]; then
    do_log "FAIL the poll acknowledgement is NOT installed (no line tagged $1): an owner poll answer waits for a model to notice it"
    return 1
  fi
  spl_desk_cron_say "$2"
  [[ -x "$4" ]] || { do_log "FAIL $4 is gone or not executable"; return 1; }
  [[ "$2" == "$3" ]] || do_log "INFO installed with other settings than this call would write - working"
  do_log "OK the poll acknowledgement is installed"
}
