#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the peer-ensure cron (spec 068 section
# @description 6.1, lane L6): ONE line in the box user's crontab running
# @description src/bash/scripts/peer-ensure-cron.sh, the poll-loop keeper of this box's seats, the reboot path (do_spl_peer_ensure, spec 068 6.1),
# @description at `* * * * *` (M = PEER_RESTART_OFFSET).
# @description Tagged `# <org>-<app>:peer-ensure`, matched EXACTLY at the end of the
# @description line; idempotent (the tagged line is replaced in place, never
# @description appended). It points at the same self-updating checkout as the
# @description desk reconcile (<shared checkout>-desk-cron, DESK_CRON_SRC
# @description overrides; an agent worktree is refused). do_spl_peer_crons
# @description APPLY=1 installs all three peer crons at once.
# @description Dry run unless DRY_RUN=0 (prints the crontab diff).
# @param PEER_CRON_ACTION (optional) - install (default) | remove | check
# @param CRON_REMOVE (optional) - 1 = PEER_CRON_ACTION=remove
# @param PEER_RESTART_OFFSET (optional) - M, 0..14; env > <spool root>/peer/peer.conf > 0
# @param PEER_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/peer
# @param DESK_CRON_SRC / DESK_CRON_SELF_UPDATE / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_peer_ensure_install_cron
# @example DRY_RUN=0 ./run -a do_spl_peer_ensure_install_cron
# @example PEER_CRON_ACTION=check ./run -a do_spl_peer_ensure_install_cron
#------------------------------------------------------------------------------
declare -F spl_peer_cron_install >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-peer-crons.func.sh"

do_spl_peer_ensure_install_cron() {
  spl_peer_cron_install ensure
}
