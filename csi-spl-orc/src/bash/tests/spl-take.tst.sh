#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_take (SPEC-spool-fleet-roles.md 3, t1 bc1a43e1 fix C) over a
#          scratch spool root, a fake do_spl_desk_reply (TAKE_REPLY_CMD) and a
#          fake spool-send (TAKE_SEND). No hub, no spool binary is touched.
#   1. DRY_RUN (default) posts nothing and records nothing
#   2. DRY_RUN=0: exactly ONE take line to the human, in the topic, kind note,
#      with the taker's id@box and the plan; ledger has one row; the agents in
#      TAKE_NOTIFY get one note each, on the topic's task
#   3. idempotent: a second take of the same (topic, taker) posts nothing and
#      sends nothing (count stays 1); another taker or another topic posts
#   4. a failed post is not recorded and sends no note; a re-run posts it
#   5. a failed note is a WARN: the take still succeeds
#   6. refusals: bad ENV, DESK_TO not a human, a topic prefix, empty plan,
#      SPOOL_TEST=1 without TAKE_REPLY_CMD
#   7. wiring: the dispatcher brief teaches the take command and it matches
#      a dispatcher allow rule
#   8. one take per human POST (SPL-5141, TAKE_POST_CMD): an old take and a new
#      post -> a new line, keyed on the post; the same post again -> none; an
#      id-less row covers only a post older than it; an unread or answered
#      topic keeps one line per (topic, taker)
#   9. spl_take_post_parse: the newest human post no agent has answered
#  10. held channels (SPL-6068, take-line-by-code.md 3.2): a topic in a channel
#      the box map holds from automatic posts (column 7 no-auto-post, its own
#      row or the workspace's * row) gets NO take line, immediate, deferred or
#      the deferred run; TAKE-HELD names the channel and the map; TAKE_NOTIFY
#      notes still go out; a map that cannot tell holds too. Controls that still
#      post: a channel with no holding row, another workspace's * row, a DM
#   control: with the ledger check removed (a planted copy), the second take
#      posts again -> the idempotency assertion would turn red
#   control: with the post key dropped (a planted copy), case 8 stays silent
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

S="$T/spool"; mkdir -p "$S/dispatch"
TOPIC=00000000-0000-4000-8000-0000000000a1
TOPIC2=00000000-0000-4000-8000-0000000000a2
# the fake desk reply: one line per post; fails while $REPLY_LOG.fail exists
cat >"$T/reply.sh" <<'EOF'
#!/usr/bin/env bash
[ -e "$REPLY_LOG.fail" ] && exit 9
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ENV" "$TENANT_ID" "$DESK_AGENT" "$DESK_TO" "$DESK_TASK" "$DESK_KIND" "$DESK_BODY" >>"$REPLY_LOG"
EOF
cat >"$T/send.sh" <<'EOF'
#!/usr/bin/env bash
[ -e "$SEND_LOG.fail" ] && exit 11
echo "$*" >>"$SEND_LOG"
EOF
# the fake topic read: prints $POST_FILE; fails while that file is missing
cat >"$T/post.sh" <<'EOF'
#!/usr/bin/env bash
[ -e "$POST_FILE" ] || exit 9
echo "a log line the run prints first"
cat "$POST_FILE"
EOF
chmod +x "$T/reply.sh" "$T/send.sh" "$T/post.sh"
export REPLY_LOG="$T/reply.log" SEND_LOG="$T/send.log"

# take [VAR=VAL ...]: run do_spl_take in a clean shell with the stubs
take() {
  env -i PATH="$PATH" HOME="$HOME" PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_TEST=1 \
    REPLY_LOG="$REPLY_LOG" SEND_LOG="$SEND_LOG" TAKE_REPLY_CMD="$T/reply.sh" TAKE_SEND="$T/send.sh" \
    ENV=prd TENANT_ID=csitea DESK_AGENT=c-002 DESK_TO=HUM-10 DESK_TASK="$TOPIC" TAKE_BOX=box-a \
    TAKE_PLAN='I read the hub logs and post the cause' "$@" bash -c '
    do_log() { echo "$*" >&2; }
    source "$PROJ_PATH/lib/bash/funcs/spl-desk-box.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    source "${TAKE_FUNC:-$PROJ_PATH/src/bash/run/spl-take.func.sh}"
    do_spl_take'
}
n() { [[ -f "$1" ]] && wc -l <"$1" | tr -d ' ' || echo 0; }

