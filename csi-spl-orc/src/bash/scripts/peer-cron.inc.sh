#!/usr/bin/env bash
# peer-cron.inc.sh - sourced by peer-distill-cron.sh, peer-ensure-cron.sh and
# peer-restart-cron.sh (spec 068 section 6.1, lane L6): the one body of the three
# peer cron wrappers. A cron job reads no profile: the PATH is set here and the
# tools are checked before any work, so a missing one names itself in the log.
#
#   peer_cron_main NAME [VAR=VALUE ...] -- [--check-tools]
#
# runs `env VAR=VALUE ... ./run -a do_spl_peer_NAME` from the checkout this file
# sits in. Exit: 0 done or nothing to do, 1 the action failed, 2 usage or a
# refusal, 3 a tool this needs is not on the PATH.
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
[ -n "${PEER_CRON_PATH_EXTRA:-}" ] && PATH="${PEER_CRON_PATH_EXTRA}:${PATH}"
export PATH
PEER_CRON_TOOLS="${PEER_CRON_TOOLS:-jq tmux flock timeout getent}"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

check_tools() {
  local t missing=""
  for t in $PEER_CRON_TOOLS; do
    command -v "$t" >/dev/null 2>&1 || missing="${missing} $t"
  done
  [ -z "$missing" ] && return 0
  say "FATAL these tools are not on the PATH:${missing} (PATH=$PATH; PEER_CRON_PATH_EXTRA adds a dir)"
  return 3
}

peer_cron_main() {
  local name="$1" vars=() check=0 self orc rc; shift
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do vars+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  case "${1:-}" in
    --check-tools) check=1 ;;
    "") ;;
    *) echo "peer-$name-cron: unknown argument: $1" >&2; exit 2 ;;
  esac

  self="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
  orc="$(cd "$self/../../.." && pwd)"
  check_tools || exit $?
  if [ "$check" = 1 ]; then say "OK every tool peer-$name needs resolves: $PEER_CRON_TOOLS"; exit 0; fi
  case "$orc" in
    *-wt/*)
      [ "${PEER_ALLOW_WORKTREE:-0}" = 1 ] ||
        { say "FATAL $orc is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
  esac
  [ -x "$orc/run" ] || { say "FATAL $orc/run not found or not executable"; exit 2; }

  say "START peer-$name"
  ( cd "$orc" && env "${vars[@]}" ./run -a "do_spl_peer_$name" ); rc=$?
  say "STOP peer-$name rc=$rc"
  [ "$rc" = 0 ] || exit 1
}
