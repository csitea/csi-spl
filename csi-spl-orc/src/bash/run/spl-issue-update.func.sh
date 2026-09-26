#!/bin/bash
#------------------------------------------------------------------------------
# @description Advance an issue from a desk agent's pane (specs/039 FR-008):
# @description `spool issue update --as <agent> --ref <key>` with every ISSUE_*
# @description variable that is SET - an empty value clears (assignee,
# @description deadline, parent, labels). Typical: ISSUE_STATUS=wip
# @description when work starts, in_review / done when it lands. Prints one
# @description JSON line with the issue. Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the agent (the pane's id)
# @param ISSUE_REF - required: the issue key, e.g. SPL-12
# @param ISSUE_TITLE ISSUE_DESCRIPTION ISSUE_DESCRIPTION_FILE ISSUE_STATUS ISSUE_PRIORITY ISSUE_LEVEL ISSUE_ASSIGNEE ISSUE_LABELS ISSUE_DEADLINE ISSUE_EPIC ISSUE_KIND (optional) - as for do_spl_issue_create (ISSUE_EPIC moves it to another epic)
# @param DESK_BOX (optional) - default box-desk
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=CLE-00 ISSUE_REF=SPL-12 ISSUE_STATUS=wip DRY_RUN=0 ./run -a do_spl_issue_update
#------------------------------------------------------------------------------
do_spl_issue_update() {
  spl_issue_check_ref || return 1
  spl_issue_check_fields || return 1
  local args=()
  mapfile -t args < <(spl_issue_field_args)
  (( ${#args[@]} )) || { do_log "FATAL set at least one ISSUE_* field to change"; return 1; }
  spl_desk_issue update --ref "$ISSUE_REF" "${args[@]}" || return 1
  [[ "${DRY_RUN:-1}" == 0 ]] && do_log "OK ${DESK_AGENT} updated $ISSUE_REF"
  return 0
}
