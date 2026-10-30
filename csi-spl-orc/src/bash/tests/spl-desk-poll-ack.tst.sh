#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_desk_poll_ack (spec 157 Rule 5, row B3, SPL-4093) answers an
#          owner's poll vote at once with **In progress**: noted, and only
#          that vote. A sandbox: its own SPOOL_ROOT (lease + lease.conf), its
#          own desk state dir; the hub-tail read, do_spl_desk_reply and the
#          wake sender are stubs that log what they were asked. No network,
#          no hub, no live spool.
#     1. RED CONTROL a non-owner (c-168) vote in the poll format -> rc 0,
#        0 replies, 0 wakes, no log line
#     2. GREEN the owner's (HUM-10) vote -> one reply by the holder into the
#        topic, to HUM-10, body **In progress**: noted (answer A, <time>);
#        one wake to the holder on dispatch-<topic8>; one automation.log line
#     3. RED CONTROL the same vote again (next cron tick) -> no second reply
#     4. RED CONTROL an agent already posted after the vote -> 0 replies
#     5. the topic has no such poll from an agent -> 0 replies
#     6. the lease held on another machine, stale, or none -> 0 replies
#     7. the dry run prints PLAN, sends nothing, logs nothing
#     8. a vote older than POLL_ACK_MAX_AGE, or not the answer format -> 0
#     9. a reply the desk refuses (rc 7) is logged refused, no wake, never
#        retried; a failure (rc 1) is retried on the next run
#    10. a multi-question answer; two votes in one topic -> one reply
#    11. a test workspace (e2e) is never read
#    12. the install cron: dry run, one exact line, idempotent, check, remove
#    13. RED CONTROL (SPL-4305) a poll another agent posted -> 0 replies; a
#        poll by the holder's role seat under another vendor letter -> 1
#    14. RED CONTROL (SPL-4305) a sole-seat channel (channel-rules.tsv
#        column 6) whose seat is not the holder -> 0 replies, the holder's
#        own poll included; an ordinary channel with the map -> 1; the
#        holder as the sole seat -> 1; fail closed: a malformed column 6, or
#        a spool binary without --with-channel while the map exists -> 0
#   POLL_ACK_FUNC points the test at another copy of the action: the red
#   controls run it against a mutant (see the commit that added this file).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
FUNC="${POLL_ACK_FUNC:-$PROJ_ROOT/src/bash/run/spl-desk-poll-ack.func.sh}"

NOW=2026-10-28T12:00:00Z
TOPIC=11111111-2222-4333-8444-555555555555
POLL=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
TOPIC2=22222222-2222-4333-8444-555555555555
POLL2=bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee

# the wake sender stub logs its args
# shellcheck disable=SC2016 # the stub expands its own args at run time
printf '#!/bin/sh\necho "WAKE $*" >>"$WAKE_LOG"\n' >"$T/send.sh"

