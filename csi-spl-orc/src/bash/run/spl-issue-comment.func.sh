#!/bin/bash
#------------------------------------------------------------------------------
# @description Post a desk agent's progress on an issue (specs/039 FR-008): a
# @description reply-level note in the issue's discussion, shown in its right
# @description pane, never a card in #tasks. `spool issue comment --as <agent>
# @description --ref <key>`. Prints one JSON line (the comment's msg_id and the
# @description issue's task_id). Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the agent (the pane's id)
# @param ISSUE_REF - required: the issue key, e.g. SPL-12
# @param ISSUE_BODY - required unless ISSUE_BODY_FILE: the progress text (markdown renders, no fence needed: csi-spl-doc/doc/help/how-to-post.md)
# @param ISSUE_BODY_FILE (optional) - read the text from this file
# @param DESK_BOX (optional) - default box-desk
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=CLE-00 ISSUE_REF=SPL-12 ISSUE_BODY='key rotated on dev' DRY_RUN=0 ./run -a do_spl_issue_comment
#------------------------------------------------------------------------------
do_spl_issue_comment() {
  spl_issue_check_ref || return 1
  if [[ -n "${ISSUE_BODY_FILE:-}" ]]; then
    [[ -r "$ISSUE_BODY_FILE" ]] || { do_log "FATAL ISSUE_BODY_FILE is not a readable file: '$ISSUE_BODY_FILE'"; return 1; }
    spl_desk_issue comment --ref "$ISSUE_REF" --body-file "$ISSUE_BODY_FILE" || return 1
  else
    [[ -n "${ISSUE_BODY:-}" ]] || { do_log "FATAL ISSUE_BODY (or ISSUE_BODY_FILE) must carry the progress text"; return 1; }
    spl_desk_issue comment --ref "$ISSUE_REF" --body "$ISSUE_BODY" || return 1
  fi
  [[ "${DRY_RUN:-1}" == 0 ]] && do_log "OK ${DESK_AGENT} posted progress on $ISSUE_REF"
  return 0
}
