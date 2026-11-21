#!/usr/bin/env bash
# peer-distill-cron.sh - run do_spl_peer_distill from the box user's crontab: the summary poke of the seat due next
# (spec 068 section 6.1, lane L6). Installed by do_spl_peer_distill_install_cron
# (or do_spl_peer_crons APPLY=1) as ONE line tagged `# csi-spl:peer-distill`,
# at M+10,M+25,M+40,M+55 (M = PEER_RESTART_OFFSET).
#
# A cron job reads no profile: peer-cron.inc.sh sets the PATH and checks the
# tools before any work, so a missing one names itself in the log.
#
#   peer-distill-cron.sh [--check-tools]
#
# Exit: 0 done or nothing to do, 1 the action failed, 2 usage or a refusal,
# 3 a tool this needs is not on the PATH.
set -uo pipefail
# shellcheck source=peer-cron.inc.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/peer-cron.inc.sh"
peer_cron_main distill DRY_RUN=0 -- "$@"
