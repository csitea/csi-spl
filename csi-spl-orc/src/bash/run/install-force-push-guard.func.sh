#!/bin/bash
#------------------------------------------------------------------------------
# @description Install the force-push block into claude, grok, agy and qwen
# @description for BOTH the box's agent user and its box user (owner order,
# @description t1 4e373f5d: nobody force-pushes master without his explicit
# @description approval). Runs spool-install step y13 in each home, as that
# @description user (sudo -n -u for the other one): the pre-tool hook plus
# @description deny rules of every harness with a config dir there, all on
# @description the one shared matcher spawn-agents/lib/force-push-guard.inc.sh.
# @description Idempotent. DRY RUN BY DEFAULT: DRY_RUN=0 writes.
# @param DRY_RUN (optional) - 1 prints the plan (default), 0 writes
# @param SPOOL_AGENT_USER (optional) - default from $SPOOL_ROOT/box.env
# @param SPOOL_BOX_USER (optional) - default the owner of $SPOOL_ROOT
# @param FORCE_PUSH_GUARD_HOMES (optional, tests) - space-separated homes, run
# @param FORCE_PUSH_GUARD_HOMES as THIS user instead of the two users above
# @example ./run -a do_install_force_push_guard
# @example DRY_RUN=0 ./run -a do_install_force_push_guard
#------------------------------------------------------------------------------
do_install_force_push_guard() {
  local step="$PROJ_PATH/src/bash/features/spool-install/steps/y13-force-push-guard.sh"
  local dry="${DRY_RUN:-1}" u h rc=0 users=() fn
  case "$dry" in 0|1) ;; *) do_log "FATAL DRY_RUN must be 0 or 1"; return 1 ;; esac
  [[ -r "$step" ]] || { do_log "FATAL no step $step"; return 1; }
  # shellcheck disable=SC2016  # expanded by the inner bash, per user
  fn='. "$1" && spool_install_force_push_guard "$2" "$2/.local/share/spool-agent" "$3" 1'
  if [[ -n "${FORCE_PUSH_GUARD_HOMES:-}" ]]; then
    for h in $FORCE_PUSH_GUARD_HOMES; do bash -c "$fn" _ "$step" "$h" "$dry" || rc=$?; done
  else
    # shellcheck source=spl-cmd-guard-mode.func.sh
    declare -F _spl_box_users_resolve >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-cmd-guard-mode.func.sh" || return 1
    _spl_box_users_resolve || return 1
    for u in "${users[@]}"; do
      local hrc=0
      _spl_box_user_home "$u" fail || hrc=$?
      (( hrc == 2 )) && { rc=1; continue; }
      (( hrc == 0 )) || return "$hrc"
      do_log "INFO force-push-guard for $u ($h)$([[ $dry == 1 ]] && echo ' - DRY RUN')"
      _spl_box_user_exec "$u" bash -c "$fn" _ "$step" "$h" "$dry" || rc=$?
    done
  fi
  (( rc == 0 )) || { do_log "FAIL force-push-guard install exited $rc"; return "$rc"; }
  do_log "OK force-push-guard $([[ $dry == 1 ]] && echo 'planned (DRY_RUN=0 writes)' || echo installed)"
}
