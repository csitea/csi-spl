#!/usr/bin/env bash
# spawn-claude.sh — invoked as a tmux window's command: runs Claude Code as the agent
# user, in its own worktree (or WORKDIR), from a task brief, speaking the spool.
#
# The claude ADAPTER of the launcher core, spawn-core.inc.sh: this file declares
# only what is claude-specific. Forked from the box engine's adapter.
#
# Usage: spawn-claude.sh <TITLE> <WORKDIR> [BRIEF_FILE] [SLUG]
#   TITLE is a spool agent id with the CLE- prefix, e.g. CLE-07.
#   SPAWN_DRY_RUN=1 prints the plan instead of launching.
set -uo pipefail
SPAWN_ADAPTER="${BASH_SOURCE[0]}"
SPAWN_KIND=claude
SPAWN_ID_PREFIX=CLE
SPAWN_BIN_VAR=CLAUDE_BIN
SPAWN_NAME_FLAG=--name
SPAWN_PROMPT_FLAG=
SPAWN_PERM_FLAGS=--dangerously-skip-permissions
SPAWN_RESUME_FLAG=--resume
SPAWN_RESUME_ID=SESSION_ID
SPAWN_CONTINUE_FLAG=--continue
spawn_rename_how() {
  printf '%s' "run the /rename slash command to retitle this session to the shortest possible description of the work you are about to implement (2-5 words)"
}
_sp_core="$(dirname "$(readlink -f "$SPAWN_ADAPTER")")/spawn-core.inc.sh"
# shellcheck source=spawn-core.inc.sh
. "$_sp_core" || { echo "ERROR: cannot load $_sp_core" >&2; exec bash; }
spawn_main "$@"
