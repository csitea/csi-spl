#!/usr/bin/env bash
# restore-agy.sh — resume an interrupted agy conversation (agy --conversation <ID>; there is no --resume).
# The agy adapter of restore-core.inc.sh (specs/048, SPL-1160); the core
# documents what every restore does.
#
# Usage: restore-agy.sh <TITLE> <RUNDIR> <SESSION_ID> [KICK_PROMPT]
set -uo pipefail
RESTORE_KIND=agy
RESTORE_ID_PREFIX=AGY
RESTORE_BIN_VAR=AGY_BIN
RESTORE_KICK_FLAG=--prompt-interactive
RESTORE_KICK_MODE=prompt
restore_args() { printf "%s" "--conversation $1"; }
RESTORE_ARGS=restore_args
_rs_core="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/restore-core.inc.sh"
# shellcheck source=restore-core.inc.sh
. "$_rs_core" || { echo "ERROR: cannot load $_rs_core" >&2; exec bash; }
restore_main "$@"
