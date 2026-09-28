#!/bin/bash
#------------------------------------------------------------------------------
# @description Delete an issue a desk agent filed by mistake (SPL-1131): the
# @description soft delete of rdb 0071, `spool issue delete --as <agent> --ref
# @description <key>`. Only the agent that created the issue may delete it (the
# @description hub refuses any other with forbidden); a member or admin deletes
# @description from the WUI. Prints one JSON line (the issue as it was).
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the agent (the pane's id), the issue's creator
# @param ISSUE_REF - required: the issue key, e.g. SPL-12
# @param DESK_BOX (optional) - default box-desk
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=CLE-00 ISSUE_REF=SPL-12 DRY_RUN=0 ./run -a do_spl_issue_delete
#------------------------------------------------------------------------------
do_spl_issue_delete() {
  spl_issue_check_ref || return 1
  spl_desk_issue delete --ref "$ISSUE_REF" || return 1
  [[ "${DRY_RUN:-1}" == 0 ]] && do_log "OK ${DESK_AGENT} deleted $ISSUE_REF"
  return 0
}
