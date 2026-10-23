#!/usr/bin/env bash
# login2-sync-cron.sh - run do_spl_agent_login2_sync (the second Claude
# login's one-way, newer-only copy into the agent user's second config folder,
# SPL-2943) from the box user's crontab, every 5 minutes, the same on every
# box. Installed by do_install_box_crons as the row login2-sync of
# cnf/box-crons/box-crons.manifest (`# csi-spl:box-cron:login2-sync`). A box
# with no source set (SPOOL_LOGIN2_SRC in box.env) logs one WARN line and
# copies nothing. A cron job reads no profile: the PATH is set here.
# LOGIN2_CRON_DRY_RUN=1 makes the tick a plan only.
#
# Exit: 0 done or nothing to do, 1 the action failed, 2 a refusal.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
case "$ORC" in
  *-wt/*) [ "${LOGIN2_ALLOW_WORKTREE:-0}" = 1 ] || { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

( cd "$ORC" && env SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" DRY_RUN="${LOGIN2_CRON_DRY_RUN:-0}" timeout 120 ./run -a do_spl_agent_login2_sync 2>&1 ) |
  grep -E '^(login2-sync|FATAL)' | sed "s/^/$(date -u +%Y-%m-%dT%H:%M:%SZ) /"
rc="${PIPESTATUS[0]}"
[ "$rc" = 0 ] || exit 1
