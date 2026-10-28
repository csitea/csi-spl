#!/bin/bash
#------------------------------------------------------------------------------
# The human-to-human gate of do_spl_desk_reply, and so of do_spl_take and
# do_spl_take_auto, which post through it (SPL-3967). Measured 2026-10-27,
# csitea #csi-fina topic f21f5a07 (n=2 desk replies, and once before in
# another workspace, d6a1d959, 2026-10-21): a person posted to another person
# (to_id HUM-10), and a desk answered it. The person, in English: "I tagged
# @HUM-10 so the agent would not step in, and it was again taken as needing
# agent action".
#
# So a reply is refused (exit 9, nothing sent) when the newest human post in
# the topic since the last agent post there
#   - has to_id = a person (HUM-*), or
#   - is a channel post (ALL-0) whose body @-mentions people only, no agent.
# A later human post that is neither opens the topic to the agents again, and
# so does an agent post after it (an agent already answered the people).
# DESK_HUMAN_TO_HUMAN_OK=<msg id> (the full id or its first 8 characters)
# lets one reply through, for when that human then asks the agents.
# The topic is read from this desk box (hub-tail --json). A topic that cannot
# be read is let through with a WARN: the lease gate already refuses an
# unread topic to every seat but the holder. Under SPOOL_TEST=1 there is no
# gate unless SPL_DESK_HUMAN_GATE_TEST=1 (its own test).
#------------------------------------------------------------------------------

# spl_desk_human_gate <state dir> <box> <tenant> <hub> <agent> <task>: 0 when
# the topic's newest human post is for the agents, else 9 with the FATAL that
# names the post and the person it was addressed to.
spl_desk_human_gate() {
  local d="$1" box="$2" tenant="$3" hub="$4" agent="$5" task="$6" out hit msg whom ok="${DESK_HUMAN_TO_HUMAN_OK:-}"
  [[ "${SPOOL_TEST:-}" == 1 && "${SPL_DESK_HUMAN_GATE_TEST:-}" != 1 ]] && return 0
  if ! out="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- hub-tail --task "$task" --json 2>&1)"; then
    do_log "WARN the human-to-human gate cannot read topic $task, not checked: $(head -c 200 <<<"$out")"
    return 0
  fi
  hit="$(spl_desk_human_verdict <<<"$out")" || return 0
  IFS=$'\t' read -r msg whom <<<"$hit"
  if [[ -n "$ok" && ( "$ok" == "$msg" || ( ${#ok} -ge 8 && "$msg" == "$ok"* ) ) ]]; then
    do_log "WARN msg $msg in topic $task is addressed to $whom, not to the agents; DESK_HUMAN_TO_HUMAN_OK=$ok lets $agent answer it"
    return 0
  fi
  do_log "FATAL nothing was sent: msg $msg in topic $task is addressed to $whom, not to the agents (SPL-3967). Leave it to them; when $whom then asks the agents, answer that post, or pass DESK_HUMAN_TO_HUMAN_OK=$msg"
  return 9
}

# spl_desk_human_verdict, the topic's hub-tail NDJSON on stdin: the newest
# human post since the last agent post, when it is addressed to people only,
# as "<msg_id>\t<HUM-a[, HUM-b]>"; exit 1 (nothing printed) otherwise. An
# agent is any sender that is not a person (HUM-*), a responder (RSP-*) or a
# guest (GST-*). A mention is @<id> after a non-id character, so mail@HUM-1
# names nobody.
spl_desk_human_verdict() {
  python3 -c '
import json, re, sys
PEOPLE = ("HUM-", "RSP-", "GST-")
MENTION = re.compile(r"(?:^|[^A-Za-z0-9_.@-])@([A-Za-z][A-Za-z0-9_-]*)")
rows = []
for i, line in enumerate(sys.stdin):
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if isinstance(m, dict) and str(m.get("from", "")):
        rows.append((str(m.get("ts", "")), i, m))
rows.sort(key=lambda r: (r[0], r[1]))
last = None
for _, _, m in rows:
    frm = str(m["from"])
    if frm.startswith("HUM-"):
        last = m
    elif not frm.startswith(PEOPLE):
        last = None
if last is None:
    sys.exit(1)
to = str(last.get("to", "")).split("@")[0]
if to.startswith("HUM-"):
    whom = [to]
elif to in ("", "ALL-0"):
    whom = list(dict.fromkeys(MENTION.findall(str(last.get("body", "")))))
    if not whom or not all(w.startswith("HUM-") for w in whom):
        sys.exit(1)
else:
    sys.exit(1)
print("%s\t%s" % (last.get("msg_id", ""), ", ".join(whom)))'
}
