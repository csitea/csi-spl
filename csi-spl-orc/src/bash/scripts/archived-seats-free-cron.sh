#!/usr/bin/env bash
# archived-seats-free-cron.sh - the standing run of do_spl_archived_seats_free
# (SPL-3983; owner HUM-10, 2026-10-27: "the discusoin has been archieved ->
# the agents should be killed / freed"): the lanes of THIS box whose
# discussion is archived are freed, the ones the code cannot free named in one
# blocker to the orchestrator. Every 5 min from the box user's crontab;
# installed by do_install_box_crons as the row archived-seats-free of
# cnf/box-crons/box-crons.manifest (`# csi-spl:box-cron:archived-seats-free`),
# on every box. A cron job reads no profile: the PATH is set here.
#
# Exit: 0 ran (or another run held the lock), 1 the action failed, 2 a refusal
# (worktree, no ./run).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
case "$ORC" in
  *-wt/*) [ "${ARCHIVED_SEATS_ALLOW_WORKTREE:-0}" = 1 ] || { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

lock="${ARCHIVED_SEATS_LOCK:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/archived-seats-free.lock}"
mkdir -p "$(dirname "$lock")"
exec 9>"$lock"
flock -n 9 || { say "OK another archived-seats-free run holds $lock"; exit 0; }
say "START archived-seats-free"
( cd "$ORC" && SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" DRY_RUN="${ARCHIVED_SEATS_DRY_RUN:-0}" timeout 900 ./run -a do_spl_archived_seats_free ); rc=$?
say "STOP archived-seats-free rc=$rc"
[ "$rc" = 0 ] || exit 1
