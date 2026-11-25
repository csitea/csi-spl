#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the Go build-cache prune cron:
# @description ONE line in the box user's crontab running
# @description src/bash/scripts/prune-go-build-cache-cron.sh every
# @description GO_CACHE_CRON_EVERY minutes (default 5). That script calls
# @description do_prune_go_build_cache with the gate on, so caches are pruned
# @description on the hourly tick and whenever the cache filesystem is at or
# @description over GO_CACHE_PRUNE_AT_PCT (default 85). Tagged
# @description `# <org>-<app>:go-cache-prune`, matched EXACTLY at the end of
# @description the line. Idempotent: the tagged line is replaced in place.
# @description It points at the self-updating checkout the desk reconcile uses
# @description (<shared checkout>-desk-cron). An agent worktree is refused.
# @description Dry run unless DRY_RUN=0 (prints the crontab diff).
# @param GO_CACHE_CRON_ACTION (optional) - install (default) | remove | check
# @param GO_CACHE_CRON_EVERY (optional) - minutes between ticks, default 5
# @param GO_CACHE_CRON_OFFSET (optional) - minute offset, default 0 (*/5)
# @param GO_CACHE_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/go-cache-prune
# @param DESK_CRON_SRC / DESK_CRON_SELF_UPDATE / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_setup_go_cache_prune_cron
# @example DRY_RUN=0 ./run -a do_setup_go_cache_prune_cron
# @example GO_CACHE_CRON_ACTION=check ./run -a do_setup_go_cache_prune_cron
#------------------------------------------------------------------------------
declare -F spl_desk_cron_update_pre >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-cron-lock.func.sh"
declare -F spl_desk_cron_render >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-desk-install-service.func.sh"
declare -F spl_desk_cron_checkout >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-cron-checkout.func.sh"

do_setup_go_cache_prune_cron() {
  do_require_bin crontab || return 1
  local act="${GO_CACHE_CRON_ACTION:-install}" every="${GO_CACHE_CRON_EVERY:-5}" off="${GO_CACHE_CRON_OFFSET:-0}"
  case "$act" in install|remove|check) ;; *) do_log "FATAL GO_CACHE_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  [[ "$every" =~ ^[0-9]+$ ]] && (( every >= 1 && every <= 59 )) || { do_log "FATAL GO_CACHE_CRON_EVERY must be 1..59 minutes, got: '$every'"; return 1; }
  [[ "$off" =~ ^[0-9]+$ ]] && (( off < every )) || { do_log "FATAL GO_CACHE_CRON_OFFSET must be 0..$((every - 1)), got: '$off'"; return 1; }
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"

  local tag src script logdir line ns sched pre="" trunk="${DESK_CRON_TRUNK:-master}"
  tag="$SPL_ORG_APP:go-cache-prune"
  spl_desk_cron_src || return 1
  src="$SPL_DESK_CRON_SRC"
  script="$src/$SPL_ORG_APP-orc/src/bash/scripts/prune-go-build-cache-cron.sh"
  logdir="${GO_CACHE_CRON_LOG_DIR:-}"
  if [[ -z "$logdir" ]]; then
    declare -F spl_var_app_subdir >/dev/null || source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../lib/bash/funcs/spl-run-paths.func.sh"
    spl_var_app_subdir logdir go-cache-prune || { do_log "FATAL cannot derive the go-cache prune cron log dir (no tree for spl_run_paths): set GO_CACHE_CRON_LOG_DIR"; return 1; }
  fi
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  if (( off == 0 )); then sched="*/$every"; else sched="$off-59/$every"; fi
  [[ "$SPL_DESK_CRON_SELF_UPDATE" == 1 ]] &&
    pre="$(spl_desk_cron_update_pre "$src" "$trunk")"
  ns="$(spl_cron_no_stack_pre "$src/$SPL_ORG_APP-orc" "$logdir/cron.lock")" || return 1
  line="$(printf '%s * * * * %s%s%s >> %s/cron.out 2>&1 # %s' "$sched" "$pre" "$ns" "$script" "$logdir" "$tag")"
  # shellcheck source=setup-box-stats-cron.func.sh
  declare -F _spl_simple_cron_apply >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/setup-box-stats-cron.func.sh"
  _spl_simple_cron_apply "$act" "$tag" "$src" "$trunk" "$script" "$logdir" "$line" \
    "go-cache prune" "ticks every ${every}m as the box user"
}
