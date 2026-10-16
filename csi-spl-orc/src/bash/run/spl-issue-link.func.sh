#!/bin/bash
#------------------------------------------------------------------------------
# @description Link an issue to one more discussion, or unlink one, from a desk
# @description agent's pane: `spool issue link|unlink --as <agent> --ref <key>
# @description --discussion <topic>`. A create links its first discussions
# @description (do_spl_issue_create ISSUE_DISCUSSIONS); this adds or drops one
# @description later. The hub never unlinks an issue's last discussion. Prints
# @description one JSON line with the issue. Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the agent (the pane's id)
# @param ISSUE_REF - required: the issue key, e.g. SPL-12
# @param ISSUE_DISCUSSION - required: the topic uuid, or its /t/<uuid> link
# @param MODE (optional) - link (default) or unlink
# @param DESK_BOX (optional) - default box-desk
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=CLE-00 ISSUE_REF=SPL-12 ISSUE_DISCUSSION=0f8fad5b-d9cb-469f-a165-70867728950e DRY_RUN=0 ./run -a do_spl_issue_link
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=CLE-00 ISSUE_REF=SPL-12 ISSUE_DISCUSSION=/t/0f8fad5b-d9cb-469f-a165-70867728950e MODE=unlink DRY_RUN=0 ./run -a do_spl_issue_link
#------------------------------------------------------------------------------
do_spl_issue_link() {
  spl_issue_check_ref || return 1
  local mode="${MODE:-link}" d="${ISSUE_DISCUSSION:-}"
  local uuid='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
  [[ "$mode" == link || "$mode" == unlink ]] ||
    { do_log "FATAL MODE must be link or unlink, got: '$mode'"; return 1; }
  [[ "$d" =~ ^${uuid}$ || "$d" =~ ^([^[:space:]]*/)?t/${uuid}$ ]] ||
    { do_log "FATAL ISSUE_DISCUSSION must be a topic uuid or its /t/<uuid> link, got: '$d'"; return 1; }
  spl_desk_issue "$mode" --ref "$ISSUE_REF" --discussion "$d" || return 1
  [[ "${DRY_RUN:-1}" == 0 ]] && do_log "OK ${DESK_AGENT} ${mode}ed $ISSUE_REF and $d"
  return 0
}
