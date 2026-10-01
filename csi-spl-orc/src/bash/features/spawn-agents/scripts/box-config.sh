#!/usr/bin/env bash
# box-config.sh — show or set the box config ($SPOOL_BOX_ENV, default
# $SPOOL_ROOT/box.env): the defaults every spawn/restore on this box resolves
# when the environment does not name them (lib/spool-env.inc.sh,
# SPOOL_BOX_ENV_KEYS). The environment always wins over the file.
#
# Usage: box-config.sh                 print the file and what resolves now
#        box-config.sh KEY=VALUE ...   set keys (KEY= removes one)
# e.g.   box-config.sh SPOOL_AGENT_USER=<HARNESS_USER>
#   An agent user's CLI paths follow from its home (<home>/.local/bin/<cli>),
#   so SPOOL_AGENT_USER alone moves CLAUDE_BIN with it.
# Exit: 0 ok, 2 usage (unknown key, bad value, unknown user).
set -uo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"
F="${SPOOL_BOX_ENV:-$SPOOL_ROOT/box.env}"

if [ $# -eq 0 ]; then
  echo "# $F"
  [ -r "$F" ] && cat "$F"
  ( spool_env_resolve
    echo "# resolves now: SPOOL_AGENT_USER=$SPOOL_AGENT_USER SPOOL_RUN_AS_AGENT=$SPOOL_RUN_AS_AGENT CLAUDE_BIN=$CLAUDE_BIN" )
  exit 0
fi

for kv in "$@"; do
  k="${kv%%=*}" v="${kv#*=}"
  case "$kv" in *=*) ;; *) echo "box-config: '$kv' is not KEY=VALUE" >&2; exit 2 ;; esac
  case " $SPOOL_BOX_ENV_KEYS " in *" $k "*) ;; *) echo "box-config: unknown key '$k' (one of: $SPOOL_BOX_ENV_KEYS)" >&2; exit 2 ;; esac
  case "$v" in *[[:space:]\'\"\$\`]*) echo "box-config: '$k' value must be one plain word" >&2; exit 2 ;; esac
  if [ "$k" = SPOOL_AGENT_USER ] && [ -n "$v" ] && ! getent passwd "$v" >/dev/null; then
    echo "box-config: no such user '$v'" >&2; exit 2
  fi
  # specs/058: a machine's own desk box id and agent-id band.
  if [ "$k" = SPOOL_DESK_BOX ] && [ -n "$v" ] && { ! [[ "$v" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || [ "$v" = box-wui ]; }; then
    echo "box-config: SPOOL_DESK_BOX must be a box id (^[a-z0-9][a-z0-9-]{0,31}\$, not box-wui), got '$v'" >&2; exit 2
  fi
  if [ "$k" = SPOOL_AGENT_ID_RANGE ] && [ -n "$v" ] && ! [[ "$v" =~ ^[0-9]{1,9}-[0-9]{1,9}$ ]]; then
    echo "box-config: SPOOL_AGENT_ID_RANGE must be <lo>-<hi>, got '$v'" >&2; exit 2
  fi
done

tmp="$F.tmp.$$"
{ [ -r "$F" ] && cat "$F"; true; } | {
  keys=" "
  for kv in "$@"; do keys+="${kv%%=*} "; done
  while IFS= read -r line || [ -n "$line" ]; do
    case "$keys" in *" ${line%%=*} "*) continue ;; esac
    printf '%s\n' "$line"
  done
  for kv in "$@"; do [ -z "${kv#*=}" ] || printf '%s\n' "$kv"; done
} >"$tmp" && chmod 0664 "$tmp" && mv -f "$tmp" "$F" || { rm -f "$tmp"; echo "box-config: cannot write $F" >&2; exit 2; }
echo "box-config: wrote $F"
