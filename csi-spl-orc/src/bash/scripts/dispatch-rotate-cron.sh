#!/usr/bin/env bash
# dispatch-rotate-cron.sh — run do_spl_dispatch_rotate DRY_RUN=0 from the box
# user's crontab (SPEC-spool-fleet-roles.md 4.4). Installed by
# do_spl_dispatch_rotate_install_cron as ONE line tagged
# `# csi-spl:dispatch-rotate`, at :15 and :45 (SPL-4795); with --heal it runs
# the HEAL step alone (ROTATE_CMD=heal), the line tagged `# csi-spl:dispatch-heal`,
# every 3 min, then the seat age check (ROTATE_CMD=age: one SEAT line per
# dispatcher, one note when one is past 30 min + grace).
#
# A cron job reads no profile: rotate-cron.inc.sh sets the PATH and the tools
# are checked before any work, so a missing one names itself in the log.
#
#   dispatch-rotate-cron.sh [--heal | --check-tools]
#
# Exit: 0 rotated, skipped or held off by the lock; 1 the rotation failed (the
# old sessions keep their roles, the action raised the alert); 2 usage or a
# refusal; 3 a tool this needs is not on the PATH.
set -uo pipefail
ROTATE_CRON_TOOLS="${ROTATE_CRON_TOOLS:-python3 jq tmux flock git}"

CHECK_TOOLS=0 CMD=auto WHAT="dispatcher rotation"
case "${1:-}" in
  --check-tools) CHECK_TOOLS=1 ;;
  --heal) CMD=heal WHAT="dispatcher heal" ;;
  "") ;;
  *) echo "dispatch-rotate-cron: unknown argument: $1" >&2; exit 2 ;;
esac

# shellcheck source=rotate-cron.inc.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/rotate-cron.inc.sh"
check_tools || exit $?
if [ "$CHECK_TOOLS" = 1 ]; then say "OK every tool the rotation needs resolves: $ROTATE_CRON_TOOLS"; exit 0; fi
rotate_cron_orc || exit $?

say "START $WHAT"
( cd "$ORC" && env DRY_RUN=0 ROTATE_CMD="$CMD" ./run -a do_spl_dispatch_rotate ); rc=$?
say "STOP $WHAT rc=$rc"
if [ "$CMD" = heal ]; then
  ( cd "$ORC" && env DRY_RUN=0 ROTATE_CMD=age ./run -a do_spl_dispatch_rotate ); arc=$?
  say "STOP dispatcher age check rc=$arc (3 = a seat past 30 min + grace)"
fi
[ "$rc" = 0 ] || exit 1
