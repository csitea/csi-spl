#!/bin/bash
#------------------------------------------------------------------------------
# @description Move ONE topic, by its task id, to another channel of the same
# @description workspace, from a desk agent's pane: the operator form of the
# @description WUI's "Move to channel" (owner HUM-10, t1 b316397f: "Move both
# @description the specification and the implementation discussion ... to the
# @description dev channel"). It goes through the hub, never SQL: `spool move
# @description --task <id> --channel <ch> --as <agent>` on the desk root sends
# @description the box `move` frame, which writes through the SAME store move,
# @description moved_by mark and topic_moved frame as the browser's POST
# @description /v1/messages/{card}/move.
# @description WHO MAY (spec 041 read for an agent): the agent that started the
# @description topic (DESK_AGENT on DESK_BOX sent its opening card), or an agent
# @description acting for ACT_FOR, a HUM-* bound as an operator of DESK_BOX who
# @description is the workspace owner or an admin. Anything else is not_allowed.
# @description The target must be a channel the mover may post in.
# @description Prints one JSON line (env, tenant, box, agent, channel, the hub's
# @description answer). Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the acting agent (moved_by)
# @param TOPIC_ID - required: the topic's task uuid (the ?topic= of the WUI URL)
# @param CHANNEL - required: the target channel id (a leading # is dropped)
# @param ACT_FOR (optional) - the HUM-* owner / admin the agent acts for
# @param DESK_BOX (optional) - default box-desk, the same value do_spl_desk_up used
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-001 TOPIC_ID=0f8fad5b-d9cb-469f-a165-70867728950e CHANNEL=dev ./run -a do_spl_topic_move
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-001 TOPIC_ID=0f8fad5b-d9cb-469f-a165-70867728950e CHANNEL=dev ACT_FOR=HUM-1 DRY_RUN=0 ./run -a do_spl_topic_move
#------------------------------------------------------------------------------
do_spl_topic_move() {
  : "${TOPIC_ID:?TOPIC_ID must be set (no default) - the task uuid of the topic, the ?topic= of the WUI URL}"
  : "${CHANNEL:?CHANNEL must be set (no default) - the target channel id}"
  do_require_bin python3 yq || return 1
  do_spl_desk_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-$(spl_desk_box_default)}" agent="${DESK_AGENT:-}"
  local topic="$TOPIC_ID" channel="${CHANNEL#\#}" act_for="${ACT_FOR:-}"
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  [[ "$topic" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
    { do_log "FATAL TOPIC_ID must be the topic's lowercase task UUID (the ?topic= of the WUI URL), got: '$topic'"; return 1; }
  [[ "$channel" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] ||
    { do_log "FATAL CHANNEL must be a lowercase channel id, got: '$CHANNEL'"; return 1; }
  [[ -z "$act_for" || "$act_for" =~ ^HUM-[0-9]+$ ]] ||
    { do_log "FATAL ACT_FOR must be a HUM-* id, got: '$act_for'"; return 1; }

  local hub d
  hub="$SPL_HUB_URL"
  d="$SPL_STATE_DIR/desk/$tenant/$box"
  if (( dry )); then
    do_log "INFO DRY_RUN would: move topic $topic to #$channel as $agent${act_for:+ for $act_for} on $box in $tenant ($hub)"
    [[ -d "$d/spool/$agent" ]] || do_log "INFO DRY_RUN there is no desk for $agent on $box in $tenant yet ($d): do_spl_desk_up seats one"
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0 to move."
    return 0
  fi
  [[ -d "$d/spool/$agent" ]] || { do_log "FATAL no desk for $agent on $box in $tenant: run do_spl_desk_up first ($d)"; return 1; }
  spl_host_spool || return 1

  local args=(move --task "$topic" --channel "$channel" --as "$agent") out rc=0
  [[ -n "$act_for" ]] && args+=(--acting-for "$act_for")
  out="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- "${args[@]}" 2>&1)" || rc=$?
  if (( rc != 0 )); then
    [[ "$out" == *not_allowed* ]] &&
      do_log "FATAL $agent may not move $topic: only the agent that started it, or one acting for a bound owner / admin (ACT_FOR)"
    [[ "$out" == *not_found* ]] &&
      do_log "FATAL no topic $topic that $box reads in $tenant (absent, past retention, or never delivered to the desk)"
    [[ "$out" == *unknown_channel* ]] &&
      do_log "FATAL #$channel is not a channel $agent${act_for:+ or $act_for} may post in, in $tenant"
    [[ "$out" == *issue_topic* ]] &&
      do_log "FATAL $topic is an issue's discussion: it stays with its issue"
    [[ "$out" == *'bad_frame'*'unknown frame type'* ]] &&
      do_log "FATAL the hub at $hub predates box move: roll the hub first"
    do_log "FATAL move $topic to #$channel as $agent: $out"
    return 1
  fi
  python3 - "$ENV" "$tenant" "$box" "$agent" "$channel" "$out" <<'EOF_PY'
import json, sys
env, tenant, box, agent, channel, out = sys.argv[1:]
try:
    out = json.loads(out)
except ValueError:
    pass
print(json.dumps({"env": env, "tenant": tenant, "box": box, "agent": agent, "channel": channel, "move": out}, sort_keys=True))
EOF_PY
  do_log "OK $agent moved topic $topic to #$channel on $box in $tenant"
}