# reset <holder> [age-seconds]: a fresh sandbox; lease held by <holder>
reset() {
  rm -rf "$T/s" && mkdir -p "$T/s/spool/dispatch" "$T/s/state/desk/t1/boxa/spool/c-002/inbox" \
    "$T/s/state/desk/t1/boxa/spool/c-002/archive" "$T/s/tails"
  printf '%s %s\n' "$1" "$(( $(date +%s) - ${2:-5} ))" >"$T/s/spool/dispatch/lease"
  printf 'LEASE_ORCH=c-001\nLEASE_MACHINE=boxa\nLEASE_ENV=prd\n' >"$T/s/spool/dispatch/lease.conf"
  : >"$T/s/replies.log"; : >"$T/s/wakes.log"
}
# vote <tenant> <file-ts> <msg ts> <from> <task> <body> <msg id>: one inbox message
vote() {
  local d="$T/s/state/desk/$1/boxa/spool/c-002/inbox"; mkdir -p "$d"
  python3 -c 'import json,sys; print(json.dumps({"body":sys.argv[1],"files":[],"from":sys.argv[2],"kind":"note",
    "msg_id":sys.argv[3],"task_id":sys.argv[4],"to":"ALL-0","ts":sys.argv[5],"v":1}))' \
    "$6" "$4" "$7" "$5" "$3" >"$d/$2--$4--poll-x-${7:0:8}.json"
}
# tail_line <task> <from> <msg id> <ts> <body>: one hub-tail NDJSON line of <task>
tail_line() {
  python3 -c 'import json,sys; print(json.dumps({"from":sys.argv[1],"msg_id":sys.argv[2],"ts":sys.argv[3],"body":sys.argv[4]}))' \
    "$2" "$3" "$4" "$5" >>"$T/s/tails/$1.ndjson"
}
# tail_ch <task> <channel> <from> <msg id> <ts> <body>: a hub-tail --with-channel line
tail_ch() {
  python3 -c 'import json,sys; print(json.dumps({"channel":sys.argv[1],"from":sys.argv[2],"msg_id":sys.argv[3],"ts":sys.argv[4],"body":sys.argv[5]}))' \
    "$2" "$3" "$4" "$5" "$6" >>"$T/s/tails/$1.ndjson"
}
POLLBODY=$'Pick one\n```poll\n? Which\n- A: one\n- B: two\n```'
# run [VAR=value]...: the action in a fresh bash; stdout+stderr in $T/out, rc returned
run() {
  # shellcheck disable=SC2016 # the script is single-quoted on purpose
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPOOL_ROOT="$T/s/spool" SPL_STATE_DIR="$T/s/state" \
    POLL_ACK_NOW="$NOW" POLL_ACK_SEND="$T/send.sh" WAKE_LOG="$T/s/wakes.log" REPLY_LOG="$T/s/replies.log" \
    TAILS="$T/s/tails" SPL_SPOOL=/nonexistent/spool DESK_BOX=boxa DRY_RUN=0 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    source "$0" || { echo "FATAL cannot source $0"; exit 97; }
    do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }
    spl_desk_spool() {
      local a; for a in "$@"; do [[ "${p:-}" == --task ]] && t="$a"; p="$a"
        [[ "$a" == --with-channel && "${OLD_SPOOL:-}" == 1 ]] && { echo "flag provided but not defined: -with-channel" >&2; return 2; }
      done; cat "$TAILS/$t.ndjson" 2>/dev/null; }
    do_spl_desk_reply() { echo "REPLY $TENANT_ID $DESK_AGENT $DESK_TASK $DESK_TO $DESK_KIND $DESK_BODY" >>"$REPLY_LOG"; return "${REPLY_RC:-0}"; }
    do_spl_desk_poll_ack' "$FUNC" >"$T/out" 2>&1
}
count() { local n; n=$(grep -c "${2:-.}" "$1" 2>/dev/null); echo "${n:-0}"; }
LOG="$T/s/spool/dispatch/automation.log"
# a topic with the poll from an agent and nothing after the vote
topic_ok() { tail_line "$1" c-002 "$2" 2026-10-28T11:50:00Z "$POLLBODY"; tail_line "$1" HUM-10 m0 2026-10-28T11:55:00Z "a question"; }

# --- 1. RED CONTROL: a non-owner vote ---------------------------------------------
reset c-002@boxa
topic_ok "$TOPIC" "$POLL"
vote t1 20261028T115800Z 2026-10-28T11:58:00Z c-168 "$TOPIC" $'Poll: '"$POLL"$'\nAnswer: A — one' 0168a000-0000-4000-8000-000000000001
run; rc=$?
if (( rc == 0 )) && [[ $(count "$T/s/replies.log") == 0 && $(count "$T/s/wakes.log") == 0 && ! -s "$LOG" ]]; then
  pass "1. RED CONTROL: a non-owner (c-168) vote is ignored: rc 0, 0 replies, 0 wakes, no log line"
else fail "1. rc=$rc replies=$(cat "$T/s/replies.log") wakes=$(cat "$T/s/wakes.log") out=$(tail -3 "$T/out")"; fi

