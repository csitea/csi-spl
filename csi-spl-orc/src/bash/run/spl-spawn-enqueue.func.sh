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
# @description Every request carries its work class (SPL-1817, rdb 0195): the
# @description queue places by class and the placer keeps the bands of the live
# @description lanes; the rule's one home is
# @description csi-spl-doc/doc/md/fleet-rules-index.md.
# @param SPAWN_CLASS (required) - ci (a CI-red fix on trunk), refactor, bug or feature; no default, never guessed
# @param SPAWN_URGENT (optional) - 1: a bug placed even over its band (owner-reported prd breakage; the dispatcher's call)
# @param SPAWN_BYPASS (optional) - the owner message id (a UUID) that explicitly asked for this feature outside the bands; ONLY on the owner's ask, recorded and listed by do_spl_spawn_share
# @param ASK_ID (required) - the ask id, or its first 8 hex digits (do_spl_asks_open prints them)
# @param SPAWN_PLACE (optional) - <vendor>:<slug>: the placer launches it itself, `spawn-window.sh <vendor> auto <workdir> <brief> <slug>`, with the brief file <slug>.md under SPAWN_PLACE_BRIEF_DIR on the orch box. Unset: the placer hands it to the orchestrator when it is next
# @param ASK_BY (optional) - the acting agent, <ID>@<box>; default this machine's orchestrator
# @param ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD (optional) - as do_spl_asks_open
# @example ASK_ID=8a70dfd7 SPAWN_CLASS=refactor ./run -a do_spl_spawn_enqueue
# @example ASK_ID=8a70dfd7 SPAWN_CLASS=bug SPAWN_PLACE=claude:hub-pg-split ./run -a do_spl_spawn_enqueue
# @example ASK_ID=8a70dfd7 SPAWN_CLASS=feature SPAWN_BYPASS=8cb6cc7d-7628-4ac3-be00-86e427bb3487 ./run -a do_spl_spawn_enqueue

do_spl_spawn_enqueue() {
  local by id row pos len rc=0
  spl_spawn_q_init || return 1
  by="$(spl_asks_by)" || return 1
  id="$(spl_spawn_q_resolve)" || return 1
  row="$(spl_spawn_q_enqueue "$id" "$by" "${SPAWN_PLACE:-}" "${SPAWN_CLASS:-}" "${SPAWN_URGENT:-0}" "${SPAWN_BYPASS:-}")" || rc=$?
  (( rc == 0 )) || return "$rc"
  pos="$(jq -r '.position // 0' <<<"$row")"
  len="$(jq -r '.queue_len // 0' <<<"$row")"
  if ! spl_spawn_q_reply "$row" "$by" "queued, position $pos of $len, placed when the box has room (ask ${id:0:8}; the queue: \`./run -a do_spl_spawn_queue\`)"; then
    do_log "WARN ask ${id:0:8} is queued but its sender was not told"
  fi
}

# One ask into the queue: the checks, the hub's queue op, the bypass record;
# the hub's row on stdout, the log on stderr. The one path every queue row
# takes: a single enqueue, and each row a work group feeds
# (spl-spawn-group-put.func.sh; a single ask is a group of one row, width 1).
spl_spawn_q_enqueue() {  # ID BY PLACE CLASS URGENT(0|1) BYPASS_MSG
  local id="$1" by="$2" place="$3" class="$4" msg="$6" flag="" row rc=0
  [[ -z "$place" || "$place" =~ ^[a-z]{2,16}:[a-z0-9][a-z0-9._-]{0,63}$ ]] ||
    { do_log "FATAL SPAWN_PLACE must be <vendor>:<slug> (lowercase), got '$place'" >&2; return 1; }
  [[ "$class" =~ ^(ci|refactor|bug|feature)$ ]] ||
    { do_log "FATAL SPAWN_CLASS must be ci, refactor, bug or feature (got '$class'; no default: classify the request)" >&2; return 1; }
  [[ "$5" == 1 ]] && flag=urgent
  if [[ -n "$msg" ]]; then
    [[ "$msg" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
      { do_log "FATAL SPAWN_BYPASS must be the owner's message id (a full lowercase UUID), got '$msg'" >&2; return 1; }
    flag=bypass
  fi
  [[ "$flag" != urgent || "$class" == bug ]] || { do_log "FATAL SPAWN_URGENT goes with SPAWN_CLASS=bug only" >&2; return 1; }
  [[ "$flag" != bypass || "$class" == feature ]] || { do_log "FATAL SPAWN_BYPASS goes with SPAWN_CLASS=feature only" >&2; return 1; }
  [[ -z "$msg" || "$5" != 1 ]] || { do_log "FATAL SPAWN_URGENT and SPAWN_BYPASS exclude each other" >&2; return 1; }
  row="$(spl_spawn_q_op queue "$id" "$by" "" "$place" "$class" "$flag" "$msg")" || rc=$?
  (( rc == 0 )) || return "$rc"
  if [[ "$flag" == bypass ]]; then
    spl_spawn_share_bypass_record "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$id" "$msg" "$by" "$(jq -r '.summary // ""' <<<"$row")" ||
      do_log "WARN the bypass of ask ${id:0:8} is on the hub row but not in the local bypass log" >&2
    do_log "INFO ask ${id:0:8} is a feature BYPASS on owner msg ${msg:0:8}: recorded, listed by do_spl_spawn_share" >&2
  fi
  do_log "OK ask ${id:0:8} queued ($class${flag:+, $flag}): position $(jq -r '.position // 0' <<<"$row") of $(jq -r '.queue_len // 0' <<<"$row")${place:+, placement $place}" >&2
  printf '%s\n' "$row"
}
