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
# @description   2. the conversation to answer. When DESK_TASK names a topic,
# @description      the answer goes into THAT topic, full stop (owner rule, prd
# @description      t1 topic b280b0e8, 2026-09-29) - no inbox read, so a busy
# @description      desk's undrained inbox cannot block a reply into a named
# @description      topic. Otherwise the picker runs. NOT simply "the newest
# @description      human": two people (or a probe) writing to the same agent
# @description      would then take turns stealing each other's topic, and an
# @description      answer meant for one appears under the other - measured
# @description      2026-09-21, while the owner watched. So: only messages
# @description      NEWER than this desk's last answer count, and
# @description        - exactly one such (sender, topic)  -> answer it
# @description        - several                            -> REFUSE, exit 4,
# @description          and name them; pass DESK_TO / DESK_TASK to choose
# @description        - none                               -> exit 3
# @description      DESK_TO overrides the human; DESK_TASK overrides the topic
# @description      and skips the picker (the recv JSON rides on stdin, never
# @description      argv - an undrained inbox once overran ARG_MAX, 2026-09-29)
# @description   3. `spool send --from <agent> --to <hum> --task <task>
# @description      --to-box box-wui --kind <DESK_KIND>`; the desk's hub-run
# @description      sidecar flushes it to the hub
# @description   4. spec 067 rule 2: when the answered message is a DM about a
# @description      channel topic T (its ref_task_id, else the poke DM's
# @description      "needs you in <wui>/t/<T>" link), the answer goes IN T,
# @description      tagging the person (@HUM-n). It falls back to the DM,
# @description      carrying --ref T, when this desk cannot read T (hub-tail
# @description      returns nothing) or the post into T fails (edge 2). The
# @description      DESK_TO + full DESK_TASK form reads no message: no T.
# @description A body that says released / deployed with a commit sha but no
# @description /releases/ link for it gets a WARN per sha (spec 065 7.3, L9):
# @description ask the lane to add the line do_release_note_link prints. A
# @description warning only - the answer is still sent, unchanged.
# @description Prints one JSON line (msg_id, task_id, to, kind, the answered
# @description message's id and its first characters). No secret is read.
# @description Exit 3 when nothing newer than this desk's last answer is
# @description waiting. Exit 4 when more than one human conversation is, which
# @description is a question for the operator, not a guess for the action.
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the answering agent id (the pane's id)
# @param DESK_BODY - required unless DESK_BODY_FILE: the answer text (markdown renders, no fence needed: csi-spl-doc/doc/help/how-to-post.md)
# @param DESK_BODY_FILE (optional) - read the answer text from this file instead
# @param   (the dispatcher's one-command form: no $(cat ...) for the harness to judge)
# @param DESK_BOX (optional) - default box-desk, the same value do_spl_desk_up used
# @param DESK_KIND (optional) - note (default) | result | reject | blocker | msg
# @param   (blocker = the agent cannot proceed without the human's input; SPL-952)
# @param DESK_TO (optional) - answer THIS human id instead of the newest sender
# @param DESK_TASK (optional) - answer in THIS topic instead of the newest one.
# @param   A full task UUID, or an 8-hex topic-id prefix resolved against the
# @param   inbox (refused when ambiguous or unknown). When given, the answer
# @param   goes into that topic even when no newer human line is waiting; the
# @param   human is DESK_TO, else the topic's opener, else it refuses naming
# @param   DESK_TO. Given with a full UUID and DESK_TO, no inbox is read.
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
  do_spl_desk_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-$(spl_desk_box_default)}" agent="${DESK_AGENT:-}"
  local body="${DESK_BODY:-}" kind="${DESK_KIND:-note}" to="${DESK_TO:-}" task="${DESK_TASK:-}"
  _spl_desk_reply_body_file || return 1
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  local uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' f files=()
  read -r -a files <<<"${DESK_FILES:-}"
  _spl_desk_reply_check_args "$body" "$kind" "$to" "$task" "${files[@]}" || return 1

  local hub d
  hub="$SPL_HUB_URL"
  d="$SPL_STATE_DIR/desk/$tenant/$box"
  if (( dry )); then
    do_log "INFO DRY_RUN would: read $agent's inbox on $box and answer the newest human${to:+ $to}${task:+ in task $task} with a $kind${files[*]:+ and ${#files[@]} file(s)}; a DM about a topic is answered in that topic (spec 067)"
    [[ -d "$d/spool/$agent" ]] || do_log "INFO DRY_RUN there is no desk for $agent on $box in $tenant yet ($d): do_spl_desk_up seats one"
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0 to answer."
    return 0
  fi
  [[ -d "$d/spool/$agent" ]] || { do_log "FATAL no desk for $agent on $box in $tenant: run do_spl_desk_up first ($d)"; return 1; }
  spl_host_spool || return 1

  local ans_to ans_task ans_msg ans_head ans_ref=""
  if [[ -n "$to" && "$task" =~ $uuid_re ]]; then
    # Owner rule (prd t1 topic b280b0e8, 2026-09-29): a full topic id plus the
    # human means post THERE, full stop - no inbox read at all, so a busy
    # desk's undrained inbox (which once overran ARG_MAX) cannot block it.
    ans_to="$to"; ans_task="$task"; ans_msg=""; ans_head=""
  else
    local recvf pick prc=0
    recvf="$(mktemp "${TMPDIR:-/tmp}/spl-desk-recv.XXXXXX")" || { do_log "FATAL could not make a temp file for $agent's inbox"; return 1; }
    # The recv JSON lands in a FILE, never a shell word: an inbox is never
    # drained, so a busy desk (CLE-001) whose JSON went on argv overran ARG_MAX
    # and python never ran (measured 2026-09-29: "Argument list too long", the
    # pick empty, a waiting topic lost). spl_desk_pick reads the file by path.
    if ! spl_desk_spool "$d" "$box" "$tenant" "$hub" -- recv --as "$agent" >"$recvf" 2>&1; then
      do_log "FATAL recv --as $agent on $box: $(cat "$recvf")"; rm -f "$recvf"; return 1
    fi
    pick="$(spl_desk_pick "$recvf" "$to" "$task" "$d/answered" "${DESK_ANY:-0}")" || prc=$?
    (( prc == 0 )) && ans_ref="$(_spl_desk_reply_ref "$recvf" "$(cut -f3 <<<"$pick")")"
    rm -f "$recvf"
    if (( prc == 3 )); then
      do_log "INFO $agent has nothing newer than its last answer to reply to (inbox $d/spool/$agent/inbox); name a topic with DESK_TASK to answer in it regardless"; return 3
    elif (( prc == 4 )); then
      do_log "FATAL $agent has more than one conversation waiting; name one with DESK_TO and DESK_TASK (or DESK_ANY=1):"
      do_log "FATAL $pick"
      return 4
    elif (( prc == 5 )); then
      do_log "FATAL $pick"; return 1
    elif (( prc != 0 )); then
      do_log "FATAL cannot choose a conversation to answer: $pick"; return 1
    fi
    IFS=$'\t' read -r ans_to ans_task ans_msg ans_head <<<"$pick"
    [[ -n "$ans_to" && -n "$ans_task" ]] || { do_log "FATAL cannot read a human and a topic out of $agent's inbox"; return 1; }
  fi

  local ids=()
  _spl_desk_reply_put_files "$d" "$box" "$tenant" "$hub" "${files[@]}" || return 1

  local sent rc=0 route=dm sent_task="$ans_task" ref_args=()
  if [[ -n "$ans_ref" ]]; then
    if _spl_desk_reply_can_read "$d" "$box" "$tenant" "$hub" "$ans_ref"; then
      sent="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- send --from "$agent" --to "$ans_to" \
        --task "$ans_ref" --to-box box-wui --kind "$kind" --body "$(_spl_desk_reply_tag "$ans_to" "$body")" "${ids[@]}")" || rc=$?
      if (( rc == 0 )); then
        route=topic; sent_task="$ans_ref"
      else
        do_log "WARN could not post in topic $ans_ref ($sent): answering $ans_to in the DM instead (spec 067 edge 2)"
        route=dm-fallback; rc=0
      fi
    else
      do_log "WARN $agent cannot read topic $ans_ref (this box holds none of it): answering $ans_to in the DM instead (spec 067 edge 2)"
      route=dm-fallback
    fi
  fi
  if [[ "$route" != topic ]]; then
    [[ "$route" == dm-fallback ]] && ref_args=(--ref "$ans_ref")
    sent="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- send --from "$agent" --to "$ans_to" \
      --task "$ans_task" --to-box box-wui --kind "$kind" --body "$body" "${ids[@]}" "${ref_args[@]}")" || rc=$?
  fi
  (( rc == 0 )) || { do_log "FATAL send $agent -> $ans_to in task $ans_task: $sent"; return 1; }
  SPL_SENT="$sent" SPL_ROUTE="$route" SPL_REF="$ans_ref" \
    _spl_desk_reply_summary "$ENV" "$tenant" "$box" "$agent" "$kind" "$ans_to" "$sent_task" "$ans_msg" "$ans_head"
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
  do_log "OK $agent answered $ans_to in topic $sent_task ($kind${ans_ref:+, $route}); the sidecar flushes it to $hub"
}