# --- 2. GREEN: the owner's vote -----------------------------------------------------
vote t1 20261028T115900Z 2026-10-28T11:59:00Z HUM-10 "$TOPIC" $'Poll: '"$POLL"$'\nAnswer: A — one' 01010000-0000-4000-8000-000000000002
run; rc=$?
want="REPLY t1 c-002 $TOPIC HUM-10 note **In progress**: noted (answer A, {{NOW_UTC}})."
if (( rc == 0 )) && [[ $(count "$T/s/replies.log") == 1 ]] && grep -qxF "$want" "$T/s/replies.log"; then
  pass "2. GREEN: the owner's vote gets one reply by the holder, in the topic, to HUM-10: **In progress**: noted (answer A, {{NOW_UTC}})"
else fail "2. rc=$rc replies=$(cat "$T/s/replies.log") out=$(tail -5 "$T/out")"; fi
if [[ $(count "$T/s/wakes.log") == 1 ]] && grep -q -- "--from c-001 --to c-002 --kind note --task dispatch-${TOPIC:0:8} --body HUM-10 answered poll $POLL with A" "$T/s/wakes.log"; then
  pass "2. the holder is woken once, on dispatch-<topic8>, never the owner topic id"
else fail "2. wakes=$(cat "$T/s/wakes.log")"; fi
if [[ $(count "$LOG") == 1 ]] && grep -qE "^20[0-9-]+T[0-9:]+Z poll-ack 01010000-0000-4000-8000-000000000002 action=sent actor=c-002@boxa tenant=t1 topic=$TOPIC poll=$POLL from=HUM-10 keys=A reply_rc=0 wake_rc=0$" "$LOG"; then
  pass "2. one automation.log line: time, msg, action, actor, topic, poll, keys, exit codes"
else fail "2. log=$(cat "$LOG" 2>/dev/null)"; fi

# --- 3. RED CONTROL: the same vote on the next tick ---------------------------------
run; rc=$?
if (( rc == 0 )) && [[ $(count "$T/s/replies.log") == 1 && $(count "$T/s/wakes.log") == 1 && $(count "$LOG") == 1 ]]; then
  pass "3. RED CONTROL: a duplicate vote (seen again next tick) is ignored: still 1 reply, 1 wake"
else fail "3. rc=$rc replies=$(count "$T/s/replies.log") wakes=$(count "$T/s/wakes.log")"; fi

# --- 4. RED CONTROL: an agent already answered ---------------------------------------
reset c-002@boxa
topic_ok "$TOPIC" "$POLL"
tail_line "$TOPIC" g-002 ag000000 2026-10-28T11:59:30Z "on it"
vote t1 20261028T115900Z 2026-10-28T11:59:00Z HUM-10 "$TOPIC" $'Poll: '"$POLL"$'\nAnswer: B' 04040000-0000-4000-8000-000000000004
run; rc=$?
if (( rc == 0 )) && [[ $(count "$T/s/replies.log") == 0 && $(count "$T/s/wakes.log") == 0 ]] && grep -q 'already posted in topic' "$T/out"; then
  pass "4. RED CONTROL: a topic an agent already answered after the vote gets no reply"
else fail "4. rc=$rc replies=$(cat "$T/s/replies.log") out=$(tail -3 "$T/out")"; fi

# --- 5. no active poll ---------------------------------------------------------------
reset c-002@boxa
tail_line "$TOPIC" HUM-10 m0 2026-10-28T11:50:00Z "$POLLBODY"
vote t1 20261028T115900Z 2026-10-28T11:59:00Z HUM-10 "$TOPIC" $'Poll: '"$POLL"$'\nAnswer: A' 05050000-0000-4000-8000-000000000005
run; rc=$?
if (( rc == 0 )) && [[ $(count "$T/s/replies.log") == 0 ]] && grep -q "holds no poll $POLL from an agent" "$T/out"; then
  pass "5. a topic with no such poll from an agent (here: posted by a person) gets no reply"
else fail "5. rc=$rc out=$(tail -3 "$T/out")"; fi
rm -f "$T/s/tails/$TOPIC.ndjson"
run; rc=$?
if (( rc == 0 )) && [[ $(count "$T/s/replies.log") == 0 ]] && grep -q 'cannot be read' "$T/out"; then
  pass "5. a topic the desk cannot read (closed or unknown) gets no reply"
else fail "5. unreadable rc=$rc out=$(tail -3 "$T/out")"; fi

