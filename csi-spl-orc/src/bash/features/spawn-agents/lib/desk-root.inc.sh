#!/usr/bin/env bash
# desk-root.inc.sh — the cloud state root a desk READER walks (spec 069
# section 8.5, row B4): <root>/<env>/desk/<workspace>/<desk id>, plus
# <root>/<env>/bin/spool. Source it after spool-env.inc.sh; the path itself
# is spool_desk_state's (row B1), never derived here.
#
#   spool_desk_root CALLER_HOME [BOX_ENV]
#
# SPOOL_DESK_USER (environment, else the key in BOX_ENV, else $SPOOL_BOX_ENV,
# else $SPOOL_ROOT/box.env; under SPOOL_TEST=1 with no SPOOL_ROOT no file is
# read) names the desk user: the root is under that user's home (getent).
# Unset: the root is under CALLER_HOME, the home each reader used before the
# key existed ($HOME, or its passwd home), so an unset key changes nothing.
# Non-zero, nothing printed, when the desk user has no passwd entry.
#
# CLI (for the python readers): bash desk-root.inc.sh CALLER_HOME [BOX_ENV]

# _spool_desk_root_key [BOX_ENV]: SPOOL_DESK_USER, else its box config value.
_spool_desk_root_key() {
  local v="${SPOOL_DESK_USER:-}" f="${1:-${SPOOL_BOX_ENV:-}}" k val
  if [ -z "$f" ]; then
    [ "${SPOOL_TEST:-}" = 1 ] && [ -z "${SPOOL_ROOT:-}" ] || f="${SPOOL_ROOT:-/var/spool-hub}/box.env"
  fi
  if [ -z "$v" ] && [ -n "$f" ] && [ -r "$f" ]; then
    while IFS='=' read -r k val || [ -n "$k" ]; do
      [ "$k" = SPOOL_DESK_USER ] || continue
      val="${val%$'\r'}"; val="${val#\"}"; val="${val%\"}"; val="${val#\'}"; val="${val%\'}"
      v="$val"
    done <"$f"
  fi
  printf '%s' "$v"
}

spool_desk_root() {  # CALLER_HOME [BOX_ENV]
  local home="${1:?spool_desk_root: CALLER_HOME}" u s
  u="$(_spool_desk_root_key "${2:-}")"
  if [ -n "$u" ]; then
    s="$(SPOOL_DESK_USER="$u" spool_desk_state _)" || return 1
  else
    # The resolver's layout under the caller's home: _spool_home_of answers
    # with CALLER_HOME inside this subshell only.
    # shellcheck disable=SC2329,SC2317 # called by spool_desk_state
    s="$(_spool_home_of() { printf '%s' "$home"; }; SPOOL_DESK_USER=caller spool_desk_state _)" || return 1
  fi
  printf '%s' "${s%/_}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # shellcheck source=spool-env.inc.sh
  . "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/spool-env.inc.sh"
  spool_desk_root "$@"
fi
