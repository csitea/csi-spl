#!/usr/bin/env bash
# restore-qwen.sh — resume an interrupted qwen session (qwen --resume <SESSION_ID>); --prompt-interactive keeps the TUI up after a kick.
# The qwen adapter of restore-core.inc.sh (specs/048, SPL-1160); the core
# documents what every restore does.
#
# Usage: restore-qwen.sh <TITLE> <RUNDIR> <SESSION_ID> [KICK_PROMPT]
set -uo pipefail
RESTORE_KIND=qwen
RESTORE_ID_PREFIX=QWN
RESTORE_BIN_VAR=QWEN_BIN
RESTORE_KICK_FLAG=--prompt-interactive
RESTORE_KICK_MODE=prompt
# qwen's own files (~/.qwen state) are created owner-only (SPL-1999).
# shellcheck disable=SC2034  # read by restore-core.inc.sh
RESTORE_UMASK=077
restore_args() { printf "%s" "--resume $1"; }
RESTORE_ARGS=restore_args
_rs_core="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/restore-core.inc.sh"
# shellcheck source=restore-core.inc.sh
. "$_rs_core" || { echo "ERROR: cannot load $_rs_core" >&2; exec bash --norc; }
restore_main "$@"
