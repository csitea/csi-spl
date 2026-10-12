#!/bin/bash
# @description Put a spawn request in line (owner HUM-10, t1 c9beaa77; rdb
# @description 0180): the ask goes queued on the hub with its position, and its
# @description sender is told on its task "queued, position N of M, placed when
# @description the box has room". From then on the asks tick never re-raises,
# @description escalates or dead-letters it; the placer (do_spl_spawn_place)
# @description takes it when it is position 1 and the box has room. The
# @description acting orchestrator runs this instead of acking a spawn request
# @description it cannot place now. Enqueueing a queued ask again keeps its
# @description place (and sets a new placement when one is given).
# @param ASK_ID (required) - the ask id, or its first 8 hex digits (do_spl_asks_open prints them)
# @param SPAWN_PLACE (optional) - <vendor>:<slug>: the placer launches it itself, `spawn-window.sh <vendor> auto <workdir> <brief> <slug>`, with the brief file <slug>.md under SPAWN_PLACE_BRIEF_DIR on the orch box. Unset: the placer hands it to the orchestrator when it is next
# @param ASK_BY (optional) - the acting agent, <ID>@<box>; default this machine's orchestrator
# @param ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD (optional) - as do_spl_asks_open
# @example ASK_ID=8a70dfd7 ./run -a do_spl_spawn_enqueue
# @example ASK_ID=8a70dfd7 SPAWN_PLACE=claude:hub-pg-split ./run -a do_spl_spawn_enqueue

do_spl_spawn_enqueue() {
  local place="${SPAWN_PLACE:-}" by id row pos len rc=0
  [[ -z "$place" || "$place" =~ ^[a-z]{2,16}:[a-z0-9][a-z0-9._-]{0,63}$ ]] ||
    { do_log "FATAL SPAWN_PLACE must be <vendor>:<slug> (lowercase), got '$place'"; return 1; }
  spl_spawn_q_init || return 1
  by="$(spl_asks_by)" || return 1
  id="$(spl_spawn_q_resolve)" || return 1
  row="$(spl_spawn_q_op queue "$id" "$by" "" "$place")" || rc=$?
  (( rc == 0 )) || return "$rc"
  pos="$(jq -r '.position // 0' <<<"$row")"
  len="$(jq -r '.queue_len // 0' <<<"$row")"
  if ! spl_spawn_q_reply "$row" "$by" "queued, position $pos of $len, placed when the box has room (ask ${id:0:8}; the queue: \`./run -a do_spl_spawn_queue\`)"; then
    do_log "WARN ask ${id:0:8} is queued but its sender was not told"
  fi
  do_log "OK ask ${id:0:8} queued: position $pos of $len${place:+, placement $place}"
}