# 1. dry run
take >"$T/o" 2>&1 || fail "1. dry run exited non-zero: $(cat "$T/o")"
[[ "$(n "$REPLY_LOG")" == 0 && ! -f "$S/dispatch/take.log" ]] && pass "1. dry run posts and records nothing" || fail "1. dry run wrote"

# 2. the take
take DRY_RUN=0 TAKE_NOTIFY='c-001 c-003' >"$T/o" 2>&1 || fail "2. take failed: $(cat "$T/o")"
[[ "$(n "$REPLY_LOG")" == 1 ]] && pass "2. exactly one take line posted" || fail "2. posts: $(n "$REPLY_LOG")"
IFS=$'\t' read -r e tn ag to tk kd bd <"$REPLY_LOG"
[[ "$e $tn $ag $to $tk $kd" == "prd csitea c-002 HUM-10 $TOPIC note" ]] && pass "2. to the human, in the topic, kind note" ||
  fail "2. wrong route: $e $tn $ag $to $tk $kd"
[[ "$bd" == "Taken by c-002@box-a: I read the hub logs and post the cause. I post the result here." ]] &&
  pass "2. the body names the taker and the plan" || fail "2. body: $bd"
[[ "$(n "$S/dispatch/take.log")" == 1 ]] && pass "2. one ledger row" || fail "2. ledger rows: $(n "$S/dispatch/take.log")"
[[ "$(n "$SEND_LOG")" == 2 ]] && grep -q -- "--to c-001 --kind note --task $TOPIC" "$SEND_LOG" &&
  grep -q -- "--to c-003 " "$SEND_LOG" && pass "2. one note per TAKE_NOTIFY id on the topic" || fail "2. notes: $(cat "$SEND_LOG" 2>/dev/null)"
grep -q "^TAKEN $TOPIC by c-002@box-a" "$T/o" && pass "2. prints TAKEN" || fail "2. output: $(cat "$T/o")"

# 3. idempotent
take DRY_RUN=0 TAKE_NOTIFY='c-001' >"$T/o" 2>&1 || fail "3. second take exited non-zero"
[[ "$(n "$REPLY_LOG")" == 1 && "$(n "$SEND_LOG")" == 2 ]] && grep -q TAKEN-ALREADY "$T/o" &&
  pass "3. a second take of the same topic+taker posts and sends nothing" || fail "3. posts $(n "$REPLY_LOG"), notes $(n "$SEND_LOG")"
take DRY_RUN=0 DESK_TASK="${TOPIC^^}" >"$T/o" 2>&1
[[ "$(n "$REPLY_LOG")" == 1 ]] && pass "3. the uppercase uuid is the same topic" || fail "3. uppercase posted again"
take DRY_RUN=0 DESK_AGENT=c-001 TAKE_BOX=box-b >"$T/o" 2>&1
take DRY_RUN=0 DESK_TASK="$TOPIC2" >>"$T/o" 2>&1
[[ "$(n "$REPLY_LOG")" == 3 && "$(n "$S/dispatch/take.log")" == 3 ]] && pass "3. another taker / another topic each post once" ||
  fail "3. posts $(n "$REPLY_LOG")"

# 4. a failed post
: >"$REPLY_LOG.fail"
take DRY_RUN=0 DESK_TASK=00000000-0000-4000-8000-0000000000a3 TAKE_NOTIFY=c-001 >"$T/o" 2>&1 && fail "4. a failed post exited 0" || pass "4. a failed post fails"
[[ "$(n "$S/dispatch/take.log")" == 3 && "$(n "$SEND_LOG")" == 2 ]] && pass "4. nothing recorded, no note" || fail "4. recorded or noted"
rm -f "$REPLY_LOG.fail"
take DRY_RUN=0 DESK_TASK=00000000-0000-4000-8000-0000000000a3 >"$T/o" 2>&1
[[ "$(n "$REPLY_LOG")" == 4 ]] && pass "4. the re-run posts it" || fail "4. re-run posts $(n "$REPLY_LOG")"

