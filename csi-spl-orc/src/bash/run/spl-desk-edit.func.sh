#!/bin/bash
#------------------------------------------------------------------------------
# @description Edit, from a desk agent's pane, a message that agent already
# @description sent - the box half of specs/032 (message-edit-v1 §10). The owner
# @description asked agents to re-edit their own posts (e.g. a slash-packed table
# @description into a markdown table) and keep the old text as a revision.
# @description   1. `spool edit --msg-id <id> --as <agent> --body[-file] ...` on the
# @description      desk root: the desk box fetches the stored envelope from the
# @description      hub, swaps the body, re-signs it with the SAME box key and
# @description      sends it back
# @description   2. the hub verifies it against the box's pin, refuses any other
# @description      box (not_author, 403) and any change besides the body
# @description      (bad_edit, 400), writes the message_revisions row, bumps the
# @description      revision and pushes message_edited to the open browsers. The
# @description      message keeps its place: same msg_id, ts and cursor
# @description Only the box that sent a message can edit it. Every agent seated
# @description on one tenant shares the desk box (box-desk), so DESK_AGENT may
# @description name an agent whose pane is closed, as long as its desk dir
# @description is still on this host.
# @description Prints one JSON line (env, tenant, box, agent, the edit result:
# @description msg_id, task_id, from, revision). No secret is read.
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the agent that wrote the message (the edit is
# @param   refused locally when the stored author is someone else)
# @param MSG_ID - required: the message's lowercase UUID
# @param DESK_BODY - the new text (or DESK_BODY_FILE) (markdown renders, no fence needed: csi-spl-doc/doc/help/how-to-post.md)
# @param DESK_BODY_FILE - read the new text from this file (exclusive with DESK_BODY)
# @param DESK_BOX (optional) - default box-desk, the same value do_spl_desk_up used
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=e2e DESK_AGENT=CLE-00 MSG_ID=0f8fad5b-d9cb-469f-a165-70867728950e DESK_BODY_FILE=/var/tmp/new.md DRY_RUN=0 ./run -a do_spl_desk_edit
#------------------------------------------------------------------------------
do_spl_desk_edit() {
  do_require_bin python3 yq || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-box-desk}" agent="${DESK_AGENT:-}"
  local id="${MSG_ID:-}" body="${DESK_BODY:-}" body_file="${DESK_BODY_FILE:-}"
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
    { do_log "FATAL MSG_ID must be the message's lowercase UUID, got: '$id'"; return 1; }
  if [[ -n "$body" && -n "$body_file" ]]; then
    do_log "FATAL DESK_BODY and DESK_BODY_FILE are exclusive"; return 1
  fi
  if [[ -n "$body_file" ]]; then
    [[ -f "$body_file" && -r "$body_file" ]] || { do_log "FATAL DESK_BODY_FILE is not a readable file: '$body_file'"; return 1; }
    [[ -n "$(tr -d '[:space:]' <"$body_file")" ]] || { do_log "FATAL DESK_BODY_FILE is empty: '$body_file'"; return 1; }
  else
    [[ -n "${body//[[:space:]]/}" ]] || { do_log "FATAL DESK_BODY or DESK_BODY_FILE must carry the new text"; return 1; }
  fi

  local hub d
  hub="https://$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  [[ "$hub" != https:// ]] || { do_log "FATAL env.dns.api_fqdn is not set in $SPL_CNF"; return 1; }
  d="$SPL_STATE_DIR/desk/$tenant/$box"
  if (( dry )); then
    do_log "INFO DRY_RUN would: edit $id (written by $agent) on $box in $tenant with a new body${body_file:+ from $body_file}"
    [[ -d "$d/spool/$agent" ]] || do_log "INFO DRY_RUN there is no desk for $agent on $box in $tenant yet ($d): do_spl_desk_up seats one"
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0 to edit."
    return 0
  fi
  [[ -d "$d/spool/$agent" ]] || { do_log "FATAL no desk for $agent on $box in $tenant: run do_spl_desk_up first ($d)"; return 1; }
  spl_host_spool || return 1

  local args=(edit --msg-id "$id" --as "$agent") out rc=0
  if [[ -n "$body_file" ]]; then args+=(--body-file "$body_file"); else args+=(--body "$body"); fi
  out="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- "${args[@]}" 2>&1)" || rc=$?
  if (( rc != 0 )); then
    [[ "$out" == *not_author* ]] &&
      do_log "FATAL $id was not sent by $box in $tenant: only the box that sent a message can edit it"
    [[ "$out" == *not_found* ]] && do_log "FATAL no message $id in $tenant (absent or past retention)"
    [[ "$out" == *'bad_frame'*'unknown frame type'* ]] &&
      do_log "FATAL the hub at $hub predates box edits (specs/032 §10): roll the hub first"
    do_log "FATAL edit $id as $agent: $out"
    return 1
  fi
  python3 - "$ENV" "$tenant" "$box" "$agent" "$out" <<'EOF_PY'
import json, sys
env, tenant, box, agent, out = sys.argv[1:]
try:
    out = json.loads(out)
except ValueError:
    pass
print(json.dumps({"env": env, "tenant": tenant, "box": box, "agent": agent, "edit": out}, sort_keys=True))
EOF_PY
  do_log "OK $agent edited $id on $box in $tenant; the old text is kept as a revision"
}
