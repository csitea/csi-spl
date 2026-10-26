#!/bin/bash
#------------------------------------------------------------------------------
# @description File concrete, specced work as an issue from a desk agent's pane
# @description (specs/039 FR-008): owner rule, specced work and its progress go
# @description to Issues, talk stays in topics. `spool issue create --as
# @description <agent>` through the desk box. Prints one JSON line with the new
# @description issue (its key, e.g. SPL-12). Dry run unless DRY_RUN=0.
# @description No issue without an epic and a git spec (owner HUM-10, t1
# @description 7a98c2d1 msg 5863d0d6): a level-2 issue (no ISSUE_PARENT, not an
# @description epic or feature) needs ISSUE_EPIC and a spec folder
# @description csi-spl-doc/specs/NNN-<slug> on origin/master named in its
# @description description (a `Spec:` line); else one FATAL line, nothing filed.
# @description In a workspace of the box map $SPOOL_ROOT/workspace-repos.tsv
# @description (its own repo, workspace-repo.inc.sh) the epic is still needed,
# @description but the spec lives in that repo: no csi-spl spec is asked for.
# @param ENV - required: dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the agent filing it (the pane's id)
# @param ISSUE_TITLE - required: the title
# @param ISSUE_DISCUSSIONS - required: the discussions it links, topic ids or /t/<id> links, comma separated (at least one; the hub refuses none: discussion_required). A /t/<id> link in the description stands in for it
# @param ISSUE_EPIC (required for a level-2 issue) - the level-1 row (epic or feature) above it, e.g. SPL-17; a level-2 issue without it is refused (owner t1 7a98c2d1 msg 5863d0d6)
# @param ISSUE_PARENT (optional) - a level-2 issue's key: the new issue is its subtask (level 3)
# @param ISSUE_KIND (optional) - issue (default) | epic | feature (epics and features are level 1)
# @param ISSUE_DESCRIPTION (required for a level-2 issue: it names the spec, `Spec: csi-spl-doc/specs/NNN-<slug>`) - markdown, no fence needed (csi-spl-doc/doc/help/how-to-post.md); or ISSUE_DESCRIPTION_FILE
# @param ISSUE_STATUS (optional) - eval (default) | todo | wip | diss | blocked | onhold | qas | done  (01-eval, 02-todo, 03-wip, 03-diss, 05-blocked, 06-onhold, 07-qas, 09-done)
# @param ISSUE_QAS_ASKED_BY (optional) - required with ISSUE_STATUS=qas: the human (HUM-n) or the msg id that asked for the review (spec 135 Q7)
# @param ISSUE_PRIORITY (optional) - prio 1 (highest) .. 5 (lowest, the default)
# @param ISSUE_LEVEL (optional) - 1 epic / feature, 2 issue, 3 subtask: the hub derives it from the tree and refuses any other
# @param ISSUE_ASSIGNEE (optional) - a member HUM-* or an agent id
# @param ISSUE_LABELS (optional) - label ids, comma separated
# @param ISSUE_DEADLINE (optional) - RFC 3339 with a zone, e.g. 2026-10-01T15:00:00Z
# @param DESK_BOX (optional) - default box-desk
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=CLE-00 ISSUE_TITLE='Rotate the relay key' ISSUE_DISCUSSIONS=<topic id> ISSUE_EPIC=SPL-17 ISSUE_DESCRIPTION='Spec: csi-spl-doc/specs/135-work-process' ISSUE_PRIORITY=2 ISSUE_ASSIGNEE=CLE-00 DRY_RUN=0 ./run -a do_spl_issue_create
#------------------------------------------------------------------------------
do_spl_issue_create() {
  [[ -n "${ISSUE_TITLE:-}" ]] || { do_log "FATAL ISSUE_TITLE must carry the issue title"; return 1; }
  spl_issue_check_fields || return 1
  spl_issue_check_discussions || return 1
  spl_issue_qas_guard create || return 1
  spl_issue_create_epic_spec || return 1
  local args=()
  mapfile -d '' -t args < <(spl_issue_field_args create)
  spl_desk_issue create "${args[@]}" || return 1
  [[ "${DRY_RUN:-1}" == 0 ]] && do_log "OK ${DESK_AGENT} filed an issue in ${TENANT_ID}"
  return 0
}

# spl_issue_create_epic_spec: a level-2 issue has an epic and names a spec
# folder on origin/master (li_epic_spec, lane-issue.inc.sh). An epic or
# feature (level 1) and a child of ISSUE_PARENT pass.
spl_issue_create_epic_spec() {
  [[ "${ISSUE_KIND:-issue}" == issue && -z "${ISSUE_PARENT:-}" ]] || return 0
  # shellcheck source=../features/spawn-agents/lib/lane-issue.inc.sh
  . "$PROJ_PATH/src/bash/features/spawn-agents/lib/lane-issue.inc.sh" || return 1
  [[ -n "${ISSUE_EPIC:-}" ]] ||
    { do_log "FATAL refused, nothing filed: $LI_EPIC_SPEC_RULE: set ISSUE_EPIC=SPL-<n>, the level-1 epic above it"; return 1; }
  wr_row "${TENANT_ID:-}" >/dev/null 2>&1 && return 0
  local d spec
  d="$(mktemp)" || return 1
  { printf '%s\n' "${ISSUE_DESCRIPTION:-}"; cat "${ISSUE_DESCRIPTION_FILE:-/dev/null}" 2>/dev/null; } >"$d"
  spec="$(li_spec_from_file "$d")"; rm -f "$d"
  li_epic_spec "$spec" "$ISSUE_EPIC" >/dev/null
}
