#!/bin/bash
#------------------------------------------------------------------------------
# @description A live discussion takes the stored priority of the archived one
# @description it carries on, from a desk agent's pane: `spool issue
# @description inherit-priority --as <agent> --from <archived> --to <live>`
# @description (SPL-5147). The hub copies the value: the caller names no number.
# @description It refuses unless the source is archived and the target live, in
# @description the desk's workspace; a source with none writes nothing and a
# @description priority the target has is kept. Prints the hub's JSON line.
# @param ENV - required: dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the desk agent that acts
# @param PRIORITY_FROM - required: the archived topic's uuid
# @param PRIORITY_TO - required: the live topic's uuid
# @param DESK_BOX (optional) - default box-desk
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=c-002 PRIORITY_FROM=<uuid> PRIORITY_TO=<uuid> DRY_RUN=0 ./run -a do_spl_topic_inherit_priority
#------------------------------------------------------------------------------
do_spl_topic_inherit_priority() {
  local uuid='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' v
  for v in PRIORITY_FROM PRIORITY_TO; do
    [[ "${!v:-}" =~ $uuid ]] || { do_log "FATAL $v must be a topic uuid, got: '${!v:-}'"; return 1; }
  done
  spl_desk_issue inherit-priority --from "$PRIORITY_FROM" --to "$PRIORITY_TO"
}
