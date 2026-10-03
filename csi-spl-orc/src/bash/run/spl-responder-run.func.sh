#!/bin/bash
#------------------------------------------------------------------------------
# @description SPL-1265 / epic SPL-1238: the PERMANENT, NON-AI responder for
# @description unheard human posts. It is a dedicated desk agent (default
# @description RSP-01 on box-rsp) seated per fallback-on tenant; because it is
# @description in no channel, EVERY message the hub delivers to it is an
# @description escalation (an SPL-997/SPL-1225 fallback frame). For each one,
# @description one pass of this action:
# @description   (a) ONLY with RESP_SEEN_REPLY=1: posts a visible "Seen: routed
# @description       to the team" reply into the topic (DESK_TO = the human,
# @description       DESK_TASK = the topic). OFF by default since the owner
# @description       rule of 2026-10-03 (HUM-10, t1 topic 02800102): a post
# @description       that only acknowledges adds nothing for the human reader
# @description       and must not occur in a channel or a DM. With it off,
# @description       (b) and (c) still run for every escalation;
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
# @description ACROSS MACHINES (c-082, prd t1 139c58c8: box-rsp and sat-rsp
# @description each posted a Seen after the lease moved): the ledger is per
# @description machine, so a topic the ledger does not know is first asked
# @description ON THE HUB (`spool hub-rsp`: RSP-* rows in the topic, any box);
# @description one there is recorded in the ledger and nothing is posted.
# @description Hub cannot say (down, an older hub): FAIL CLOSED, bounded - the
# @description Seen is deferred to $d/seen-pending and retried every pass;
# @description after RESP_HUB_WAIT it is given up (no Seen, WARN). A missing
# @description Seen beats a second one: the escalation FILE still went to
# @description RESP_FORWARD_TO on the first pass, so the post is never lost.
# @description A box spool or hub without hub-rsp (a rollout gap) is not an
# @description outage: WARN and answer on the local ledger, as before.
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
# @param RESP_HUB_WAIT (optional) - seconds a Seen waits for the hub to answer hub-rsp, default 900
# @param RESP_SEEN_REPLY (optional) - 1 posts the visible "Seen" reply (a); default 0: file + ack only
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 DRY_RUN=0 ./run -a do_spl_responder_run
#------------------------------------------------------------------------------
do_spl_responder_run() {
  do_require_bin python3 yq || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-box-rsp}" agent="${DESK_AGENT:-RSP-01}"
  local fwd="${RESP_FORWARD_TO:-CLE-001}" wait="${RESP_HUB_WAIT:-900}" reply="${RESP_SEEN_REPLY:-0}"
  [[ "$wait" =~ ^[0-9]+$ ]] || { do_log "FATAL RESP_HUB_WAIT must be whole seconds, got: '$wait'"; return 1; }
  [[ "$reply" =~ ^[01]$ ]] || { do_log "FATAL RESP_SEEN_REPLY must be 0 or 1, got: '$reply'"; return 1; }
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  spl_is_participant_id "$fwd" || { do_log "FATAL RESP_FORWARD_TO must be an agent id, got: '$fwd'"; return 1; }
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
  # The inbox as TAB-separated (task_id, from, msg_ids, seen, pending-since)
  # lines, ONE PER TOPIC: every message to a channel-less responder is an
  # escalation, and seen=1 marks a topic this desk already answered (ledger or
  # outbox). A topic deferred while the hub could not answer comes back from
  # $d/seen-pending with no msg ids.
  local rows; rows="$(spl_responder_topics "$recvf" "$d/seen-topics" "$d/spool/$agent/outbox" "$agent" "$d/seen-pending")"
  rm -f "$recvf"
  if [[ -z "$rows" ]]; then
    exec {lockfd}>&-
    do_log "OK $agent ($tenant): no escalation waiting"
    return 0
  fi

  local send="${RESP_SEND:-$APP_PATH/$SPL_ORG_APP-orc/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  local n=0 skipped=0 filed=0 fails=0 task frm mids seen since hubn hrc
  while IFS=$'\t' read -r task frm mids seen since; do
    [[ -n "$task" ]] || continue
    [[ "$mids" == - ]] && mids=""
    [[ "$since" == - ]] && since=""
    if (( ! reply )); then
      # No visible Seen (owner rule 2026-10-03): file the escalation, ack it.
      if (( dry )); then
        do_log "INFO DRY_RUN would: file msg(s) ${mids:-none} of $frm in topic $task to $fwd and ack; no reply in the topic (RESP_SEEN_REPLY=0)"
      else
        _spl_responder_pending_drop "$d" "$task"
        [[ -n "$mids" ]] && _spl_responder_forward "$send" "$agent" "$fwd" "$tenant" "$frm" "$task" "$mids"
        filed=$((filed + 1))
      fi
      n=$((n + 1)); continue
    fi
    if (( dry )); then
      if [[ "$seen" == 1 ]]; then
        do_log "INFO DRY_RUN topic $task already has its Seen reply: would file msg(s) $mids to $fwd and ack, no second reply"
      else
        do_log "INFO DRY_RUN would: ask the hub for an RSP row in topic $task, then (none) reply 'Seen: routed to the team' to $frm there, file msg(s) $mids to $fwd, and ack"
      fi
      n=$((n + 1)); continue
    fi
    hrc=0
    [[ "$seen" == 1 ]] || { hubn="$(spl_responder_hub_rsp "$d" "$box" "$tenant" "$hub" "$task")" || hrc=$?; }
    if [[ "$seen" == 1 ]]; then
      skipped=$((skipped + 1))
    elif (( hrc == 2 )); then
      do_log "WARN the hub-rsp check is not deployed on this box or hub: topic $task is answered on this machine's ledger only (the pre-c-082 behaviour)"
      _spl_responder_seen_reply "$d" "$tenant" "$box" "$agent" "$frm" "$task" "$mids" || { fails=$((fails + 1)); continue; }
      _spl_responder_pending_drop "$d" "$task"
    elif (( hrc == 0 )); then
      if (( hubn > 0 )); then
        _spl_responder_settle "$d" "$task"
        do_log "INFO topic $task already holds $hubn RSP row(s) on the hub (another machine answered): no second Seen"
        skipped=$((skipped + 1))
      else
        _spl_responder_seen_reply "$d" "$tenant" "$box" "$agent" "$frm" "$task" "$mids" || { fails=$((fails + 1)); continue; }
        _spl_responder_pending_drop "$d" "$task"
      fi
    else
      _spl_responder_defer "$d" "$agent" "$task" "$frm" "$since" "$wait"
      skipped=$((skipped + 1))
    fi
    [[ -n "$mids" ]] && _spl_responder_forward "$send" "$agent" "$fwd" "$tenant" "$frm" "$task" "$mids"
    n=$((n + 1))
  done <<<"$rows"
  # A seen-only or file-only pass sent no reply, so nothing acked its inbox:
  # ack it here.
  if (( ! dry && skipped + filed > 0 )); then
    spl_desk_spool "$d" "$box" "$tenant" "$hub" -- recv --as "$agent" --ack >/dev/null 2>&1 ||
      do_log "WARN could not archive $agent's inbox"
  fi
  exec {lockfd}>&-

  do_log "OK $agent ($tenant): handled $n topic(s), $filed filed without a reply, $skipped already seen (no second reply), $fails failed"
  (( fails == 0 ))
}

