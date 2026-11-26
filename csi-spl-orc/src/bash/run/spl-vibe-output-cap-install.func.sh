#!/bin/bash
#------------------------------------------------------------------------------
# @description Install the Mistral Vibe output cap (spool-install step Y15,
# @description SPL-2217) into the ~/.vibe of BOTH the box's agent user
# @description (SPOOL_AGENT_USER, else $SPOOL_ROOT/box.env) and the box user.
# @description A post_tool hook "spool-output-cap" on bash: a result longer
# @description than VIBE_OUTPUT_CAP_CHARS (4000) reaches the model as its
# @description return code, head and tail plus the path of the full log.
# @description Another user's home is written through sudo -n -u <user>. A
# @description user without ~/.vibe is skipped. Idempotent. Dry run unless
# @description DRY_RUN=0. A running vibe reads hooks.toml at session start.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param VIBE_OUTPUT_CAP_USERS (optional) - space-separated users, default "<agent user> <box user>"
# @example ./run -a do_spl_vibe_output_cap_install
# @example DRY_RUN=0 ./run -a do_spl_vibe_output_cap_install
#------------------------------------------------------------------------------
do_spl_vibe_output_cap_install() {
  local dry="${DRY_RUN:-1}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  do_require_bin python3 || return 1
  # shellcheck source=spl-git-pager-off-install.func.sh
  declare -F _spl_user_step_install >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-git-pager-off-install.func.sh" || return 1
  _spl_user_step_install "vibe output cap" \
    "$PROJ_PATH/src/bash/features/spool-install/steps/y15-vibe-output-cap.sh" \
    spool_install_vibe_output_cap "${VIBE_OUTPUT_CAP_USERS:-}" "$dry" "/.vibe"
}
