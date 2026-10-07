#!/usr/bin/env bash
# restore-grok.sh — resume an interrupted grok session (grok --resume <SESSION_ID>); RUNDIR must be the cwd it ran in, or grok does not find the session.
# The grok adapter of restore-core.inc.sh (specs/048, SPL-1160); the core
# documents what every restore does.
#
# Usage: restore-grok.sh <TITLE> <RUNDIR> <SESSION_ID> [KICK_PROMPT]
set -uo pipefail
RESTORE_KIND=grok
RESTORE_ID_PREFIX=GRK
RESTORE_BIN_VAR=GROK_BIN
RESTORE_KICK_FLAG=
RESTORE_KICK_MODE=prompt
restore_args() { printf "%s" "--resume $1"; }
RESTORE_ARGS=restore_args
_rs_core="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/restore-core.inc.sh"
# shellcheck source=restore-core.inc.sh
. "$_rs_core" || { echo "ERROR: cannot load $_rs_core" >&2; exec bash; }
restore_main "$@"
