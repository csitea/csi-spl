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
    # shellcheck source=../features/spawn-agents/lib/spool-env.inc.sh
    source "$PROJ_PATH/src/bash/features/spawn-agents/lib/spool-env.inc.sh" || return 1
    SPOOL_ENV_NO_BINS=1 spool_env_resolve >/dev/null 2>&1
    users=("${SPOOL_AGENT_USER:-}")
    [[ "${SPOOL_BOX_USER:-}" != "${SPOOL_AGENT_USER:-}" ]] && users+=("${SPOOL_BOX_USER:-}")
    for u in "${users[@]}"; do
      [[ -n "$u" ]] || { do_log "FATAL no agent / box user: set SPOOL_AGENT_USER and SPOOL_BOX_USER"; return 1; }
      h="$(getent passwd "$u" | cut -d: -f6)"
      [[ -d "$h" ]] || { do_log "FAIL no home for $u"; rc=1; continue; }
      do_log "INFO force-push-guard for $u ($h)$([[ $dry == 1 ]] && echo ' - DRY RUN')"
      if [[ "$(id -un)" == "$u" ]]; then bash -c "$fn" _ "$step" "$h" "$dry" || rc=$?
      else sudo -n -u "$u" -H bash -c "$fn" _ "$step" "$h" "$dry" || rc=$?
      fi
    done
  fi
  (( rc == 0 )) || { do_log "FAIL force-push-guard install exited $rc"; return "$rc"; }
  do_log "OK force-push-guard $([[ $dry == 1 ]] && echo 'planned (DRY_RUN=0 writes)' || echo installed)"
}
