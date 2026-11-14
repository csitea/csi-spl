#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the take line and the poll "noted" line are deferred, and one take
#          line per human post (SPL-5514, owner poll d0c7b716 item 1). A
#          sandbox: a scratch SPOOL_ROOT, stubbed desk reply, topic read,
#          wake sender and deferred re-run. No hub, no prd, no live spool.
#   a. a result within the window -> 0 ack posts:
#      take: the first call posts nothing and starts one deferred run; that
#      run, with the post answered, posts nothing (TAKE-QUIET)
#      poll: a vote 1 min old is not acked; an agent posts; 5 min on -> 0
#   b. no result in the window -> exactly 1:
#      take: the deferred run with the post still unanswered posts one line
#      poll: 4:59 after the vote 0, at 5:00 1, later runs still 1
#   c. two takes on one post (two seats, as c-003 and c-002 on 2026-11-09,
#      post 382450e2) -> 1 line; two deferred runs of two seats -> 1 line
#   d. R7 a-770 W1-W4 (SPL-5514), on the real topic parser (stub hub-tail):
#      W1 a later human post does not hide the deferred post: 1 line
#      W2 two calls in the window: 1 deferred run (a sleep, then ./run),
#         the second prints TAKEN-ALREADY; TAKE_NOTIFY goes out once
#      W3 a "noted" line is an ack, not an answer (take: no second ack);
#         poll: a take line after the vote posts no "noted" but wakes the
#         holder; a relay to another agent answers nothing
#      W4 a take line of another box in the topic: TAKEN-ALREADY, 0 lines
#   RED CONTROL: ACK_QUIET_TAKE_FUNC / ACK_QUIET_POLL_FUNC point at another
#   copy of the actions; origin/master's copies turn a and c red (the commit
#   that added this file carries that run).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
TAKE_FUNC="${ACK_QUIET_TAKE_FUNC:-$PROJ_ROOT/src/bash/run/spl-take.func.sh}"
POLL_FUNC="${ACK_QUIET_POLL_FUNC:-$PROJ_ROOT/src/bash/run/spl-desk-poll-ack.func.sh}"
n() { [[ -f "$1" ]] && wc -l <"$1" | tr -d ' ' || echo 0; }

# --- the take stubs -----------------------------------------------------------
S="$T/spool"; mkdir -p "$S/dispatch"
# shellcheck disable=SC2016 # the stubs expand their own vars at run time
{
  printf '#!/usr/bin/env bash\necho "$DESK_AGENT $DESK_TASK $DESK_BODY" >>"$REPLY_LOG"\n' >"$T/reply.sh"
  printf '#!/usr/bin/env bash\n[ -e "$POST_FILE" ] || exit 9\ncat "$POST_FILE"\n' >"$T/post.sh"
  printf '#!/usr/bin/env bash\necho "$* due=$TAKE_DEFER_DUE post=$TAKE_DEFER_POST agent=$DESK_AGENT box=$TAKE_BOX" >>"$SPAWN_LOG"\n' >"$T/spawn.sh"
  printf '#!/bin/sh\n[ -n "${SEND_LOG:-}" ] && echo "$*" >>"$SEND_LOG"\n:\n' >"$T/send.sh"
  printf '#!/bin/sh\necho "sleep $1" >>"$SLEEP_LOG"\n' >"$T/sleep.sh"
  printf '#!/usr/bin/env bash\nsource "$PROJ_PATH/src/bash/run/spl-take-post.func.sh"\nspl_take_post_parse <"$TAIL_FILE"\n' >"$T/parse.sh"
}
chmod +x "$T/reply.sh" "$T/post.sh" "$T/spawn.sh" "$T/send.sh" "$T/sleep.sh" "$T/parse.sh"
R="$T/replies.log" SP="$T/spawns.log" P="$T/post"
# take [VAR=VAL ...]: do_spl_take in a clean shell, deferral 300 s
take() {
  env -i PATH="$PATH" HOME="$HOME" PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_TEST=1 \
    REPLY_LOG="$R" SPAWN_LOG="$SP" POST_FILE="$P" TAKE_REPLY_CMD="$T/reply.sh" TAKE_SEND="$T/send.sh" \
    TAKE_POST_CMD="$T/post.sh" TAKE_DEFER_RUN="$T/spawn.sh" ACK_DEFER_S=300 TAKE_FUNC="$TAKE_FUNC" \
    TAKE_DEFER_SLEEP="$T/sleep.sh" SLEEP_LOG="$T/sleeps.log" SEND_LOG="$T/sends.log" TAIL_FILE="$T/tail.ndjson" \
    ENV=prd TENANT_ID=csitea DESK_AGENT=c-002 DESK_TO=HUM-10 TAKE_BOX=box-a \
    TAKE_PLAN='I read your post now' "$@" bash -c '
    do_log() { echo "$*" >&2; }
    source "$PROJ_PATH/lib/bash/funcs/spl-desk-box.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    source "$TAKE_FUNC"
    do_spl_take' >"$T/o" 2>&1
}
# wait_n <file> <count>: the deferred run is started in the background
wait_n() { local _; for _ in $(seq 50); do [[ "$(n "$1")" -ge "$2" ]] && return 0; sleep 0.1; done; return 1; }
now=$(date +%s)

