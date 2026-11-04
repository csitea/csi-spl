#!/usr/bin/env bash
# box-link-watch-cron.sh — run do_spl_box_link_watch every minute from the box
# user's crontab (SPL-4816): a relay bundle, command, box log or link stuck
# for more than 7 min sends ONE blocker to the seat of the topic that owns
# the box, and one note when it clears. Installed by do_install_box_crons as
# the manifest row box-link-watch (cnf/box-crons/box-crons.manifest), tagged
# `# csi-spl:box-cron:box-link-watch`. A box with no relay configured
# (no box-local env file, see do_spl_box_link_watch) has nothing to watch and
# exits 0.
#
#   box-link-watch-cron.sh
#
# Exit: 0 ran, 1 the action failed, 2 usage or a refusal.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

[ "$#" = 0 ] || { echo "box-link-watch-cron: unknown argument: $1" >&2; exit 2; }
ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
case "$ORC" in
  *-wt/*)
    [ "${BOX_LINK_WATCH_ALLOW_WORKTREE:-0}" = 1 ] ||
      { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }
say "START box-link-watch"
( cd "$ORC" && DRY_RUN=0 ./run -a do_spl_box_link_watch ); rc=$?
say "STOP box-link-watch rc=$rc"
[ "$rc" = 0 ] || exit 1
