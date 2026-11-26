#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the accepted-close cron (spec 157
# @description Rule 2, row B5, SPL-4102): ONE line in the running user's
# @description crontab running `DRY_RUN=0 ./run -a do_spl_accepted_close`
# @description every minute, with a PATH that has /usr/local/bin and
# @description ~/.local/bin (gh) and under flock -n. On every machine but the
# @description dispatch lease holder's the tick only logs that the lease is
# @description held elsewhere, so the line can sit on every machine and follows
# @description the dispatch role. The lease is read, never written. Run it as
# @description env.box.box_agent_user (spec 157 Rule 2 section 5): the user
# @description that owns the lane worktrees and reads the spool. Tagged
# @description `# <org>-<app>:accepted-close`, matched EXACTLY at the end of the
# @description line; idempotent. It runs from the same self-updating checkout as
# @description the desk reconcile (<shared checkout>-desk-cron, DESK_CRON_SRC
# @description overrides; an agent worktree is refused). Dry run unless
# @description DRY_RUN=0 (prints the crontab diff).
# @param ACCEPT_CRON_ACTION (optional) - install (default) | remove | check
# @param ACCEPT_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/accepted-close
# @param DESK_CRON_SRC / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_accepted_close_install_cron
# @example DRY_RUN=0 ./run -a do_spl_accepted_close_install_cron
# @example ACCEPT_CRON_ACTION=check ./run -a do_spl_accepted_close_install_cron
#------------------------------------------------------------------------------
declare -F spl_desk_cron_checkout >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-cron-checkout.func.sh"

do_spl_accepted_close_install_cron() {
  do_require_bin crontab || return 1
  local act="${ACCEPT_CRON_ACTION:-install}" tag src run logdir line trunk="${DESK_CRON_TRUNK:-master}"
  case "$act" in install|remove|check) ;; *) do_log "FATAL ACCEPT_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"
  tag="$SPL_ORG_APP:accepted-close"
  DESK_CRON_SELF_UPDATE=0 spl_desk_cron_src || return 1
  src="$SPL_DESK_CRON_SRC"
  run="$src/$SPL_ORG_APP-orc/run"
  logdir="${ACCEPT_CRON_LOG_DIR:-}"
  if [[ -z "$logdir" ]]; then
    declare -F spl_var_app_subdir >/dev/null || source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../lib/bash/funcs/spl-run-paths.func.sh"
    spl_var_app_subdir logdir accepted-close || { do_log "FATAL cannot derive the accepted close cron log dir (no tree for spl_run_paths): set ACCEPT_CRON_LOG_DIR"; return 1; }
  fi
  # cron's own PATH (/usr/bin:/bin) has neither gh nor yq
  # shellcheck disable=SC2016 # $HOME is for the cron shell, not this one
  line="$(printf '* * * * * cd %s && PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin flock -n %s/accepted-close.cron.lock env DRY_RUN=0 ./run -a do_spl_accepted_close >> %s/cron.out 2>&1 # %s' "${run%/run}" "$logdir" "$logdir" "$tag")"
  # shellcheck source=spl-spawn-fill-install-cron.func.sh
  declare -F _spl_run_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-spawn-fill-install-cron.func.sh"
  _spl_run_cron_apply "$act" "$tag" "$src" "$trunk" "$run" "$logdir" "$line" \
    "accepted close" \
    "runs every minute as $(id -un) (it acts only while this machine holds the dispatch lease)" \
    ": a landed, reviewed lane waits for a model to send its ACCEPTED"
}
