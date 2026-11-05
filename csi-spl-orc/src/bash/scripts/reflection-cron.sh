#!/usr/bin/env bash
# reflection-cron.sh - do_spl_reflection_gather from the box user's crontab,
# every 15 min (spec 166 row B8). The action gathers and queues at most once a
# night: only in phase night (do_spl_rhythm_phase), only on the box of the
# dispatch lease holder, only when it has not run this night, so the first
# tick of the window (19:00Z in winter) acts. Installed by
# do_install_box_crons as the row reflection of cnf/box-crons/box-crons.manifest
# (`# csi-spl:box-cron:reflection`). A cron job reads no profile: the PATH is
# set here.
#
# DRY_RUN is 1 (the gathered file and the brief, nothing queued) unless the
# dispatch lease.conf says REFLECTION_DRY_RUN=0: switching it on is the
# orchestrator holder's call, one line in that file, no crontab edit.
#
# Exit: 0 ran (queued, planned, or nothing to do), 1 the action failed (the
# next tick retries), 2 a refusal (worktree, no ./run).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
case "$ORC" in
  *-wt/*) [ "${REFLECTION_ALLOW_WORKTREE:-0}" = 1 ] || { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

dry="$(sed -n 's/^REFLECTION_DRY_RUN=\([01]\)$/\1/p' "${SPOOL_ROOT:-/var/spool-hub}/dispatch/lease.conf" 2>/dev/null | tail -1)"

cd "$ORC" || exit 2
out="$(env DRY_RUN="${dry:-1}" timeout 3000 nice -n 10 ./run -a do_spl_reflection_gather 2>&1)"
rc=$?
while IFS= read -r line; do
  case "$line" in *reflection*|*WARN*|*FATAL*) say "$line" ;; esac
done <<<"$out"
[ "$rc" = 0 ] || { say "WARN do_spl_reflection_gather rc=$rc"; exit 1; }
exit 0
