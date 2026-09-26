#!/bin/bash
#------------------------------------------------------------------------------
# @description A desk agent's issues (specs/039 FR-008): `spool issue list --as
# @description <agent>` with the issues-v1 §4 filters. Default: the ones
# @description assigned to the agent itself, open (not done / canceled),
# @description Linear's priority order. Read-only, but like every desk action
# @description it calls the hub only with DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the agent (the pane's id)
# @param ISSUE_ASSIGNEE (optional) - default me; any id, none, or '' for everyone
# @param ISSUE_STATUS (optional) - comma list; default backlog,todo,in_progress,in_review
# @param ISSUE_PRIORITY ISSUE_LEVEL ISSUE_LABEL (optional) - comma lists
# @param ISSUE_SORT (optional) - priority (default) | level | deadline | updated | created
# @param DESK_BOX (optional) - default box-desk
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=CLE-00 DRY_RUN=0 ./run -a do_spl_issue_list
#------------------------------------------------------------------------------
do_spl_issue_list() {
  local args=() v
  local assignee="${ISSUE_ASSIGNEE-me}" status="${ISSUE_STATUS-backlog,todo,in_progress,in_review}"
  [[ -z "$assignee" ]] || args+=(--assignee "$assignee")
  [[ -z "$status" ]] || args+=(--status "$status")
  for v in PRIORITY:priority LEVEL:level LABEL:label SORT:sort; do
    local n="ISSUE_${v%%:*}"
    [[ -n "${!n:-}" ]] && args+=("--${v#*:}" "${!n}")
  done
  spl_desk_issue list "${args[@]}"
}
