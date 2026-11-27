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
  _spl_memory_step_install "grok memory" \
    "$PROJ_PATH/src/bash/features/spool-install/steps/y18-grok-memory.sh" \
    spool_install_grok_memory "${GROK_MEMORY_USERS:-}" "${DRY_RUN:-1}" \
    "${GROK_MEMORY_REPO:-}" "GROK_MEMORY_REPO"
}

# _spl_memory_step_install <label> <step_file> <fn> <users_override> <dry> <repo_override> <repo_var>
# Validates DRY_RUN and <step_file>, derives the main worktree root when
# <repo_override> is empty, then delegates the per-user loop to
# _spl_user_step_install.
_spl_memory_step_install() {
  local label="$1" step="$2" fn="$3" users="$4" dry="$5" repo="$6" repo_var="$7"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ -r "$step" ]] || { do_log "FATAL the step $step is not readable"; return 1; }
  if [[ -z "$repo" ]]; then
    repo="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
      { do_log "FATAL cannot tell the repo of $PROJ_PATH (set $repo_var)"; return 1; }
    repo="$(dirname "$repo")"
  fi
  # shellcheck source=spl-git-pager-off-install.func.sh
  declare -F _spl_user_step_install >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-git-pager-off-install.func.sh" || return 1
  _spl_user_step_install "$label" "$step" "$fn" "$users" "$dry" "" "$repo"
}
