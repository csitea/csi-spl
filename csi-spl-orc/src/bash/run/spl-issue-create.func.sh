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
# @description An issue the owner ordered for work with no repo (SPL-4443):
# @description ISSUE_OWNER_GO=<the owner's message uuid> skips ONLY the git-spec
# @description check, outside t1 (csi-spl's own workspace), when that message
# @description is in a linked discussion of TENANT_ID (read as the desk,
# @description hub-tail) from a HUM-<n>, with ONE description source; the epic is still
# @description needed and the description's first line becomes `Owner order: <uuid>`.
# @param ENV - required: dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the agent filing it (the pane's id)
# @param ISSUE_TITLE - required: the title
# @param ISSUE_DISCUSSIONS - required: the discussions it links, topic ids or /t/<id> links, comma separated (at least one; the hub refuses none: discussion_required). A /t/<id> link in the description stands in for it
# @param ISSUE_EPIC (required for a level-2 issue) - the level-1 row (epic or feature) above it, e.g. SPL-17; a level-2 issue without it is refused (owner t1 7a98c2d1 msg 5863d0d6)
# @param ISSUE_OWNER_GO (optional) - the full lowercase uuid of the owner's (HUM-<n>) message that ordered this issue, in one of ISSUE_DISCUSSIONS (or a /t/<id> of the description): a level-2 issue then needs no git spec (SPL-4443); refused in t1 and with both ISSUE_DESCRIPTION and ISSUE_DESCRIPTION_FILE; read from the hub only when DRY_RUN=0
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
# @example ENV=prd TENANT_ID=csitea DESK_AGENT=c-001 ISSUE_TITLE='Invoice run' ISSUE_DISCUSSIONS=<topic uuid> ISSUE_EPIC=CSI-1 ISSUE_OWNER_GO=<owner msg uuid> ISSUE_DESCRIPTION='card' DRY_RUN=0 ./run -a do_spl_issue_create
#------------------------------------------------------------------------------
do_spl_issue_create() {
  [[ -n "${ISSUE_TITLE:-}" ]] || { do_log "FATAL ISSUE_TITLE must carry the issue title"; return 1; }
  spl_issue_check_fields || return 1
  spl_issue_check_discussions || return 1
  spl_issue_qas_guard create || return 1
  local SPL_ISSUE_GO_TMP=""
  spl_issue_create_epic_spec || { rm -f "$SPL_ISSUE_GO_TMP"; return 1; }
  local args=()
  mapfile -d '' -t args < <(spl_issue_field_args create)
  spl_desk_issue create "${args[@]}" || { rm -f "$SPL_ISSUE_GO_TMP"; return 1; }
  rm -f "$SPL_ISSUE_GO_TMP"
  [[ "${DRY_RUN:-1}" == 0 ]] && do_log "OK ${DESK_AGENT} filed an issue in ${TENANT_ID}"
  return 0
}

# spl_issue_create_epic_spec: a level-2 issue has an epic and names a spec
# folder on origin/master (li_epic_spec, lane-issue.inc.sh). An epic or
# feature (level 1) and a child of ISSUE_PARENT pass. ISSUE_OWNER_GO stands in
# for the spec (spl_issue_owner_go); unset, nothing changes.
spl_issue_create_epic_spec() {
  [[ -z "${ISSUE_OWNER_GO+x}" ]] || spl_issue_owner_go_shape || return 1
  [[ "${ISSUE_KIND:-issue}" == issue && -z "${ISSUE_PARENT:-}" ]] || return 0
  # shellcheck source=../features/spawn-agents/lib/lane-issue.inc.sh
  . "$PROJ_PATH/src/bash/features/spawn-agents/lib/lane-issue.inc.sh" || return 1
  [[ -n "${ISSUE_EPIC:-}" ]] ||
    { do_log "FATAL refused, nothing filed: $LI_EPIC_SPEC_RULE: set ISSUE_EPIC=SPL-<n>, the level-1 epic above it"; return 1; }
  [[ -n "${ISSUE_OWNER_GO+x}" ]] && { spl_issue_owner_go; return; }
  wr_row "${TENANT_ID:-}" >/dev/null 2>&1 && return 0
  local d spec
  d="$(mktemp)" || return 1
  { printf '%s\n' "${ISSUE_DESCRIPTION:-}"; cat "${ISSUE_DESCRIPTION_FILE:-/dev/null}" 2>/dev/null; } >"$d"
  spec="$(li_spec_from_file "$d")"; rm -f "$d"
  li_epic_spec "$spec" "$ISSUE_EPIC" >/dev/null
}