# --- 6. the lease ---------------------------------------------------------------------
for lease in "c-002@sat 5" "c-002@boxa 999" "none 0"; do
  # shellcheck disable=SC2086 # holder and age, split on purpose
  reset $lease
  topic_ok "$TOPIC" "$POLL"
  vote t1 20261028T115900Z 2026-10-28T11:59:00Z HUM-10 "$TOPIC" $'Poll: '"$POLL"$'\nAnswer: A' 06060000-0000-4000-8000-000000000006
  [[ "$lease" == none* ]] && rm -f "$T/s/spool/dispatch/lease"
  run; rc=$?
  if (( rc == 0 )) && [[ $(count "$T/s/replies.log") == 0 ]] && grep -qE 'another machine|no live dispatch lease holder' "$T/out"; then
    pass "6. lease '$lease': nothing acknowledged on this machine"
  else fail "6. lease '$lease' rc=$rc out=$(tail -3 "$T/out")"; fi
done
reset c-002@boxa
topic_ok "$TOPIC" "$POLL"
vote t1 20261028T115900Z 2026-10-28T11:59:00Z HUM-10 "$TOPIC" $'Poll: '"$POLL"$'\nAnswer: A' 06060000-0000-4000-8000-000000000006
cp -p "$T/s/spool/dispatch/lease" "$T/lease.before"
run; cmp -s "$T/lease.before" "$T/s/spool/dispatch/lease" && [[ ! -e "$T/s/spool/dispatch/lease.log" ]] &&
  pass "6. the lease is read, never written" || fail "6. the lease changed"

# --- 7. dry run -------------------------------------------------------------------------
reset c-002@boxa
topic_ok "$TOPIC" "$POLL"
vote t1 20261028T115900Z 2026-10-28T11:59:00Z HUM-10 "$TOPIC" $'Poll: '"$POLL"$'\nAnswer: A' 07070000-0000-4000-8000-000000000007
run DRY_RUN=1; rc=$?
if (( rc == 0 )) && grep -q "^PLAN t1 topic $TOPIC: c-002 answers HUM-10's vote" "$T/out" && [[ $(count "$T/s/replies.log") == 0 && $(count "$T/s/wakes.log") == 0 && ! -e "$LOG" ]]; then
  pass "7. the dry run prints PLAN and sends, wakes and logs nothing"
else fail "7. rc=$rc out=$(tail -3 "$T/out")"; fi

# --- 8. the window and the format ---------------------------------------------------------
reset c-002@boxa
tail_line "$TOPIC" c-002 "$POLL" 2026-10-28T09:50:00Z "$POLLBODY"
vote t1 20261028T100000Z 2026-10-28T10:00:00Z HUM-10 "$TOPIC" $'Poll: '"$POLL"$'\nAnswer: A' 08080000-0000-4000-8000-000000000008
vote t1 20261028T115900Z 2026-10-28T11:59:00Z HUM-10 "$TOPIC" $'I vote A on poll '"$POLL" 08080000-0000-4000-8000-000000000009
vote t1 20261028T115900Z 2026-10-28T11:59:00Z HUM-10 "$TOPIC" $'Poll: '"$POLL"$'\nno answer line' 08080000-0000-4000-8000-00000000000a
run; rc=$?
if (( rc == 0 )) && [[ $(count "$T/s/replies.log") == 0 ]]; then
  pass "8. a vote older than the window, free text, and a Poll line with no Answer line are ignored"
else fail "8. rc=$rc replies=$(cat "$T/s/replies.log")"; fi
run POLL_ACK_MAX_AGE=180; rc=$?
if (( rc == 0 )) && [[ $(count "$T/s/replies.log") == 1 ]]; then
  pass "8. control: a wider window acknowledges the older vote"
else fail "8. control rc=$rc replies=$(cat "$T/s/replies.log")"; fi
run POLL_ACK_MAX_AGE=x; rc=$?
(( rc == 1 )) && grep -q 'FATAL POLL_ACK_MAX_AGE' "$T/out" && pass "8. a bad POLL_ACK_MAX_AGE is refused" || fail "8. bad max rc=$rc"

