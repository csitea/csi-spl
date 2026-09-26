#!/bin/bash
# spl_desk_issue <op> <spool issue args...>: the shared leg of the desk issue
# actions (specs/039 FR-008, issues-v1 §6). A seated desk agent files and
# advances its work as issues: `spool issue <op> --as <agent> ...` through the
# desk box's own spool, whose hub session the box key signs. Validates the
# desk ids, honours DRY_RUN (default 1: says what it would do, calls nothing),
# prints one JSON line {env, tenant, box, agent, op, result}.
spl_desk_issue() {
  local op="$1"; shift
  do_require_bin python3 yq || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-box-desk}" agent="${DESK_AGENT:-}"
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  local hub d
  hub="https://$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  [[ "$hub" != https:// ]] || { do_log "FATAL env.dns.api_fqdn is not set in $SPL_CNF"; return 1; }
  d="$SPL_STATE_DIR/desk/$tenant/$box"
  if (( dry )); then
    do_log "INFO DRY_RUN would: spool issue $op --as $agent $* (box $box, tenant $tenant, $hub)"
    [[ -d "$d/spool/$agent" ]] || do_log "INFO DRY_RUN there is no desk for $agent on $box in $tenant yet ($d): do_spl_desk_up seats one"
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0."
    return 0
  fi
  [[ -d "$d/spool/$agent" ]] || { do_log "FATAL no desk for $agent on $box in $tenant: run do_spl_desk_up first ($d)"; return 1; }
  spl_host_spool || return 1
  local out rc=0
  out="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- issue "$op" --as "$agent" "$@" 2>&1)" || rc=$?
  if (( rc != 0 )); then
    do_log "FATAL spool issue $op as $agent: $out"
    return 1
  fi
  # The list of every issue is one JSON document. Passing it as an argv
  # blows past the kernel's argument limit once a tenant holds the git-spec
  # (measured: python3 "Argument list too long" on the prd t1 list).
  local raw prc=0
  raw="$(mktemp)"
  printf '%s' "$out" >"$raw"
  python3 - "$ENV" "$tenant" "$box" "$agent" "$op" "$raw" <<'EOF_PY' || prc=$?
import json, sys
env, tenant, box, agent, op, path = sys.argv[1:]
out = open(path, encoding="utf-8").read()
try:
    out = json.loads(out)
except ValueError:
    pass
print(json.dumps({"env": env, "tenant": tenant, "box": box, "agent": agent, "op": op, "result": out}, sort_keys=True))
EOF_PY
  rm -f "$raw"
  return $prc
}

# spl_issue_field_args: the create / update flags for every ISSUE_* variable
# that is SET (an empty value clears on update), one per line pair.
spl_issue_field_args() {
  local v flag
  for v in TITLE:title DESCRIPTION:description STATUS:status PRIORITY:priority LEVEL:level \
           ASSIGNEE:assignee LABELS:labels DEADLINE:deadline PARENT:parent EPIC:epic KIND:kind DESCRIPTION_FILE:description-file; do
    flag="${v#*:}"; v="ISSUE_${v%%:*}"
    [[ -n "${!v+x}" ]] && printf -- '--%s\n%s\n' "$flag" "${!v}"
  done
  return 0
}

# spl_issue_check_fields: the shape checks the hub would refuse anyway, so a
# typo fails here with the variable's name.
spl_issue_check_fields() {
  # rdb 0055: the owner's statuses; the first set's names still map (backlog -> eval, ...)
  [[ -z "${ISSUE_STATUS:-}" || "$ISSUE_STATUS" =~ ^(eval|todo|wip|diss|blocked|onhold|qas|done|backlog|in_progress|in_review|canceled)$ ]] ||
    { do_log "FATAL ISSUE_STATUS must be eval, todo, wip, diss, blocked, onhold, qas or done (01-eval .. 09-done), got: '$ISSUE_STATUS'"; return 1; }
  [[ -z "${ISSUE_PRIORITY:-}" || "$ISSUE_PRIORITY" =~ ^[1-5]$ ]] ||
    { do_log "FATAL ISSUE_PRIORITY (prio) must be 1 (highest) .. 5 (lowest), got: '$ISSUE_PRIORITY'"; return 1; }
  # rdb 0056: level is the tree's (1 epic / feature, 2 issue, 3 subtask); the hub derives it
  [[ -z "${ISSUE_LEVEL:-}" || "$ISSUE_LEVEL" =~ ^[1-3]$ ]] ||
    { do_log "FATAL ISSUE_LEVEL must be 1 (epic / feature), 2 (issue) or 3 (subtask), got: '$ISSUE_LEVEL'"; return 1; }
  [[ -z "${ISSUE_KIND:-}" || "$ISSUE_KIND" =~ ^(epic|feature|issue)$ ]] ||
    { do_log "FATAL ISSUE_KIND must be epic, feature or issue, got: '$ISSUE_KIND'"; return 1; }
  [[ -z "${ISSUE_EPIC:-}" || "$ISSUE_EPIC" =~ ^([A-Za-z][A-Za-z0-9]{0,9}-)?[1-9][0-9]*$ ]] ||
    { do_log "FATAL ISSUE_EPIC must be an epic's key like SPL-17, got: '$ISSUE_EPIC'"; return 1; }
  [[ -z "${ISSUE_DESCRIPTION_FILE:-}" || -r "$ISSUE_DESCRIPTION_FILE" ]] ||
    { do_log "FATAL ISSUE_DESCRIPTION_FILE is not a readable file: '$ISSUE_DESCRIPTION_FILE'"; return 1; }
  return 0
}

# spl_issue_check_ref: ISSUE_REF is an issue key.
spl_issue_check_ref() {
  [[ "${ISSUE_REF:-}" =~ ^([A-Za-z][A-Za-z0-9]{0,9}-)?[1-9][0-9]*$ ]] ||
    { do_log "FATAL ISSUE_REF must be an issue key like SPL-12, got: '${ISSUE_REF:-}'"; return 1; }
}
