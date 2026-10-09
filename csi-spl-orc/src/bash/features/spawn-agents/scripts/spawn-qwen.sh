#!/usr/bin/env bash
# spawn-qwen.sh — invoked as a tmux window's command: runs the Qwen Code CLI (qwen) as the
# agent user, in its own worktree (or WORKDIR), from a task brief, speaking the spool.
#
# The qwen ADAPTER of the launcher core, spawn-core.inc.sh: this file declares
# only what is qwen-specific (specs/048-agent-harness-parity §3.4).
#
# Authentication is NOT the launcher's business: qwen reads it from the agent
# user's own <home>/.qwen/settings.json and <home>/.qwen/.env, set once by a
# human. No key ever travels on this command line, where ps would show it.
#
# Usage: spawn-qwen.sh <TITLE> <WORKDIR> [BRIEF_FILE] [SLUG]
#   TITLE is a spool agent id with the QWN- prefix, e.g. QWN-07.
#   SPAWN_DRY_RUN=1 prints the plan instead of launching.
set -uo pipefail
SPAWN_ADAPTER="${BASH_SOURCE[0]}"
SPAWN_KIND=qwen
SPAWN_ID_PREFIX=QWN
SPAWN_BIN_VAR=QWEN_BIN
# qwen cannot NAME a session (--session-id takes a UUID only), so the tmux
# window alone carries the name, as for grok and agy.
SPAWN_NAME_FLAG=
# A bare positional prompt is ONE-SHOT (qwen answers and exits):
# --prompt-interactive runs it and keeps the TUI up.
SPAWN_PROMPT_FLAG=--prompt-interactive
SPAWN_RESUME_FLAG=--resume
SPAWN_RESUME_ID=SESSION_ID
SPAWN_CONTINUE_FLAG=--continue
spawn_rename_how() {
  # $SLUG is embedded already escaped for a double-quoted argument, so the
  # agent copy-pastes a command that cannot run $(...) from the title.
  local desc_esc
  spool_dq_escape desc_esc "${SLUG:-}"
  printf '%s' "retitle your tmux window to the shortest possible description of the work you are about to implement (2-5 words) by running: bash ${_SP_DIR}/riname.sh --agent ${TITLE} \"${desc_esc}\" (qwen cannot name its own session)"
}
_sp_core="$(dirname "$(readlink -f "$SPAWN_ADAPTER")")/spawn-core.inc.sh"
# shellcheck source=spawn-core.inc.sh
. "$_sp_core" || { echo "ERROR: cannot load $_sp_core" >&2; exec bash; }
spawn_main "$@"
