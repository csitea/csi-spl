#!/usr/bin/env bash
# dispatch-rotate-cron.sh — run do_spl_dispatch_rotate DRY_RUN=0 from the box
# user's crontab (SPEC-spool-fleet-roles.md 4.4). Installed by
# do_spl_dispatch_rotate_install_cron as ONE line tagged
# `# csi-spl:dispatch-rotate`, hourly at :15; with --heal it runs the HEAL step
# alone (ROTATE_CMD=heal), the line tagged `# csi-spl:dispatch-heal`, every 3 min.
#
# A cron job reads no profile: the PATH is set here and the tools are checked
# before any work, so a missing one names itself in the log.
#
#   dispatch-rotate-cron.sh [--heal | --check-tools]
#
# Exit: 0 rotated, skipped or held off by the lock; 1 the rotation failed (the
# old sessions keep their roles, the action raised the alert); 2 usage or a
# refusal; 3 a tool this needs is not on the PATH.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
[ -n "${ROTATE_CRON_PATH_EXTRA:-}" ] && PATH="${ROTATE_CRON_PATH_EXTRA}:${PATH}"
export PATH
ROTATE_CRON_TOOLS="${ROTATE_CRON_TOOLS:-python3 jq tmux flock git}"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

check_tools() {
  local t missing=""
  for t in $ROTATE_CRON_TOOLS; do
    command -v "$t" >/dev/null 2>&1 || missing="${missing} $t"
  done
  [ -z "$missing" ] && return 0
  say "FATAL these tools are not on the PATH:${missing} (PATH=$PATH; ROTATE_CRON_PATH_EXTRA adds a dir)"
  return 3
}

CHECK_TOOLS=0 CMD=auto WHAT="dispatcher rotation"
case "${1:-}" in
  --check-tools) CHECK_TOOLS=1 ;;
  --heal) CMD=heal WHAT="dispatcher heal" ;;
  "") ;;
  *) echo "dispatch-rotate-cron: unknown argument: $1" >&2; exit 2 ;;
esac

SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ORC="$(cd "$SELF/../../.." && pwd)"
check_tools || exit $?
if [ "$CHECK_TOOLS" = 1 ]; then say "OK every tool the rotation needs resolves: $ROTATE_CRON_TOOLS"; exit 0; fi
case "$ORC" in
  *-wt/*)
    [ "${ROTATE_ALLOW_WORKTREE:-0}" = 1 ] ||
      { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

say "START $WHAT"
( cd "$ORC" && env DRY_RUN=0 ROTATE_CMD="$CMD" ./run -a do_spl_dispatch_rotate ); rc=$?
say "STOP $WHAT rc=$rc"
[ "$rc" = 0 ] || exit 1
