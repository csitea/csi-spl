#!/usr/bin/env bash
# agent-login-check-cron.sh - run do_spl_agent_login_check (the agent login
# self-heal) from the box user's crontab, every minute, the same on every box.
# Installed by do_install_box_crons as the row agent-login-check of
# cnf/box-crons/box-crons.manifest (`# csi-spl:box-cron:agent-login-check`).
# A cron job reads no profile: the PATH is set here. LOGIN_CRON_DRY_RUN=1 makes
# the tick a plan only.
#
# Exit: 0 done or nothing to do, 1 the action failed, 2 a refusal.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
case "$ORC" in
  *-wt/*) [ "${LOGIN_ALLOW_WORKTREE:-0}" = 1 ] || { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

( cd "$ORC" && env SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" DRY_RUN="${LOGIN_CRON_DRY_RUN:-0}" ./run -a do_spl_agent_login_check 2>&1 ) |
  grep -E '^(login-check|ALERT|PLAN|  |FATAL|WARN)|copied|FAILED' | sed "s/^/$(date -u +%Y-%m-%dT%H:%M:%SZ) /"
rc="${PIPESTATUS[0]}"
[ "$rc" = 0 ] || exit 1
