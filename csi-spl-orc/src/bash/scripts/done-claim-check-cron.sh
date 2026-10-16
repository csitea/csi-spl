#!/usr/bin/env bash
# done-claim-check-cron.sh - the standing run of do_spl_done_claim_check
# (SPL-2265, owner t1 b61851fb row D2): a lane result with no sha, or a sha
# not on the trunk 15 min after it was sent, is ONE note to the dispatch lease
# holder. Every 5 min from the box user's crontab; installed by
# do_install_box_crons as the row done-claim-check of
# cnf/box-crons/box-crons.manifest (`# csi-spl:box-cron:done-claim-check`).
# Every box runs it on the results of the lanes it hosts. A cron job reads no
# profile: the PATH is set here.
#
# Exit: 0 ran (or another run held the lock), 1 the action failed, 2 a refusal
# (worktree, no ./run).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
case "$ORC" in
  *-wt/*) [ "${DONE_CLAIM_ALLOW_WORKTREE:-0}" = 1 ] || { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

lock="${DONE_CLAIM_LOCK:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/done-claim-check.lock}"
mkdir -p "$(dirname "$lock")"
exec 9>"$lock"
flock -n 9 || { say "OK another done-claim-check run holds $lock"; exit 0; }
say "START done-claim-check"
( cd "$ORC" && DRY_RUN=0 timeout 600 ./run -a do_spl_done_claim_check ); rc=$?
say "STOP done-claim-check rc=$rc"
[ "$rc" = 0 ] || exit 1
