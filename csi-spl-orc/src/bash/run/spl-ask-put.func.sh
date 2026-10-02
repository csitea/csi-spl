#!/bin/bash
# @description Record one ask to the orchestrator by hand (CLE-77929;
# @description SPEC-spool-fleet-roles.md 4.3): the journal first
# @description (<spool root>/asks/<id>.json, never lost to a hub outage), then
# @description the hub (rdb 0097, `spool ask put`). spool-send.sh already does
# @description this for every blocker / task it sends to the orchestrator and
# @description for --ask <kind>; this action is for an ask raised another way
# @description (kind escalation, a WUI post relayed by a dispatcher). A put is
# @description idempotent on ASK_ID: a replay changes nothing. The hub leg is
# @description best effort - the next lease tick pushes what it missed.
# @param ASK_ID (required) - the msg_id of the message that carries the ask (a lowercase UUID)
# @param ASK_KIND (required) - blocker, task or escalation
# @param ASK_FROM (required) - the sender, <ID> or <ID>@<box> (a bare id gets this machine's box)
# @param ASK_SUMMARY (optional) - one line, cut to 200 bytes
# @param ASK_TOPIC (optional) - the topic (task id)
# @param ASK_TO (optional) - the orchestrator it went to, for the record
# @param ASK_DEADLINE (optional) - when it is due, RFC 3339 UTC (2026-10-02T06:00:00Z)
# @param ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD (optional) - as do_spl_asks_open
# @example ASK_ID=39451306-8830-4e8e-878c-eb29f2803839 ASK_KIND=escalation ASK_FROM=CLE-002 ASK_TOPIC=692aefe8 ASK_SUMMARY='no lane for 6 h' ./run -a do_spl_ask_put

do_spl_ask_put() {
  [[ "${ASK_ID:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { do_log "FATAL ASK_ID must be the carrying msg_id (a lowercase UUID)"; return 1; }
  [[ "${ASK_KIND:-}" =~ ^(blocker|task|escalation)$ ]] || { do_log "FATAL ASK_KIND must be blocker, task or escalation"; return 1; }
  [[ -z "${ASK_DEADLINE:-}" || "$ASK_DEADLINE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { do_log "FATAL ASK_DEADLINE must be RFC 3339 UTC, e.g. 2026-10-02T06:00:00Z"; return 1; }
  spl_asks_init || return 1
  local from="${ASK_FROM:-}"
  [[ "$from" =~ ^${SPOOL_PARTICIPANT_RX}$ ]] && from="$from@$ASKS_BOX"
  { spl_is_participant_id "${from%@*}" && [[ "$from" =~ @[a-z0-9][a-z0-9-]{0,31}$ ]]; } || { do_log "FATAL ASK_FROM must be <ID> or <ID>@<box>, got '${ASK_FROM:-}'"; return 1; }
  spool_ask_journal_open "$ASK_ID" "$ASK_KIND" "$from" "${ASK_TO:-}" "${ASK_TOPIC:-}" \
    "$(spool_ask_summary "${ASK_SUMMARY:-}")" "${ASK_DEADLINE:-}" || { do_log "FATAL the journal did not take ask $ASK_ID"; return 1; }
  do_log "OK ask ${ASK_ID:0:8} journaled ($ASK_KIND from $from)"
  spl_asks_sync_pending
}