# 5. a failed note
: >"$SEND_LOG.fail"
take DRY_RUN=0 DESK_TASK=00000000-0000-4000-8000-0000000000a4 TAKE_NOTIFY=c-001 >"$T/o" 2>&1 &&
  grep -q "WARN could not tell c-001" "$T/o" && pass "5. a failed note is a WARN" || fail "5. $(cat "$T/o")"
rm -f "$SEND_LOG.fail"

# 6. refusals
before="$(n "$REPLY_LOG")"
take DRY_RUN=0 ENV=stage >/dev/null 2>&1 && fail "6. ENV=stage accepted" || pass "6. bad ENV refused"
take DRY_RUN=0 DESK_TO=c-001 DESK_TASK=00000000-0000-4000-8000-0000000000b1 >/dev/null 2>&1 && fail "6. agent as DESK_TO accepted" || pass "6. DESK_TO must be a human"
take DRY_RUN=0 DESK_TASK=00000000 >/dev/null 2>&1 && fail "6. topic prefix accepted" || pass "6. a topic prefix is refused"
take DRY_RUN=0 TAKE_PLAN='  ' DESK_TASK=00000000-0000-4000-8000-0000000000b2 >/dev/null 2>&1 && fail "6. empty plan accepted" || pass "6. an empty plan is refused"
take DRY_RUN=0 TAKE_REPLY_CMD= DESK_TASK=00000000-0000-4000-8000-0000000000b3 >/dev/null 2>&1; rc=$?
[[ $rc == 96 ]] && pass "6. SPOOL_TEST=1 without TAKE_REPLY_CMD exits 96" || fail "6. SPOOL_TEST guard rc=$rc"
[[ "$(n "$REPLY_LOG")" == "$before" ]] && pass "6. no refusal posted" || fail "6. a refusal posted"

# 7. wiring: the brief template renders the take command, and that command
#    (one command, no $(), no &&) matches one of the dispatcher's allow rules
grep -qF '{TAKE_CMD}' "$PROJ_ROOT/src/bash/features/dispatch/brief-dispatcher.tpl.md" &&
  pass "7. the dispatcher brief teaches the take command" || fail "7. brief does not carry {TAKE_CMD}"
env -i PATH="$PATH" PROJ_PATH="$PROJ_ROOT" DISPATCH_BOX_USER=box ENV=prd T="$T" bash -c '
  source "$PROJ_PATH/src/bash/run/spl-dispatch-setup.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-dispatch-check.func.sh"
  spl_dispatch_settings_json c-002 >"$T/settings.json"
  cmd="$(spl_dispatch_take_cmd c-002)"
  [[ "$cmd" == *"./run -a do_spl_take" ]] && spl_dispatch_rule_allows "$T/settings.json" "$cmd"' 2>"$T/o" &&
  pass "7. the taught take command matches a dispatcher allow rule" || fail "7. take command not allowed: $(cat "$T/o")"

