#!/bin/bash
#------------------------------------------------------------------------------
# @description Install the Mistral Vibe push guard (spool-install step Y12,
# @description owner order t1 4e373f5d: nobody force-pushes master without
# @description the owner's explicit approval) into the ~/.vibe of BOTH the
# @description box's agent user (SPOOL_AGENT_USER, else $SPOOL_ROOT/box.env)
# @description and the box user (the user running ./run). Each gets a copy
# @description of the guard + the shared matcher in ~/.vibe/spool-push-guard/
# @description and one strict pre_tool [[hooks]] entry "spool-push-guard" in
# @description ~/.vibe/hooks.toml; every other entry is kept. Another user's
# @description home is written through sudo -n -u <user>. A user without
# @description ~/.vibe is skipped. Idempotent. Dry run unless DRY_RUN=0.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param VIBE_PUSH_GUARD_USERS (optional) - space-separated users, default "<agent user> <box user>"
# @example ./run -a do_spl_vibe_push_guard_install
# @example DRY_RUN=0 ./run -a do_spl_vibe_push_guard_install
#------------------------------------------------------------------------------
do_spl_vibe_push_guard_install() {
  local dry="${DRY_RUN:-1}" me agent f users u home step seen=" " rc=0
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  do_require_bin python3 || return 1
  step="$PROJ_PATH/src/bash/features/spool-install/steps/y12-vibe-push-guard.sh"
  [[ -r "$step" ]] || { do_log "FATAL the step $step is not readable"; return 1; }
  me="$(id -un)"
  agent="${SPOOL_AGENT_USER:-}"
  f="${SPOOL_BOX_ENV:-${SPOOL_ROOT:-/var/spool-hub}/box.env}"
  if [[ -z "$agent" && -r "$f" ]]; then
    agent="$(sed -n 's/^SPOOL_AGENT_USER=//p' "$f" | tail -1 | tr -d "\"'\r")"
  fi
  users="${VIBE_PUSH_GUARD_USERS:-$agent $me}"
  for u in $users; do
    [[ "$seen" == *" $u "* ]] && continue
    seen+="$u "
    home="$(getent passwd "$u" | cut -d: -f6)"
    [[ -n "$home" ]] || { do_log "ERROR no passwd entry for $u"; rc=1; continue; }
    do_log "INFO vibe push guard: $u ($home/.vibe), DRY_RUN=$dry"
    if [[ "$u" == "$me" ]]; then
      bash -c '. "$1" && spool_install_vibe_push_guard "$2" "$3"' _ "$step" "$home/.vibe" "$dry" || rc=1
    else
      sudo -n -u "$u" bash -c '. "$1" && spool_install_vibe_push_guard "$2" "$3"' _ "$step" "$home/.vibe" "$dry" || rc=1
    fi
  done
  [[ "$rc" == 0 ]] && do_log "OK vibe push guard: $users (DRY_RUN=$dry)"
  return "$rc"
}
