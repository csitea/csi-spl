#!/usr/bin/env bash
# box-stats-cron.sh - post one hardware sample of this box to the hub
# (do_post_box_stats, rdb 0117) from the box user's crontab, every 5 min.
# Installed by do_setup_box_stats_cron as ONE line tagged `# csi-spl:box-stats`.
# The lane map runs only on spawns and checks, so it is no clock for a
# history; this line is.
#
# A cron job reads no profile: the PATH is set here and the tools are checked
# before any work, so a missing one names itself in the log.
#
#   box-stats-cron.sh [--check-tools]
#
# Exit: 0 posted, 1 the post failed, 2 usage or a refusal, 3 a tool this needs
# is not on the PATH.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
[ -n "${BOX_STATS_CRON_PATH_EXTRA:-}" ] && PATH="${BOX_STATS_CRON_PATH_EXTRA}:${PATH}"
export PATH
BOX_STATS_CRON_TOOLS="${BOX_STATS_CRON_TOOLS:-jq awk nproc timeout yq}"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

check_tools() {
  local t missing=""
  for t in $BOX_STATS_CRON_TOOLS; do
    command -v "$t" >/dev/null 2>&1 || missing="${missing} $t"
  done
  [ -z "$missing" ] && return 0
  say "FATAL these tools are not on the PATH:${missing} (PATH=$PATH; BOX_STATS_CRON_PATH_EXTRA adds a dir)"
  return 3
}

CHECK_TOOLS=0
case "${1:-}" in
  --check-tools) CHECK_TOOLS=1 ;;
  "") ;;
  *) echo "box-stats-cron: unknown argument: $1" >&2; exit 2 ;;
esac

SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ORC="$(cd "$SELF/../../.." && pwd)"
check_tools || exit $?
if [ "$CHECK_TOOLS" = 1 ]; then say "OK every tool the sample needs resolves: $BOX_STATS_CRON_TOOLS"; exit 0; fi
case "$ORC" in
  *-wt/*)
    [ "${BOX_STATS_ALLOW_WORKTREE:-0}" = 1 ] ||
      { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

( cd "$ORC" && ./run -a do_post_box_stats ); rc=$?
[ "$rc" = 0 ] || { say "FAIL box stats sample rc=$rc"; exit 1; }
