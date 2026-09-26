#!/bin/bash
#------------------------------------------------------------------------------
# @description Answer, from a desk agent's pane, the human who last wrote to it
# @description in the WUI - the reply leg of do_spl_desk_up. The agent reads its
# @description own inbox, takes the newest message from a human (a HUM-* sender,
# @description the id a signed-in WUI session carries), and sends one message
# @description back into the SAME topic, addressed to box-wui, so the answer
# @description appears in the browser's open DM.
# @description   1. `spool recv --as <agent>` on the desk root (no --ack: the
# @description      message stays in the inbox unless DESK_ACK=1)
# @description   2. the conversation to answer. NOT simply "the newest human":
# @description      two people (or a probe) writing to the same agent would
# @description      then take turns stealing each other's topic, and an answer
# @description      meant for one appears under the other - measured
# @description      2026-09-21, while the owner watched. So: only messages
# @description      NEWER than this desk's last answer count, and
# @description        - exactly one such (sender, topic)  -> answer it
# @description        - several                            -> REFUSE, exit 4,
# @description          and name them; pass DESK_TO / DESK_TASK to choose
# @description        - none                               -> exit 3
# @description      DESK_TO / DESK_TASK override the whole rule
# @description   3. `spool send --from <agent> --to <hum> --task <task>
# @description      --to-box box-wui --kind <DESK_KIND>`; the desk's hub-run
# @description      sidecar flushes it to the hub
# @description Prints one JSON line (msg_id, task_id, to, kind, the answered
# @description message's id and its first characters). No secret is read.
# @description Exit 3 when nothing newer than this desk's last answer is
# @description waiting. Exit 4 when more than one human conversation is, which
# @description is a question for the operator, not a guess for the action.
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the answering agent id (the pane's id)
# @param DESK_BODY - required: the answer text
# @param DESK_BOX (optional) - default box-desk, the same value do_spl_desk_up used
# @param DESK_KIND (optional) - note (default) | result | reject | blocker | msg
# @param   (blocker = the agent cannot proceed without the human's input; SPL-952)
# @param DESK_TO (optional) - answer THIS human id instead of the newest sender
# @param DESK_TASK (optional) - answer in THIS topic instead of the newest one
# @param DESK_FILES (optional) - space-separated paths to attach to the answer
# @param   (each put as a blob first, exactly as do_spl_desk_post does)
# @param DESK_ACK (optional) - 1 = archive the answered message, default 0
# @param DESK_ANY (optional) - 1 = answer the newest human message even when
# @param   several conversations are waiting (the pre-2026-09-21 behaviour)
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
  [[ "$kind" =~ ^(note|result|reject|blocker|msg)$ ]] || { do_log "FATAL DESK_KIND must be note, result, reject, blocker or msg, got: '$kind'"; return 1; }
  [[ -z "$to" || "$to" =~ ^HUM-[A-Za-z0-9_-]{1,64}$ ]] || { do_log "FATAL DESK_TO must be a human id (HUM-...), got: '$to'"; return 1; }
  [[ -z "$task" || "$task" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { do_log "FATAL DESK_TASK must be a lowercase task UUID, got: '$task'"; return 1; }
  local f files=()
  read -r -a files <<<"${DESK_FILES:-}"
  for f in "${files[@]}"; do
    [[ -f "$f" && -r "$f" ]] || { do_log "FATAL DESK_FILES entry is not a readable file: '$f'"; return 1; }
  done

  local hub d
  hub="https://$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  [[ "$hub" != https:// ]] || { do_log "FATAL env.dns.api_fqdn is not set in $SPL_CNF"; return 1; }
  d="$SPL_STATE_DIR/desk/$tenant/$box"
  if (( dry )); then
    do_log "INFO DRY_RUN would: read $agent's inbox on $box and answer the newest human${to:+ $to}${task:+ in task $task} with a $kind${files[*]:+ and ${#files[@]} file(s)}"
    [[ -d "$d/spool/$agent" ]] || do_log "INFO DRY_RUN there is no desk for $agent on $box in $tenant yet ($d): do_spl_desk_up seats one"
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0 to answer."
    return 0
  fi
  [[ -d "$d/spool/$agent" ]] || { do_log "FATAL no desk for $agent on $box in $tenant: run do_spl_desk_up first ($d)"; return 1; }
  spl_host_spool || return 1

  local msgs pick prc=0
  msgs="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- recv --as "$agent" 2>&1)" ||
    { do_log "FATAL recv --as $agent on $box: $msgs"; return 1; }
  pick="$(spl_desk_pick "$msgs" "$to" "$task" "$d/answered" "${DESK_ANY:-0}")" || prc=$?
  if (( prc == 3 )); then
    do_log "INFO $agent has nothing newer than its last answer to reply to (inbox $d/spool/$agent/inbox)"; return 3
  elif (( prc == 4 )); then
    do_log "FATAL $agent has more than one conversation waiting; name one with DESK_TO and DESK_TASK (or DESK_ANY=1):"
    do_log "FATAL $pick"
    return 4
  elif (( prc != 0 )); then
    do_log "FATAL cannot choose a conversation to answer: $pick"; return 1
  fi
  local ans_to ans_task ans_msg ans_head
  IFS=$'\t' read -r ans_to ans_task ans_msg ans_head <<<"$pick"
  [[ -n "$ans_to" && -n "$ans_task" ]] || { do_log "FATAL cannot read a human and a topic out of $agent's inbox"; return 1; }

  local ids=() put id
  for f in "${files[@]}"; do
    put="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- put-file "$f" 2>&1)" ||
      { do_log "FATAL put-file $f: $put"; return 1; }
    id="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["file_id"])' "$put" 2>/dev/null)" ||
      { do_log "FATAL put-file $f returned no file_id: $put"; return 1; }
    ids+=(--file-id "$id")
  done

  local sent rc=0
  sent="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- send --from "$agent" --to "$ans_to" \
    --task "$ans_task" --to-box box-wui --kind "$kind" --body "$body" "${ids[@]}")" || rc=$?
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
  # The watermark of this desk's conversation: what "newer than the last
  # answer" means next time. It is a hint, not a record - losing it only makes
  # the next run ask instead of choosing.
  python3 -c 'import json,sys; open(sys.argv[1],"w").write(json.dumps({"to":sys.argv[2],"task":sys.argv[3],"ts":sys.argv[4]}))' \
    "$d/answered" "$ans_to" "$ans_task" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null ||
    do_log "WARN could not record which conversation $agent just answered ($d/answered)"
  if [[ "${DESK_ACK:-0}" == 1 ]]; then
    spl_desk_spool "$d" "$box" "$tenant" "$hub" -- recv --as "$agent" --ack >/dev/null 2>&1 ||
      do_log "WARN could not archive $agent's inbox after the answer"
  fi
  do_log "OK $agent answered $ans_to in topic $ans_task ($kind); the sidecar flushes it to $hub"
}

# spl_desk_pick <recv json> <to override> <task override> <answered file> <any>:
# the conversation to answer, as "<to>\t<task>\t<msg_id>\t<head>".
#
# Humans only (a HUM-* sender): a desk answers the person in the browser, not
# another box. Among those, only messages NEWER than this desk's last answer
# are candidates - an inbox is never drained, so "the newest human message"
# alone would keep re-picking whoever spoke most recently ANYWHERE, and an
# answer meant for one person would land in another's topic.
#
# Exit 3 nothing to answer; exit 4 more than one conversation is waiting, with
# them listed on stdout - that is a question for the operator, not a guess.
spl_desk_pick() {
  python3 - "$1" "${2:-}" "${3:-}" "${4:-}" "${5:-0}" <<'EOF_PY'
import json, sys
raw, to, task, answered, any_one = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] == "1"
try:
    msgs = json.loads(raw) or []
except ValueError:
    msgs = []
rows = [m for m in msgs if isinstance(m, dict) and str(m.get("from", "")).startswith("HUM-")]

def out(m, to_=None, task_=None):
    head = " ".join(str(m.get("body", "")).split())[:80] if m else ""
    print("\t".join([to_ or m.get("from", ""), task_ or m.get("task_id", ""),
                     (m or {}).get("msg_id", "") if m else "", head]))
    sys.exit(0)

if to:
    rows = [m for m in rows if m.get("from") == to]
if task:
    rows = [m for m in rows if m.get("task_id") == task]
rows.sort(key=lambda m: (str(m.get("ts", "")), str(m.get("msg_id", ""))))

if to or task:
    # An explicit choice is obeyed, including a topic we hold no message of
    # yet (the person opened a fresh DM) when BOTH halves are named.
    if rows:
        out(rows[-1])
    if to and task:
        print("\t".join([to, task, "", ""]))
        sys.exit(0)
    sys.exit(3)

since = ""
try:
    with open(answered) as f:
        since = str(json.load(f).get("ts", ""))
except (OSError, ValueError, AttributeError):
    since = ""
fresh = [m for m in rows if not since or str(m.get("ts", "")) > since]
if not fresh:
    sys.exit(3)
topics = {}
for m in fresh:
    topics.setdefault((m.get("from", ""), m.get("task_id", "")), []).append(m)
if len(topics) > 1 and not any_one:
    for (frm, tsk), ms in sorted(topics.items(), key=lambda kv: str(kv[1][-1].get("ts", ""))):
        print("DESK_TO=%s DESK_TASK=%s  (%d waiting, newest: %s)"
              % (frm, tsk, len(ms), " ".join(str(ms[-1].get("body", "")).split())[:60]))
    sys.exit(4)
out(fresh[-1])
EOF_PY
}
