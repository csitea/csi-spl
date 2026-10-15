#!/bin/bash
#------------------------------------------------------------------------------
# @description Move ONE message (and its thread), by its msg id, into another
# @description topic of the same workspace, from a desk agent's pane: the
# @description operator form of the WUI's message move (SPL-1988; owner HUM-10,
# @description t1 69fd5022: "Create a new discussion ... and move those
# @description messages there"). The twin of do_spl_topic_move. It goes through
# @description the hub, never SQL: `spool move --msg <id> --to-task <task> --as
# @description <agent>` on the desk root sends the box `move` frame, which
# @description writes through the SAME store move, moved_by mark and
# @description message_moved frame as the browser's POST
# @description /v1/messages/{msg_id}/move {to_task}.
# @description WHO MAY (spec 045 read for an agent): an AGENT's message, any
# @description agent that reaches it (its box got it, or the agent is in its
# @description channel); a PERSON's message, only an agent acting for ACT_FOR,
# @description a HUM-* bound as an operator of DESK_BOX who is the workspace
# @description owner or an admin. Anything else is not_allowed. The target
# @description topic must open in a channel the mover may post in.
# @description Prints one JSON line (env, tenant, box, agent, to_task, the
# @description hub's answer). Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the acting agent (moved_by)
# @param MSG_ID - required: the message's uuid
# @param TO_TASK - required: the target topic's task uuid (the ?topic= of the WUI URL)
# @param ACT_FOR (optional) - the HUM-* owner / admin the agent acts for
# @param DESK_BOX (optional) - default box-desk, the same value do_spl_desk_up used
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=c-001 MSG_ID=0f8fad5b-d9cb-469f-a165-70867728950e TO_TASK=e2c3fbad-c8df-42d3-8233-2d7e8d5a0c2f ./run -a do_spl_msg_move
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-001 MSG_ID=0f8fad5b-d9cb-469f-a165-70867728950e TO_TASK=e2c3fbad-c8df-42d3-8233-2d7e8d5a0c2f ACT_FOR=HUM-1 DRY_RUN=0 ./run -a do_spl_msg_move
#------------------------------------------------------------------------------
do_spl_msg_move() {
  : "${MSG_ID:?MSG_ID must be set (no default) - the uuid of the message to move}"
  : "${TO_TASK:?TO_TASK must be set (no default) - the task uuid of the target topic, the ?topic= of the WUI URL}"
  do_require_bin python3 yq || return 1
  do_spl_desk_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-$(spl_desk_box_default)}" agent="${DESK_AGENT:-}"
  local id="$MSG_ID" task="$TO_TASK" act_for="${ACT_FOR:-}"
  local uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  [[ "$id" =~ $uuid_re ]] ||
    { do_log "FATAL MSG_ID must be the message's lowercase UUID, got: '$id'"; return 1; }
  [[ "$task" =~ $uuid_re ]] ||
    { do_log "FATAL TO_TASK must be the target topic's lowercase task UUID (the ?topic= of the WUI URL), got: '$task'"; return 1; }
  [[ -z "$act_for" || "$act_for" =~ ^HUM-[0-9]+$ ]] ||
    { do_log "FATAL ACT_FOR must be a HUM-* id, got: '$act_for'"; return 1; }

  local hub d
  hub="$SPL_HUB_URL"
  d="$SPL_STATE_DIR/desk/$tenant/$box"
  if (( dry )); then
    do_log "INFO DRY_RUN would: move message $id to topic $task as $agent${act_for:+ for $act_for} on $box in $tenant ($hub)"
    [[ -d "$d/spool/$agent" ]] || do_log "INFO DRY_RUN there is no desk for $agent on $box in $tenant yet ($d): do_spl_desk_up seats one"
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0 to move."
    return 0
  fi
  [[ -d "$d/spool/$agent" ]] || { do_log "FATAL no desk for $agent on $box in $tenant: run do_spl_desk_up first ($d)"; return 1; }
  spl_host_spool || return 1

  local args=(move --msg "$id" --to-task "$task" --as "$agent") out rc=0
  [[ -n "$act_for" ]] && args+=(--acting-for "$act_for")
  out="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- "${args[@]}" 2>&1)" || rc=$?
  if (( rc != 0 )); then
    _spl_msg_move_why "$out" "$id" "$task" "$agent" "$act_for" "$box" "$tenant" "$hub"
    do_log "FATAL move message $id to topic $task as $agent: $out"
    return 1
  fi
  python3 - "$ENV" "$tenant" "$box" "$agent" "$task" "$out" <<'EOF_PY'
import json, sys
env, tenant, box, agent, task, out = sys.argv[1:]
try:
    out = json.loads(out)
except ValueError:
    pass
print(json.dumps({"env": env, "tenant": tenant, "box": box, "agent": agent, "to_task": task, "move": out}, sort_keys=True))
EOF_PY
  do_log "OK $agent moved message $id to topic $task on $box in $tenant"
}

# _spl_msg_move_why names a hub refusal of a message move in one line.
_spl_msg_move_why() {
  local out="$1" id="$2" task="$3" agent="$4" act_for="$5" box="$6" tenant="$7" hub="$8"
  [[ "$out" == *not_allowed* ]] &&
    do_log "FATAL $agent may not move $id: a person's message moves only for a bound owner / admin (ACT_FOR)"
  [[ "$out" == *not_found* ]] &&
    do_log "FATAL no message $id or topic $task that $agent on $box reaches in $tenant (absent, past retention, or never delivered)"
  [[ "$out" == *unknown_channel* ]] &&
    do_log "FATAL topic $task is in a channel $agent${act_for:+ or $act_for} may not post in, in $tenant"
  [[ "$out" == *is_card* ]] &&
    do_log "FATAL $id opens its topic: move the whole topic with do_spl_topic_move instead"
  [[ "$out" == *issue_topic* ]] &&
    do_log "FATAL an issue's discussion keeps its messages: $id or topic $task is one"
  [[ "$out" == *'bad_frame'* ]] &&
    do_log "FATAL the hub at $hub predates the box message move (SPL-1988): roll the hub first"
  return 0
}
