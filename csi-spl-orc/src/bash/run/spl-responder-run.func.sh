#!/bin/bash
#------------------------------------------------------------------------------
# @description SPL-1265 / epic SPL-1238: the PERMANENT, NON-AI responder for
# @description unheard human posts. It is a dedicated desk agent (default
# @description RSP-01 on box-rsp) seated per fallback-on tenant; because it is
# @description in no channel, EVERY message the hub delivers to it is an
# @description escalation (an SPL-997/SPL-1225 fallback frame). For each one,
# @description one pass of this action:
# @description   (a) posts a visible "Seen: routed to the team" reply into the
# @description       topic (DESK_TO = the human, DESK_TASK = the topic), so the
# @description       owner sees the post was received;
# @description   (b) forwards the escalation as a FILE into RESP_FORWARD_TO's
# @description       inbox (default CLE-001) - a file cannot be refused the way
# @description       a busy pane refuses a poke (the SPL-1225 miss, 4b0ba40a);
# @description   (c) acks it so it is handled once.
# @description AT MOST ONE "Seen" per topic, EVER (CLE-77847, t1 35582e7b): a
# @description human who writes five lines into one topic is five escalations,
# @description and the old per-message reply posted five identical "Seen"s
# @description (t1 5dc55d94 x5 in 2 s, 2026-10-01). The escalations are now
# @description grouped per topic, and a topic is answered only when it is in
# @description neither the desk's ledger ($d/seen-topics) nor its outbox (an
# @description earlier "Seen" this desk sent there) - so a re-delivered or
# @description un-acked post, a later post in the same topic, a second sweep,
# @description a restart or a lost ledger cannot post it again. A flock on
# @description $d/responder.lock keeps the service and the cron from answering
# @description the same inbox concurrently. Later posts in a seen topic are
# @description still filed to RESP_FORWARD_TO; only the visible reply is once.
# @description No model, no prompt: it cannot stall on a rate limit or unsent
# @description text. Run in a loop by the systemd service (do_spl_responder
# @description _install); the every-3-min watchdog is the safety net.
# @description The loud #spool-hub-ops tier (a post unanswered past
# @description RESP_ALERT_AFTER) is do_spl_report_unheard + do_spl_desk_post,
# @description driven by the watchdog, not this hot path.
# @description Sends real messages, so it is a DRY RUN unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant whose RSP desk to drain
# @param DESK_AGENT (optional) - the responder agent, default RSP-01
# @param DESK_BOX (optional) - the responder box, default box-rsp
# @param RESP_FORWARD_TO (optional) - who the escalation is filed to, default CLE-001
# @param RESP_SEND (optional) - the send script, default spawn-agents spool-send.sh (tests stub it)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 DRY_RUN=0 ./run -a do_spl_responder_run
#------------------------------------------------------------------------------
do_spl_responder_run() {
  do_require_bin python3 yq || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-box-rsp}" agent="${DESK_AGENT:-RSP-01}"
  local fwd="${RESP_FORWARD_TO:-CLE-001}"
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  [[ "$fwd" =~ ^[A-Z]{2,4}-[0-9]+$ ]] || { do_log "FATAL RESP_FORWARD_TO must be an agent id, got: '$fwd'"; return 1; }
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local d="$SPL_STATE_DIR/desk/$tenant/$box" api_fqdn hub
  spl_cnf_api_fqdn api_fqdn || return 1
  hub="https://$api_fqdn"
  [[ -d "$d/spool" ]] || { do_log "FATAL responder $agent on $box in $tenant is not seated ($d); seat it with do_spl_desk_up"; return 1; }
  spl_host_spool || return 1

  # One responder per desk at a time: the service loop and the every-3-min
  # cron would otherwise read the same inbox and both answer it.
  local lockfd
  exec {lockfd}>"$d/responder.lock" || { do_log "FATAL cannot open $d/responder.lock"; return 1; }
  if ! flock -n "$lockfd"; then
    exec {lockfd}>&-
    do_log "OK $agent ($tenant): another responder run holds $d/responder.lock; it answers this inbox"
    return 0
  fi

  local recvf; recvf="$(mktemp "${TMPDIR:-/tmp}/spl-responder-recv.XXXXXX")" || { exec {lockfd}>&-; return 1; }
  if ! spl_desk_spool "$d" "$box" "$tenant" "$hub" -- recv --as "$agent" >"$recvf" 2>&1; then
    do_log "FATAL recv --as $agent on $box: $(cat "$recvf")"; rm -f "$recvf"; exec {lockfd}>&-; return 1
  fi
  # The inbox as TAB-separated (task_id, from, msg_ids, seen) lines, ONE PER
  # TOPIC: every message to a channel-less responder is an escalation, and
  # seen=1 marks a topic this desk already answered (ledger or outbox).
  local rows; rows="$(spl_responder_topics "$recvf" "$d/seen-topics" "$d/spool/$agent/outbox" "$agent")"
  rm -f "$recvf"
  if [[ -z "$rows" ]]; then
    exec {lockfd}>&-
    do_log "OK $agent ($tenant): no escalation waiting"
    return 0
  fi

  local send="${RESP_SEND:-$APP_PATH/$SPL_ORG_APP-orc/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  local n=0 skipped=0 fails=0 task frm mids seen
  while IFS=$'\t' read -r task frm mids seen; do
    [[ -n "$task" ]] || continue
    if (( dry )); then
      if [[ "$seen" == 1 ]]; then
        do_log "INFO DRY_RUN topic $task already has its Seen reply: would file msg(s) $mids to $fwd and ack, no second reply"
      else
        do_log "INFO DRY_RUN would: reply 'Seen: routed to the team' to $frm in topic $task, file msg(s) $mids to $fwd, and ack"
      fi
      n=$((n + 1)); continue
    fi
    if [[ "$seen" == 1 ]]; then
      skipped=$((skipped + 1))
    else
      # (a) the visible "Seen" reply into the topic, once per topic ever. The
      # ledger line is written BEFORE the send: a crash between the two loses
      # one "Seen" (the file to the orchestrator still goes), never doubles it.
      printf '%s\n' "$task" >>"$d/seen-topics" ||
        { do_log "FAIL $agent cannot record topic $task in $d/seen-topics; not replying"; fails=$((fails + 1)); continue; }
      if ! ENV="$ENV" TENANT_ID="$tenant" DESK_AGENT="$agent" DESK_BOX="$box" \
           DESK_TO="$frm" DESK_TASK="$task" DESK_ACK=1 \
           DESK_BODY="Seen: routed to the team." DRY_RUN=0 do_spl_desk_reply >/dev/null 2>&1; then
        do_log "FAIL $agent could not reply to $frm in $task (msg $mids)"; fails=$((fails + 1)); continue
      fi
    fi
    # (b) forward the escalation as a FILE to the orchestrator (never refused)
    local body; body="$(printf 'Unheard human post escalated by the responder (%s, tenant %s).\nFrom %s, topic %s, msg %s.\nReply in the topic; the responder already posted "Seen".' "$agent" "$tenant" "$frm" "$task" "$mids")"
    if ! bash "$send" --from "$agent" --to "$fwd" --kind note --task "$task" --body "$body" >/dev/null 2>&1; then
      do_log "WARN $agent could not file msg $mids to $fwd (it is answered in-topic)"
    fi
    n=$((n + 1))
  done <<<"$rows"
  # A seen-only pass sent no reply, so nothing acked its inbox: ack it here.
  if (( ! dry && skipped > 0 )); then
    spl_desk_spool "$d" "$box" "$tenant" "$hub" -- recv --as "$agent" --ack >/dev/null 2>&1 ||
      do_log "WARN could not archive $agent's inbox"
  fi
  exec {lockfd}>&-

  do_log "OK $agent ($tenant): handled $n topic(s), $skipped already seen (no second reply), $fails failed"
  (( fails == 0 ))
}