# 8. one take per human post. old_take <topic> <epoch>: a row from before the key
L="$S/dispatch/take.log" P="$T/post"
old_take() { printf '%s\t%s\tc-002@box-a\tI read your post now\n' "$2" "$1" >>"$L"; }
tp() { take DRY_RUN=0 TAKE_POST_CMD="$T/post.sh" POST_FILE="$P" "$@" >"$T/o" 2>&1; }
A=00000000-0000-4000-8000-0000000000d1
old_take "$A" 1000
echo "TAKE-POST post-two 2000" >"$P"; b="$(n "$REPLY_LOG")"
tp DESK_TASK="$A"
[[ "$(n "$REPLY_LOG")" == $((b + 1)) ]] && pass "8. an old take and a new human post: a new take line" || fail "8. new post took no line: $(cat "$T/o")"
[[ "$(tail -n 1 "$L" | cut -f2,5)" == "$A"$'\tpost-two' ]] && pass "8. the row names the post" || fail "8. row: $(tail -n 1 "$L")"
tp DESK_TASK="$A"
[[ "$(n "$REPLY_LOG")" == $((b + 1)) ]] && grep -q TAKEN-ALREADY "$T/o" && pass "8. the same post again posts nothing" || fail "8. re-run posted: $(cat "$T/o")"
echo "TAKE-POST post-three 3000" >"$P"
tp DESK_TASK="$A"
[[ "$(n "$REPLY_LOG")" == $((b + 2)) ]] && pass "8. the next human post takes its own line" || fail "8. third post: $(cat "$T/o")"
B=00000000-0000-4000-8000-0000000000d2
old_take "$B" 5000
echo "TAKE-POST post-four 4000" >"$P"; b="$(n "$REPLY_LOG")"
tp DESK_TASK="$B"
[[ "$(n "$REPLY_LOG")" == "$b" ]] && pass "8. an id-less row newer than the post covers it" || fail "8. id-less row: $(cat "$T/o")"
: >"$P"
tp DESK_TASK="$B"
[[ "$(n "$REPLY_LOG")" == "$b" ]] && pass "8. nothing unanswered: an existing take still holds" || fail "8. answered topic posted"
tp DESK_TASK="$B" POST_FILE="$T/no-such-file"
[[ "$(n "$REPLY_LOG")" == "$b" ]] && grep -q TAKEN-ALREADY "$T/o" && pass "8. an unread topic: an existing take still holds" || fail "8. unread topic posted: $(cat "$T/o")"
tp DESK_TASK=00000000-0000-4000-8000-0000000000d3 POST_FILE="$T/no-such-file"
[[ "$(n "$REPLY_LOG")" == $((b + 1)) ]] && pass "8. an unread topic with no take still gets its line" || fail "8. unread, no take: $(cat "$T/o")"

# 9. the parser. row <from> <to> <id> <ts> <body>: one hub-tail line
row() { jq -cn --arg f "$1" --arg t "$2" --arg i "$3" --arg s "$4" --arg b "$5" '{from:$f,to:$t,msg_id:$i,ts:$s,body:$b}'; }
parse() { env -i PATH="$PATH" PROJ_PATH="$PROJ_ROOT" bash -c 'source "$PROJ_PATH/src/bash/run/spl-take-post.func.sh"; spl_take_post_parse'; }
H1="$(row HUM-10 ALL-0 m1 2026-11-07T20:50:06Z 'Status ?!')"
TK="$(row c-002 HUM-10 m2 2026-11-07T20:50:40Z 'Taken by c-002@box-a: I read your post now. I post the result here.')"
AN="$(row c-002 HUM-10 m3 2026-11-07T20:54:21Z 'The answer')"
H2="$(row HUM-10 c-002@box-a m4 2026-11-07T21:00:00Z 'And now?')"
NOTE="$(row c-002 c-001 m5 2026-11-07T21:00:30Z 'a relay')"
[[ "$(printf '%s\n' "$H1" | parse)" == "TAKE-POST m1 1794084606" ]] && pass "9. a lone human post, with its epoch" || fail "9. lone post: $(printf '%s\n' "$H1" | parse)"
[[ "$(printf '%s\n' "$H1" "$TK" | parse)" == "TAKE-ACKED m1 "* ]] && pass "9. a take line is not an answer; it marks the post TAKE-ACKED" || fail "9. take counted as an answer"
[[ -z "$(printf '%s\n' "$H1" "$TK" "$AN" | parse)" ]] && pass "9. an agent's answer ends it: nothing printed" || fail "9. answered: $(printf '%s\n' "$H1" "$TK" "$AN" | parse)"
[[ "$(printf '%s\n' "$H1" "$TK" "$AN" "$H2" "$NOTE" | parse)" == "TAKE-POST m4 "* ]] && pass "9. the follow-up post is the key; an agent-to-agent note answers nothing" || fail "9. follow-up: $(printf '%s\n' "$H1" "$AN" "$H2" "$NOTE" | parse)"
[[ "$(printf '%s\n' "$H2" "$AN" | parse)" == "TAKE-POST m4 "* ]] && pass "9. rows sort by ts, not by line" || fail "9. order: $(printf '%s\n' "$H2" "$AN" | parse)"

