#!/bin/bash
#------------------------------------------------------------------------------
# @description File concrete, specced work as an issue from a desk agent's pane
# @description (specs/039 FR-008): owner rule, specced work and its progress go
# @description to Issues, talk stays in topics. `spool issue create --as
# @description <agent>` through the desk box. Prints one JSON line with the new
# @description issue (its key, e.g. SPL-12). Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the agent filing it (the pane's id)
# @param ISSUE_TITLE - required: the title
# @param ISSUE_DESCRIPTION (optional) - markdown; or ISSUE_DESCRIPTION_FILE
# @param ISSUE_STATUS (optional) - backlog (default) | todo | in_progress | in_review | done | canceled
# @param ISSUE_PRIORITY (optional) - 0 none, 1 urgent, 2 high, 3 medium, 4 low
# @param ISSUE_LEVEL (optional) - 0 none, 1 XS, 2 S, 3 M, 4 L, 5 XL
# @param ISSUE_ASSIGNEE (optional) - a member HUM-* or an agent id
# @param ISSUE_LABELS (optional) - label ids, comma separated
# @param ISSUE_DEADLINE (optional) - RFC 3339 with a zone, e.g. 2026-10-01T15:00:00Z
# @param ISSUE_PARENT (optional) - parent issue key
# @param DESK_BOX (optional) - default box-desk
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=CLE-00 ISSUE_TITLE='Rotate the relay key' ISSUE_PRIORITY=2 ISSUE_ASSIGNEE=CLE-00 DRY_RUN=0 ./run -a do_spl_issue_create
#------------------------------------------------------------------------------
do_spl_issue_create() {
  [[ -n "${ISSUE_TITLE:-}" ]] || { do_log "FATAL ISSUE_TITLE must carry the issue title"; return 1; }
  spl_issue_check_fields || return 1
  local args=()
  mapfile -t args < <(spl_issue_field_args)
  spl_desk_issue create "${args[@]}" || return 1
  [[ "${DRY_RUN:-1}" == 0 ]] && do_log "OK ${DESK_AGENT} filed an issue in ${TENANT_ID}"
  return 0
}
