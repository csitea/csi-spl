#!/bin/bash
#------------------------------------------------------------------------------
# @description Advance an issue from a desk agent's pane (specs/039 FR-008):
# @description `spool issue update --as <agent> --ref <key>` with every ISSUE_*
# @description variable that is SET - an empty value clears (assignee,
# @description deadline, parent, labels). Typical: ISSUE_STATUS=wip
# @description when work starts; the hourly do_spl_issue_close_landed moves
# @description it to done when its commit lands. qas holds only a review a
# @description human asked for (spec 135 Q7): ISSUE_STATUS=qas needs
# @description ISSUE_QAS_ASKED_BY (HUM-n or the msg id), unless the issue is
# @description already in qas. Prints one JSON line with the issue. Dry run
# @description unless DRY_RUN=0.
# @param ENV - required: dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the agent (the pane's id)
# @param ISSUE_REF - required: the issue key, e.g. SPL-12
# @param ISSUE_TITLE ISSUE_DESCRIPTION ISSUE_DESCRIPTION_FILE ISSUE_STATUS ISSUE_PRIORITY ISSUE_LEVEL ISSUE_ASSIGNEE ISSUE_LABELS ISSUE_DEADLINE ISSUE_EPIC ISSUE_KIND (optional) - as for do_spl_issue_create (ISSUE_EPIC moves it to another epic)
# @param ISSUE_QAS_ASKED_BY (optional) - required with ISSUE_STATUS=qas: the human (HUM-n) or the msg id that asked for the review
# @param DESK_BOX (optional) - default box-desk
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=CLE-00 ISSUE_REF=SPL-12 ISSUE_STATUS=wip DRY_RUN=0 ./run -a do_spl_issue_update
#------------------------------------------------------------------------------
do_spl_issue_update() {
  spl_issue_check_ref || return 1
  spl_issue_check_fields || return 1
  local args=()
  mapfile -d '' -t args < <(spl_issue_field_args)
  (( ${#args[@]} )) || { do_log "FATAL set at least one ISSUE_* field to change"; return 1; }
  spl_issue_qas_guard update || return 1
  spl_desk_issue update --ref "$ISSUE_REF" "${args[@]}" || return 1
  [[ "${DRY_RUN:-1}" == 0 ]] && do_log "OK ${DESK_AGENT} updated $ISSUE_REF"
  return 0
}
