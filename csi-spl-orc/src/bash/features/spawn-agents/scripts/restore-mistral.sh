#!/usr/bin/env bash
# restore-mistral.sh — resume an interrupted mistral session (vibe --resume <SESSION_ID>), or,
# with no session id ('' or '-'), the last session in RUNDIR (vibe --continue).
# The mistral adapter of restore-core.inc.sh (specs/110 3.3, T007), the twin of
# restore-qwen.sh; the core documents what every restore does.
#
# The launch words are spawn-mistral.sh's, read from that file rather than
# copied (specs/110 T005): its SPAWN_EXEC_PREFIX (env -u MISTRAL_API_KEY and the
# VIBE_* off switches) and its cnf --max-price cap, so a restored lane runs
# under exactly the line it was spawned with.
#
# vibe renames its process to "Vibe CLI" (comm and cmdline): match a live m-
# lane by SPOOL_AGENT_ID in its environ, never by the name vibe.
#
# Usage: restore-mistral.sh <TITLE> <RUNDIR> [SESSION_ID|-] [KICK_PROMPT]
#   SPOOL_MISTRAL_MAX_PRICE overrides cnf env.box.mistral_vibe.max_price.
# shellcheck disable=SC2034  # the RESTORE_* declarations are read by restore-core.inc.sh
set -uo pipefail
RESTORE_KIND=mistral
RESTORE_ID_PREFIX=
RESTORE_BIN_VAR=MISTRAL_BIN
RESTORE_KICK_FLAG=
RESTORE_KICK_MODE=prompt
RESTORE_SID_OPTIONAL=1
restore_args() { if [ -n "$1" ]; then printf "%s" "--resume $1"; else printf "%s" "--continue"; fi; }
RESTORE_ARGS=restore_args
_rs_here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
_rs_core="$_rs_here/restore-core.inc.sh"
# shellcheck source=restore-core.inc.sh
. "$_rs_core" || { echo "ERROR: cannot load $_rs_core" >&2; exec bash; }

# spawn-mistral.sh's own SPAWN_EXEC_PREFIX line and _sp_cnf_max_price
# function (which reads the cnf next to $SPAWN_ADAPTER).
SPAWN_ADAPTER="$_rs_here/spawn-mistral.sh"
eval "$(sed -n -e '/^SPAWN_EXEC_PREFIX=/p' -e '/^_sp_cnf_max_price() {$/,/^}$/p' "$SPAWN_ADAPTER")"
[ -n "${SPAWN_EXEC_PREFIX:-}" ] && declare -F _sp_cnf_max_price >/dev/null \
  || _rs_fail "cannot read the launch line from $SPAWN_ADAPTER"
RESTORE_EXEC_PREFIX="$SPAWN_EXEC_PREFIX"
_rs_max_price="${SPOOL_MISTRAL_MAX_PRICE:-$(_sp_cnf_max_price)}"
[[ "$_rs_max_price" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
  || _rs_fail "no cost cap: cnf env.box.mistral_vibe.max_price (or SPOOL_MISTRAL_MAX_PRICE) must be a dollar amount, got '${_rs_max_price}' (specs/110 2.5)"
RESTORE_EXTRA_FLAGS="--max-price ${_rs_max_price}"
restore_main "$@"
