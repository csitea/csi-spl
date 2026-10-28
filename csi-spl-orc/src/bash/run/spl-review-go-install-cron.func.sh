#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the review GO cron (spec 157
# @description Rule 1, row B4, SPL-4101): ONE line in the running user's
# @description crontab running `DRY_RUN=0 ./run -a do_spl_review_go` every
# @description minute, with a PATH that has /usr/local/bin and under flock -n.
# @description On every machine but the dispatch lease holder's the tick only
# @description logs that the lease is held elsewhere, so the line can sit on
# @description every machine and follows the dispatch role. The lease is read,
# @description never written. Run it as env.box.box_agent_user (spec 157 Rule
# @description 1 section 4): the user that reads the spool and the reviewers'
# @description session logs. Tagged `# <org>-<app>:review-go`, matched EXACTLY
# @description at the end of the line; idempotent. It runs from the same
# @description self-updating checkout as the desk reconcile (<shared
# @description checkout>-desk-cron, DESK_CRON_SRC overrides; an agent worktree
# @description is refused). Dry run unless DRY_RUN=0 (prints the crontab diff).
# @param REVIEW_GO_CRON_ACTION (optional) - install (default) | remove | check
# @param REVIEW_GO_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/review-go
# @param DESK_CRON_SRC / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_review_go_install_cron
# @example DRY_RUN=0 ./run -a do_spl_review_go_install_cron
# @example REVIEW_GO_CRON_ACTION=check ./run -a do_spl_review_go_install_cron
#------------------------------------------------------------------------------
declare -F spl_desk_cron_checkout >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-cron-checkout.func.sh"

do_spl_review_go_install_cron() {
  do_require_bin crontab || return 1
  local act="${REVIEW_GO_CRON_ACTION:-install}" tag src run logdir line current trunk="${DESK_CRON_TRUNK:-master}"
  case "$act" in install|remove|check) ;; *) do_log "FATAL REVIEW_GO_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"
  tag="$SPL_ORG_APP:review-go"
  DESK_CRON_SELF_UPDATE=0 spl_desk_cron_src || return 1
  src="$SPL_DESK_CRON_SRC"
  run="$src/$SPL_ORG_APP-orc/run"
  logdir="${REVIEW_GO_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/review-go}"
  # shellcheck disable=SC2016 # $HOME is for the cron shell, not this one
  line="$(printf '* * * * * cd %s && PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin flock -n %s/review-go.cron.lock env DRY_RUN=0 ./run -a do_spl_review_go >> %s/cron.out 2>&1 # %s' "${run%/run}" "$logdir" "$logdir" "$tag")"
  current="$(spl_desk_cron_line "$tag")"
  if [[ "$act" == check ]]; then
    spl_review_go_cron_check "$tag" "$current" "$line" "$run"; return
  fi
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_desk_cron_diff "$tag" "$([[ "$act" == install ]] && printf '%s' "$line")"
    [[ "$act" == install ]] && spl_desk_cron_checkout_dry "$src" "$trunk"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi
  if [[ "$act" == remove ]]; then
    spl_desk_cron_write "$tag" "" || return 1
    do_log "OK the review GO is out of the crontab"
    return 0
  fi
  spl_desk_cron_checkout "$src" "$trunk" || return 1
  [[ -x "$run" ]] || { do_log "FATAL $run is missing or not executable in $src"; return 1; }
  mkdir -p "$logdir" 2>/dev/null || { do_log "FATAL cannot create $logdir"; return 1; }
  spl_desk_cron_write "$tag" "$line" || return 1
  [[ "$(spl_desk_cron_line "$tag")" == "$line" ]] || { do_log "FATAL the crontab does not read back what was written"; return 1; }
  do_log "OK the review GO runs every minute as $(id -un) (it acts only while this machine holds the dispatch lease):"
  spl_desk_cron_say "$line"
}

spl_review_go_cron_check() {  # TAG CURRENT LINE RUN
  if [[ -z "$2" ]]; then
    do_log "FAIL the review GO is NOT installed (no line tagged $1): a review PASS waits for a model to send the GO"
    return 1
  fi
  spl_desk_cron_say "$2"
  [[ -x "$4" ]] || { do_log "FAIL $4 is gone or not executable"; return 1; }
  [[ "$2" == "$3" ]] || do_log "INFO installed with other settings than this call would write - working"
  do_log "OK the review GO is installed"
}
