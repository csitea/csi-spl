#!/bin/bash
#------------------------------------------------------------------------------
# @description Answer, from a desk agent's pane, the human who last wrote to it
# @description in the WUI - the reply leg of do_spl_desk_up. The agent reads its
# @description own inbox, takes the newest message from a human (a HUM-* sender,
# @description the id a signed-in WUI session carries), and sends one message
# @description back into the SAME thread, addressed to box-wui, so the answer
# @description appears in the browser's open DM.
# @description   1. `spool recv --as <agent>` on the desk root (no --ack: the
# @description      message stays in the inbox unless DESK_ACK=1)
# @description   2. the newest message whose `from` is a HUM-* id, unless
# @description      DESK_TO / DESK_TASK name the thread explicitly
# @description   3. `spool send --from <agent> --to <hum> --task <task>
# @description      --to-box box-wui --kind <DESK_KIND>`; the desk's hub-run
# @description      sidecar flushes it to the hub
# @description Prints one JSON line (msg_id, task_id, to, kind, the answered
# @description message's id and its first characters). No secret is read.
# @description Exit 3 when the inbox holds nothing from a human yet: the owner
# @description has not written, so there is nothing to answer.
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the answering agent id (the pane's id)
# @param DESK_BODY - required: the answer text
# @param DESK_BOX (optional) - default box-desk, the same value do_spl_desk_up used
# @param DESK_KIND (optional) - note (default) | result | reject
# @param DESK_TO (optional) - answer THIS human id instead of the newest sender
# @param DESK_TASK (optional) - answer in THIS thread instead of the newest one
# @param DESK_ACK (optional) - 1 = archive the answered message, default 0
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=CLE-00 DESK_BODY='Moi! Olen CLE-00.' DRY_RUN=0 ./run -a do_spl_desk_reply
#------------------------------------------------------------------------------
do_spl_desk_reply() {
  do_require_bin python3 yq || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-box-desk}" agent="${DESK_AGENT:-}"
  local body="${DESK_BODY:-}" kind="${DESK_KIND:-note}" to="${DESK_TO:-}" task="${DESK_TASK:-}"
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  [[ -n "$body" ]] || { do_log "FATAL DESK_BODY must carry the answer text"; return 1; }
  [[ "$kind" =~ ^(note|result|reject)$ ]] || { do_log "FATAL DESK_KIND must be note, result or reject, got: '$kind'"; return 1; }
  [[ -z "$to" || "$to" =~ ^HUM-[A-Za-z0-9_-]{1,64}$ ]] || { do_log "FATAL DESK_TO must be a human id (HUM-...), got: '$to'"; return 1; }
  [[ -z "$task" || "$task" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { do_log "FATAL DESK_TASK must be a lowercase task UUID, got: '$task'"; return 1; }

  local hub d
  hub="https://$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  [[ "$hub" != https:// ]] || { do_log "FATAL env.dns.api_fqdn is not set in $SPL_CNF"; return 1; }
  d="$SPL_STATE_DIR/desk/$tenant/$box"
  [[ -d "$d/spool/$agent" ]] || { do_log "FATAL no desk for $agent on $box in $tenant: run do_spl_desk_up first ($d)"; return 1; }
  if (( dry )); then
    do_log "INFO DRY_RUN would: read $agent's inbox on $box and answer the newest human${to:+ $to}${task:+ in task $task} with a $kind"
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0 to answer."
    return 0
  fi
  spl_host_spool || return 1

  local msgs pick
  msgs="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- recv --as "$agent" 2>&1)" ||
    { do_log "FATAL recv --as $agent on $box: $msgs"; return 1; }
  pick="$(spl_desk_pick "$msgs" "$to" "$task")" || {
    do_log "INFO $agent has nothing from a human to answer yet (inbox $d/spool/$agent/inbox)"; return 3; }
  local ans_to ans_task ans_msg ans_head
  IFS=$'\t' read -r ans_to ans_task ans_msg ans_head <<<"$pick"
  [[ -n "$ans_to" && -n "$ans_task" ]] || { do_log "FATAL cannot read a human and a thread out of $agent's inbox"; return 1; }

  local sent rc=0
  sent="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- send --from "$agent" --to "$ans_to" \
    --task "$ans_task" --to-box box-wui --kind "$kind" --body "$body")" || rc=$?
  (( rc == 0 )) || { do_log "FATAL send $agent -> $ans_to in task $ans_task: $sent"; return 1; }
  python3 - "$ENV" "$tenant" "$box" "$agent" "$kind" "$ans_to" "$ans_task" "$ans_msg" "$ans_head" "$sent" <<'EOF_PY'
import json, sys
env, tenant, box, agent, kind, to, task, in_msg, head, sent = sys.argv[1:]
try:
    sent = json.loads(sent)
except ValueError:
    pass
print(json.dumps({"env": env, "tenant": tenant, "box": box, "agent": agent, "kind": kind,
                  "to": to, "task_id": task, "answered_msg_id": in_msg, "answered_head": head,
                  "send": sent}, sort_keys=True))
EOF_PY
  if [[ "${DESK_ACK:-0}" == 1 ]]; then
    spl_desk_spool "$d" "$box" "$tenant" "$hub" -- recv --as "$agent" --ack >/dev/null 2>&1 ||
      do_log "WARN could not archive $agent's inbox after the answer"
  fi
  do_log "OK $agent answered $ans_to in thread $ans_task ($kind); the sidecar flushes it to $hub"
}

# spl_desk_pick <recv json> <to override> <task override>: the message to
# answer, as "<to>\t<task>\t<msg_id>\t<head>". Newest first by ts, humans only
# (a HUM-* sender): a desk answers the person in the browser, not another box.
# Exit 3 when there is nothing to answer.
spl_desk_pick() {
  python3 - "$1" "${2:-}" "${3:-}" <<'EOF_PY'
import json, sys
raw, to, task = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    msgs = json.loads(raw) or []
except ValueError:
    msgs = []
def human(m):
    return str(m.get("from", "")).startswith("HUM-")
rows = [m for m in msgs if isinstance(m, dict) and human(m)]
if to:
    rows = [m for m in rows if m.get("from") == to]
if task:
    rows = [m for m in rows if m.get("task_id") == task]
if not rows:
    # An override may name a thread no message of ours carries yet (the owner
    # opened a fresh DM): answer it anyway when BOTH are given.
    if to and task:
        print("\t".join([to, task, "", ""]))
        sys.exit(0)
    sys.exit(3)
rows.sort(key=lambda m: (str(m.get("ts", "")), str(m.get("msg_id", ""))))
m = rows[-1]
head = " ".join(str(m.get("body", "")).split())[:80]
print("\t".join([m.get("from", ""), m.get("task_id", ""), m.get("msg_id", ""), head]))
EOF_PY
}
