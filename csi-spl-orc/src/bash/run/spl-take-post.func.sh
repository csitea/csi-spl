#!/bin/bash
#------------------------------------------------------------------------------
# @description Print "TAKE-POST <msg id> <epoch>" for the newest human post in
# @description a topic that no agent has answered; nothing when there is none.
# @description "TAKE-ACKED <msg id> <epoch>" instead when an ack line (a take
# @description line or a poll "**In progress**: noted", any seat, any box)
# @description already follows that post (SPL-5514: one ack per post).
# @description First "TAKE-CHANNELS [<channel>...]": every channel the topic
# @description touches, without # and lower-case, none for a DM (hub-tail
# @description --with-channel), for do_spl_take's no-auto-post check (SPL-6068).
# @description With DESK_TAKE_AFTER=<msg id> the same, for that post only: a
# @description later human post does not replace it (the deferred take run).
# @description Read only, through the desk (hub-tail), as the desk's user: a
# @description moved desk re-runs this as its owner, like do_spl_desk_reply.
# @param ENV (required) - dev, prd or self
# @param TENANT_ID (required) - the workspace of the topic
# @param DESK_AGENT (required) - the seat's agent id
# @param DESK_TASK (required) - the full topic uuid
# @param DESK_BOX (optional) - the desk box, default this machine's desk box id
# @param DESK_TAKE_AFTER (optional) - judge this post msg id, not the newest one
# @example ENV=prd TENANT_ID=csitea DESK_AGENT=c-002 DESK_TASK=<full topic uuid> ./run -a do_spl_take_post
#------------------------------------------------------------------------------
do_spl_take_post() {
  do_require_bin python3 yq || return 1
  do_spl_desk_cnf || return 1
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-$(spl_desk_box_default)}" agent="${DESK_AGENT:-}" task="${DESK_TASK:-}" hop_to d out
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  [[ "$task" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
    { do_log "FATAL DESK_TASK must be the full topic uuid, got: '$task'"; return 1; }
  if hop_to="$(spl_desk_action_hop_to "$tenant" "$box")"; then
    spl_desk_action_hop do_spl_take_post "$hop_to" "$tenant" "$box" "$agent"; return $?
  fi
  d="$(spl_desk_dir "$tenant" "$box")" || return 1
  spl_host_spool || return 1
  out="$(spl_desk_spool "$d" "$box" "$tenant" "$SPL_HUB_URL" -- hub-tail --task "$task" --with-channel 2>/dev/null)" || return 1
  spl_take_post_parse <<<"$out"
}

# spl_take_post_parse, the topic's hub-tail NDJSON on stdin: the marked line of
# its newest human post with no agent answer after it (DESK_TAKE_AFTER: of
# that post). An answer is an agent's message to a person or the channel that
# is not an ack line (SPL-1718: a take is not the answer, the same test as
# _spl_sweep_take_sql; SPL-5514: nor is a poll "noted" line); an
# agent-to-agent relay answers nobody. An ack line after the post marks it
# TAKE-ACKED. Sorted as spl_desk_human_verdict: hub-tail is not. First, when
# every row carries its envelope "channel" (--with-channel), the line
# "TAKE-CHANNELS [<channel>...]"; a name with a blank keeps one, as "?", so the
# take reads it as "cannot tell".
spl_take_post_parse() {
  DESK_TAKE_AFTER="${DESK_TAKE_AFTER:-}" python3 -c '
import calendar, json, os, re, sys, time
PEOPLE = ("HUM-", "RSP-", "GST-")
ACK = re.compile(r"^(Taken by .*: .* I post the result here\.|\*\*In progress\*\*: noted \(.*\)\.)$", re.S)
after = os.environ.get("DESK_TAKE_AFTER", "")
rows = []
for i, line in enumerate(sys.stdin):
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if isinstance(m, dict) and str(m.get("from", "")):
        rows.append((str(m.get("ts", "")), i, m))
rows.sort(key=lambda r: (r[0], r[1]))
if rows and all("channel" in m for _, _, m in rows):
    chans = {re.sub(r"\s+", "?", str(m["channel"] or "").lstrip("#").lower()) for _, _, m in rows}
    print(" ".join(["TAKE-CHANNELS"] + sorted(c for c in chans if c)))
post, acked = None, False
for _, _, m in rows:
    frm = str(m["from"])
    to = str(m.get("to", "")).split("@")[0]
    if frm.startswith("HUM-"):
        if not after or str(m.get("msg_id", "")) == after:
            post, acked = m, False
    elif not frm.startswith(PEOPLE) and (to == "ALL-0" or to.startswith("HUM-")):
        if ACK.match(str(m.get("body", ""))):
            acked = acked or post is not None
        else:
            post = None
if post is None or not re.fullmatch(r"[A-Za-z0-9-]+", str(post.get("msg_id", ""))):
    sys.exit(0)
try:
    at = calendar.timegm(time.strptime(str(post.get("ts", ""))[:19], "%Y-%m-%dT%H:%M:%S"))
except ValueError:
    at = 0
print("%s %s %d" % ("TAKE-ACKED" if acked else "TAKE-POST", post["msg_id"], at))'
}
