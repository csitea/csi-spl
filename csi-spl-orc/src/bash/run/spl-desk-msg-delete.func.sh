#!/bin/bash
#------------------------------------------------------------------------------
# @description Delete, from a desk agent's pane, the messages THAT agent sent
# @description in ONE topic: every one of them, or only MSG_IDS. The operator
# @description form of the WUI's per-message Delete, through the hub, never
# @description SQL: `spool delete --msg-id <id> --as <agent>` on the desk root
# @description (specs/032 section 10), so the hub only lets a box delete what
# @description it sent itself. Made for the repair of a shuffled
# @description do_spl_topic_copy_cross copy (csitea 8da3f62a, 2026-10-10).
# @description   1. `spool hub-tail --task <TOPIC>` lists the topic as the desk
# @description      box holds it; DESK_AGENT's messages are the candidates
# @description   2. MSG_IDS (full ids or 8+ hex prefixes) narrows them; each
# @description      entry must match exactly one of the agent's messages
# @description   3. deleted newest first, so a topic root goes last
# @description   4. hub-tail again: none of the deleted ids may still be there
# @description Prints one JSON line (env, tenant, box, agent, topic, the ids,
# @description deleted, left). Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the agent whose own messages go
# @param TOPIC - required: the topic's task uuid
# @param MSG_IDS (optional) - space- or comma-separated msg ids or prefixes (8+ hex);
# @param   default every message DESK_AGENT sent in TOPIC
# @param DESK_BOX (optional) - default the desk box, the same value do_spl_desk_up used
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-001 TOPIC=0f8fad5b-d9cb-469f-a165-70867728950e ./run -a do_spl_desk_msg_delete
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-001 TOPIC=0f8fad5b-d9cb-469f-a165-70867728950e MSG_IDS='1a2b3c4d 5e6f7a8b' DRY_RUN=0 ./run -a do_spl_desk_msg_delete
#------------------------------------------------------------------------------
do_spl_desk_msg_delete() {
  do_require_bin python3 yq || return 1
  do_spl_desk_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-$(spl_desk_box_default)}" agent="${DESK_AGENT:-}"
  local topic="${TOPIC:-}" sel id
  sel="$(tr ',' ' ' <<<"${MSG_IDS:-}" | xargs)"
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  [[ "$topic" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
    { do_log "FATAL TOPIC must be the topic's lowercase task UUID, got: '$topic'"; return 1; }
  for id in $sel; do
    [[ "$id" =~ ^[0-9a-f]{8}[0-9a-f-]{0,28}$ ]] || { do_log "FATAL MSG_IDS entry must be a msg id or a prefix of 8+ hex, got: '$id'"; return 1; }
  done
  local hub="$SPL_HUB_URL" d="$SPL_STATE_DIR/desk/$tenant/$box"
  [[ -d "$d/spool/$agent" ]] || { do_log "FATAL no desk for $agent on $box in $tenant: run do_spl_desk_up first ($d)"; return 1; }
  spl_host_spool || return 1

  local tail ids
  tail="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- hub-tail --task "$topic" --json 2>&1)" ||
    { do_log "FATAL hub-tail $topic on $box in $tenant: $tail"; return 1; }
  ids="$(_spl_desk_msg_delete_pick "$agent" "$sel" <<<"$tail")" || { do_log "FATAL $ids"; return 1; }
  [[ -n "$ids" ]] || { do_log "INFO $agent has no message in $topic on $box in $tenant: nothing to delete"; _spl_desk_msg_delete_row "" 0 0; return 0; }
  if (( dry )); then
    while read -r id; do do_log "INFO DRY_RUN would delete $id ($agent in $topic)"; done <<<"$ids"
    _spl_desk_msg_delete_row "$ids" 0 "$(grep -c . <<<"$ids")"
    do_log "OK DRY_RUN nothing was deleted. Re-run with DRY_RUN=0 to delete."
    return 0
  fi
  local out n=0 left
  while read -r id; do
    out="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- delete --msg-id "$id" --as "$agent" 2>&1)" ||
      { do_log "FATAL delete $id as $agent: $out ($n deleted before it; a re-run continues)"; return 1; }
    n=$((n + 1))
  done <<<"$ids"
  tail="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- hub-tail --task "$topic" --json 2>&1)" ||
    { do_log "FATAL hub-tail $topic after the delete: $tail"; return 1; }
  left="$(grep -cFf <(printf '"msg_id":"%s"\n' $ids; printf '"msg_id": "%s"\n' $ids) <<<"$tail")"
  _spl_desk_msg_delete_row "$ids" "$n" "$left"
  (( left == 0 )) || { do_log "FATAL $left of the deleted messages still show in $topic"; return 1; }
  do_log "OK $agent deleted $n message(s) of its own in $topic on $box in $tenant"
}

# _spl_desk_msg_delete_pick <agent> <sel>: the agent's msg ids in the hub-tail
# NDJSON on stdin, narrowed by <sel>, newest first; on a <sel> entry that does
# not match exactly one, exit 1 with the reason on stdout.
_spl_desk_msg_delete_pick() {
  python3 -c '
import json, sys
agent, sel = sys.argv[1], sys.argv[2].split()
rows = []
for line in sys.stdin:
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if isinstance(m, dict) and m.get("from") == agent and m.get("msg_id"):
        rows.append(m)
if sel:
    keep = []
    for want in sel:
        hits = [m for m in rows if m["msg_id"].startswith(want)]
        if len(hits) != 1:
            print("MSG_IDS entry %s matches %d message(s) of %s in the topic" % (want, len(hits), agent)); sys.exit(1)
        keep.append(hits[0])
    rows = keep
rows = sorted({m["msg_id"]: m for m in rows}.values(), key=lambda m: (str(m.get("ts", "")), m["msg_id"]), reverse=True)
print("\n".join(m["msg_id"] for m in rows))
' "$1" "$2"
}

# _spl_desk_msg_delete_row <ids> <deleted> <left or would>: the result line.
_spl_desk_msg_delete_row() {
  python3 -c '
import json, sys
env, tenant, box, agent, topic, ids, n, left, dry = sys.argv[1:]
print(json.dumps({"env": env, "tenant": tenant, "box": box, "agent": agent, "topic": topic,
                  "msg_ids": [i for i in ids.split("\n") if i], "deleted": int(n),
                  ("would_delete" if dry == "1" else "left"): int(left)}, sort_keys=True))
' "$ENV" "$tenant" "$box" "$agent" "$topic" "$1" "$2" "$3" "$dry"
}