# spl_issue_owner_go_shape: a set ISSUE_OWNER_GO is a full lowercase uuid,
# at every level, never in t1 (csi-spl's own workspace: its issues keep the
# git-spec rule, spec 145 Form 4), and comes with ONE description source:
# spool sends the file over ISSUE_DESCRIPTION when both are set, so the
# first-line checks below would read the text that is not filed.
spl_issue_owner_go_shape() {
  local go="$ISSUE_OWNER_GO" no="FATAL refused, nothing filed: ISSUE_OWNER_GO"
  [[ "${TENANT_ID:-}" != t1 ]] ||
    { do_log "$no $go: t1 is csi-spl's own workspace, its issues name a git spec (spec 145 Form 4); the go is for a workspace with no repo"; return 1; }
  [[ "$go" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
    { do_log "$no '$go' is not a full lowercase message uuid (an id8 is not enough)"; return 1; }
  [[ -n "${ISSUE_DESCRIPTION+x}" && -n "${ISSUE_DESCRIPTION_FILE:-}" ]] &&
    { do_log "$no $go: set ISSUE_DESCRIPTION or ISSUE_DESCRIPTION_FILE, not both"; return 1; }
  return 0
}

# spl_issue_owner_go: ISSUE_OWNER_GO (SPL-4443, shape checked above): the
# description's first line is, or becomes, `Owner order: <uuid>`; with
# DRY_RUN=0 the message is read through the desk (spl_issue_owner_go_from)
# and must come from a HUM-<n>. One log line names the uuid, pass or refusal.
spl_issue_owner_go() {
  local go="$ISSUE_OWNER_GO" no="FATAL refused, nothing filed: ISSUE_OWNER_GO" first from
  if [[ -n "${ISSUE_DESCRIPTION+x}" || -z "${ISSUE_DESCRIPTION_FILE:-}" ]]; then
    first="${ISSUE_DESCRIPTION:-}"; first="${first%%$'\n'*}"
  else
    first="$(head -n1 "$ISSUE_DESCRIPTION_FILE")"
  fi
  [[ "$first" =~ ^Owner\ order: && "$first" != "Owner order: $go" ]] &&
    { do_log "$no $go: the description's first line cites another order: $first"; return 1; }
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    do_log "INFO DRY_RUN owner go $go is not read: with DRY_RUN=0 it must be a HUM-<n>'s message of a linked discussion in $TENANT_ID, then the git-spec check would be skipped (SPL-4443)"
    return 0
  fi
  from="$(spl_issue_owner_go_from "$go")" || return 1
  [[ "$from" =~ ^HUM-[0-9]+$ ]] ||
    { do_log "$no $go is from '$from', not a human member (HUM-<n>)"; return 1; }
  [[ "$first" == "Owner order: $go" ]] || spl_issue_owner_go_line "$go" || return 1
  do_log "INFO owner go $go from $from in $TENANT_ID: the git-spec check is skipped (SPL-4443), the epic $ISSUE_EPIC stays"
}

# spl_issue_owner_go_line <uuid>: put `Owner order: <uuid>` on top of the
# description that is sent: ISSUE_DESCRIPTION, else a copy of the file
# (SPL_ISSUE_GO_TMP, removed by do_spl_issue_create).
spl_issue_owner_go_line() {
  local line="Owner order: $1"
  if [[ -n "${ISSUE_DESCRIPTION+x}" || -z "${ISSUE_DESCRIPTION_FILE:-}" ]]; then
    ISSUE_DESCRIPTION="$line${ISSUE_DESCRIPTION:+$'\n\n'$ISSUE_DESCRIPTION}"
    return 0
  fi
  SPL_ISSUE_GO_TMP="$(mktemp)" || return 1
  { printf '%s\n\n' "$line"; cat "$ISSUE_DESCRIPTION_FILE"; } >"$SPL_ISSUE_GO_TMP" || return 1
  ISSUE_DESCRIPTION_FILE="$SPL_ISSUE_GO_TMP"
}

# spl_issue_owner_go_from <uuid>: the `from` of that message, read as the desk
# of TENANT_ID (`spool hub-tail --task <topic> --json`; the hub scopes the
# read to the desk's tenant) in each discussion the issue links:
# ISSUE_DISCUSSIONS and the /t/<id> links of the description. Not found: one
# FATAL line naming the topics read.
spl_issue_owner_go_from() {
  local go="$1" tenant="${TENANT_ID:-}" box="${DESK_BOX:-$(spl_desk_box_default)}" t tail from topics=()
  spl_desk_issue_once >&2 || return 1
  mapfile -t topics < <({ printf '%s\n' "${ISSUE_DISCUSSIONS:-}" | sed -E 's/[, ]+/\n/g' | sed 's#^.*/t/##'
    { printf '%s\n' "${ISSUE_DESCRIPTION:-}"; cat "${ISSUE_DESCRIPTION_FILE:-/dev/null}" 2>/dev/null; } |
      grep -oE '/t/[0-9A-Za-z-]+' | sed 's#^/t/##'; } | awk 'NF && !seen[$0]++')
  for t in "${topics[@]}"; do
    tail="$(spl_desk_spool "$SPL_STATE_DIR/desk/$tenant/$box" "$box" "$tenant" "$SPL_HUB_URL" -- hub-tail --task "$t" --json 2>/dev/null)" || continue
    from="$(printf '%s\n' "$tail" | python3 -c 'import json, sys
for l in sys.stdin:
    try: m = json.loads(l)
    except ValueError: continue
    if isinstance(m, dict) and m.get("msg_id") == sys.argv[1]: print(m.get("from") or "-"); break' "$go")"
    [[ -n "$from" ]] && { printf '%s\n' "$from"; return 0; }
  done
  do_log "FATAL refused, nothing filed: ISSUE_OWNER_GO $go is not a message of the linked discussions (${topics[*]:-none}) in $tenant" >&2
  return 1
}
