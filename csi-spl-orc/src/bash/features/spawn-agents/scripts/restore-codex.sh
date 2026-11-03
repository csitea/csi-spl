#!/usr/bin/env bash
# restore-codex.sh — resume an interrupted codex session (codex resume <SESSION_ID>), or,
# with no session id ('' or '-'), the last session in RUNDIR (codex resume --last).
# The codex adapter of restore-core.inc.sh (spec 161 4.2 item 2), the twin of
# restore-mistral.sh; the core documents what every restore does.
#
# The launch words are spawn-codex.sh's, read from that file rather than
# copied: its SPAWN_EXEC_PREFIX (env -u OPENAI_API_KEY -u CODEX_API_KEY),
# and SPAWN_EXTRA_FLAGS (the -c telemetry and update-check off switches), so
# a restored lane runs under exactly the line it was spawned with (its
# worktree keeps the rwX ACL its spawn set). The resume subcommand follows the global flags:
# `codex --dangerously-bypass-approvals-and-sandbox -c ... resume <id> "<kick>"`.
#
# Off until the owner's login is on the box, as a spawn: spool_codex_ready
# first, one REFUSED line and exit 13 without it, nothing started.
#
# The kick is a brief kick (restore-core _rs_kick: re-read the brief, the
# inbox, continue), the brief being arg 4 when it is a file, else
# lifetime/brief.md; with neither, the kick points at the session's first
# message (the spawn seed).
#
# Usage: restore-codex.sh <TITLE> <RUNDIR> [SESSION_ID|-] [BRIEF_FILE|KICK_PROMPT]
# shellcheck disable=SC2034  # the RESTORE_* declarations are read by restore-core.inc.sh
set -uo pipefail
RESTORE_KIND=codex
RESTORE_ID_PREFIX=
RESTORE_BIN_VAR=CODEX_BIN
RESTORE_KICK_FLAG=
RESTORE_KICK_MODE=prompt
RESTORE_SID_OPTIONAL=1
restore_args() { if [ -n "$1" ]; then printf "%s" "resume $1"; else printf "%s" "resume --last"; fi; }
RESTORE_ARGS=restore_args
_rs_here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
_rs_core="$_rs_here/restore-core.inc.sh"
# shellcheck source=restore-core.inc.sh
. "$_rs_core" || { echo "ERROR: cannot load $_rs_core" >&2; exec env HISTSIZE=-1 HISTFILESIZE=-1 BASHOPTS=histappend bash --norc; }

# spawn-codex.sh's own launch words (see the head).
SPAWN_ADAPTER="$_rs_here/spawn-codex.sh"
eval "$(sed -n -e '/^SPAWN_EXEC_PREFIX=/p' -e '/^SPAWN_EXTRA_FLAGS=/p' "$SPAWN_ADAPTER")"
[ -n "${SPAWN_EXEC_PREFIX:-}" ] && [ -n "${SPAWN_EXTRA_FLAGS:-}" ] \
  || _rs_fail "cannot read the launch line from $SPAWN_ADAPTER"
RESTORE_EXEC_PREFIX="$SPAWN_EXEC_PREFIX"
RESTORE_EXTRA_FLAGS="$SPAWN_EXTRA_FLAGS"

SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"
SPOOL_ENV_NO_BINS=0 spool_env_resolve
spool_codex_ready "${1:-}" || exit 13
if spool_valid_id "${1:-}" 2>/dev/null && [ -d "${2:-}" ] && { [ -z "${4:-}" ] || [ -f "${4:-}" ]; }; then
  _rs_brief="${4:-}"
  [ -n "$_rs_brief" ] || { [ ! -s "$SPOOL_ROOT/$1/lifetime/brief.md" ] || _rs_brief="$SPOOL_ROOT/$1/lifetime/brief.md"; }
  RESTORE_KICK_MODE=brief
  RESTORE_NOBRIEF_CLAUSE="Your task brief is the first message of this session (your spawn seed): re-read it to reload the full scope. "
  restore_main "$1" "$2" "${3:-}" "$_rs_brief"
else
  restore_main "$@"
fi
