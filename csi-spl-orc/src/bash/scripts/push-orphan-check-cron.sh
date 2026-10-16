#!/usr/bin/env bash
# push-orphan-check-cron.sh - run do_spl_push_orphan_check (a refused or dead
# push whose lane is gone -> ONE blocker to the dispatch lease holder,
# SPL-2264) from the box user's crontab, every minute, the same on every box.
# Installed by do_install_box_crons as the row push-orphan-check of
# cnf/box-crons/box-crons.manifest (`# csi-spl:box-cron:push-orphan-check`).
# A cron job reads no profile: the PATH is set here. PUSH_ORPHAN_CRON_DRY_RUN=1
# makes the tick a plan only.
#
# Exit: 0 done or nothing to do, 1 the action failed, 2 a refusal.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
case "$ORC" in
  *-wt/*) [ "${PUSH_ORPHAN_ALLOW_WORKTREE:-0}" = 1 ] || { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

# One tick at a time: a slow tick never overlaps the next minute's.
state="${PUSH_ORPHAN_STATE_DIR:-/var/csi/csi-spl/push-orphan-check}"
mkdir -p "$state" 2>/dev/null; lock="$state/tick.lock"
exec 9>>"$lock" || { say "FATAL cannot open $lock"; exit 2; }
flock -n 9 || { say "OK another push-orphan-check tick holds $lock"; exit 0; }

( cd "$ORC" && env SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" DRY_RUN="${PUSH_ORPHAN_CRON_DRY_RUN:-0}" timeout 50 ./run -a do_spl_push_orphan_check 2>&1 ) |
  grep -E '^(push-orphan-check|ALERT|PLAN|  |FATAL|WARN)' | sed "s/^/$(date -u +%Y-%m-%dT%H:%M:%SZ) /"
rc="${PIPESTATUS[0]}"
[ "$rc" = 0 ] || exit 1
