#!/bin/bash
# @description Close a spawn request as placed (owner HUM-10, t1 c9beaa77;
# @description rdb 0180): the ask goes done with the reason "placed:
# @description <ID>@<box>", its carrying message leaves the inbox, and its
# @description sender is told on its task "placed: <ID>@<box>". The next one in
# @description line moves up. The placer (do_spl_spawn_place) runs it itself
# @description for a placement it launched; the orchestrator runs it after
# @description placing one the placer handed to it.
# @param ASK_ID (required) - the ask id, or its first 8 hex digits
# @param PLACED_AS (required) - the new agent, <ID>@<box>
# @param ASK_BY (optional) - the acting agent, <ID>@<box>; default this machine's orchestrator
# @param ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD (optional) - as do_spl_asks_open
# @example ASK_ID=8a70dfd7 PLACED_AS=c-281@box-b ./run -a do_spl_spawn_placed

do_spl_spawn_placed() {
  local as="${PLACED_AS:-}" by id
  [[ "$as" =~ ^[a-zA-Z0-9-]{3,16}@[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL PLACED_AS must be the new agent, <ID>@<box>, got '$as'"; return 1; }
  spl_spawn_q_init || return 1
  by="$(spl_asks_by)" || return 1
  id="$(spl_spawn_q_resolve)" || return 1
  spl_spawn_placed_close "$id" "$by" "$as"
}

# done "placed: AS" on the hub, the sender told, the inbox file archived.
spl_spawn_placed_close() {  # ID BY AS
  local row rc=0
  row="$(spl_spawn_q_op "done" "$1" "$2" "placed: $3")" || rc=$?
  (( rc == 0 )) || return "$rc"
  spl_spawn_q_reply "$row" "$2" "placed: $3" || do_log "WARN ask ${1:0:8} is placed but its sender was not told"
  spl_asks_archive_msg "$1"
  do_log "OK ask ${1:0:8} placed: $3"
}
