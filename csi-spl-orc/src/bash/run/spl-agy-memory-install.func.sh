#!/bin/bash
#------------------------------------------------------------------------------
# @description agy sessions load the fleet lessons claude keeps in its
# @description auto-memory, only those on the box's allow-list agy-allow.list
# @description beside MEMORY.md, no list = no index (the data rule, spool-install
# @description step Y20, SPL-4911, spec 048 section 5.3): two home rules
# @description in ~/.gemini/config/rules of BOTH the box's agent user (SPOOL_AGENT_USER,
# @description else $SPOOL_ROOT/box.env) and the box user (the user running
# @description this), a header and an index generated from that user's claude
# @description MEMORY.md of the repo. A user without ~/.gemini
# @description or without that memory is skipped and named. Another user's
# @description home is written through sudo -n -u <user>. Idempotent. Dry run
# @description unless DRY_RUN=0.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param AGY_MEMORY_USERS (optional) - space-separated users, default "<agent user> <box user>"
# @param AGY_MEMORY_REPO (optional) - the repo whose claude memory agy loads, default the main worktree of this checkout
# @example ./run -a do_spl_agy_memory_install
# @example DRY_RUN=0 ./run -a do_spl_agy_memory_install
#------------------------------------------------------------------------------
do_spl_agy_memory_install() {
  # shellcheck source=spl-grok-memory-install.func.sh
  declare -F _spl_memory_step_install >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-grok-memory-install.func.sh" || return 1
  _spl_memory_step_install "agy memory" \
    "$PROJ_PATH/src/bash/features/spool-install/steps/y20-agy-memory.sh" \
    spool_install_agy_memory "${AGY_MEMORY_USERS:-}" "${DRY_RUN:-1}" \
    "${AGY_MEMORY_REPO:-}" "AGY_MEMORY_REPO"
}
