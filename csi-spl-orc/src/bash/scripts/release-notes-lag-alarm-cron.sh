#!/usr/bin/env bash
# release-notes-lag-alarm-cron.sh — run do_spl_release_notes_lag_alarm every 15
# min from the box user's crontab (SPL-4988): ONE #alerts post when a master
# commit older than the limit has no release_notes row, one when it recovers.
# Installed by do_install_box_crons as the manifest row release-notes-lag-alarm
# (cnf/box-crons/box-crons.manifest), tagged
# `# csi-spl:box-cron:release-notes-lag-alarm`. Every box runs it; only the
# dispatch lease holder's box reads and posts (the action checks).
#
#   release-notes-lag-alarm-cron.sh [--check-tools]
#
# Exit: 0 ran (or another run held the lock), 1 the action failed, 2 usage or
# a refusal, 3 a tool this needs is not on the PATH.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH
RELEASE_LAG_TOOLS="${RELEASE_LAG_TOOLS:-git jq yq psql gcloud flock}"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

check_tools() {
  local t missing=""
  for t in $RELEASE_LAG_TOOLS; do
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
  *) echo "release-notes-lag-alarm-cron: unknown argument: $1" >&2; exit 2 ;;
esac

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
check_tools || exit $?
if [ "$CHECK_TOOLS" = 1 ]; then say "OK every tool the run needs resolves: $RELEASE_LAG_TOOLS"; exit 0; fi
case "$ORC" in
  *-wt/*)
    [ "${RELEASE_LAG_ALLOW_WORKTREE:-0}" = 1 ] ||
      { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

lock="${RELEASE_LAG_LOCK:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/release-notes-lag-alarm.lock}"
mkdir -p "$(dirname "$lock")"
exec 9>"$lock"
flock -n 9 || { say "OK another release-notes-lag-alarm run holds $lock"; exit 0; }
say "START release-notes-lag-alarm"
( cd "$ORC" && DRY_RUN=0 ./run -a do_spl_release_notes_lag_alarm ); rc=$?
say "STOP release-notes-lag-alarm rc=$rc"
[ "$rc" = 0 ] || exit 1
