#!/usr/bin/env bash
# peer-distill-cron.sh - run do_spl_peer_distill from the box user's crontab: the summary poke of the seat due next
# (spec 068 section 6.1, lane L6). Installed by do_spl_peer_distill_install_cron
# (or do_spl_peer_crons APPLY=1) as ONE line tagged `# csi-spl:peer-distill`,
# at M+10,M+25,M+40,M+55 (M = PEER_RESTART_OFFSET).
#
# A cron job reads no profile: the PATH is set here and the tools are checked
# before any work, so a missing one names itself in the log.
#
#   peer-distill-cron.sh [--check-tools]
#
# Exit: 0 done or nothing to do, 1 the action failed, 2 usage or a refusal,
# 3 a tool this needs is not on the PATH.
set -uo pipefail
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

CHECK_TOOLS=0
case "${1:-}" in
  --check-tools) CHECK_TOOLS=1 ;;
  "") ;;
  *) echo "peer-distill-cron: unknown argument: $1" >&2; exit 2 ;;
esac

SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ORC="$(cd "$SELF/../../.." && pwd)"
check_tools || exit $?
if [ "$CHECK_TOOLS" = 1 ]; then say "OK every tool peer-distill needs resolves: $PEER_CRON_TOOLS"; exit 0; fi
case "$ORC" in
  *-wt/*)
    [ "${PEER_ALLOW_WORKTREE:-0}" = 1 ] ||
      { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

say "START peer-distill"
( cd "$ORC" && env DRY_RUN=0 ./run -a do_spl_peer_distill ); rc=$?
say "STOP peer-distill rc=$rc"
[ "$rc" = 0 ] || exit 1