# _spl_desk_reply_summary <env> <tenant> <box> <agent> <kind> <to> <task>
# <answered msg> <answered head>: the JSON line of an answer, with the send
# result from SPL_SENT. With SPL_REF (spec 067) it adds ref_task_id and route:
# topic (answered in it), dm-fallback (edge 2) or dm.
_spl_desk_reply_summary() {
  python3 - "$@" <<'EOF_PY'
import json, os, sys
env, tenant, box, agent, kind, to, task, in_msg, head = sys.argv[1:]
sent = os.environ.get("SPL_SENT", "")
try:
    sent = json.loads(sent)
except ValueError:
    pass
row = {"env": env, "tenant": tenant, "box": box, "agent": agent, "kind": kind,
       "to": to, "task_id": task, "answered_msg_id": in_msg, "answered_head": head,
       "send": sent}
if os.environ.get("SPL_REF"):
    row["ref_task_id"], row["route"] = os.environ["SPL_REF"], os.environ.get("SPL_ROUTE", "")
print(json.dumps(row, sort_keys=True))
EOF_PY
}

# _spl_desk_reply_ref <recv file> <msg_id>: the channel topic T the answered
# message is about (spec 067 3.3), or nothing. Only a DM counts (a channel post
# is to ALL-0 and already lives in its topic). T is the message's ref_task_id
# when a box reader carries it, else the poke DM's link: the WUI's poke body
# is "<author> needs you in <wui>/t/<T>: ..." (mention-poke.mjs pokeBody).
_spl_desk_reply_ref() {
  python3 - "${1:-}" "${2:-}" <<'EOF_PY'
import json, re, sys
src, msg_id = sys.argv[1], sys.argv[2]
UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
try:
    with open(src) as f:
        msgs = json.load(f) or []
except (OSError, ValueError):
    sys.exit(0)
m = next((x for x in msgs if isinstance(x, dict) and msg_id and x.get("msg_id") == msg_id), None) if isinstance(msgs, list) else None
if not m or str(m.get("to", "")) in ("", "ALL-0"):
    sys.exit(0)
ref = str(m.get("ref_task_id", "")).lower()
if not re.fullmatch(UUID, ref):
    hit = re.search(r"needs you in \S*/t/(" + UUID + r")\b", str(m.get("body", "")), re.I)
    ref = hit.group(1).lower() if hit else ""
if ref and ref != str(m.get("task_id", "")).lower():
    print(ref)
EOF_PY
}

