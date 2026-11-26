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
  local act="${ARCHIVE_SUGGEST_CRON_ACTION:-install}" tag src script logdir line trunk="${DESK_CRON_TRUNK:-master}"
  case "$act" in install|remove|check) ;; *) do_log "FATAL ARCHIVE_SUGGEST_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"
  tag="$SPL_ORG_APP:topic-archive-suggest"
  DESK_CRON_SELF_UPDATE=0 spl_desk_cron_src || return 1
  src="$SPL_DESK_CRON_SRC"
  script="$src/$SPL_ORG_APP-orc/src/bash/scripts/topic-archive-suggest-cron.sh"
  logdir="${ARCHIVE_SUGGEST_CRON_LOG_DIR:-}"
  if [[ -z "$logdir" ]]; then
    declare -F spl_var_app_subdir >/dev/null || source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../lib/bash/funcs/spl-run-paths.func.sh"
    spl_var_app_subdir logdir topic-archive-suggest || { do_log "FATAL cannot derive the topic archive suggest cron log dir (no tree for spl_run_paths): set ARCHIVE_SUGGEST_CRON_LOG_DIR"; return 1; }
  fi
  line="$(printf '17 * * * * flock -n %s/topic-archive-suggest.cron.lock /bin/bash %s >> %s/cron.log 2>&1 # %s' "$logdir" "$script" "$logdir" "$tag")"
  # shellcheck source=spl-spawn-fill-install-cron.func.sh
  declare -F _spl_run_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-spawn-fill-install-cron.func.sh"
  _spl_run_cron_apply "$act" "$tag" "$src" "$trunk" "$script" "$logdir" "$line" \
    "archive suggestion" \
    "runs hourly as $(id -un) (dry until lease.conf says ARCHIVE_SUGGEST_DRY_RUN=0)" \
    "" r
}
