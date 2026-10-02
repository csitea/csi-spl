#!/bin/bash
# @description Push this machine's journal asks the hub has not got yet
# @description (CLE-77929; SPEC-spool-fleet-roles.md 4.3): a new ask is put, a
# @description later state (acked, done, declined) is replayed as its op, and a
# @description close the hub already has from another machine takes the hub's
# @description row. spool-send.sh runs it in the background after recording an
# @description ask, and every machine's lease tick runs it (do_spl_asks_tick),
# @description so an ask written while the hub was down reaches it once the hub
# @description answers. Without a fleet it is a logged no-op.
# @param ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD (optional) - as do_spl_asks_open
# @example ./run -a do_spl_asks_sync

do_spl_asks_sync() {
  spl_asks_init || return 1
  if [[ "$LANE_MODE" != hub ]]; then
    do_log "INFO no fleet hub here: the journal is the whole book, nothing to push"
    return 0
  fi
  spl_asks_sync_pending
}
