#!/usr/bin/env bash
# lane-rotate-cron.sh - one tick of do_spl_lane_rotate (the hourly rotation of
# every agent on this box) from the box user's crontab, every minute, the same
# on every box. Installed by do_install_box_crons as the row lane-rotate of
# cnf/box-crons/box-crons.manifest (`# csi-spl:box-cron:lane-rotate`).
# A cron job reads no profile: the PATH is set here and the tools are checked
# first. LANE_ROTATE_CRON_DRY_RUN=1 makes the tick a plan only.
#
# Exit: 0 done or nothing to do, 1 the tick failed, 2 a refusal, 3 a missing tool.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

missing=""
for t in jq tmux flock timeout getent setsid git; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
[ -z "$missing" ] || { say "FATAL these tools are not on the PATH:$missing (PATH=$PATH)"; exit 3; }

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
case "$ORC" in
  *-wt/*) [ "${LANE_ROTATE_ALLOW_WORKTREE:-0}" = 1 ] || { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

( cd "$ORC" && env SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" DRY_RUN="${LANE_ROTATE_CRON_DRY_RUN:-0}" ROTATE_CMD=auto ./run -a do_spl_lane_rotate 2>&1 ) |
  grep -vE '^\[?(INFO|DEBUG)' | grep . || true
rc="${PIPESTATUS[0]}"
[ "$rc" = 0 ] || { say "FAIL lane-rotate tick rc=$rc"; exit 1; }