# --- 9. refused and failed replies ------------------------------------------------------------
reset c-002@boxa
topic_ok "$TOPIC" "$POLL"
vote t1 20261028T115900Z 2026-10-28T11:59:00Z HUM-10 "$TOPIC" $'Poll: '"$POLL"$'\nAnswer: A' 09090000-0000-4000-8000-000000000009
run REPLY_RC=7; run REPLY_RC=7; rc=$?
if (( rc == 0 )) && [[ $(count "$T/s/replies.log") == 1 && $(count "$T/s/wakes.log") == 0 ]] && grep -q 'action=refused .* reply_rc=7 wake_rc=0$' "$LOG"; then
  pass "9. a reply the desk refuses (rc 7) is logged refused, nobody woken, not tried again"
else fail "9. rc=$rc replies=$(count "$T/s/replies.log") log=$(cat "$LOG" 2>/dev/null)"; fi
reset c-002@boxa
topic_ok "$TOPIC" "$POLL"
vote t1 20261028T115900Z 2026-10-28T11:59:00Z HUM-10 "$TOPIC" $'Poll: '"$POLL"$'\nAnswer: A' 09090000-0000-4000-8000-00000000000b
run REPLY_RC=1; run; rc=$?
if (( rc == 0 )) && [[ $(count "$T/s/replies.log") == 2 && $(count "$T/s/wakes.log") == 1 && $(count "$LOG") == 1 ]]; then
  pass "9. a failed reply (rc 1) is retried on the next run, then logged once"
else fail "9. retry replies=$(count "$T/s/replies.log") wakes=$(count "$T/s/wakes.log") log=$(cat "$LOG" 2>/dev/null)"; fi

# --- 10. multi-question; two votes in one topic -------------------------------------------------
reset c-002@boxa
topic_ok "$TOPIC" "$POLL"
topic_ok "$TOPIC2" "$POLL2"
vote t1 20261028T115800Z 2026-10-28T11:58:00Z HUM-10 "$TOPIC" $'Poll: '"$POLL"$'\nAnswer 1: A — one\nAnswer 2: B,C — two; three' 10100000-0000-4000-8000-000000000001
vote t1 20261028T115900Z 2026-10-28T11:59:00Z HUM-10 "$TOPIC" $'Poll: '"$POLL"$'\nAnswer 1: B\nAnswer 2: C' 10100000-0000-4000-8000-000000000002
vote t1 20261028T115900Z 2026-10-28T11:59:00Z HUM-10 "$TOPIC2" $'Poll: '"$POLL2"$'\nAnswer: B' 10100000-0000-4000-8000-000000000003
run; rc=$?
if (( rc == 0 )) && [[ $(count "$T/s/replies.log") == 2 && $(count "$T/s/replies.log" "$TOPIC ") == 1 ]] &&
  grep -qF "noted (answer A, B,C, {{NOW_UTC}})." "$T/s/replies.log" && grep -qF "$TOPIC2 HUM-10 note **In progress**: noted (answer B," "$T/s/replies.log"; then
  pass "10. a multi-question answer names every key; two votes in one topic get one reply; another topic its own"
else fail "10. rc=$rc replies=$(cat "$T/s/replies.log")"; fi

# --- 11. a test workspace ------------------------------------------------------------------------
reset c-002@boxa
topic_ok "$TOPIC" "$POLL"
vote e2e 20261028T115900Z 2026-10-28T11:59:00Z HUM-10 "$TOPIC" $'Poll: '"$POLL"$'\nAnswer: A' 11110000-0000-4000-8000-000000000001
rm -rf "$T/s/state/desk/t1"
run; rc=$?
(( rc == 0 )) && [[ $(count "$T/s/replies.log") == 0 ]] && grep -q '0 workspace(s) read' "$T/out" &&
  pass "11. the e2e test workspace is never read" || fail "11. rc=$rc out=$(tail -2 "$T/out")"

