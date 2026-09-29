#!/usr/bin/env bash
# restore-claude-plain.sh — re-attach an already-finished Claude session with NO work kick (its commits are on the trunk); an optional KICK_PROMPT is passed as is.
# The claude adapter of restore-core.inc.sh (specs/048, SPL-1160); the core
# documents what every restore does.
#
# Usage: restore-claude-plain.sh <TITLE> <RUNDIR> <SESSION_ID> [KICK_PROMPT]
set -uo pipefail
RESTORE_KIND=claude
RESTORE_ID_PREFIX=CLE
RESTORE_BIN_VAR=CLAUDE_BIN
RESTORE_KICK_FLAG=
RESTORE_KICK_MODE=prompt
restore_args() { printf "%s" "--resume $1 --permission-mode auto"; }
RESTORE_ARGS=restore_args
_rs_core="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/restore-core.inc.sh"
# shellcheck source=restore-core.inc.sh
. "$_rs_core" || { echo "ERROR: cannot load $_rs_core" >&2; exec bash; }
restore_main "$@"
