#!/usr/bin/env bash
# spawn-agy.sh — invoked as a tmux window's command: runs the antigravity CLI (agy) as the agent
# user, in its own worktree (or WORKDIR), from a task brief, speaking the spool.
#
# The agy ADAPTER of the launcher core, spawn-core.inc.sh: this file declares
# only what is agy-specific. Forked from the box engine's adapter.
#
# Usage: spawn-agy.sh <TITLE> <WORKDIR> [BRIEF_FILE] [SLUG]
#   TITLE is a spool agent id with the AGY- prefix, e.g. AGY-07.
#   SPAWN_DRY_RUN=1 prints the plan instead of launching.
set -uo pipefail
SPAWN_ADAPTER="${BASH_SOURCE[0]}"
SPAWN_KIND=agy
SPAWN_ID_PREFIX=AGY
SPAWN_BIN_VAR=AGY_BIN
SPAWN_NAME_FLAG=
SPAWN_PROMPT_FLAG=--prompt-interactive
SPAWN_RESUME_FLAG=--conversation
SPAWN_RESUME_ID=CONVERSATION_ID
SPAWN_CONTINUE_FLAG=--continue
spawn_rename_how() {
  # $SLUG is embedded already escaped for a double-quoted argument, so the
  # agent copy-pastes a command that cannot run $(...) from the title.
  local desc_esc
  spool_dq_escape desc_esc "${SLUG:-}"
  printf '%s' "retitle your tmux window to the shortest possible description of the work you are about to implement (2-5 words) by running: bash ${_SP_DIR}/riname.sh --agent ${TITLE} \"${desc_esc}\" (agy cannot name its own session)"
}
_sp_core="$(dirname "$(readlink -f "$SPAWN_ADAPTER")")/spawn-core.inc.sh"
# shellcheck source=spawn-core.inc.sh
. "$_sp_core" || { echo "ERROR: cannot load $_sp_core" >&2; exec env HISTSIZE=-1 HISTFILESIZE=-1 BASHOPTS=histappend bash --norc; }
# spec 184 section 10 (SPL-6661): agy's own alternative model when its Gemini
# quota is low; nothing at all while cnf agy_fallback.enabled is not true.
# shellcheck source=../lib/agy-fallback.inc.sh disable=SC2034 # SPAWN_EXTRA_FLAGS is read by the core
. "$(dirname "$_sp_core")/../lib/agy-fallback.inc.sh" && SPAWN_EXTRA_FLAGS="$(spool_agy_fallback_flags "${1:-}" "${3:-}")"
spawn_main "$@"