# _spl_desk_reply_can_read <state dir> <box> <tenant> <hub> <task>: 0 when
# this desk box holds any message of topic <task> on the hub (hub-tail serves
# only what the box holds), i.e. its agent sees the topic. Edge 2: never tag a
# person into a topic the answer cannot be seen in.
_spl_desk_reply_can_read() {
  local out
  out="$(spl_desk_spool "$1" "$2" "$3" "$4" -- hub-tail --task "$5" --json 2>/dev/null)" || return 1
  grep -q '^{' <<<"$out"
}

# _spl_desk_reply_tag <human> <body>: body tagging the human (@HUM-n) once:
# a body that already tags them is left as it is.
_spl_desk_reply_tag() {
  if grep -qE "(^|[^A-Za-z0-9_-])@$1([^A-Za-z0-9_-]|\$)" <<<"$2"; then
    printf '%s' "$2"
  else
    printf '@%s %s' "$1" "$2"
  fi
}

# _spl_desk_reply_body_file: DESK_BODY_FILE's text into the caller's body
# (do_spl_desk_reply's local); 1 with the FATAL when DESK_BODY is set too or
# the file is unreadable. Unset: body stays DESK_BODY.
_spl_desk_reply_body_file() {
  [[ -n "${DESK_BODY_FILE:-}" ]] || return 0
  [[ -z "$body" ]] || { do_log "FATAL set DESK_BODY or DESK_BODY_FILE, not both"; return 1; }
  [[ -f "$DESK_BODY_FILE" && -r "$DESK_BODY_FILE" ]] || { do_log "FATAL DESK_BODY_FILE is not a readable file: '$DESK_BODY_FILE'"; return 1; }
  body="$(cat "$DESK_BODY_FILE")"
}