# --- 13. whose poll it is (SPL-4305) ----------------------------------------------------------------
reset c-002@boxa
tail_line "$TOPIC" c-423 "$POLL" 2026-10-28T11:50:00Z "$POLLBODY"
vote t1 20261028T115900Z 2026-10-28T11:59:00Z HUM-10 "$TOPIC" $'Poll: '"$POLL"$'\nAnswer: A' 13130000-0000-4000-8000-000000000001
run; rc=$?
if (( rc == 0 )) && [[ $(count "$T/s/replies.log") == 0 && $(count "$T/s/wakes.log") == 0 && ! -s "$LOG" ]] && grep -q "posted by c-423, not by c-002" "$T/out"; then
  pass "13. RED CONTROL: a poll another agent (c-423) posted gets no ack from the holder"
else fail "13. rc=$rc replies=$(cat "$T/s/replies.log") out=$(tail -3 "$T/out")"; fi
reset c-002@boxa
tail_line "$TOPIC" g-002 "$POLL" 2026-10-28T11:50:00Z "$POLLBODY"
vote t1 20261028T115900Z 2026-10-28T11:59:00Z HUM-10 "$TOPIC" $'Poll: '"$POLL"$'\nAnswer: A' 13130000-0000-4000-8000-000000000002
run; rc=$?
(( rc == 0 )) && [[ $(count "$T/s/replies.log") == 1 ]] &&
  pass "13. a poll by the holder's role seat under another vendor letter (g-002 for c-002) is acknowledged" ||
  fail "13. role seat rc=$rc out=$(tail -3 "$T/out")"

# --- 14. a sole-seat channel (SPL-4305) ---------------------------------------------------------------
MAP="$T/s/spool/channel-rules.tsv"
DOC=cccccccc-dddd-4eee-8fff-000000000000
# ack14 <case> <want replies> <poller> <channel> <map column 6> [VAR=value]...
ack14() {
  local c="$1" want="$2" poller="$3" ch="$4" sole="$5"; shift 5
  reset c-002@boxa
  printf 't1\tsole\t%s\tprd\tc-423\t%s\nt1\tgeneral\t%s\tprd\tc-423\n' "$DOC" "$sole" "$DOC" >"$MAP"
  tail_ch "$TOPIC" "$ch" "$poller" "$POLL" 2026-10-28T11:50:00Z "$POLLBODY"
  tail_ch "$TOPIC" "$ch" HUM-10 m0 2026-10-28T11:55:00Z "a question"
  vote t1 20261028T115900Z 2026-10-28T11:59:00Z HUM-10 "$TOPIC" $'Poll: '"$POLL"$'\nAnswer: A' "14140000-0000-4000-8000-00000000000$c"
  run "$@"; rc=$?
  if (( rc == 0 )) && [[ $(count "$T/s/replies.log") == "$want" ]]; then return 0; fi
  echo "rc=$rc replies=$(cat "$T/s/replies.log") out=$(tail -3 "$T/out")"; return 1
}
ack14 1 0 c-002 sole c-423@boxb && grep -q '#sole is a sole-seat channel: only c-423@boxb posts there' "$T/out" &&
  pass "14. RED CONTROL: the holder's own poll in a sole-seat channel of another seat gets no ack" || fail "14. sole holder poll"
ack14 2 0 c-423 sole c-423@boxb && pass "14. RED CONTROL: the 2026-10-30 shape, the sole seat's poll in its channel: no ack" || fail "14. sole seat poll"
ack14 3 1 c-002 general c-423@boxb && pass "14. an ordinary channel (no column 6) with the map present: the holder's poll is acknowledged" || fail "14. ordinary channel"
ack14 4 1 c-002 sole c-002@boxa && pass "14. the holder as the channel's sole seat: acknowledged" || fail "14. holder is sole seat"
ack14 5 0 c-002 sole c-423 && grep -q 'cannot tell the sole seat of #sole' "$T/out" &&
  pass "14. fail closed: a column 6 that is not <id>@<box> acks nothing" || fail "14. malformed column 6"
ack14 6 0 c-002 general c-423@boxb OLD_SPOOL=1 && grep -q "cannot say the topic's channel" "$T/out" &&
  pass "14. fail closed: a spool binary without --with-channel while the map exists acks nothing" || fail "14. old binary with map"
