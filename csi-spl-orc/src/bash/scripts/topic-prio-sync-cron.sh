#!/usr/bin/env bash
# topic-prio-sync-cron.sh - do_spl_topic_prio_sync DRY_RUN=0 from the box
# user's crontab, every 5 min (spec 150 section 3.4 item 4, SPL-4813; owner
# HUM-10, csitea b0f50875, msg f061e485): the discussions' priorities reach
# the issues born of them, and so their lanes. The action acts on the box of
# the dispatch lease holder only. Installed by do_install_box_crons as the row
# topic-prio-sync of cnf/box-crons/box-crons.manifest
# (`# csi-spl:box-cron:topic-prio-sync`). A cron job reads no profile: the
# PATH is set here.
#
# Exit: 0 ran (or not this box), 1 the action failed (the next tick
# retries), 2 a refusal (worktree, no ./run).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
case "$ORC" in
  *-wt/*) [ "${TOPIC_PRIO_ALLOW_WORKTREE:-0}" = 1 ] || { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

cd "$ORC" || exit 2
out="$(env DRY_RUN=0 timeout 240 nice -n 10 ./run -a do_spl_topic_prio_sync 2>&1)"
rc=$?
while IFS= read -r line; do
  case "$line" in *topic-prio-sync*|*WARN*|*FATAL*) say "$line" ;; esac
done <<<"$out"
[ "$rc" = 0 ] || { say "WARN do_spl_topic_prio_sync rc=$rc"; exit 1; }
exit 0
