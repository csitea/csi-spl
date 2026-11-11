#!/usr/bin/env bash
# spool-notify.sh: a topic seat (a lane placed by a `# Seat brief:` for ONE
# topic) is typed a channel post of ANOTHER topic only when that topic has no
# live seat of its own on the box, or the post names it (SPL-5261). Its own
# topic's posts, DMs and messages addressed to it are typed as before; the
# held post still lands in its inbox.
#
# Why: one channel can hold one seat per topic. Every channel post reaches
# every channel member (owner rule 2026-09-22), so on 2026-11-10 the owner's
# posts in one topic were typed into the seats of two other topics too, and
# each forwarded them to the topic's own seat, which already had them.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
SN="$T_SCRIPTS/spool-notify.sh"

. "$T_FEAT/lib/spool-env.inc.sh"
. "$T_FEAT/lib/spool-notify.inc.sh"
spool_env_resolve

TA="aaaaaaaa-1111-4111-8111-111111111111"   # c-507's topic
TB="bbbbbbbb-2222-4222-8222-222222222222"   # c-508's topic
TC="cccccccc-3333-4333-8333-333333333333"   # a topic with no seat

seat_brief() {  # ID HEADING DISCUSSION-LINE
  mkdir -p "$SPOOL_ROOT/$1/lifetime"
  printf '%s\n\nChannel: acme #ops\n%s\n\nAnswer the owner in this one topic.\n' "$2" "$3" \
    >"$SPOOL_ROOT/$1/lifetime/brief.md"
}
seat_brief c-507 "# Seat brief: acme #ops topic aaaaaaaa - one topic" "Discussion: $TA"
seat_brief c-508 "# Seat brief: acme #ops wf-12 topic \`bbbbbbbb\` - one topic" "**Topic $TB is yours**"
seat_brief c-509 "# Lane brief: bug - a lane, not a seat" "Discussion: $TB"
seat_brief c-510 "# Seat brief: acme, channel #ops - answer the owner's posts there" "Topic: $TB"
seat_brief c-511 "# Seat brief: acme #ops topic $TB - one topic" "Discussion: $TB"
seat_brief c-512 "# Seat brief: acme #ops rollout (topic bbbbbbbb), new seat" "Discussion: $TB"
seat_brief c-513 "# Seat brief: acme #ops wf-12 topic 0956269e - rebase the branch, then stay as the topic's seat" "Topic: $TB"

# ---- which topic a seat holds ------------------------------------------------
t=""
spool_notify_seat_topic_var t c-507; eq "a Seat brief's heading 'topic <8hex>' is the seat's topic" "aaaaaaaa" "$t"
spool_notify_seat_topic_var t c-508; eq "...with more words before it and in backticks" "bbbbbbbb" "$t"
spool_notify_seat_topic_var t c-511; eq "...or as a full uuid" "bbbbbbbb" "$t"
spool_notify_seat_topic_var t c-512; eq "...or in parentheses" "bbbbbbbb" "$t"
# The live wf-12 seat's heading shape (read on its box 2026-11-11, c-001 d08915fc).
spool_notify_seat_topic_var t c-513; eq "...after a word between the channel and 'topic' (the heading, not the body)" "0956269e" "$t"
spool_notify_seat_topic_var t c-508
spool_notify_topic_is "$TB" "$t" && ok "...and the topic's uuid matches it" || nok "...and the topic's uuid matches it"
spool_notify_topic_is "$TA" "$t" && nok "CONTROL: another uuid does not" || ok "CONTROL: another uuid does not"
spool_notify_seat_topic_var t c-509; eq "CONTROL: a Lane brief is no topic seat" "" "$t"
spool_notify_seat_topic_var t c-510; eq "CONTROL: a whole-channel Seat brief is no topic seat, whatever its body names" "" "$t"
spool_notify_seat_topic_var t c-999; eq "CONTROL: no recorded brief, no topic seat" "" "$t"
# The desk sidecar: SPOOL_ROOT is the desk spool, the briefs are the box's.
FR="$T_TMP/fleet"; mkdir -p "$FR"; cp -r "$SPOOL_ROOT/c-507" "$FR/c-517"
SPOOL_FLEET_ROOT="$FR" spool_notify_seat_topic_var t c-517
eq "the desk sidecar reads the brief under SPOOL_FLEET_ROOT" "aaaaaaaa" "$t"