# _spl_responder_seen_reply <desk dir> <tenant> <box> <agent> <from> <task>
# <msg ids>: (a) the visible "Seen" reply into the topic, once per topic ever.
# The ledger line is written BEFORE the send: a crash between the two loses one
# "Seen" (the file to the orchestrator still goes), never doubles it. 1 (with
# the FAIL) when the ledger or the reply fails.
_spl_responder_seen_reply() {
  local d="$1" tenant="$2" box="$3" agent="$4" frm="$5" task="$6" mids="$7"
  printf '%s\n' "$task" >>"$d/seen-topics" ||
    { do_log "FAIL $agent cannot record topic $task in $d/seen-topics; not replying"; return 1; }
  if ! ENV="$ENV" TENANT_ID="$tenant" DESK_AGENT="$agent" DESK_BOX="$box" \
       DESK_TO="$frm" DESK_TASK="$task" DESK_ACK=1 \
       DESK_BODY="Seen: routed to the team." DRY_RUN=0 do_spl_desk_reply >/dev/null 2>&1; then
    do_log "FAIL $agent could not reply to $frm in $task (msg $mids)"; return 1
  fi
}

# spl_responder_hub_rsp <desk dir> <box> <tenant> <hub> <task>: prints how
# many RSP-* rows the topic holds on the hub, from ANY box (`spool hub-rsp`).
# Never a guessed 0; printing nothing it returns
#   1 - the hub cannot say (down, refused, a bad answer);
#   2 - the check is not deployed yet: this box's spool binary has no hub-rsp,
#       or the hub does not answer rsp_count. A rollout gap, not an outage.
spl_responder_hub_rsp() {
  local out errf rc=0
  errf="$(mktemp "${TMPDIR:-/tmp}/spl-responder-rsp.XXXXXX")" || return 1
  out="$(spl_desk_spool "$1" "$2" "$3" "$4" -- hub-rsp --task "$5" 2>"$errf")" || rc=1
  if (( rc )); then
    grep -qE 'unknown command "hub-rsp"|does not answer rsp_count' "$errf" && rc=2
    rm -f "$errf"; return "$rc"
  fi
  rm -f "$errf"
  python3 -c 'import json,sys
v = json.loads(sys.argv[1]).get("rsp")
sys.exit(0 if type(v) is int and v >= 0 and print(v) is None else 1)' "$out" 2>/dev/null
}

