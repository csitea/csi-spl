#!/usr/bin/env bash
# orch-rotate-cron.sh — run do_spl_orch_rotate DRY_RUN=0 from the box user's
# crontab (spec 060 FR-050, CLE-77939). Installed by
# do_spl_orch_rotate_install_cron as ONE line tagged `# csi-spl:orch-rotate`,
# hourly at :05 (the dispatcher rotation runs at :15).
#
# A cron job reads no profile: the PATH is set here and the tools are checked
# before any work, so a missing one names itself in the log.
#
#   orch-rotate-cron.sh [--check-tools]
#
# Exit: 0 rotated or skipped by a gate, 1 the rotation failed (rolled back and
# alerted), 2 usage or a refusal, 3 a tool this needs is not on the PATH.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
[ -n "${ROTATE_CRON_PATH_EXTRA:-}" ] && PATH="${ROTATE_CRON_PATH_EXTRA}:${PATH}"
export PATH
ROTATE_CRON_TOOLS="${ROTATE_CRON_TOOLS:-jq tmux flock timeout getent}"

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

CHECK_TOOLS=0
case "${1:-}" in
  --check-tools) CHECK_TOOLS=1 ;;
  "") ;;
  *) echo "orch-rotate-cron: unknown argument: $1" >&2; exit 2 ;;
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

say "START orchestrator rotation"
( cd "$ORC" && env DRY_RUN=0 ROTATE_CMD=auto ./run -a do_spl_orch_rotate ); rc=$?
say "STOP orchestrator rotation rc=$rc"
[ "$rc" = 0 ] || exit 1