# 10. held channels. The topic read names its channels (TAKE-CHANNELS).
M="$S/channel-rules.tsv"
printf 'csitea\tquiet\t-\t-\t-\t-\tno-auto-post\nwsb\t*\t-\t-\t-\t-\tno-auto-post\nheldws\t*\t-\t-\t-\t-\tno-auto-post\n' >"$M"
printf '#!/usr/bin/env bash\necho "$*" >>"$SPAWN_LOG"\n' >"$T/spawn.sh"; chmod +x "$T/spawn.sh"
SPW="$T/spawns.log"; : >"$SPW"
th() { take DRY_RUN=0 TAKE_POST_CMD="$T/post.sh" POST_FILE="$P" TAKE_DEFER_RUN="$T/spawn.sh" TAKE_DEFER_SLEEP=true SPAWN_LOG="$SPW" "$@" >"$T/o" 2>&1; }
now=$(date +%s)
E1=00000000-0000-4000-8000-0000000000e1
printf 'TAKE-CHANNELS quiet\nTAKE-POST p-e1 %s\n' "$((now - 10))" >"$P"
b="$(n "$REPLY_LOG")" nb="$(n "$SEND_LOG")"
th DESK_TASK="$E1" ACK_DEFER_S=0 TAKE_NOTIFY=c-009; rc=$?
[[ $rc == 0 && "$(n "$REPLY_LOG")" == "$b" ]] && pass "10. immediate: a no-auto-post channel gets no take line, exit 0" ||
  fail "10. immediate: rc=$rc, $(( $(n "$REPLY_LOG") - b )) lines: $(cat "$T/o")"
grep -q "^TAKE-HELD $E1 by c-002@box-a: no-auto-post channel #quiet: the box map holds it from automatic posts.*$M" "$T/o" &&
  pass "10. TAKE-HELD names the channel and the map" || fail "10. no TAKE-HELD line: $(cat "$T/o")"
[[ "$(n "$SEND_LOG")" == $((nb + 1)) ]] && grep -q -- "--to c-009 --kind note --task $E1" "$SEND_LOG" &&
  pass "10. the TAKE_NOTIFY note still goes out" || fail "10. notes: $(( $(n "$SEND_LOG") - nb ))"
grep -q "$E1" "$S/dispatch/take.log" 2>/dev/null && fail "10. a held take was recorded" || pass "10. nothing recorded as taken"
E2=00000000-0000-4000-8000-0000000000e2
th DESK_TASK="$E2" ACK_DEFER_S=300
[[ "$(n "$REPLY_LOG")" == "$b" && "$(n "$SPW")" == 0 ]] && grep -q "^TAKE-HELD $E2" "$T/o" && ! grep -q TAKE-DEFERRED "$T/o" &&
  pass "10. deferred: no take line and no deferred run is started" || fail "10. deferred: spawns $(n "$SPW"): $(cat "$T/o")"
th DESK_TASK="$E2" TAKE_DEFER_DUE="$((now - 1))" TAKE_DEFER_POST=p-e1
[[ "$(n "$REPLY_LOG")" == "$b" ]] && grep -q "^TAKE-HELD $E2" "$T/o" && pass "10. the deferred run posts nothing in a held channel" ||
  fail "10. deferred run: $(cat "$T/o")"
printf 'TAKE-CHANNELS general quiet\nTAKE-POST p-e3 %s\n' "$((now - 10))" >"$P"
th DESK_TASK=00000000-0000-4000-8000-0000000000e3 ACK_DEFER_S=0
[[ "$(n "$REPLY_LOG")" == "$b" ]] && grep -q "#quiet" "$T/o" && pass "10. any channel the topic touches counts" || fail "10. two channels: $(cat "$T/o")"
printf 'TAKE-CHANNELS general\nTAKE-POST p-e4 %s\n' "$((now - 10))" >"$P"
th DESK_TASK=00000000-0000-4000-8000-0000000000e4 ACK_DEFER_S=0 TENANT_ID=heldws
[[ "$(n "$REPLY_LOG")" == "$b" ]] && grep -q "^TAKE-HELD .*#general" "$T/o" && pass "10. the workspace's * row holds every channel" ||
  fail "10. * row: $(cat "$T/o")"
mv "$M" "$M.off"
th DESK_TASK=00000000-0000-4000-8000-0000000000e5 ACK_DEFER_S=0
[[ "$(n "$REPLY_LOG")" == "$b" ]] && grep -q "^TAKE-HELD .*cannot tell whether the box map holds #general (the map is missing)" "$T/o" &&
  pass "10. no box map: cannot tell, no take line" || fail "10. no map: $(cat "$T/o")"
