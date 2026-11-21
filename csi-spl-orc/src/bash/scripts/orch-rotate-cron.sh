#!/usr/bin/env bash
# orch-rotate-cron.sh — run do_spl_orch_rotate DRY_RUN=0 from the box user's
# crontab (spec 060 FR-050, CLE-77939). Installed by
# do_spl_orch_rotate_install_cron as ONE line tagged `# csi-spl:orch-rotate`,
# hourly at :05 (the dispatcher rotation runs at :15).
#
# A cron job reads no profile: rotate-cron.inc.sh sets the PATH and the tools
# are checked before any work, so a missing one names itself in the log.
#
#   orch-rotate-cron.sh [--check-tools]
#
# Exit: 0 rotated or skipped by a gate, 1 the rotation failed (rolled back and
# alerted), 2 usage or a refusal, 3 a tool this needs is not on the PATH.
set -uo pipefail
ROTATE_CRON_TOOLS="${ROTATE_CRON_TOOLS:-jq tmux flock timeout getent}"

CHECK_TOOLS=0
case "${1:-}" in
  --check-tools) CHECK_TOOLS=1 ;;
  "") ;;
  *) echo "orch-rotate-cron: unknown argument: $1" >&2; exit 2 ;;
esac

# shellcheck source=rotate-cron.inc.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/rotate-cron.inc.sh"
check_tools || exit $?
if [ "$CHECK_TOOLS" = 1 ]; then say "OK every tool the rotation needs resolves: $ROTATE_CRON_TOOLS"; exit 0; fi
rotate_cron_orc || exit $?

say "START orchestrator rotation"
( cd "$ORC" && env DRY_RUN=0 ROTATE_CMD=auto ./run -a do_spl_orch_rotate ); rc=$?
say "STOP orchestrator rotation rc=$rc"
[ "$rc" = 0 ] || exit 1
