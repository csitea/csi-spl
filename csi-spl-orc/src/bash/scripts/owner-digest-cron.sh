#!/usr/bin/env bash
# owner-digest-cron.sh - do_spl_owner_digest_post DRY_RUN=0 from the box user's
# crontab, every hour. The action posts at most once a day: only on the box of
# the dispatch lease holder, only in the cnf hour (env.owner_digest), only when
# it has not run today. Installed by do_install_box_crons as the row
# owner-digest of cnf/box-crons/box-crons.manifest
# (`# csi-spl:box-cron:owner-digest`). A cron job reads no profile: the PATH is
# set here.
#
# Exit: 0 ran (posted, or nothing to do), 1 the action failed (the next hour
# retries), 2 a refusal (worktree, no ./run).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
case "$ORC" in
  *-wt/*) [ "${OWNER_DIGEST_ALLOW_WORKTREE:-0}" = 1 ] || { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

cd "$ORC" || exit 2
out="$(env DRY_RUN=0 timeout 600 nice -n 10 ./run -a do_spl_owner_digest_post 2>&1)"
rc=$?
while IFS= read -r line; do
  case "$line" in *owner-digest*|*WARN*|*FATAL*) say "$line" ;; esac
done <<<"$out"
[ "$rc" = 0 ] || { say "WARN do_spl_owner_digest_post rc=$rc"; exit 1; }
exit 0