mv "$M.off" "$M"
th DESK_TASK=00000000-0000-4000-8000-0000000000e6 ACK_DEFER_S=0
[[ "$(n "$REPLY_LOG")" == $((b + 1)) ]] && grep -q "^TAKEN " "$T/o" && pass "10. control: a channel with no holding row posts" ||
  fail "10. free channel: $(cat "$T/o")"
printf 'TAKE-CHANNELS general\nTAKE-POST p-e7 %s\n' "$((now - 10))" >"$P"
th DESK_TASK=00000000-0000-4000-8000-0000000000e7 ACK_DEFER_S=0 TENANT_ID=wsc
[[ "$(n "$REPLY_LOG")" == $((b + 2)) ]] && pass "10. control: another workspace's * row does not hold this one" ||
  fail "10. other * row: $(cat "$T/o")"
printf 'TAKE-CHANNELS\nTAKE-POST p-e8 %s\n' "$((now - 10))" >"$P"
th DESK_TASK=00000000-0000-4000-8000-0000000000e8 ACK_DEFER_S=0
[[ "$(n "$REPLY_LOG")" == $((b + 3)) ]] && pass "10. control: a DM (no channel) posts" || fail "10. DM: $(cat "$T/o")"
# the parser names the channels when every row carries one ("" = a DM)
crow() { jq -cn --arg c "$1" --arg f "$2" --arg i "$3" '{channel:$c,from:$f,to:"ALL-0",msg_id:$i,ts:"2026-11-20T14:45:00Z",body:"q"}'; }
[[ "$(crow '#QUIET' HUM-10 m1 | parse | sed -n 1p)" == "TAKE-CHANNELS quiet" ]] && pass "10. parser: the channel, without # and lower-case" ||
  fail "10. parser: $(crow '#QUIET' HUM-10 m1 | parse)"
[[ "$( { crow '' HUM-10 m1; crow ops c-001 m2; } | parse | sed -n 1p)" == "TAKE-CHANNELS ops" ]] && pass "10. parser: every channel, a DM row adds none" ||
  fail "10. parser two rows: $( { crow '' HUM-10 m1; crow ops c-001 m2; } | parse)"
[[ "$(printf '%s\n' "$H1" | parse)" != *TAKE-CHANNELS* ]] && pass "10. parser: rows with no channel field name none" ||
  fail "10. parser, no channel field: $(printf '%s\n' "$H1" | parse)"

# control: without the post key the new post of case 8 takes no line
sed 's/ "\$post" "\$post_at"//' "$PROJ_ROOT/src/bash/run/spl-take.func.sh" >"$T/nokey.func.sh"
C2=00000000-0000-4000-8000-0000000000c2 N="$T/nokey.log"
old_take "$C2" 1000
echo "TAKE-POST post-c 2000" >"$P"
REPLY_LOG="$N" tp TAKE_FUNC="$T/nokey.func.sh" DESK_TASK="$C2"
[[ "$(n "$N")" == 0 ]] && pass "control: without the post key a new post takes no line" ||
  fail "control: the planted copy posted $(n "$N") (case 8 would not see a regression)"

# control: the same second take without the ledger check posts twice
sed 's/if spl_take_seen "\$f" "\$task" "\$by" "\$post" "\$post_at"; then/if false; then/; s/spl_take_seen "\$f" "\$task" "\$by" "\$post" "\$post_at" \&\&/false \&\&/' \
  "$PROJ_ROOT/src/bash/run/spl-take.func.sh" >"$T/planted.func.sh"
C="$T/ctl.log"
REPLY_LOG="$C" take DRY_RUN=0 TAKE_FUNC="$T/planted.func.sh" DESK_TASK=00000000-0000-4000-8000-0000000000c1 >/dev/null 2>&1
REPLY_LOG="$C" take DRY_RUN=0 TAKE_FUNC="$T/planted.func.sh" DESK_TASK=00000000-0000-4000-8000-0000000000c1 >/dev/null 2>&1
[[ "$(n "$C")" == 2 ]] && pass "control: without the ledger check the take line is posted twice" ||
  fail "control: planted copy posted $(n "$C") (the idempotency test would not see a regression)"

echo
(( fails == 0 )) && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