reset c-002@boxa; topic_ok "$TOPIC" "$POLL"
vote t1 20261028T115900Z 2026-10-28T11:59:00Z HUM-10 "$TOPIC" $'Poll: '"$POLL"$'\nAnswer: A' 14140000-0000-4000-8000-000000000008
run OLD_SPOOL=1; rc=$?
(( rc == 0 )) && [[ $(count "$T/s/replies.log") == 1 ]] &&
  pass "14. no map: an old spool binary (plain --json) still acknowledges" || fail "14. old binary no map rc=$rc out=$(tail -3 "$T/out")"

# --- 12. the install cron -------------------------------------------------------------------------
mkdir -p "$T/bin"
cat >"$T/bin/crontab" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi
cp "$1" "$FAKE_CRONTAB"
EOF
chmod +x "$T/bin/crontab"
SRC="$T/shared"; mkdir -p "$SRC/csi-spl-orc"; printf '#!/bin/sh\n' >"$SRC/csi-spl-orc/run"; chmod +x "$SRC/csi-spl-orc/run"
printf '*/3 * * * * other job # csi-spl:desk-reconcile\n* * * * * x # csi-spl:poll-ack-not-this\n' >"$T/crontab"
cron() {
  # shellcheck disable=SC2016 # the script is single-quoted on purpose
  env PATH="$T/bin:$PATH" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" FAKE_CRONTAB="$T/crontab" DESK_CRON_SRC="$SRC" \
    POLL_ACK_CRON_LOG_DIR="$T/log" "$@" bash -c '
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_desk_poll_ack_install_cron' >"$T/o" 2>&1
}
before="$(md5sum <"$T/crontab")"
cron; rc=$?
[[ $rc -eq 0 && "$(md5sum <"$T/crontab")" == "$before" ]] && grep -q 'do_spl_desk_poll_ack >> .*/cron.out 2>&1 # csi-spl:poll-ack$' "$T/o" &&
  pass "12. dry run: the diff, nothing written" || fail "12. dry rc=$rc $(cat "$T/o")"
cron POLL_ACK_CRON_ACTION=check && fail "12. check passed with no line" || pass "12. check fails while not installed"
cron DRY_RUN=0; rc=$?
# shellcheck disable=SC2016 # $HOME stays literal in the line
want="* * * * * cd $SRC/csi-spl-orc && PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$HOME/.local/bin flock -n $T/log/poll-ack.cron.lock env DRY_RUN=0 ./run -a do_spl_desk_poll_ack >> $T/log/cron.out 2>&1 # csi-spl:poll-ack"
[[ $rc -eq 0 ]] && grep -qxF "$want" "$T/crontab" && grep -q 'desk-reconcile$' "$T/crontab" && grep -q 'poll-ack-not-this$' "$T/crontab" &&
  pass "12. DRY_RUN=0: one exact every-minute line, the other lines kept" || fail "12. install rc=$rc: $(cat "$T/crontab") $(cat "$T/o")"
cp "$T/crontab" "$T/ct.1"; cron DRY_RUN=0
cmp -s "$T/crontab" "$T/ct.1" && [[ $(grep -c '# csi-spl:poll-ack$' "$T/crontab") == 1 ]] && pass "12. a second install changes nothing" || fail "12. idempotent: $(cat "$T/crontab")"
cron POLL_ACK_CRON_ACTION=check && grep -q 'OK the poll acknowledgement is installed' "$T/o" && pass "12. check passes once installed" || fail "12. check: $(cat "$T/o")"
cron DRY_RUN=0 POLL_ACK_CRON_ACTION=remove
! grep -q '# csi-spl:poll-ack$' "$T/crontab" && grep -q 'desk-reconcile$' "$T/crontab" && grep -q 'poll-ack-not-this$' "$T/crontab" &&
  pass "12. remove takes only its line" || fail "12. remove: $(cat "$T/crontab")"
cron POLL_ACK_CRON_ACTION=bogus; rc=$?
(( rc == 1 )) && grep -q 'FATAL POLL_ACK_CRON_ACTION' "$T/o" && pass "12. a bad action is refused" || fail "12. bad action rc=$rc"

echo "spl-desk-poll-ack: ${fails} failure(s)"
[ "$fails" -eq 0 ]
