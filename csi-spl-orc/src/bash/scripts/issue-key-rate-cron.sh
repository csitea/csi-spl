#!/usr/bin/env bash
# issue-key-rate-cron.sh - do_spl_issue_key_rate once a week from the box
# user's crontab (owner Q6 A, spec 135 section 9: the fleet's issue key rate is
# measured weekly). Fetches trunk, then appends the week's row to
# <state>/issue-key-rate/history.tsv next to this cron's log. Installed by
# do_install_box_crons as the row issue-key-rate of
# cnf/box-crons/box-crons.manifest (`# csi-spl:box-cron:issue-key-rate`). A cron
# job reads no profile: the PATH is set here.
#
# Exit: 0 measured, 1 the action failed, 2 a refusal (worktree, no ./run).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
case "$ORC" in
  *-wt/*) [ "${KEY_RATE_ALLOW_WORKTREE:-0}" = 1 ] || { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

hist="${KEY_RATE_HISTORY:-${BOX_CRONS_STATE_DIR:-/var/csi/csi-spl}/issue-key-rate/history.tsv}"
timeout 120 git -C "$ORC/.." fetch -q origin master 2>/dev/null || say "WARN fetch failed: measuring the last fetched origin/master"
cd "$ORC" || exit 2
out="$(env KEY_RATE_HISTORY="$hist" timeout 300 nice -n 10 ./run -a do_spl_issue_key_rate 2>&1)"
rc=$?
while IFS= read -r line; do
  case "$line" in *'key rate'*|*WARN*|*FATAL*) say "$line" ;; esac
done <<<"$out"
[ "$rc" = 0 ] || { say "WARN do_spl_issue_key_rate rc=$rc"; exit 1; }
exit 0
