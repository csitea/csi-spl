#!/usr/bin/env bash
# box-restart-cron.sh - the scheduled box restart's tick, from the box user's
# crontab every 5 minutes (do_spl_box_restart_tick): the restart when this
# box's slot is due, the after-boot pass once the box is back, else nothing.
# Installed by do_spl_box_restart_install_cron as ONE line tagged
# `# csi-spl:box-restart`.
#
# A cron job reads no profile: the PATH is set here and the tools are checked
# before any work, so a missing one names itself in the log. The ./run
# START/STOP banners are dropped, so a tick with nothing to do writes no line.
#
#   box-restart-cron.sh --at '<weekday> <HH:MM> <tz>' | --check-tools
#
# Exit: 0 done or nothing to do, 1 the action failed, 2 usage or a refusal,
# 3 a tool this needs is not on the PATH.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
[ -n "${BOX_RESTART_PATH_EXTRA:-}" ] && PATH="${BOX_RESTART_PATH_EXTRA}:${PATH}"
export PATH
BOX_RESTART_TOOLS="${BOX_RESTART_TOOLS:-gh flock systemctl sudo tmux crontab}"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

check_tools() {
  local t missing=""
  for t in $BOX_RESTART_TOOLS; do
    command -v "$t" >/dev/null 2>&1 || missing="${missing} $t"
  done
  [ -z "$missing" ] && return 0
  say "FATAL these tools are not on the PATH:${missing} (PATH=$PATH; BOX_RESTART_PATH_EXTRA adds a dir)"
  return 3
}

CHECK_TOOLS=0 AT=""
case "${1:-}" in
  --check-tools) CHECK_TOOLS=1 ;;
  --at) AT="${2:-}" ;;
  *) echo "box-restart-cron: usage: --at '<weekday> <HH:MM> <tz>' | --check-tools" >&2; exit 2 ;;
esac

SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ORC="$(cd "$SELF/../../.." && pwd)"
check_tools || exit $?
if [ "$CHECK_TOOLS" = 1 ]; then say "OK every tool box-restart needs resolves: $BOX_RESTART_TOOLS"; exit 0; fi
[ -n "$AT" ] || { echo "box-restart-cron: --at needs the slot" >&2; exit 2; }
case "$ORC" in
  *-wt/*)
    [ "${BOX_RESTART_ALLOW_WORKTREE:-0}" = 1 ] ||
      { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

( cd "$ORC" && env BOX_RESTART_AT="$AT" ./run -a do_spl_box_restart_tick 2>&1 ) |
  grep --line-buffered -vE 'INFO (START|STOP) +::: running' | while IFS= read -r l; do say "$l"; done
rc="${PIPESTATUS[0]}"
[ "$rc" = 0 ] || exit 1