# --- a. take: a result within the window -> 0 posts ---------------------------
A=00000000-0000-4000-8000-00000000a001
echo "TAKE-POST post-a $((now - 10))" >"$P"
take DRY_RUN=0 DESK_TASK="$A"
wait_n "$SP" 1
if [[ "$(n "$R")" == 0 ]] && grep -q "^TAKE-DEFERRED $A" "$T/o"; then
  pass "a. take: the first call posts no line (TAKE-DEFERRED)"
else fail "a. take: the first call posted $(n "$R"): $(cat "$T/o")"; fi
[[ "$(n "$SP")" == 1 ]] && grep -q -- "-a do_spl_take due=$((now + 290)) post=post-a agent=c-002 box=box-a" "$SP" &&
  pass "a. take: one deferred run, due 300 s after the post, for that post" || fail "a. spawns: $(cat "$SP" 2>/dev/null)"
: >"$P"
take DRY_RUN=0 DESK_TASK="$A" TAKE_DEFER_DUE="$((now - 1))" TAKE_DEFER_POST=post-a
[[ "$(n "$R")" == 0 ]] && grep -q "^TAKE-QUIET $A" "$T/o" &&
  pass "a. take: the deferred run finds the post answered: 0 ack posts" || fail "a. take quiet: $(n "$R") posts: $(cat "$T/o")"

# --- b. take: no result in the window -> exactly 1 ----------------------------
B=00000000-0000-4000-8000-00000000b001
echo "TAKE-POST post-b $((now - 301))" >"$P"; b="$(n "$R")"
take DRY_RUN=0 DESK_TASK="$B" TAKE_DEFER_DUE="$((now - 1))" TAKE_DEFER_POST=post-b
take DRY_RUN=0 DESK_TASK="$B" TAKE_DEFER_DUE="$((now - 1))" TAKE_DEFER_POST=post-b
[[ "$(n "$R")" == $((b + 1)) ]] && grep -q "c-002 $B Taken by c-002@box-a: I read your post now. I post the result here." "$R" &&
  pass "b. take: the post still unanswered: exactly 1 take line" || fail "b. take: $(( $(n "$R") - b )) posts: $(cat "$T/o")"
[[ "$(tail -n 1 "$S/dispatch/take.log" | cut -f2,5)" == "$B"$'\tpost-b' ]] && pass "b. take: the ledger row names the post" ||
  fail "b. ledger: $(tail -n 1 "$S/dispatch/take.log")"

# --- c. two takes on one post -> 1 line ---------------------------------------
C=00000000-0000-4000-8000-00000000c001
echo "TAKE-POST post-c 1000" >"$P"; b="$(n "$R")"
take DRY_RUN=0 DESK_TASK="$C" DESK_AGENT=c-003
take DRY_RUN=0 DESK_TASK="$C" DESK_AGENT=c-002
[[ "$(n "$R")" == $((b + 1)) ]] && grep -q "^TAKEN-ALREADY $C by c-002@box-a" "$T/o" &&
  pass "c. two seats take one post: 1 line, the second prints TAKEN-ALREADY" || fail "c. two seats: $(( $(n "$R") - b )) lines: $(cat "$T/o")"
