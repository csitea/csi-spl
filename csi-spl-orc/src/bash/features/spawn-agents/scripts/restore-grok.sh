#!/usr/bin/env bash
# restore-grok.sh — resume an interrupted grok session (grok --resume <SESSION_ID>); RUNDIR must be the cwd it ran in, or grok does not find the session.
# The grok adapter of restore-core.inc.sh (specs/048, SPL-1160); the core
# documents what every restore does.
#
# A role seat with no recorded session gets SESSION_ID - : a NEW grok session,
# kicked to its role handoff (RESTORE_SID_FRESH, SPL-2638).
#
# Usage: restore-grok.sh <TITLE> <RUNDIR> <SESSION_ID|-> [KICK_PROMPT]
set -uo pipefail
RESTORE_KIND=grok
RESTORE_ID_PREFIX=GRK
RESTORE_BIN_VAR=GROK_BIN
RESTORE_KICK_FLAG=
RESTORE_KICK_MODE=prompt
# shellcheck disable=SC2034  # read by restore-core.inc.sh
RESTORE_SID_FRESH=1
restore_args() { if [ -n "$1" ]; then printf "%s" "--resume $1"; fi; }
RESTORE_ARGS=restore_args
_rs_core="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/restore-core.inc.sh"
# shellcheck source=restore-core.inc.sh
. "$_rs_core" || { echo "ERROR: cannot load $_rs_core" >&2; exec env HISTSIZE=-1 HISTFILESIZE=-1 BASHOPTS=histappend bash --norc; }
restore_main "$@"
