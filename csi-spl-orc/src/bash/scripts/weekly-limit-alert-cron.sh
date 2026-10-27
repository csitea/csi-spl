#!/usr/bin/env bash
# weekly-limit-alert-cron.sh — run do_spl_weekly_limit_alert every 5 min from
# the box user's crontab (SPL-3849): ONE #alerts line per agent kind per box
# when its weekly used % crosses 90, 95 or 99, once per reset week. Installed
# by do_install_box_crons as the manifest row weekly-limit-alert
# (cnf/box-crons/box-crons.manifest), tagged
# `# csi-spl:box-cron:weekly-limit-alert`. Every box runs it for itself.
#
#   weekly-limit-alert-cron.sh [--check-tools]
#
# Exit: 0 ran (or another run held the lock), 1 the action failed, 2 usage or
# a refusal, 3 a tool this needs is not on the PATH.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH
WEEKLY_ALERT_TOOLS="${WEEKLY_ALERT_TOOLS:-jq tmux flock}"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

check_tools() {
  local t missing=""
  for t in $WEEKLY_ALERT_TOOLS; do
    command -v "$t" >/dev/null 2>&1 || missing="${missing} $t"
  done
  [ -z "$missing" ] && return 0
  say "FATAL these tools are not on the PATH:${missing} (PATH=$PATH)"
  return 3
}

CHECK_TOOLS=0
case "${1:-}" in
  --check-tools) CHECK_TOOLS=1 ;;
  "") ;;
  *) echo "weekly-limit-alert-cron: unknown argument: $1" >&2; exit 2 ;;
esac

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
check_tools || exit $?
if [ "$CHECK_TOOLS" = 1 ]; then say "OK every tool the run needs resolves: $WEEKLY_ALERT_TOOLS"; exit 0; fi
case "$ORC" in
  *-wt/*)
    [ "${WEEKLY_ALERT_ALLOW_WORKTREE:-0}" = 1 ] ||
      { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

lock="${WEEKLY_ALERT_LOCK:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/weekly-limit-alert.lock}"
mkdir -p "$(dirname "$lock")"
exec 9>"$lock"
flock -n 9 || { say "OK another weekly-limit-alert run holds $lock"; exit 0; }
say "START weekly-limit-alert"
( cd "$ORC" && DRY_RUN=0 ./run -a do_spl_weekly_limit_alert ); rc=$?
say "STOP weekly-limit-alert rc=$rc"
[ "$rc" = 0 ] || exit 1
