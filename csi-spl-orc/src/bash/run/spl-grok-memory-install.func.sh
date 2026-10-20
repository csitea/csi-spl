#!/bin/bash
#------------------------------------------------------------------------------
# @description grok sessions load the fleet lessons claude keeps in its
# @description auto-memory (spool-install step Y18, SPL-2738): two home rules
# @description in ~/.grok/rules of BOTH the box's agent user (SPOOL_AGENT_USER,
# @description else $SPOOL_ROOT/box.env) and the box user (the user running
# @description this), a header and a symlink to that user's claude MEMORY.md
# @description of the repo. No memory text is copied. A user without ~/.grok
# @description or without that memory is skipped and named. Another user's
# @description home is written through sudo -n -u <user>. Idempotent. Dry run
# @description unless DRY_RUN=0.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param GROK_MEMORY_USERS (optional) - space-separated users, default "<agent user> <box user>"
# @param GROK_MEMORY_REPO (optional) - the repo whose claude memory grok loads, default the main worktree of this checkout
# @example ./run -a do_spl_grok_memory_install
# @example DRY_RUN=0 ./run -a do_spl_grok_memory_install
#------------------------------------------------------------------------------
do_spl_grok_memory_install() {
  local dry="${DRY_RUN:-1}" me agent f users u home step repo seen=" " rc=0
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  step="$PROJ_PATH/src/bash/features/spool-install/steps/y18-grok-memory.sh"
  [[ -r "$step" ]] || { do_log "FATAL the step $step is not readable"; return 1; }
  repo="${GROK_MEMORY_REPO:-}"
  if [[ -z "$repo" ]]; then
    repo="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
      { do_log "FATAL cannot tell the repo of $PROJ_PATH (set GROK_MEMORY_REPO)"; return 1; }
    repo="$(dirname "$repo")"
  fi
  me="$(id -un)"
  agent="${SPOOL_AGENT_USER:-}"
  f="${SPOOL_BOX_ENV:-${SPOOL_ROOT:-/var/spool-hub}/box.env}"
  if [[ -z "$agent" && -r "$f" ]]; then
    agent="$(sed -n 's/^SPOOL_AGENT_USER=//p' "$f" | tail -1 | tr -d "\"'\r")"
  fi
  users="${GROK_MEMORY_USERS:-$agent $me}"
  for u in $users; do
    [[ "$seen" == *" $u "* ]] && continue
    seen+="$u "
    home="$(getent passwd "$u" | cut -d: -f6)"
    [[ -n "$home" ]] || { do_log "ERROR no passwd entry for $u"; rc=1; continue; }
    do_log "INFO grok memory: $u ($home), repo $repo, DRY_RUN=$dry"
    if [[ "$u" == "$me" ]]; then
      bash -c '. "$1" && spool_install_grok_memory "$2" "$3" "$4"' _ "$step" "$home" "$dry" "$repo" || rc=1
    else
      sudo -n -u "$u" bash -c '. "$1" && spool_install_grok_memory "$2" "$3" "$4"' _ "$step" "$home" "$dry" "$repo" || rc=1
    fi
  done
  [[ "$rc" == 0 ]] && do_log "OK grok memory: $users (DRY_RUN=$dry)"
  return "$rc"
}