C2=00000000-0000-4000-8000-00000000c002
echo "TAKE-POST post-c2 $((now - 301))" >"$P"; b="$(n "$R")"
take DRY_RUN=0 DESK_TASK="$C2" DESK_AGENT=c-003 TAKE_DEFER_DUE="$((now - 1))" TAKE_DEFER_POST=post-c2
take DRY_RUN=0 DESK_TASK="$C2" DESK_AGENT=c-002 TAKE_DEFER_DUE="$((now - 1))" TAKE_DEFER_POST=post-c2
[[ "$(n "$R")" == $((b + 1)) ]] && pass "c. two seats' deferred runs on one post: 1 line" || fail "c. deferred: $(( $(n "$R") - b )) lines"
C3=00000000-0000-4000-8000-00000000c003
echo "TAKE-POST post-c3 2000" >"$P"; b="$(n "$R")"
take DRY_RUN=0 DESK_TASK="$C3" DESK_AGENT=c-003
echo "TAKE-POST post-c4 3000" >"$P"
take DRY_RUN=0 DESK_TASK="$C3" DESK_AGENT=c-002
[[ "$(n "$R")" == $((b + 2)) ]] && pass "c. a newer post in the same topic still gets its own line" || fail "c. newer post: $(( $(n "$R") - b ))"

# --- d. R7 W1/W2/W4 and the take side of W3, on the real parser --------------
# hrow <from> <to> <id> <epoch> <body>: one hub-tail line
hrow() { jq -cn --arg f "$1" --arg t "$2" --arg i "$3" --arg s "$(date -u -d "@$4" +%Y-%m-%dT%H:%M:%SZ)" --arg b "$5" '{from:$f,to:$t,msg_id:$i,ts:$s,body:$b}'; }
TK3='Taken by c-003@box-b: I read your post now. I post the result here.'
D1=00000000-0000-4000-8000-00000000d001
{ hrow HUM-10 ALL-0 m-d1 $((now - 301)) 'Status?'; hrow HUM-10 ALL-0 m-d2 $((now - 200)) 'and a screenshot'; } >"$T/tail.ndjson"
b="$(n "$R")"
take DRY_RUN=0 DESK_TASK="$D1" TAKE_POST_CMD="$T/parse.sh" TAKE_DEFER_DUE="$((now - 1))" TAKE_DEFER_POST=m-d1
[[ "$(n "$R")" == $((b + 1)) ]] && pass "d. W1: a later human post does not hide the deferred post: 1 take line" ||
  fail "d. W1: $(( $(n "$R") - b )) lines: $(cat "$T/o")"
D2=00000000-0000-4000-8000-00000000d002
hrow HUM-10 ALL-0 m-d3 $((now - 10)) 'New topic' >"$T/tail.ndjson"
: >"$SP"; : >"$T/sleeps.log"; : >"$T/sends.log"; b="$(n "$R")"
take DRY_RUN=0 DESK_TASK="$D2" TAKE_POST_CMD="$T/parse.sh" TAKE_NOTIFY=c-009
wait_n "$SP" 1; cp "$T/o" "$T/o1"
take DRY_RUN=0 DESK_TASK="$D2" TAKE_POST_CMD="$T/parse.sh" DESK_AGENT=c-003
sleep 0.5
[[ "$(n "$SP")" == 1 && "$(n "$R")" == "$b" ]] && grep -q "^TAKE-DEFERRED $D2" "$T/o1" && grep -q "^TAKEN-ALREADY $D2 by c-003@box-a: the take line of post m-d3 already waits" "$T/o" &&
  pass "d. W2: two calls in the window: 1 deferred run, the second prints TAKEN-ALREADY" || fail "d. W2: spawns $(n "$SP"), lines $(( $(n "$R") - b )): $(cat "$T/o1" "$T/o")"
grep -qE '^sleep (2[89][0-9]|300)$' "$T/sleeps.log" && pass "d. W2: the deferred run sleeps first, then starts ./run" || fail "d. W2 sleep: $(cat "$T/sleeps.log")"
[[ "$(grep -c -- '--to c-009' "$T/sends.log")" == 1 ]] && pass "d. W2: TAKE_NOTIFY goes out once, at the deferral" || fail "d. W2 notify: $(cat "$T/sends.log")"
D3=00000000-0000-4000-8000-00000000d003
{ hrow HUM-10 ALL-0 m-d4 $((now - 301)) 'Status?'; hrow c-003 HUM-10 m-d5 $((now - 100)) "$TK3"; } >"$T/tail.ndjson"
b="$(n "$R")"
take DRY_RUN=0 DESK_TASK="$D3" TAKE_POST_CMD="$T/parse.sh"
take DRY_RUN=0 DESK_TASK="$D3" TAKE_POST_CMD="$T/parse.sh" TAKE_DEFER_DUE="$((now - 1))" TAKE_DEFER_POST=m-d4
[[ "$(n "$R")" == "$b" ]] && grep -q "^TAKEN-ALREADY $D3 by c-002@box-a: an ack line already follows post m-d4" "$T/o" &&
  pass "d. W4: another box's take line in the topic: TAKEN-ALREADY, 0 lines" || fail "d. W4: $(( $(n "$R") - b )) lines: $(cat "$T/o")"
