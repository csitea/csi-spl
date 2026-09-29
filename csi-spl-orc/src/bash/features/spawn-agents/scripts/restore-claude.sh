#!/usr/bin/env bash
# restore-claude.sh — resume an interrupted Claude worker in the worktree it ran in, with a re-orientation kick (a worker gets its closing steps; an orchestrator or a non-lane dir gets no git step).
# The claude adapter of restore-core.inc.sh (specs/048, SPL-1160); the core
# documents what every restore does.
#
# Usage: restore-claude.sh <TITLE> <RUNDIR> <SESSION_ID> [BRIEF_FILE]
set -uo pipefail
RESTORE_KIND=claude
RESTORE_ID_PREFIX=CLE
RESTORE_BIN_VAR=CLAUDE_BIN
RESTORE_KICK_FLAG=
RESTORE_KICK_MODE=brief
restore_args() { printf "%s" "--resume $1 --permission-mode auto"; }
RESTORE_ARGS=restore_args
_rs_core="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/restore-core.inc.sh"
# shellcheck source=restore-core.inc.sh
. "$_rs_core" || { echo "ERROR: cannot load $_rs_core" >&2; exec bash; }
restore_main "$@"
