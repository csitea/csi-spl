#!/bin/bash
#------------------------------------------------------------------------------
# @description Archive (or unarchive) ONE topic by its task id, from a desk
# @description agent's pane: the operator form of the WUI's Archive (owner
# @description order 2026-10-01, "archive the discussion"). It goes through the
# @description hub, never SQL: `spool archive --task <id> --as <agent>` on the
# @description desk root sends the box `archive` frame (CLE-77869), which writes
# @description through the SAME card, store write and topic_archived frame as
# @description the browser's PUT/DELETE /v1/messages/{card}/archive. The topic
# @description leaves every list and shows in the Archive view; MODE=unarchive
# @description brings it back.
# @description WHO MAY: the workspace setting "Who can archive topics" -
# @description everyone (default): a desk box that reads the topic (it sent,
# @description was addressed or was delivered the opening card); starter: only
# @description a topic the desk box opened; admins: never a box (use the WUI).
# @description An issue's discussion is archived with its issue (issue_topic),
# @description and the lobby card by card from the WUI.
# @description Prints one JSON line (env, tenant, box, agent, mode, the hub's
# @description answer: msg_id, task_id, archived, archived_at, archived_by).
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the acting agent (archived_by)
# @param TOPIC - required: the topic's task uuid (the ?topic= of the WUI URL)
# @param MODE (optional) - archive (default) or unarchive
# @param DESK_BOX (optional) - default box-desk, the same value do_spl_desk_up used
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=CLE-001 TOPIC=0f8fad5b-d9cb-469f-a165-70867728950e ./run -a do_spl_topic_archive
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=CLE-001 TOPIC=0f8fad5b-d9cb-469f-a165-70867728950e MODE=unarchive DRY_RUN=0 ./run -a do_spl_topic_archive
#------------------------------------------------------------------------------
do_spl_topic_archive() {
  do_require_bin python3 yq || return 1
  do_spl_desk_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-$(spl_desk_box_default)}" agent="${DESK_AGENT:-}"
  local topic="${TOPIC:-}" mode="${MODE:-archive}"
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  [[ "$topic" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
    { do_log "FATAL TOPIC must be the topic's lowercase task UUID (the ?topic= of the WUI URL), got: '$topic'"; return 1; }
  [[ "$mode" == archive || "$mode" == unarchive ]] ||
    { do_log "FATAL MODE must be archive or unarchive, got: '$mode'"; return 1; }

  local hub d
  hub="$SPL_HUB_URL"
  d="$SPL_STATE_DIR/desk/$tenant/$box"
  if (( dry )); then
    do_log "INFO DRY_RUN would: $mode topic $topic as $agent on $box in $tenant ($hub)"
    [[ -d "$d/spool/$agent" ]] || do_log "INFO DRY_RUN there is no desk for $agent on $box in $tenant yet ($d): do_spl_desk_up seats one"
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0 to $mode."
    return 0
  fi
  [[ -d "$d/spool/$agent" ]] || { do_log "FATAL no desk for $agent on $box in $tenant: run do_spl_desk_up first ($d)"; return 1; }
  spl_host_spool || return 1

  local args=(archive --task "$topic" --as "$agent") out rc=0
  [[ "$mode" == unarchive ]] && args+=(--unarchive)
  out="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- "${args[@]}" 2>&1)" || rc=$?
  if (( rc != 0 )); then
    [[ "$out" == *issue_topic* ]] &&
      do_log "FATAL $topic is an issue's discussion: it is archived with its issue (the issue dialog's Archive), not here"
    [[ "$out" == *not_found* ]] &&
      do_log "FATAL no topic $topic that $box reads in $tenant (absent, past retention, or never delivered to the desk)"
    [[ "$out" == *not_allowed* ]] &&
      do_log "FATAL the workspace setting \"Who can archive topics\" does not let $box $mode $topic: use the WUI as an owner / admin"
    [[ "$out" == *'bad_frame'*'unknown frame type'* ]] &&
      do_log "FATAL the hub at $hub predates box archive (CLE-77869): roll the hub first"
    do_log "FATAL $mode $topic as $agent: $out"
    return 1
  fi
  python3 - "$ENV" "$tenant" "$box" "$agent" "$mode" "$out" <<'EOF_PY'
import json, sys
env, tenant, box, agent, mode, out = sys.argv[1:]
try:
    out = json.loads(out)
except ValueError:
    pass
print(json.dumps({"env": env, "tenant": tenant, "box": box, "agent": agent, "mode": mode, "archive": out}, sort_keys=True))
EOF_PY
  do_log "OK $agent ${mode}d topic $topic on $box in $tenant"
}