D4=00000000-0000-4000-8000-00000000d004
{ hrow HUM-10 ALL-0 m-d6 $((now - 301)) 'Pick A'; hrow c-002 HUM-10 m-d7 $((now - 100)) '**In progress**: noted (answer A, 12:00Z).'; } >"$T/tail.ndjson"
b="$(n "$R")"
take DRY_RUN=0 DESK_TASK="$D4" TAKE_POST_CMD="$T/parse.sh" TAKE_DEFER_DUE="$((now - 1))" TAKE_DEFER_POST=m-d6
[[ "$(n "$R")" == "$b" ]] && grep -q "^TAKEN-ALREADY $D4" "$T/o" &&
  pass "d. W3: a noted line is an ack, not an answer: no second ack line" || fail "d. W3 take: $(( $(n "$R") - b )) lines: $(cat "$T/o")"

# --- the poll ack stubs (as spl-desk-poll-ack.tst.sh) -------------------------
TOPIC=11111111-2222-4333-8444-555555555555 POLL=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
TOPIC2=22222222-2222-4333-8444-555555555555 POLL2=bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee
POLLBODY=$'Pick one\n```poll\n? Which\n- A: one\n- B: two\n```'
rm -rf "$T/s" && mkdir -p "$T/s/spool/dispatch" "$T/s/state/desk/t1/boxa/spool/c-002/inbox" "$T/s/tails"
printf 'c-002@boxa %s\n' "$(( $(date +%s) - 5 ))" >"$T/s/spool/dispatch/lease"
printf 'LEASE_ORCH=c-001\nLEASE_MACHINE=boxa\nLEASE_ENV=prd\n' >"$T/s/spool/dispatch/lease.conf"
: >"$T/s/replies.log"
# vote <file-ts> <msg ts> <task> <poll> <msg id>: the owner's answer in the holder's inbox
vote() {
  python3 -c 'import json,sys; print(json.dumps({"body":"Poll: "+sys.argv[1]+"\nAnswer: A — one","files":[],"from":"HUM-10","kind":"note",
    "msg_id":sys.argv[2],"task_id":sys.argv[3],"to":"ALL-0","ts":sys.argv[4],"v":1}))' "$4" "$5" "$3" "$2" \
    >"$T/s/state/desk/t1/boxa/spool/c-002/inbox/$1--HUM-10--poll-x-${5:0:8}.json"
}
# tail_line <task> <from> <msg id> <ts> <body> [to]: one hub-tail line
tail_line() {
  python3 -c 'import json,sys; m={"from":sys.argv[1],"msg_id":sys.argv[2],"ts":sys.argv[3],"body":sys.argv[4]}
if sys.argv[5]: m["to"]=sys.argv[5]
print(json.dumps(m))' "$2" "$3" "$4" "$5" "${6:-}" >>"$T/s/tails/$1.ndjson"
}
# poll_ack <now> [VAR=VAL ...]: one cron tick at <now>, deferral 300 s
poll_ack() {
  local at="$1"; shift
  # shellcheck disable=SC2016 # the script is single-quoted on purpose
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPOOL_ROOT="$T/s/spool" SPL_STATE_DIR="$T/s/state" \
    POLL_ACK_NOW="$at" POLL_ACK_SEND="$T/send.sh" SEND_LOG="$T/s/sends.log" REPLY_LOG="$T/s/replies.log" TAILS="$T/s/tails" \
    SPL_SPOOL=/nonexistent/spool DESK_BOX=boxa DRY_RUN=0 ACK_DEFER_S=300 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    source "$0" || exit 97
    do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }
    spl_desk_spool() { local a p t; for a in "$@"; do [[ "${p:-}" == --task ]] && t="$a"; p="$a"; done; cat "$TAILS/$t.ndjson" 2>/dev/null; }
    do_spl_desk_reply() { echo "REPLY $DESK_TASK $DESK_BODY" >>"$REPLY_LOG"; }
    do_spl_desk_poll_ack' "$POLL_FUNC" >"$T/out" 2>&1
}
acks() { grep -c "REPLY $1 " "$T/s/replies.log"; }