# spl_responder_topics <recv file> <ledger> <outbox dir> <agent>: the inbox's
# HUM-* escalations grouped per topic, as "<task>\t<from>\t<msg_ids,>\t<seen>"
# lines, oldest topic first. <from> is the topic's first human; seen=1 when the
# ledger lists the topic or the agent's outbox already holds a "Seen" reply in
# it - the outbox makes it idempotent even when the ledger is lost.
spl_responder_topics() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import glob, json, os, sys
src, ledger, outbox, agent = sys.argv[1:5]
try:
    msgs = json.load(open(src))
except Exception:
    sys.exit(0)
seen = set()
try:
    seen.update(l.strip() for l in open(ledger) if l.strip())
except OSError:
    pass
for f in glob.glob(os.path.join(outbox, "*")):
    try:
        m = json.load(open(f))
    except Exception:
        continue
    if isinstance(m, dict) and m.get("from") == agent and str(m.get("body", "")).startswith("Seen:"):
        seen.add(str(m.get("task_id", "")))
topics = {}
for m in msgs if isinstance(msgs, list) else []:
    if not isinstance(m, dict):
        continue
    frm, task, mid = str(m.get("from", "")), str(m.get("task_id", "")), str(m.get("msg_id", ""))
    if frm.startswith("HUM-") and task and mid:
        topics.setdefault(task, []).append((str(m.get("ts", "")), mid, frm))
for task, ms in sorted(topics.items(), key=lambda kv: min(kv[1])):
    ms.sort()
    print("\t".join([task, ms[0][2], ",".join(x[1] for x in ms), "1" if task in seen else "0"]))
PY
}
