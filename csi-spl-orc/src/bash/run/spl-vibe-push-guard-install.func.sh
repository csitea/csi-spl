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
  local dry="${DRY_RUN:-1}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  do_require_bin python3 || return 1
  # shellcheck source=spl-git-pager-off-install.func.sh
  declare -F _spl_user_step_install >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-git-pager-off-install.func.sh" || return 1
  _spl_user_step_install "vibe push guard" \
    "$PROJ_PATH/src/bash/features/spool-install/steps/y12-vibe-push-guard.sh" \
    spool_install_vibe_push_guard "${VIBE_PUSH_GUARD_USERS:-}" "$dry" "/.vibe"
}