# --- a. poll: an agent answers within the window -> 0 -------------------------
tail_line "$TOPIC" c-002 "$POLL" 2026-10-28T11:50:00Z "$POLLBODY"
vote 20261028T115900Z 2026-10-28T11:59:00Z "$TOPIC" "$POLL" 0a0a0000-0000-4000-8000-000000000001
poll_ack 2026-10-28T12:00:00Z
[[ "$(acks "$TOPIC")" == 0 ]] && pass "a. poll: a vote 1 min old is not acked yet" || fail "a. poll: acked at once: $(cat "$T/s/replies.log")"
tail_line "$TOPIC" c-002 0a0a0000-0000-4000-8000-0000000000a2 2026-10-28T12:01:30Z "Done: the result"
poll_ack 2026-10-28T12:04:00Z; poll_ack 2026-10-28T12:10:00Z
[[ "$(acks "$TOPIC")" == 0 ]] && pass "a. poll: the result came within 5 min: 0 ack posts" || fail "a. poll: $(acks "$TOPIC") acks"

# --- b. poll: no agent answer in the window -> exactly 1 ----------------------
tail_line "$TOPIC2" c-002 "$POLL2" 2026-10-28T11:50:00Z "$POLLBODY"
vote 20261028T115900Z 2026-10-28T11:59:00Z "$TOPIC2" "$POLL2" 0b0b0000-0000-4000-8000-000000000001
poll_ack 2026-10-28T12:03:59Z
[[ "$(acks "$TOPIC2")" == 0 ]] && pass "b. poll: 4:59 after the vote: no ack yet" || fail "b. poll: early ack: $(cat "$T/s/replies.log")"
poll_ack 2026-10-28T12:04:00Z; poll_ack 2026-10-28T12:05:00Z
[[ "$(acks "$TOPIC2")" == 1 ]] && pass "b. poll: 5:00 after the vote and nothing answered: exactly 1 ack" || fail "b. poll: $(acks "$TOPIC2") acks: $(tail -3 "$T/out")"

# --- d. poll side of W3 --------------------------------------------------------
TOPIC3=33333333-2222-4333-8444-555555555555 POLL3=cccccccc-bbbb-4ccc-8ddd-eeeeeeeeeeee
tail_line "$TOPIC3" c-002 "$POLL3" 2026-10-28T11:50:00Z "$POLLBODY"
tail_line "$TOPIC3" c-003 0c0c0000-0000-4000-8000-0000000000c2 2026-10-28T11:59:30Z 'Taken by c-003@boxb: I read your post now. I post the result here.' HUM-10
vote 20261028T115900Z 2026-10-28T11:59:00Z "$TOPIC3" "$POLL3" 0c0c0000-0000-4000-8000-000000000001
: >"$T/s/sends.log"
poll_ack 2026-10-28T12:04:00Z; poll_ack 2026-10-28T12:05:00Z
[[ "$(acks "$TOPIC3")" == 0 && "$(grep -c "dispatch-${TOPIC3:0:8}" "$T/s/sends.log")" == 1 ]] &&
  pass "d. W3: a take line after the vote: no noted line, the holder is woken once" || fail "d. W3 poll acked: $(acks "$TOPIC3") acks, $(cat "$T/s/sends.log"): $(tail -3 "$T/out")"
TOPIC4=44444444-2222-4333-8444-555555555555 POLL4=dddddddd-bbbb-4ccc-8ddd-eeeeeeeeeeee
tail_line "$TOPIC4" c-002 "$POLL4" 2026-10-28T11:50:00Z "$POLLBODY"
tail_line "$TOPIC4" c-002 0d0d0000-0000-4000-8000-0000000000d2 2026-10-28T11:59:30Z 'a relay' c-001
vote 20261028T115900Z 2026-10-28T11:59:00Z "$TOPIC4" "$POLL4" 0d0d0000-0000-4000-8000-000000000001
poll_ack 2026-10-28T12:04:00Z
[[ "$(acks "$TOPIC4")" == 1 ]] && pass "d. W3: a relay to another agent answers nothing: 1 noted line" || fail "d. W3 relay: $(acks "$TOPIC4") acks: $(tail -3 "$T/out")"

echo
(( fails == 0 )) && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
