#!/usr/bin/env bash
# file-stream-follow-cron.sh - the box file follower (spec 160 row B1) from
# the box user's crontab: every minute it starts do_spl_file_stream_follow,
# which runs the long-lived follower as the box's agent user; while one runs
# (flock) the new start exits 0 at once, so a crashed or exited follower is
# back within a minute. At nice 10 and the lowest best-effort IO priority:
# the agents' turns go first on a loaded box. Installed by
# do_install_box_crons as the row file-streams of
# cnf/box-crons/box-crons.manifest (`# csi-spl:box-cron:file-streams`).
# Off by cnf (env.box.file_streams.enabled: false) until row B2, the hub's
# file_streams_push, is on master: then each run logs one "off" line.
# A cron job reads no profile: the PATH is set here.
#
# Exit: 0 ran (a failed follower included: it logs a WARN line), 2 a
# refusal (worktree, no action file).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
case "$ORC" in
  *-wt/*) [ "${FILE_STREAMS_ALLOW_WORKTREE:-0}" = 1 ] || { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
FUNC="$ORC/src/bash/run/spl-file-stream-follow.func.sh"
[ -f "$FUNC" ] || { say "FATAL $FUNC not found"; exit 2; }
cd "$ORC" || exit 2
renice -n 10 -p $$ >/dev/null 2>&1 || true
ionice -c 2 -n 7 -p $$ >/dev/null 2>&1 || true

# shellcheck source=../run/spl-file-stream-follow.func.sh
source "$FUNC"
do_spl_file_stream_follow 2>&1 | while IFS= read -r line; do say "$line"; done
rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] || say "WARN do_spl_file_stream_follow rc=$rc"
exit 0
