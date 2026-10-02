#!/bin/bash
# @description Ack one ask to the orchestrator: "in progress, mine"
# @description (CLE-77929; SPEC-spool-fleet-roles.md 4.3). An acked ask is no
# @description longer re-raised by the lease tick (unless its deadline passes);
# @description it stays in do_spl_asks_open until do_spl_ask_close. Written to
# @description the journal first, then the hub; a hub refusal because another
# @description holder already closed it prints who closed it and why.
# @param ASK_ID (required) - the ask id, or its first 8 hex digits (do_spl_asks_open prints them)
# @param ASK_BY (optional) - the acting agent, <ID>@<box>; default this machine's orchestrator (LEASE_ORCH) at its box
# @param ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD (optional) - as do_spl_asks_open
# @example ASK_ID=39451306 ./run -a do_spl_ask_ack

do_spl_ask_ack() {
  spl_ask_update ack acked ""
}

# The shared update of ack / close: OP (ack|done|decline) and the journal
# STATE it means, with a REASON. Resolves ASK_ID against the merged book.
spl_ask_update() {
  local op="$1" state="$2" reason="$3" rows id by out cur
  spl_asks_init || return 1
  by="$(spl_asks_by)" || return 1
  spl_asks_sync_pending
  spl_asks_load || return 1
  rows="$ASKS_ROWS"
  id="$(spl_asks_resolve "${ASK_ID:-}" "$rows")" || return 1
  cur="$(jq -c --arg id "$id" '.[] | select(.ask_id == $id)' <<<"$rows")"
  if [[ "$(jq -r '.state' <<<"$cur")" =~ ^(done|declined|dead)$ ]]; then
    do_log "WARN ask ${id:0:8} is already $(jq -r '.state + " by " + .closed_by + ": " + .reason' <<<"$cur")"
    return 3
  fi
  spool_ask_journal_get "$id" >/dev/null 2>&1 || jq -c '. + {synced: true} | del(.src, .overdue, .age_s, .quiet_s, .writer_box)' <<<"$cur" | _spool_ask_write "$id"
  local fields
  if [[ "$op" == ack ]]; then
    fields="$(jq -n -c --arg b "$by" '{state: "acked", acked_by: $b, synced: false}')"
  else
    fields="$(jq -n -c --arg s "$state" --arg b "$by" --arg r "$reason" '{state: $s, closed_by: $b, reason: $r, synced: false}')"
  fi
  spool_ask_journal_set "$id" "$fields" "$op" "$by" || { do_log "FATAL the journal did not take the $op of ${id:0:8}"; return 1; }
  if [[ "$LANE_MODE" == hub ]]; then
    if out="$(spl_asks_hub "$op" --fleet "$LANE_FLEET" --id "$id" --by "$by" --reason "$reason" 2>&1)"; then
      spool_ask_journal_set "$id" '{"synced":true}' sync hub
    elif grep -q 'ask_closed' <<<"$out"; then
      do_log "WARN ask ${id:0:8}: the hub says $(tail -1 <<<"$out")"
      spool_ask_journal_set "$id" '{"synced":true}' sync hub
      return 3
    else
      do_log "WARN ask ${id:0:8} $op is journaled; the hub did not take it yet ($(tail -1 <<<"$out")): the next lease tick pushes it"
    fi
  fi
  do_log "OK ask ${id:0:8} $state by $by${reason:+ ($reason)}"
  [[ "$op" == ack ]] || spl_asks_archive_msg "$id"
  return 0
}

# A closed ask's carrying message leaves the orchestrator's inbox for its
# archive/ on this machine (the inbox shows what is still to do).
spl_asks_archive_msg() {
  local id="$1" d f n=0
  for d in "$SPOOL_ROOT"/*/inbox; do
    [[ -d "$d" ]] || continue
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      mkdir -p "${d%/inbox}/archive" 2>/dev/null
      mv -f "$f" "${d%/inbox}/archive/" 2>/dev/null && n=$((n + 1))
    done < <(grep -l -F "\"msg_id\":\"$id\"" "$d"/*.json 2>/dev/null; grep -l -F "\"msg_id\": \"$id\"" "$d"/*.json 2>/dev/null)
  done
  (( n > 0 )) && do_log "INFO archived $n inbox file(s) of ask ${id:0:8}"
  return 0
}
