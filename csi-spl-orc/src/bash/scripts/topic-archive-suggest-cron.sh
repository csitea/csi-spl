#!/usr/bin/env bash
# topic-archive-suggest-cron.sh - do_spl_topic_archive_suggest from the box
# user's crontab, hourly (spec 041 section 7, SPL-5520). Each tick reads the
# answers of the archive polls already posted; the new polls go out once a
# UTC day, only on the box of the dispatch lease holder. Installed by
# do_spl_topic_archive_suggest_install_cron (`# csi-spl:topic-archive-suggest`).
# A cron job reads no profile: the PATH is set here.
#
# Default off: DRY_RUN is 1 (a report, nothing posted or archived) unless the
# dispatch lease.conf says ARCHIVE_SUGGEST_DRY_RUN=0. Turning it on is the
# owner's call, one line in that file, no crontab edit.
#
# Exit: 0 ran (posted, or nothing to do), 1 the action failed (the next tick
# retries), 2 a refusal (worktree, no ./run).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
case "$ORC" in
  *-wt/*) [ "${ARCHIVE_SUGGEST_ALLOW_WORKTREE:-0}" = 1 ] || { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

dry="$(sed -n 's/^ARCHIVE_SUGGEST_DRY_RUN=\([01]\)$/\1/p' "${SPOOL_ROOT:-/var/spool-hub}/dispatch/lease.conf" 2>/dev/null | tail -1)"

cd "$ORC" || exit 2
out="$(env DRY_RUN="${dry:-1}" timeout 3000 nice -n 10 ./run -a do_spl_topic_archive_suggest 2>&1)"
rc=$?
while IFS= read -r line; do
  case "$line" in *archive-suggest*|*WARN*|*FATAL*) say "$line" ;; esac
done <<<"$out"
[ "$rc" = 0 ] || { say "WARN do_spl_topic_archive_suggest rc=$rc"; exit 1; }
exit 0