# ---- live, against a private tmux server -----------------------------------
t_tmux
tui() {  # ID -> pane on the alternate screen (the agent-TUI shape)
  local p
  p="$(t_window "$1" "sh -c 'printf \"\033[?1049h\"; sleep 600'")"
  printf '%s\tclaude\t%s\t/x\t20260101T000000Z\n' "$1" "$p" >>"$SPOOL_ROOT/registry.tsv"
  printf '%s' "$p"
}
P7="$(tui c-507)"
sleep 0.4
msg() {  # TO-INBOX MSGID8 ADDRESSED-TO FROM TASK BODY
  mkdir -p "$SPOOL_ROOT/$1/inbox"
  printf '{"body":"%s","from":"%s","kind":"msg","msg_id":"%s-0000-0000-0000-000000000000","task_id":"%s","to":"%s","v":1}' \
    "$6" "$4" "$2" "$5" "$3" >"$SPOOL_ROOT/$1/inbox/20260101T000000Z--$4--x-$2.json"
}
notify() {  # TO FROM MSGID8 TASK BODY
  bash "$SN" --to "$1" --from "$2" --kind task --task "$4" --msg-id "$3-0000-0000-0000-000000000000" --body "$5"
}
screen() { sleep 0.6; tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$1" | tr -d '\n'; }

# 1. CONTROL first: topic B's seat c-508 has no live pane, so B has no live
#    seat - the owner's post in B is typed into c-507 (someone must see it).
msg c-507 b0000001 ALL-0 HUM-10 "$TB" 'recursion bug zz01'
notify c-507 HUM-10 b0000001 "$TB" 'recursion bug zz01' >/dev/null
has "CONTROL: a post in a topic with no live seat is TYPED into another seat" "zz01" "$(screen "$P7")"

# 2. c-508 is up: the same kind of post in B is held from c-507.
P8="$(tui c-508)"; sleep 0.4
rm -rf "$SPOOL_ROOT/c-507/.mirror/trigger"
msg c-507 b0000002 ALL-0 HUM-10 "$TB" 'Fixit now zz02'
out="$(notify c-507 HUM-10 b0000002 "$TB" 'Fixit now zz02')"
eq "a post in another seat's topic: exit 0" 0 "$?"
has "...the notifier says the topic-seat filter held it" "poke: topic-seat filter - c-507" "$out"
hasnt "...it is NOT typed into the other seat's pane" "zz02" "$(screen "$P7")"
check "...it is still in that seat's inbox" test -s "$SPOOL_ROOT/c-507/inbox/20260101T000000Z--HUM-10--x-b0000002.json"
check "...and leaves no mirror trigger (nothing was typed)" test ! -e "$SPOOL_ROOT/c-507/.mirror/trigger"

# 3. The topic's own seat is typed it.
msg c-508 b0000002 ALL-0 HUM-10 "$TB" 'Fixit now zz02'
notify c-508 HUM-10 b0000002 "$TB" 'Fixit now zz02' >/dev/null
has "the topic's own seat IS typed the post" "zz02" "$(screen "$P8")"

# 4. A seat's own topic: typed.
msg c-507 a0000003 ALL-0 HUM-10 "$TA" 'own topic zz03'
notify c-507 HUM-10 a0000003 "$TA" 'own topic zz03' >/dev/null
has "a post in the seat's own topic is TYPED" "zz03" "$(screen "$P7")"

# 5. Another seat's agent reply fans out too: held as well.
msg c-507 b0000004 HUM-10 c-508 "$TB" 'In progress (c-508) zz04'
out="$(notify c-507 c-508 b0000004 "$TB" 'In progress (c-508) zz04')"
has "an agent's channel post in another seat's topic is held" "poke: topic-seat filter - c-507" "$out"
hasnt "...not typed" "zz04" "$(screen "$P7")"

# 6. A post that names the seat, a DM to it, and a seatless topic: typed.
msg c-507 b0000005 ALL-0 HUM-10 "$TB" '@c-507 look here too zz05'
notify c-507 HUM-10 b0000005 "$TB" '@c-507 look here too zz05' >/dev/null
has "a post in another seat's topic that NAMES the seat is TYPED" "zz05" "$(screen "$P7")"
msg c-507 b0000006 c-507 c-508 "$TB" 'handing you a file zz06'
notify c-507 c-508 b0000006 "$TB" 'handing you a file zz06' >/dev/null
has "a message addressed to the seat is TYPED, whatever its topic" "zz06" "$(screen "$P7")"
msg c-507 c0000007 ALL-0 HUM-10 "$TC" 'new topic zz07'
notify c-507 HUM-10 c0000007 "$TC" 'new topic zz07' >/dev/null
has "a post in a topic with no seat is TYPED" "zz07" "$(screen "$P7")"

# 7. A lane that is not a seat is typed every channel post, as before.
P9="$(tui c-509)"; sleep 0.4
msg c-509 b0000008 ALL-0 HUM-10 "$TB" 'lane sees it zz08'
notify c-509 HUM-10 b0000008 "$TB" 'lane sees it zz08' >/dev/null
has "CONTROL: a non-seat lane is TYPED the channel post" "zz08" "$(screen "$P9")"

t_done
