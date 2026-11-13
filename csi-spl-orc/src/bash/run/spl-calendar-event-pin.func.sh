#!/bin/bash
#------------------------------------------------------------------------------
# @description Pin (or unpin) events of one workspace's calendar, AS AN AGENT,
# @description THROUGH THE HUB: PATCH /v1/operator/calendar/events/<id> with
# @description props.pinned and nothing else (calendar_operator_write.go,
# @description SPL-5453). A pinned event leads its day in every calendar view
# @description (spec 097 section 3.3.1). Only a single workspace event: a
# @description private, synced or repeating one is refused by the hub. Each id
# @description is read back (GET, pinned as asked). The per-id driver is
# @description _spl_calendar_event_each (spl-calendar-event-delete.func.sh).
# @description DRY_RUN=1 (default): print what it would send, write nothing.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the workspace slug
# @param EVENT_IDS - required: 1..200 event ids (uuids), comma- or space-separated
# @param AGENT_ID - required: the agent doing it, e.g. c-042
# @param ORDERED_BY (optional) - the human who ordered it, a HUM-* id (logged by the hub)
# @param PINNED (optional) - 1 (default) pins, 0 unpins
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=<tenant> EVENT_IDS=<uuid>,<uuid> AGENT_ID=c-042 ORDERED_BY=HUM-10 ./run -a do_spl_calendar_event_pin
#------------------------------------------------------------------------------
do_spl_calendar_event_pin() {
  do_require_bin jq curl gcloud || return 1
  _spl_calendar_event_each pin
}
