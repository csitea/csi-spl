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
# A restored m- seat gets its task back (restart drill 3, 2026-10-09: the
# seats came back at an empty prompt, "0 tokens"). Arg 4 from the identity
# restore is a brief FILE, not a prompt. The seat's brief is the first of:
# arg 4 (a readable file), lifetime/session.json .brief, lifetime/brief.md,
# the spec 102 handoff.md (its "## 2. brief" path, else the handoff itself);
# the kick is restore-claude.sh's own (restore-core _rs_kick: re-read the
# brief, the inbox, continue), and a seat ALWAYS gets it, as a claude restore
# does: a vibe --continue / --resume with no prompt waits at an empty prompt
# for good (a box reboot, 2026-10-09 16:23Z: m-630, spawned before lifetime/brief.md
# existed, came back bare and idle). The spawn seed lifetime/prompt.txt ("task
# brief at <path>") is one more source, after lifetime/brief.md. No brief file
# on disk: the kick points at the session's first message (the seed) and the
# seat is reported to the orchestrator (RESTORE_REPORT_SEND overrides the
# sender; with RESTORE_PRINT=1 nothing is sent unless it is set).
# An arg 4 that is not a file is still a literal kick.
#
# The seat's own worktree (<repo>-wt/<ID>) gets spawn-mistral.sh's
# SPAWN_AGENT_ACL (rwX) back before vibe starts: a seat spawned under the old
# rX wrote through a shell and mangled the files (spawn-mistral.sh).
#
# Usage: restore-mistral.sh <TITLE> <RUNDIR> [SESSION_ID|-] [BRIEF_FILE|KICK_PROMPT]
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

# spawn-mistral.sh's own SPAWN_EXEC_PREFIX and SPAWN_AGENT_ACL lines and
# _sp_cnf_max_price function (which reads the cnf next to $SPAWN_ADAPTER).
SPAWN_ADAPTER="$_rs_here/spawn-mistral.sh"
eval "$(sed -n -e '/^SPAWN_EXEC_PREFIX=/p' -e '/^SPAWN_AGENT_ACL=/p' -e '/^_sp_cnf_max_price() {$/,/^}$/p' "$SPAWN_ADAPTER")"
[ -n "${SPAWN_EXEC_PREFIX:-}" ] && [ -n "${SPAWN_AGENT_ACL:-}" ] && declare -F _sp_cnf_max_price >/dev/null \
  || _rs_fail "cannot read the launch line from $SPAWN_ADAPTER"
RESTORE_EXEC_PREFIX="$SPAWN_EXEC_PREFIX"
_rs_max_price="${SPOOL_MISTRAL_MAX_PRICE:-$(_sp_cnf_max_price)}"
[[ "$_rs_max_price" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
  || _rs_fail "no cost cap: cnf env.box.mistral_vibe.max_price (or SPOOL_MISTRAL_MAX_PRICE) must be a dollar amount, got '${_rs_max_price}' (specs/110 2.5)"
RESTORE_EXTRA_FLAGS="--max-price ${_rs_max_price}"

# The seat's brief file (see the head), or nothing.
_rs_mistral_brief() {  # ID ARG4
  local lt="$SPOOL_ROOT/$1/lifetime" ho="$SPOOL_ROOT/$1/handoff.md" b sec
  if [ -n "$2" ] && [ -f "$2" ] && [ -r "$2" ]; then echo "$2"; return 0; fi
  b="$(jq -r '.brief // empty' "$lt/session.json" 2>/dev/null || true)"
  if [ -n "$b" ] && [ -r "$b" ]; then echo "$b"; return 0; fi
  if [ -s "$lt/brief.md" ]; then echo "$lt/brief.md"; return 0; fi
  b="$(grep -oE 'task brief at [^[:space:]]+' "$lt/prompt.txt" 2>/dev/null | sed -n '1{s/^task brief at //;s/[.,;:]$//;p}')"
  if [ -n "$b" ] && [ -r "$b" ]; then echo "$b"; return 0; fi
  [ -s "$ho" ] || return 0
  sec="$(awk '/^## /{on = ($0 == "## 2. brief"); next} on' "$ho" | sed '/^[[:space:]]*$/d')"
  [ -n "$sec" ] && [ "$sec" != "(none)" ] || return 0
  b="$(sed -n '1s/^brief: //p' <<<"$sec")"
  if [ -n "$b" ] && [ -r "$b" ]; then echo "$b"; else echo "$ho"; fi
}

_rs_mistral_nobrief() {  # ID RUNDIR
  local msg="NO-BRIEF $1: restored with the generic restore kick only, no brief on disk (arg 4, $SPOOL_ROOT/$1/lifetime/session.json .brief, lifetime/brief.md, lifetime/prompt.txt, handoff.md section 2). It is told to re-read its session's first message in $2: check that it continues, else send it its task."
  echo "$msg" >&2
  [ "${RESTORE_PRINT:-0}" = 1 ] && [ -z "${RESTORE_REPORT_SEND:-}" ] && return 0
  ${RESTORE_REPORT_SEND:-bash "$_rs_here/spool-send.sh"} --from "$1" --to orchestrator --kind blocker \
    --task "restore-$1" --no-ask --body "$msg" >/dev/null 2>&1 || echo "WARN $1: the NO-BRIEF report was not sent" >&2
}

# SPAWN_AGENT_ACL on RUNDIR when it is the seat's own worktree <repo>-wt/<ID>
# and this (box) user owns it; never on any other dir. Non-fatal.
_rs_mistral_acl() {  # ID RUNDIR
  [ "$(basename "$2")" = "$1" ] && [[ "$(dirname "$2")" == *-wt ]] && [ -O "$2" ] || return 0
  SPOOL_ENV_NO_BINS=0 spool_env_resolve
  [ "$SPOOL_AGENT_USER" != "$SPOOL_BOX_USER" ] && command -v setfacl >/dev/null 2>&1 || return 0
  echo "INFO $1: setfacl -R -m u:${SPOOL_AGENT_USER}:${SPAWN_AGENT_ACL} (+ default) $2" >&2
  [ "${RESTORE_PRINT:-0}" = 1 ] && return 0
  setfacl -R -m "u:${SPOOL_AGENT_USER}:${SPAWN_AGENT_ACL}" -m "d:u:${SPOOL_AGENT_USER}:${SPAWN_AGENT_ACL}" "$2" 2>/dev/null \
    || echo "WARN $1: setfacl on $2 failed: its vibe writes through a shell" >&2
}

SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"
[ -z "${1:-}" ] || [ ! -d "${2:-}" ] || _rs_mistral_acl "$1" "$2"
if spool_valid_id "${1:-}" 2>/dev/null && [ -d "${2:-}" ] && { [ -z "${4:-}" ] || [ -f "${4:-}" ]; }; then
  _rs_brief="$(_rs_mistral_brief "$1" "${4:-}")"
  RESTORE_KICK_MODE=brief
  RESTORE_NOBRIEF_CLAUSE="Your task brief is the first message of this session (your spawn seed): re-read it to reload the full scope. "
  [ -n "$_rs_brief" ] || _rs_mistral_nobrief "$1" "$2"
  restore_main "$1" "$2" "${3:-}" "$_rs_brief"
else
  restore_main "$@"
fi
