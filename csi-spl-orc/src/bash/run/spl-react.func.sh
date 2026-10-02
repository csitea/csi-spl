#!/bin/bash
#------------------------------------------------------------------------------
# @description Add (or remove) ONE emoji reaction from a desk agent's pane:
# @description the operator form of the WUI's reaction chip (CLE-77895, owner
# @description t1 b23639e2: "Do not archive this discussion. Leave it there for
# @description now but add an emoji for something on hold"). It goes through
# @description the hub, never SQL: `spool react` on the desk root sends the box
# @description `react` frame, which writes through the SAME store write and
# @description message_reaction frame as the browser's PUT/DELETE
# @description /v1/messages/{msg_id}/reactions. The target is MSG, or the
# @description topic's opening message when only TOPIC is given.
# @description ⏸️ on a topic's opening message = on hold (not archived).
# @description WHO MAY: a desk box that reads the message (it sent, was
# @description addressed or was delivered it); the actor is DESK_AGENT.
# @description MODE=check only READS the target's reactions (the hub's react
# @description list op): no write, so it runs with the default DRY_RUN=1.
# @description add / remove read the mark before and after the write.
# @description Prints one JSON line (env, tenant, box, agent, mode, emoji,
# @description result, the hub's answer: msg_id, task_id, reactions), then ONE
# @description line on stdout: RESULT <added|already|removed|absent|present|failed>
# @description emoji=<e> msg=<id> task=<id> by=<actors with that emoji>.
# @description Dry run unless DRY_RUN=0 (MODE=check never writes).
# @param ENV - required: dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the acting agent (the reaction's actor)
# @param TOPIC - the topic's task uuid (the ?topic= of the WUI URL); required unless MSG is set
# @param MSG (optional) - the message uuid to react to (default: TOPIC's opening message)
# @param EMOJI - required: one picker glyph, e.g. ⏸️ (on hold)
# @param MODE (optional) - add (default), remove, or check (read-only)
# @param DESK_BOX (optional) - default box-desk, the same value do_spl_desk_up used
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=CLE-001 TOPIC=0f8fad5b-d9cb-469f-a165-70867728950e EMOJI=⏸️ ./run -a do_spl_react
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=CLE-001 TOPIC=0f8fad5b-d9cb-469f-a165-70867728950e EMOJI=⏸️ MODE=remove DRY_RUN=0 ./run -a do_spl_react
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=CLE-001 TOPIC=0f8fad5b-d9cb-469f-a165-70867728950e EMOJI=⏸️ MODE=check ./run -a do_spl_react
#------------------------------------------------------------------------------
do_spl_react() {
  do_require_bin python3 yq || return 1
  do_spl_desk_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-$(spl_desk_box_default)}" agent="${DESK_AGENT:-}"
  local topic="${TOPIC:-}" msg="${MSG:-}" emoji="${EMOJI:-}" mode="${MODE:-add}"
  local uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  [[ -n "$topic" || -n "$msg" ]] ||
    { do_log "FATAL set TOPIC (the topic's task uuid) or MSG (a message uuid)"; return 1; }
  [[ -z "$topic" || "$topic" =~ $uuid_re ]] ||
    { do_log "FATAL TOPIC must be the topic's lowercase task UUID (the ?topic= of the WUI URL), got: '$topic'"; return 1; }
  [[ -z "$msg" || "$msg" =~ $uuid_re ]] ||
    { do_log "FATAL MSG must be a lowercase message UUID, got: '$msg'"; return 1; }
  [[ -n "$emoji" && "$emoji" != *[[:space:]]* ]] ||
    { do_log "FATAL EMOJI must be one picker glyph, e.g. ⏸️ (on hold), got: '$emoji'"; return 1; }
  [[ "$mode" == add || "$mode" == remove || "$mode" == check ]] ||
    { do_log "FATAL MODE must be add, remove or check, got: '$mode'"; return 1; }

  local hub d target
  hub="$SPL_HUB_URL"
  d="$SPL_STATE_DIR/desk/$tenant/$box"
  target="${msg:-the opening message}${topic:+ of topic $topic}"
  if (( dry )) && [[ "$mode" != check ]]; then
    do_log "INFO DRY_RUN would: $mode $emoji on $target as $agent on $box in $tenant ($hub)"
    [[ -d "$d/spool/$agent" ]] || do_log "INFO DRY_RUN there is no desk for $agent on $box in $tenant yet ($d): do_spl_desk_up seats one"
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0 to $mode (MODE=check reads the mark, writes nothing)."
    return 0
  fi
  [[ -d "$d/spool/$agent" ]] || { do_log "FATAL no desk for $agent on $box in $tenant: run do_spl_desk_up first ($d)"; return 1; }
  spl_host_spool || return 1

  local where=() before="" out rc=0
  [[ -n "$topic" ]] && where+=(--task "$topic")
  [[ -n "$msg" ]] && where+=(--msg "$msg")
  # The mark before the write: tells "added" from "already". A hub without
  # the list op (pre 51e527c1) leaves it unknown and the write still runs.
  before="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- react "${where[@]}" --list --as "$agent" 2>&1)" || {
    [[ "$mode" == check ]] && { out="$before"; rc=1; }
    before=""
  }
  if [[ "$mode" == check ]]; then
    out="${out:-$before}"
  else
    local args=(react "${where[@]}" --emoji "$emoji" --as "$agent")
    [[ "$mode" == remove ]] && args+=(--remove)
    out="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- "${args[@]}" 2>&1)" || rc=$?
  fi
  if (( rc != 0 )); then
    [[ "$out" == *bad_emoji* ]] &&
      do_log "FATAL $emoji is not a glyph the picker offers (csi-spl-wui/src/utils/emoji.mjs EMOJI_CHOICES)"
    [[ "$out" == *not_found* ]] &&
      do_log "FATAL no message $target that $box reads in $tenant (absent, past retention, another topic's, or never delivered to the desk)"
    [[ "$out" == *not_a_card* ]] &&
      do_log "FATAL the lobby is many cards: name the one with MSG"
    [[ "$out" == *'bad_frame'*'unknown frame type'* || "$out" == *'react_op must be add or remove'* ]] &&
      do_log "FATAL the hub at $hub predates box react (CLE-77895; MODE=check needs 51e527c1): roll the hub first"
    do_log "FATAL $mode $emoji on $target as $agent: $out"
    echo "RESULT failed mode=$mode emoji=$emoji target=${msg:-${topic}} agent=$agent"
    return 1
  fi
  _spl_react_verdict "$ENV" "$tenant" "$box" "$agent" "$mode" "$emoji" "$before" "$out"
}