# _spl_desk_reply_check_args <body> <kind> <to> <task> <file>...: 0 when the
# answer's inputs are sane, else the FATAL that names the bad one.
_spl_desk_reply_check_args() {
  local body="$1" kind="$2" to="$3" task="$4" f; shift 4
  local uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' pfx_re='^[0-9a-f]{8}$'
  [[ -n "$body" ]] || { do_log "FATAL DESK_BODY must carry the answer text"; return 1; }
  [[ "$kind" =~ ^(note|result|reject|blocker|msg)$ ]] || { do_log "FATAL DESK_KIND must be note, result, reject, blocker or msg, got: '$kind'"; return 1; }
  [[ -z "$to" || "$to" =~ ^HUM-[A-Za-z0-9_-]{1,64}$ ]] || { do_log "FATAL DESK_TO must be a human id (HUM-...), got: '$to'"; return 1; }
  [[ -z "$task" || "$task" =~ $uuid_re || "$task" =~ $pfx_re ]] || { do_log "FATAL DESK_TASK must be a lowercase task UUID or an 8-hex topic prefix, got: '$task'"; return 1; }
  for f in "$@"; do
    [[ -f "$f" && -r "$f" ]] || { do_log "FATAL DESK_FILES entry is not a readable file: '$f'"; return 1; }
  done
  _spl_desk_reply_release_warn "$body"
  return 0
}

# _spl_desk_reply_release_warn <body>: spec 065 7.3 (L9). A post that says
# released / deployed and names a commit sha carries that sha's note link
# (`/releases/<sha>`). One WARN per sha without one, naming the command that
# prints the line, so the dispatcher asks the lane for it before the owner
# reads the post. Never refuses: a missing link must not lose a report.
# A sha is 7..40 lowercase hex with a digit AND a letter; topic UUIDs are
# skipped. A link covers a sha when either is a prefix of the other.
_spl_desk_reply_release_warn() {
  local body="$1" sha l covered links=() seen=" "
  grep -qiE '\b(released|deployed)\b' <<<"$body" || return 0
  mapfile -t links < <(grep -oE '/releases/[0-9a-f]{7,40}' <<<"$body" | sed 's#^/releases/##')
  while read -r sha; do
    [[ -n "$sha" && "$sha" =~ [0-9] && "$sha" =~ [a-f] && "$seen" != *" $sha "* ]] || continue
    seen+="$sha "
    covered=0
    for l in "${links[@]}"; do [[ "$l" == "$sha"* || "$sha" == "$l"* ]] && { covered=1; break; }; done
    (( covered )) && continue
    do_log "WARN release-note link missing: the post says released/deployed with sha $sha but no /releases/ link; ask the lane to add it (./run -a do_release_note_link SHA=$sha ENV=<dev|prd>). The post is sent unchanged."
  done < <(sed -E 's/[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}//g; s#/releases/[0-9a-f]+##g' <<<"$body" |
    grep -oE '\b[0-9a-f]{7,40}\b')
  return 0
}

# _spl_desk_reply_put_files <state dir> <box> <tenant> <hub> <file>...: upload
# each file through the desk's spool and append "--file-id <id>" to the
# caller's ids[] (do_spl_desk_reply's local); 1 with the FATAL on a failure.
_spl_desk_reply_put_files() {
  local d="$1" box="$2" tenant="$3" hub="$4" f put id; shift 4
  for f in "$@"; do
    put="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- put-file "$f" 2>&1)" ||
      { do_log "FATAL put-file $f: $put"; return 1; }
    id="$(printf '%s' "$put" | python3 -c 'import json,sys; print(json.load(sys.stdin)["file_id"])' 2>/dev/null)" ||
      { do_log "FATAL put-file $f returned no file_id: $put"; return 1; }
    ids+=(--file-id "$id")
  done
}

