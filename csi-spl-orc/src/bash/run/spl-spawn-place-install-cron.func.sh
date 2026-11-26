#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the spawn queue's placer (owner
# @description HUM-10, t1 c9beaa77; rdb 0180): ONE line in the box user's
# @description crontab running `./run -a do_spl_spawn_place` every minute, with a
# @description PATH that has /usr/local/bin (yq) and under flock -n. On
# @description every machine but the orch holder's the tick only logs that the
# @description role is held elsewhere, so the line can sit on every machine and
# @description the placer follows the orch role. Tagged
# @description `# <org>-<app>:spawn-place`, matched EXACTLY at the end of the
# @description line; idempotent. It runs from the same self-updating checkout as
# @description the desk reconcile (<shared checkout>-desk-cron, DESK_CRON_SRC
# @description overrides; an agent worktree is refused), which moves to trunk
# @description every 3 minutes, so the line itself does not self-update. Dry run
# @description unless DRY_RUN=0 (prints the crontab diff).
# @param SPAWN_PLACE_CRON_ACTION (optional) - install (default) | remove | check
# @param SPAWN_PLACE_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/spawn-place
# @param DESK_CRON_SRC / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_spawn_place_install_cron
# @example DRY_RUN=0 ./run -a do_spl_spawn_place_install_cron
# @example SPAWN_PLACE_CRON_ACTION=check ./run -a do_spl_spawn_place_install_cron
#------------------------------------------------------------------------------
declare -F spl_desk_cron_checkout >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-cron-checkout.func.sh"

do_spl_spawn_place_install_cron() {
  do_require_bin crontab || return 1
  local act="${SPAWN_PLACE_CRON_ACTION:-install}" tag src run logdir line trunk="${DESK_CRON_TRUNK:-master}"
  case "$act" in install|remove|check) ;; *) do_log "FATAL SPAWN_PLACE_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"
  tag="$SPL_ORG_APP:spawn-place"
  DESK_CRON_SELF_UPDATE=0 spl_desk_cron_src || return 1
  src="$SPL_DESK_CRON_SRC"
  run="$src/$SPL_ORG_APP-orc/run"
  logdir="${SPAWN_PLACE_CRON_LOG_DIR:-}"
  if [[ -z "$logdir" ]]; then
    declare -F spl_var_app_subdir >/dev/null || source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../lib/bash/funcs/spl-run-paths.func.sh"
    spl_var_app_subdir logdir spawn-place || { do_log "FATAL cannot derive the spawn placer cron log dir (no tree for spl_run_paths): set SPAWN_PLACE_CRON_LOG_DIR"; return 1; }
  fi
  # cron's own PATH (/usr/bin:/bin) has no yq: every tick read no cnf (c-001@sat, 10-12)
  # shellcheck disable=SC2016 # $HOME is for the cron shell, not this one
  line="$(printf '* * * * * cd %s && PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin flock -n %s/spawn-place.lock ./run -a do_spl_spawn_place >> %s/cron.out 2>&1 # %s' "${run%/run}" "$logdir" "$logdir" "$tag")"
  # shellcheck source=spl-spawn-fill-install-cron.func.sh
  declare -F _spl_run_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-spawn-fill-install-cron.func.sh"
  _spl_run_cron_apply "$act" "$tag" "$src" "$trunk" "$run" "$logdir" "$line" \
    "spawn placer" \
    "runs every minute as the box user (it acts only while this machine holds the orch role)" \
    ": queued spawn requests wait for a hand placement"
}
