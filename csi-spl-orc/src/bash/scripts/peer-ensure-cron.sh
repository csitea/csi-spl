#!/usr/bin/env bash
# peer-ensure-cron.sh - run do_spl_peer_ensure from the box user's crontab: the poll loops of this box's seats
# (spec 068 section 6.1, lane L6). Installed by do_spl_peer_ensure_install_cron
# (or do_spl_peer_crons APPLY=1) as ONE line tagged `# csi-spl:peer-ensure`,
# at every minute (M = PEER_RESTART_OFFSET).
#
# A cron job reads no profile: peer-cron.inc.sh sets the PATH and checks the
# tools before any work, so a missing one names itself in the log.
#
#   peer-ensure-cron.sh [--check-tools]
#
# Exit: 0 done or nothing to do, 1 the action failed, 2 usage or a refusal,
# 3 a tool this needs is not on the PATH.
set -uo pipefail
# shellcheck source=peer-cron.inc.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/peer-cron.inc.sh"
peer_cron_main ensure -- "$@"