# spl_desk_pick <recv file> <to override> <task override> <answered file> <any>:
# the conversation to answer, as "<to>\t<task>\t<msg_id>\t<head>". The recv JSON
# is read from a FILE, never argv - a desk's inbox is never drained, so a busy
# one (its JSON as an argv word) overran ARG_MAX and python never ran (measured
# 2026-09-29: "Argument list too long", the pick empty, a waiting topic lost).
#
# Humans only (a HUM-* sender): a desk answers the person in the browser, not
# another box. When DESK_TASK names a topic, the answer goes into THAT topic
# full stop (owner rule, prd t1 topic b280b0e8, 2026-09-29) - no "newer than
# the last answer" gate. Otherwise, among the human messages, only ones NEWER
# than this desk's last answer are candidates - an inbox is never drained, so
# "the newest human message" alone would keep re-picking whoever spoke most
# recently ANYWHERE, and an answer meant for one person would land in another's.
#
# An 8-hex DESK_TASK is a topic-id prefix, resolved against the inbox's
# task_ids. Exit 3 nothing to answer; exit 4 more than one conversation is
# waiting; exit 5 a named topic could not be resolved or addressed - each
# listed on stdout, a question for the operator, not a guess.
spl_desk_pick() {
  python3 - "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-0}" <<'EOF_PY'
import json, re, sys
src, to, task, answered, any_one = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] == "1"
try:
    with open(src) as f:
        msgs = json.load(f) or []
except (OSError, ValueError):
    msgs = []
if not isinstance(msgs, list):
    msgs = []
msgs = [m for m in msgs if isinstance(m, dict)]

UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

# An 8-hex (or otherwise partial) DESK_TASK is a topic-id prefix: resolve it to
# the one full task_id the inbox carries; refuse it ambiguous or unknown.
if task and not UUID.match(task):
    cands = sorted({str(m.get("task_id", "")) for m in msgs
                    if str(m.get("task_id", "")).startswith(task)})
    if len(cands) == 1:
        task = cands[0]
    elif not cands:
        print("no topic in this desk's inbox starts with '%s'; pass the full DESK_TASK uuid" % task)
        sys.exit(5)
    else:
        print("DESK_TASK prefix '%s' is ambiguous, name the full uuid: %s" % (task, ", ".join(cands)))
        sys.exit(5)

hums = [m for m in msgs if str(m.get("from", "")).startswith("HUM-")]

def out(to_, task_, m=None):
    head = " ".join(str((m or {}).get("body", "")).split())[:80]
    print("\t".join([to_, task_, (m or {}).get("msg_id", "") if m else "", head]))
    sys.exit(0)

# Owner rule (prd t1 topic b280b0e8, 2026-09-29): "if the agent gives the topic
# id, post there, full stop. The 'answer the last human' logic is used only when
# no topic is given." So a named DESK_TASK never falls through to exit 3.
if task:
    in_topic = sorted([m for m in hums if m.get("task_id") == task],
                      key=lambda m: (str(m.get("ts", "")), str(m.get("msg_id", ""))))
    if to:
        m = next((x for x in reversed(in_topic) if x.get("from") == to), None)
        out(to, task, m)  # obey the explicit human, with a message or without
    if in_topic:
        out(in_topic[-1].get("from", ""), task, in_topic[-1])  # the topic's human opener
    print("topic %s has no human message in this desk's inbox; name the human with DESK_TO" % task)
    sys.exit(5)

# No DESK_TASK: the "answer the last human" picker.
rows = hums
if to:
    rows = [m for m in rows if m.get("from") == to]
rows.sort(key=lambda m: (str(m.get("ts", "")), str(m.get("msg_id", ""))))
if to:
    if rows:
        out(to, rows[-1].get("task_id", ""), rows[-1])
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
out(fresh[-1].get("from", ""), fresh[-1].get("task_id", ""), fresh[-1])
EOF_PY
}
