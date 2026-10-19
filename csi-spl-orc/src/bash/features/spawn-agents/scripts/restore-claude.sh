#!/usr/bin/env bash
# restore-claude.sh — resume an interrupted Claude worker in the worktree it ran in, with a re-orientation kick (a worker gets its closing steps; an orchestrator or a non-lane dir gets no git step).
# The claude adapter of restore-core.inc.sh (specs/048, SPL-1160); the core
# documents what every restore does.
#
# A role seat with no recorded session gets SESSION_ID - : a NEW claude session,
# kicked to its role handoff (RESTORE_SID_FRESH, SPL-2638).
#
# Usage: restore-claude.sh <TITLE> <RUNDIR> <SESSION_ID|-> [BRIEF_FILE]
set -uo pipefail
RESTORE_KIND=claude
RESTORE_ID_PREFIX=CLE
RESTORE_BIN_VAR=CLAUDE_BIN
RESTORE_KICK_FLAG=
RESTORE_KICK_MODE=brief
# shellcheck disable=SC2034  # read by restore-core.inc.sh
RESTORE_SID_FRESH=1
restore_args() { if [ -n "$1" ]; then printf "%s" "--resume $1"; fi; }
RESTORE_ARGS=restore_args
_rs_core="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/restore-core.inc.sh"
# shellcheck source=restore-core.inc.sh
. "$_rs_core" || { echo "ERROR: cannot load $_rs_core" >&2; exec bash --norc; }
restore_main "$@"