# _spl_responder_settle <desk dir> <task>: another machine's Seen is on the
# hub - record the topic in this desk's ledger (the fast path from now on).
_spl_responder_settle() {
  printf '%s\n' "$2" >>"$1/seen-topics" || do_log "WARN cannot record topic $2 in $1/seen-topics"
  _spl_responder_pending_drop "$1" "$2"
}

# _spl_responder_defer <desk dir> <agent> <task> <from> <pending since> <wait>:
# the hub could not say whether the topic has an RSP row. FAIL CLOSED: no
# Seen now; the topic waits in <desk>/seen-pending (it survives the inbox ack)
# and is retried each pass. Past <wait> seconds it is given up: settled with
# NO Seen, because posting blind is exactly how two machines doubled it.
_spl_responder_defer() {
  local d="$1" agent="$2" task="$3" frm="$4" since="$5" wait="$6" now
  now="$(date +%s)"
  if [[ ! "$since" =~ ^[0-9]+$ ]]; then
    since="$now"
    printf '%s\t%s\t%s\n' "$task" "$frm" "$since" >>"$d/seen-pending" ||
      do_log "WARN cannot record topic $task in $d/seen-pending"
  fi
  if (( now - since >= wait )); then
    _spl_responder_settle "$d" "$task"
    do_log "WARN $agent gave up the Seen in topic $task: the hub could not say for ${wait}s whether another machine posted one, and a second Seen is worse than none (the escalation was filed)"
  else
    do_log "WARN $agent deferred the Seen in topic $task: the hub cannot say whether it already has an RSP row (retry next pass, gives up after ${wait}s)"
  fi
}

# _spl_responder_pending_drop <desk dir> <task>: the topic is settled.
_spl_responder_pending_drop() {
  local f="$1/seen-pending" tmp
  [[ -s "$f" ]] || return 0
  tmp="$(mktemp "$f.XXXXXX")" || return 0
  awk -F '\t' -v t="$2" '$1 != t' "$f" >"$tmp" && mv -f "$tmp" "$f" || rm -f "$tmp"
}

# _spl_responder_forward <send script> <agent> <to> <tenant> <from> <task>
# <msg ids>: (b) forward the escalation as a FILE to the orchestrator (never
# refused); a failed send only warns - the topic already has its "Seen".
_spl_responder_forward() {
  local send="$1" agent="$2" fwd="$3" tenant="$4" frm="$5" task="$6" mids="$7" body
  body="$(printf 'Unheard human post escalated by the responder (%s, tenant %s).\nFrom %s, topic %s, msg %s.\nReply in the topic with the answer.' "$agent" "$tenant" "$frm" "$task" "$mids")"
  if ! bash "$send" --from "$agent" --to "$fwd" --kind note --task "$task" --body "$body" >/dev/null 2>&1; then
    do_log "WARN $agent could not file msg $mids to $fwd (it is answered in-topic)"
  fi
}

# spl_responder_topics <recv file> <ledger> <outbox dir> <agent> [<pending>]:
# the inbox's HUM-* escalations grouped per topic, as
# "<task>\t<from>\t<msg_ids,>\t<seen>\t<pending since>" lines, oldest topic
# first. <from> is the topic's first human; seen=1 when the ledger lists the
# topic or the agent's outbox already holds a "Seen" reply in it - the outbox
# makes it idempotent even when the ledger is lost. Then every topic still in
# <pending> ("<task>\t<from>\t<epoch>", a deferred Seen) and not seen, with
# msg ids "-". An empty field is "-": read's tab IFS would collapse it.
spl_responder_topics() {
  python3 - "$1" "$2" "$3" "$4" "${5:-}" <<'PY'
import glob, json, os, sys
src, ledger, outbox, agent, pend = sys.argv[1:6]
try:
    msgs = json.load(open(src))
except Exception:
    msgs = []
pending = {}
try:
    for l in open(pend) if pend else []:
        p = l.rstrip("\n").split("\t")
        if len(p) >= 3 and p[0]:
            pending.setdefault(p[0], (p[1], p[2]))
except OSError:
    pass
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
    print("\t".join([task, ms[0][2], ",".join(x[1] for x in ms), "1" if task in seen else "0",
                     pending.get(task, ("", "-"))[1] or "-"]))
for task, (frm, since) in pending.items():
    if task not in topics and task not in seen:
        print("\t".join([task, frm or "-", "-", "0", since or "-"]))
PY
}