# _spl_react_verdict <env> <tenant> <box> <agent> <mode> <emoji> <before> <after>:
# the JSON line and the RESULT line of a react call, read from the reaction
# state before and after it; exit 1 when the add/remove did not take.
_spl_react_verdict() {
  python3 - "$@" <<'EOF_PY'
import json, sys
env, tenant, box, agent, mode, emoji, before, out = sys.argv[1:]
bare = lambda e: e.replace("️", "")
def parse(s):
    try:
        return json.loads(s)
    except ValueError:
        return None
def actors(ans):
    for r in (ans or {}).get("reactions") or []:
        if bare(r.get("emoji", "")) == bare(emoji):
            return r.get("actors") or []
    return []
pre, ans = parse(before), parse(out)
had = None if pre is None else agent in actors(pre)
has = agent in actors(ans)
if mode == "check":
    result = "present" if actors(ans) else "absent"
elif mode == "add":
    result = "already" if had else ("added" if has else "failed")
else:
    result = ("absent" if had is False else "removed") if not has else "failed"
print(json.dumps({"env": env, "tenant": tenant, "box": box, "agent": agent, "mode": mode, "emoji": emoji, "result": result,
                  "reaction": ans if ans is not None else out}, sort_keys=True, ensure_ascii=False))
a = ans or {}
print(f"RESULT {result} emoji={emoji} msg={a.get('msg_id', '?')} task={a.get('task_id', '?')} by={','.join(actors(ans)) or '-'}")
sys.exit(1 if result == "failed" else 0)
EOF_PY
}
