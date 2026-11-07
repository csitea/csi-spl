#!/usr/bin/env bash
# test-spool-discussion-mirror.sh — an agent's work reaches its discussion
# (SPL-4657, spec 067 section 11), behind cnf env.box.discussion_mirror.
#
#   R1  THE BUG: a turn started by a task notification, with findings in its
#       final text, appears in the discussion
#   R2  every vendor's hook payload reaches the same post (grok, qwen, agy,
#       mistral)
#   C1  the switch: off, missing and unparsable all post nothing, and the
#       repo's default stays false
#   C2  never posted: tool output, poke lines, task-notification text, a sealed
#       envelope, a status-only answer
#   C3  redaction runs first
#   C4  no discussion: nothing posted and exactly one log line; the same for
#       an unseated lane
#   C5  two discussions: nothing, unless the turn's own channel post names one
#   C6  no post crosses a workspace: a topic this seat cannot read, an agent
#       on two seats
#   C7  no post reaches a DM: a topic with no channel; a DM-triggered turn
#       answers its DM only
#   C8  role seats never post
#   C9  nothing twice: the agent posted this turn (hub row, seat outbox), the
#       same text is in the topic, two hooks for one answer
#   C10 the send is the no-loop form: ALL-0, box-wui, no --channel
#   C11 the rate cap skips, logs, and the next post counts what it skipped
#   C12 the brief: only its Discussion: line names a discussion, and two
#       distinct uuids on such lines are silence
#   C13 the DM hold: two hooks on a DM turn, a follow-up turn after a DM, and an
#       unreadable hold all stay out of the channel
#   C14 a corrupt seen-list does not fail the prompt hook
#   C15 is_role_seat agrees with SPL_ROLE_SEAT_RX
#   C16 a DM no prompt has taken yet stops every post of the agent, on every
#       seat, a muted one too
#   C17 a second seat lookup that fails stops the post, it does not read as no DM
#   C18 a second seat lookup that does not cover the agent's seats stops the post
#   C19 a seat that cannot be listed counts as a hold; an absent dir does not
#   C20 a trigger dir that cannot be read counts as a hold; an absent one does not
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.inc.sh"
t_sandbox
unset SPOOL_AGENT_ID MCP_BOT_AGENT_ID SPOOL_MIRROR_TO SPOOL_MIRROR_POST SPOOL_MIRROR_SYNC SPOOL_MIRROR_DRY SPOOL_MIRROR_SPOOL SPOOL_BOX_USER

MIRROR="$T_SCRIPTS/spool-mirror.py"
ID=c-777
SEAT="$T_TMP/cloud/dev/desk/t1/box-desk"
SEAT2="$T_TMP/cloud/dev/desk/t2/box-desk"
A="$SEAT/spool/$ID"
A2="$SEAT2/spool/$ID"
FLEET="$T_TMP/fleet"
TD=11111111-1111-4111-8111-111111111111   # a discussion of t1
TE=22222222-2222-4222-8222-222222222222   # another discussion of t1
TM=33333333-3333-4333-8333-333333333333   # a DM topic of t1
TX=44444444-4444-4444-8444-444444444444   # a discussion of t2 only
mkdir -p "$A/inbox" "$SEAT/spool/.hub" "$SEAT/keys" "$T_TMP/cloud/dev/bin" "$FLEET/$ID/lifetime"
mkdir -p "$SEAT2/spool/.hub" "$SEAT2/keys"

env SPOOL_HUB_URL=https://hub.example.test SPOOL_TENANT=t1 SPOOL_BOX_ID=box-desk sleep 300 &
SIDECAR=$!
env SPOOL_HUB_URL=https://hub.example.test SPOOL_TENANT=t2 SPOOL_BOX_ID=box-desk sleep 300 &
SIDECAR2=$!
echo "$SIDECAR" >"$SEAT/spool/.hub/hub-run.pid"
echo "$SIDECAR2" >"$SEAT2/spool/.hub/hub-run.pid"
trap 'kill $SIDECAR $SIDECAR2 2>/dev/null; chmod -R u+rwX "$T_TMP" 2>/dev/null; t_cleanup' EXIT

# The spool stub: send records its argv; hub-tail prints <tails>/<tenant>/<task>.
SENDS="$T_TMP/sends"; TAILS="$T_TMP/tails"; mkdir -p "$SENDS" "$TAILS/t1" "$TAILS/t2"
cat >"$T_TMP/cloud/dev/bin/spool" <<STUB
#!/usr/bin/env bash
case "\$1" in
  hub-tail)
    prev=""; for a in "\$@"; do [ "\$prev" = --task ] && task="\$a"; prev="\$a"; done
    [ -f "$TAILS/\$SPOOL_TENANT/\$task" ] && cat "$TAILS/\$SPOOL_TENANT/\$task"
    exit 0 ;;
  send)
    n=\$(ls "$SENDS" | wc -l)
    { printf '%s\n' "\$@"; echo "TENANT=\$SPOOL_TENANT"; } >"$SENDS/\$n"
    printf '{"msg_id":"m-%s"}\n' "\$n" ;;
esac
STUB
chmod +x "$T_TMP/cloud/dev/bin/spool"

# A row of the hub's --with-channel NDJSON.
row() {  # TENANT TASK CHANNEL FROM TS BODY
  python3 -c 'import json,sys; print(json.dumps(dict(zip(("channel","from","ts","body"), sys.argv[3:]), task_id=sys.argv[2])))' "$@" >>"$TAILS/$1/$2"
}
HUMAN_TS=2026-01-01T00:00:00Z
row t1 "$TD" spool-hub-bugs HUM-9 "$HUMAN_TS" "the opening card"
row t1 "$TE" spool-hub-bugs HUM-9 "$HUMAN_TS" "another card"
row t1 "$TM" "" HUM-9 "$HUMAN_TS" "a dm"
row t2 "$TX" customer-channel HUM-5 "$HUMAN_TS" "a card of the other workspace"

CNF="$T_TMP/cnf"; mkdir -p "$CNF"
export SPOOL_DISCUSSION_MIRROR_CNF="$CNF" SPOOL_ROOT="$FLEET"
export SPOOL_MIRROR_SEATS="$T_TMP/cloud/*/desk/*/*"
switch() {  # true|false|absent [MAX_PER_HOUR]
  case "$1" in
    absent) printf 'env:\n  box: {}\n' >"$CNF/all.env.yaml" ;;
    *) printf 'env:\n  box:\n    discussion_mirror:\n      enabled: false\n      max_posts_per_hour: %s\n' "${2:-12}" >"$CNF/all.env.yaml"
       printf 'env:\n  box:\n    discussion_mirror:\n      enabled: %s\n' "$1" >"$CNF/dev.env.yaml" ;;
  esac
}
reset() {  # wipe every record of the earlier case
  rm -f "${SENDS:?}"/* "${FLEET:?}/$ID/lifetime/brief.md" "${FLEET:?}/$ID/mirror.log"
  rm -rf "${A:?}/.mirror" "${A:?}/outbox" "${A2:?}"
  N=$((${N:-0} + 1)); S="s$N"
}
post() {  # EVENT TEXT [ID]
  printf '%s' "$2" | python3 "$MIRROR" post --agent "${3:-$ID}" --event "$1" --session "$S" >/dev/null 2>&1
}
nsends() { ls "$SENDS" | wc -l | tr -d ' '; }
send_arg() {  # N FLAG -> the value after FLAG in send N
  awk -v f="$2" 'p{print; exit} $0==f{p=1}' "$SENDS/$1"
}
send_body() {  # N -> everything between --body and the stub's TENANT line
  awk '$0=="--body"{p=1; next} /^TENANT=/{p=0} p' "$SENDS/$1"
}
brief() { printf '# Lane brief\n\nDiscussion: https://hub.example.test/t/%s\n' "$1" >"$FLEET/$ID/lifetime/brief.md"; }
trig() {  # KIND FROM TASK LINE [AGENT_DIR]
  local d="${5:-$A}/.mirror/trigger"; mkdir -p "$d"
  python3 -c 'import json,sys; print(json.dumps(dict(zip(("kind","from","task","msg","line"), sys.argv[1:]))))' \
    "$1" "$2" "$3" "m-$RANDOM" "$4" >"$d/$(date +%s%N)-$RANDOM"
}
NOTIFICATION='<task-notification><task-id>x</task-id><status>completed</status><summary>Background command finished</summary></task-notification>'
FINDINGS='Findings: the book build broke on my change, and three unit tests fail in the deploy suite. Fix committed as abc1234.'
turn_notification() { post prompt "$NOTIFICATION"; post answer "${1:-$FINDINGS}"; }

# --- R1 the bug ---------------------------------------------------------------
switch true; reset; brief "$TD"
turn_notification
eq "R1. a task-notification turn's findings reach the discussion" 1 "$(nsends)"
eq "R1. ... in the lane's discussion" "$TD" "$(send_arg 0 --task)"
eq "R1. ... the final text is the body" "$FINDINGS" "$(send_body 0)"
has "R1. ... and the log says it" "discussion: OK" "$(tail -1 "$A/.mirror/mirror.log")"

# --- C10 the no-loop form -----------------------------------------------------
eq "C10. addressed to no person" ALL-0 "$(send_arg 0 --to)"
eq "C10. sent to the web UI's box, so no seat is poked" box-wui "$(send_arg 0 --to-box)"
if grep -qx -- '--channel' "$SENDS/0"; then nok "C10. --channel would fan out to every seat"; else ok "C10. no --channel"; fi

# --- C1 the switch ------------------------------------------------------------
switch false; reset; brief "$TD"; turn_notification
eq "C1. switch false: nothing" 0 "$(nsends)"
rm -f "${CNF:?}/dev.env.yaml"; switch absent; reset; brief "$TD"; turn_notification
eq "C1. key missing: nothing" 0 "$(nsends)"
printf ': : not yaml [\n' >"$CNF/all.env.yaml"; reset; brief "$TD"; turn_notification
eq "C1. a file that does not parse: nothing" 0 "$(nsends)"
# Only a YAML true is on: a truthy value of any other type is off.
for v in 1 '"true"' '[x]' '{a: 1}'; do
  printf 'env:\n  box:\n    discussion_mirror:\n      enabled: false\n' >"$CNF/all.env.yaml"
  printf 'env:\n  box:\n    discussion_mirror:\n      enabled: %s\n' "$v" >"$CNF/dev.env.yaml"
  reset; brief "$TD"; turn_notification
  eq "C1. enabled: $v is not true: nothing" 0 "$(nsends)"
done
# all.env.yaml on, the env file broken: a broken env file must not read as on.
printf 'env:\n  box:\n    discussion_mirror:\n      enabled: true\n' >"$CNF/all.env.yaml"
printf ': : not yaml [\n' >"$CNF/dev.env.yaml"; reset; brief "$TD"; turn_notification
eq "C1. all on, the env file unparsable: nothing" 0 "$(nsends)"
rm -f "${CNF:?}/dev.env.yaml"; reset; brief "$TD"; turn_notification
eq "C1. CONTROL: all on, no env file: it posts" 1 "$(nsends)"
eq "C1. the repo's default stays false" "False" \
  "$(python3 -c 'import yaml,sys; print(yaml.safe_load(open(sys.argv[1]))["env"]["box"]["discussion_mirror"]["enabled"])' "$T_REPO/csi-spl-cnf/csi-spl/all.env.yaml")"
switch true

# --- C2 never posted ----------------------------------------------------------
reset; brief "$TD"; post prompt "$NOTIFICATION"
eq "C2. task-notification text as a prompt: nothing" 0 "$(nsends)"
post prompt ": 'SPOOL c-001 note: a poke line'"
eq "C2. a poke line as a prompt: nothing" 0 "$(nsends)"
post prompt "the seed: read your brief"
eq "C2. a typed prompt: nothing" 0 "$(nsends)"
reset; brief "$TD"; post prompt "$NOTIFICATION"; post answer "Still waiting for CI on the other lane."
eq "C2. a status-only answer: nothing" 0 "$(nsends)"
reset; brief "$TD"; post prompt "$NOTIFICATION"
post answer '{"v":3,"enc":true,"from":"HUM-9","kind":"note","task_id":"x","msg_id":"y","ct":"SEALED"}'
eq "C2. a sealed envelope: nothing" 0 "$(nsends)"
reset; brief "$TD"; post prompt "$NOTIFICATION"
post answer "$NOTIFICATION
$FINDINGS"
eq "C2. an injected block quoted in the answer is cut" "$FINDINGS" "$(send_body 0)"
# End to end through the hook: tool events carry no post at all.
reset; brief "$TD"
export SPOOL_AGENT_ID=$ID SPOOL_MIRROR_POST="python3 $MIRROR" SPOOL_MIRROR_SYNC=1
hook() { python3 "$MIRROR" hook "$@" >/dev/null 2>&1; }
printf '{"hook_event_name":"PostToolUse","session_id":"%s","tool_name":"Bash","tool_response":{"stdout":"LOG LINE 123"}}' "$S" | hook
printf '{"hook_event_name":"PreToolUse","session_id":"%s","tool_name":"Bash","tool_input":{"command":"ls"}}' "$S" | hook
eq "C2. tool output through the hook: nothing" 0 "$(nsends)"

# --- R2 every vendor ----------------------------------------------------------
stop_payload() { python3 -c 'import json,sys; print(json.dumps({sys.argv[1]:"Stop",sys.argv[2]:sys.argv[3],sys.argv[4]:sys.argv[5]}))' "$@"; }
reset; brief "$TD"
stop_payload hook_event_name session_id "$S" last_assistant_message "$FINDINGS (claude and qwen shape)" | hook
eq "R2. claude / qwen Stop payload posts" 1 "$(nsends)"
reset; brief "$TD"
stop_payload hookEventName sessionId "$S" lastAssistantMessage "$FINDINGS (grok shape)" | hook
eq "R2. grok's camelCase Stop posts" 1 "$(nsends)"
reset; brief "$TD"
printf '{"hookEventName":"Stop","sessionId":"%s","reason":"session_end","lastAssistantMessage":"%s"}' "$S" "$FINDINGS" | hook
eq "R2. grok's session-end Stop: nothing" 0 "$(nsends)"
reset; brief "$TD"
AGY="$T_TMP/agy.jsonl"
python3 -c 'import json,sys
for s in ({"type":"USER_INPUT","source":"USER_EXPLICIT","content":"<USER_REQUEST>go</USER_REQUEST>"},{"type":"TOOL","source":"MODEL","content":"TOOL OUTPUT"},{"type":"PLANNER_RESPONSE","source":"MODEL","content":sys.argv[1]}):
    print(json.dumps(s))' "$FINDINGS (agy)" >"$AGY"
printf '{"conversationId":"%s","transcriptPath":"%s"}' "$S" "$AGY" | hook --agy stop
eq "R2. agy's Stop posts from its transcript" 1 "$(nsends)"
if grep -q 'TOOL OUTPUT' "$SENDS/0"; then nok "R2. agy: a tool step leaked"; else ok "R2. agy: no tool step in the body"; fi
reset; brief "$TD"
VIBE="$T_TMP/vibe.jsonl"
python3 -c 'import json,sys
for s in ({"role":"user","content":"go"},{"role":"tool","content":"TOOL OUTPUT"},{"role":"assistant","content":sys.argv[1]}):
    print(json.dumps(s))' "$FINDINGS (mistral)" >"$VIBE"
printf '{"session_id":"%s","transcript_path":"%s"}' "$S" "$VIBE" | hook --vibe
eq "R2. mistral's post_agent posts from its session" 1 "$(nsends)"
if grep -q 'TOOL OUTPUT' "$SENDS/0"; then nok "R2. mistral: a tool message leaked"; else ok "R2. mistral: no tool message in the body"; fi
unset SPOOL_AGENT_ID SPOOL_MIRROR_POST SPOOL_MIRROR_SYNC

# --- C3 redaction -------------------------------------------------------------
GH="ghp_$(printf 'a%.0s' {1..24})"
reset; brief "$TD"; turn_notification "$FINDINGS The token was $GH and it is rotated."
if grep -q "$GH" "$SENDS/0"; then nok "C3. a planted secret reached spool send"; else ok "C3. a planted secret is redacted"; fi
has "C3. ... by the one redaction pass" "<redacted:github-token>" "$(send_body 0)"
if grep -rq "$GH" "$A/.mirror"; then nok "C3. a planted secret reached the mirror's state"; else ok "C3. ... and the mirror's state holds no secret"; fi

# --- C4 no discussion ---------------------------------------------------------
reset; turn_notification
eq "C4. no discussion: nothing" 0 "$(nsends)"
eq "C4. ... and exactly one log line" 1 "$(grep -c 'discussion: nothing' "$A/.mirror/mirror.log")"
if grep -qF "$FINDINGS" "$A/.mirror/mirror.log"; then nok "C4. the log holds the text"; else ok "C4. ... which holds no text"; fi
reset; brief "$TD"; rm -rf "${A:?}"; turn_notification
eq "C4. an unseated lane: nothing" 0 "$(nsends)"
eq "C4. ... and one line in its fleet dir" 1 "$(grep -c 'discussion: nothing' "$FLEET/$ID/mirror.log")"
mkdir -p "$A/inbox"
# A relay id or a short hash on the brief is no discussion: full uuid only.
reset; printf 'Discussion: https://hub.example.test/t/11111111\n' >"$FLEET/$ID/lifetime/brief.md"; turn_notification
eq "C4. a brief with a short id: nothing" 0 "$(nsends)"

# --- C5 two discussions -------------------------------------------------------
reset
trig channel HUM-9 "$TD" "line one"; post prompt "line one"; post answer "$FINDINGS one"
eq "C5. a channel-started turn posts in its topic" "$TD" "$(send_arg 0 --task)"
turn_notification "$FINDINGS two"
eq "C5. one discussion seen: a notification turn lands there" "$TD" "$(send_arg 1 --task)"
trig channel HUM-9 "$TE" "line two"; post prompt "line two"; post answer "$FINDINGS three"
eq "C5. a channel post of the second discussion answers there" "$TE" "$(send_arg 2 --task)"
n="$(nsends)"; turn_notification "$FINDINGS four"
eq "C5. two discussions and no trigger: nothing (silence beats a wrong landing)" "$n" "$(nsends)"
has "C5. ... and the log names why" "2 discussions and this turn names none" "$(tail -1 "$A/.mirror/mirror.log")"

# --- C6 workspaces ------------------------------------------------------------
reset; brief "$TX"; turn_notification
eq "C6. a discussion of another workspace, seat t1 only: nothing" 0 "$(nsends)"
reset; brief "$TD"; mkdir -p "$A2/inbox"; turn_notification
eq "C6. two seats: the one that can read it posts, once" 1 "$(nsends)"
has "C6. ... on its own workspace" "TENANT=t1" "$(cat "$SENDS/0")"
# Each seat saw its own discussion: the text cannot choose between workspaces.
reset; mkdir -p "$A2/inbox"
trig channel HUM-9 "$TD" "line one"; post prompt "line one"; post answer "$FINDINGS a"
trig channel HUM-5 "$TX" "line x" "$A2"; post prompt "line x"; post answer "$FINDINGS b"
eq "C6. a channel post posts on its own seat only" "TENANT=t1 TENANT=t2" "$(tail -qn1 "$SENDS"/0 "$SENDS"/1 | tr '\n' ' ' | sed 's/ $//')"
n="$(nsends)"; turn_notification "$FINDINGS c"
eq "C6. seen on two seats, no trigger: nothing crosses" "$n" "$(nsends)"

# --- C7 DMs -------------------------------------------------------------------
reset; brief "$TM"; turn_notification
eq "C7. a topic with no channel is never posted to" 0 "$(nsends)"
has "C7. ... and the log says why" "not a channel discussion" "$(tail -1 "$A/.mirror/mirror.log")"
reset; brief "$TD"
trig dm HUM-9 "$TM" "a person's dm"; post prompt "a person's dm"; post answer "$FINDINGS to the dm"
eq "C7. a DM-triggered turn sends one message" 1 "$(nsends)"
eq "C7. ... into that DM, to that person" "$TM HUM-9" "$(send_arg 0 --task) $(send_arg 0 --to)"

# --- C8 role seats ------------------------------------------------------------
R=c-002; RA="$SEAT/spool/$R"; mkdir -p "$RA/inbox" "$FLEET/$R/lifetime"
reset; printf 'Discussion: https://hub.example.test/t/%s\n' "$TD" >"$FLEET/$R/lifetime/brief.md"
trig channel HUM-9 "$TD" "to the dispatcher" "$RA"
post prompt "to the dispatcher" "$R"; post answer "$FINDINGS" "$R"
eq "C8. a role seat never posts, even on its own channel post" 0 "$(nsends)"
rm -rf "${RA:?}"

# --- C9 nothing twice ---------------------------------------------------------
reset; brief "$TD"
post prompt "$NOTIFICATION"
cp "$TAILS/t1/$TD" "$T_TMP/td.keep"
row t1 "$TD" spool-hub-bugs "$ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "its own words, not the final text"
post answer "$FINDINGS"
eq "C9. the agent's own row since the turn began: nothing" 0 "$(nsends)"
cp "$T_TMP/td.keep" "$TAILS/t1/$TD"
reset; brief "$TD"; post prompt "$NOTIFICATION"
mkdir -p "$A/outbox"; printf '{"task_id":"%s","from":"%s","body":"queued, not flushed"}\n' "$TD" "$ID" >"$A/outbox/20260101T000000Z--x.json"
post answer "$FINDINGS"
eq "C9. a send in the seat's outbox since the turn began: nothing" 0 "$(nsends)"
# CONTROL: the same row BEFORE the turn does not count.
reset; brief "$TD"
row t1 "$TD" spool-hub-bugs "$ID" 2026-01-02T00:00:00Z "an older post"
turn_notification
eq "C9. CONTROL: the agent's older row does not stop this turn" 1 "$(nsends)"
cp "$T_TMP/td.keep" "$TAILS/t1/$TD"
reset; brief "$TD"
row t1 "$TD" spool-hub-bugs "$ID" 2026-01-02T00:00:00Z "$FINDINGS"
turn_notification
eq "C9. the same text is already in the topic: nothing" 0 "$(nsends)"
cp "$T_TMP/td.keep" "$TAILS/t1/$TD"
reset; brief "$TD"; post prompt "$NOTIFICATION"; post answer "$FINDINGS"; post answer "$FINDINGS"
eq "C9. two hooks for one answer: one post" 1 "$(nsends)"

# --- C12 the brief's line -----------------------------------------------------
briefs() { printf '%b' "$1" >"$FLEET/$ID/lifetime/brief.md"; }
U=https://hub.example.test/t
reset; briefs "# Lane\n\nSee $U/$TE for the history.\nDiscussion: $U/$TD\n"; turn_notification
eq "C12. a link cited above the Discussion: line does not win" "$TD" "$(send_arg 0 --task)"
reset; briefs "# Lane\n\nSee $U/$TD for the history.\n"; turn_notification
eq "C12. a link on no Discussion: line names nothing" 0 "$(nsends)"
reset; briefs "# Lane\n\nthe old discussion: $TD was closed\n"; turn_notification
eq "C12. a prose mention mid-line names nothing" 0 "$(nsends)"
reset; briefs "Discussion: $U/$TD\nDiscussion: $U/$TE\n"; turn_notification
eq "C12. two distinct Discussion: lines: nothing" 0 "$(nsends)"
has "C12. ... and the log names why" "the brief names 2 discussions" "$(tail -1 "$A/.mirror/mirror.log")"
reset; trig channel HUM-9 "$TD" "line one"; post prompt "line one"; post answer "$FINDINGS one"
n="$(nsends)"; briefs "Discussion: $U/$TD\nDiscussion: $U/$TE\n"; turn_notification "$FINDINGS two"
eq "C12. two Discussion: lines do not fall through to the seen topic" "$n" "$(nsends)"
reset; briefs "Discussion: $U/$TD\nDiscussion: $TD\n"; turn_notification
eq "C12. the same uuid twice is one discussion" "$TD" "$(send_arg 0 --task)"
reset; briefs '**Discussion:** `'"$TD"'`\n'; turn_notification
eq "C12. a bold label and a bare uuid are accepted" "$TD" "$(send_arg 0 --task)"

# --- C13 the DM hold ----------------------------------------------------------
dm_turn() { trig dm HUM-9 "$TM" "a person's dm"; post prompt "a person's dm"; post answer "$1"; }
reset; brief "$TD"; dm_turn "PRIVATE answer"; post answer "PRIVATE answer"
eq "C13. a DM turn with two hooks: one send" 1 "$(nsends)"
eq "C13. ... into the DM" "$TM HUM-9" "$(send_arg 0 --task) $(send_arg 0 --to)"
reset; brief "$TD"; dm_turn "PRIVATE answer"; turn_notification "$FINDINGS from the DM's background job"
eq "C13. a follow-up turn after a DM stays out of the channel" 1 "$(nsends)"
has "C13. ... and the log says it" "a DM turn in the last hour" "$(tail -1 "$A/.mirror/mirror.log")"
if grep -qF "from the DM's background job" "$A/.mirror/mirror.log"; then nok "C13. the log holds the text"; else ok "C13. ... which holds no text"; fi
# The person's own channel post still answers in its thread.
trig channel HUM-9 "$TD" "line one"; post prompt "line one"; post answer "$FINDINGS in the thread"
eq "C13. a channel post during the hold answers there" "$TD" "$(send_arg 1 --task)"
# The hour passes.
reset; brief "$TD"; dm_turn "PRIVATE answer"
python3 -c 'import json,sys,time; json.dump({"ts":time.time()-3700},open(sys.argv[1],"w"))' "$A/.mirror/dm-turn"
turn_notification
eq "C13. CONTROL: the hour passes, a notification turn posts" "$TD" "$(send_arg 1 --task)"
# The edge of the window, both sides: 3,700 s above posts, 3,500 s holds.
reset; brief "$TD"; dm_turn "PRIVATE answer"
python3 -c 'import json,sys,time; json.dump({"ts":time.time()-3500},open(sys.argv[1],"w"))' "$A/.mirror/dm-turn"
turn_notification
eq "C13. 3,500 s after the DM it still holds" 1 "$(nsends)"
# A hold it cannot read is a hold.
reset; brief "$TD"; post prompt "$NOTIFICATION"; printf 'not json' >"$A/.mirror/dm-turn"; post answer "$FINDINGS"
eq "C13. an unreadable hold: nothing" 0 "$(nsends)"
# A hold on one seat holds the agent's other seat: a DM of t1 stays out of t2.
reset; brief "$TX"; mkdir -p "$A2/inbox"; dm_turn "PRIVATE answer"; turn_notification
eq "C13. a DM on one seat holds the other seat too" 1 "$(nsends)"
eq "C13. ... whose workspace got nothing" "TENANT=t1" "$(tail -qn1 "$SENDS"/0)"
reset; brief "$TD"; mkdir -p "$A2/inbox"
trig dm HUM-5 "$TX" "a dm on the second seat" "$A2"; post prompt "a dm on the second seat"; post answer "PRIVATE answer"
turn_notification
eq "C13. a DM on the second seat holds the first too" "1 TENANT=t2" "$(nsends) $(tail -qn1 "$SENDS"/0)"

# During a hold only the channel post's own seat may post. Its plan fails (t1
# cannot read that topic), and the other seat, which can, stays silent.
reset; brief "$TX"; mkdir -p "$A2/inbox"; dm_turn "PRIVATE answer"
trig channel HUM-9 "$TX" "line one"; post prompt "line one"; post answer "$FINDINGS"
eq "C13. during a hold another seat does not stand in for the channel seat" 1 "$(nsends)"
# The hold is read on every seat, so a seat muted after its DM still holds.
reset; brief "$TD"; mkdir -p "$A2/inbox"
trig dm HUM-5 "$TX" "a dm on the second seat" "$A2"; post prompt "a dm on the second seat"; post answer "PRIVATE answer"
touch "$A2/.no-mirror"; turn_notification
eq "C13. a seat muted after its DM still holds" "1 TENANT=t2" "$(nsends) $(tail -qn1 "$SENDS"/0)"

# --- C16 a DM no prompt has taken --------------------------------------------
# A line typed during a turn queues: no prompt hook takes its record, and the
# turn's answer can already answer it.
dm_pending() { trig dm HUM-9 "$TM" "a person's dm, typed mid-turn" "${1:-$A}"; }
age_triggers() {  # SECONDS [AGENT_DIR]
  find "${2:-$A}/.mirror/trigger" -type f -exec touch -d "@$(($(date +%s) - $1))" {} +
}
reset; brief "$TD"; trig channel HUM-9 "$TD" "line one"; post prompt "line one"; dm_pending; post answer "$FINDINGS"
eq "C16. a DM typed during a channel turn: nothing" 0 "$(nsends)"
has "C16. ... and the log says it" "a person's DM has no turn yet" "$(tail -1 "$A/.mirror/mirror.log")"
reset; brief "$TD"; dm_pending; turn_notification
eq "C16. a DM the prompt does not match: nothing" 0 "$(nsends)"
reset; brief "$TD"; mkdir -p "$A2/inbox"; dm_pending "$A2"; turn_notification
eq "C16. a DM waiting on the other seat: nothing" 0 "$(nsends)"
reset; brief "$TD"; mkdir -p "$A2/inbox"; dm_pending; turn_notification
eq "C16. a DM waiting on the first seat of two: nothing" 0 "$(nsends)"
reset; brief "$TD"; mkdir -p "$A2/inbox"; touch "$A2/.no-mirror"; dm_pending "$A2"; turn_notification
eq "C16. a DM waiting on a muted seat: nothing" 0 "$(nsends)"
reset; brief "$TD"; mkdir -p "$A2/inbox"; touch "$A2/.no-mirror"; turn_notification
eq "C16. CONTROL: a muted seat with no DM does not stop the post" 1 "$(nsends)"
reset; brief "$TD"; post prompt "$NOTIFICATION"; dm_pending; age_triggers 3500; post answer "$FINDINGS"
eq "C16. a waiting DM 3,500 s old still holds" 0 "$(nsends)"
reset; brief "$TD"; post prompt "$NOTIFICATION"; dm_pending; age_triggers 3700; post answer "$FINDINGS"
eq "C16. CONTROL: past the hour it no longer holds" 1 "$(nsends)"
reset; brief "$TD"; post prompt "$NOTIFICATION"; mkdir -p "$A/.mirror/trigger"; printf 'not json' >"$A/.mirror/trigger/x"; post answer "$FINDINGS"
eq "C16. a record that cannot be read: nothing" 0 "$(nsends)"
reset; brief "$TD"; trig channel HUM-9 "$TE" "another line"; trig task c-001 "" "a task line"; turn_notification
eq "C16. CONTROL: other waiting kinds do not stop the post" "1 $TD" "$(nsends) $(send_arg 0 --task)"

# --- C17 the seats cannot be read a second time ------------------------------
# The DM reads look the seats up again, muted ones too. A lookup that fails there
# has read no record at all, which is not the same as no record.
cat >"$T_TMP/lookup.py" <<'WRAP'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("spool_mirror", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
calls = {"n": 0}
def desk_root(_home):
    calls["n"] += 1
    if calls["n"] >= 2 and os.environ.get("LOOKUP_GONE"):
        os.rename(os.environ["LOOKUP_GONE"], os.environ["LOOKUP_GONE"] + ".gone")
    if calls["n"] >= 2 and os.environ.get("LOOKUP_ROOT2"):
        return os.environ["LOOKUP_ROOT2"]
    return "" if os.environ["LOOKUP_FAIL"] == "1" and calls["n"] >= 2 else os.environ["LOOKUP_ROOT"]
m.desk_root = desk_root
sys.exit(m.main(["spool-mirror.py"] + sys.argv[2:]))
WRAP
answer_lookup() {  # FAIL(0|1) TEXT: the Stop hook, desk_root stubbed, its second call failing on 1
  printf '%s' "$2" | env -u SPOOL_MIRROR_SEATS LOOKUP_FAIL="$1" LOOKUP_ROOT="$T_TMP/cloud" \
    python3 "$T_TMP/lookup.py" "$MIRROR" post --agent "$ID" --event answer --session "$S" >/dev/null 2>&1
}
reset; brief "$TD"; post prompt "$NOTIFICATION"; answer_lookup 0 "$FINDINGS"
eq "C17. CONTROL: the lookup works and a notification turn posts" "1 $TD" "$(nsends) $(send_arg 0 --task)"
reset; brief "$TD"; post prompt "$NOTIFICATION"; answer_lookup 1 "$FINDINGS"
eq "C17. the second lookup fails: nothing" 0 "$(nsends)"
has "C17. ... and the log says it" "the seats cannot be read" "$(tail -1 "$A/.mirror/mirror.log")"
reset; brief "$TD"; dm_turn "PRIVATE answer"; post prompt "$NOTIFICATION"; answer_lookup 1 "$FINDINGS"
eq "C17. a hold, the second lookup fails: only the DM answer" "1 $TM" "$(nsends) $(send_arg 0 --task)"
reset; brief "$TD"; post prompt "$NOTIFICATION"; dm_pending; answer_lookup 1 "$FINDINGS"
eq "C17. a waiting DM, the second lookup fails: nothing" 0 "$(nsends)"

# --- C18 the second lookup answers, wrongly --------------------------------------
# Another root holding the same agent id reads no record of the seats in hand.
OTHER="$T_TMP/other"; mkdir -p "$OTHER/dev/desk/t1/box-desk/spool/$ID"
reset; brief "$TD"; dm_turn "PRIVATE answer"; post prompt "$NOTIFICATION"; LOOKUP_ROOT2="$OTHER" answer_lookup 0 "$FINDINGS"
eq "C18. a hold, the second lookup names another root: only the DM answer" "1 $TM" "$(nsends) $(send_arg 0 --task)"
has "C18. ... and the log says it" "the seats cannot be read" "$(tail -1 "$A/.mirror/mirror.log")"
reset; brief "$TD"; post prompt "$NOTIFICATION"; dm_pending; LOOKUP_ROOT2="$OTHER" answer_lookup 0 "$FINDINGS"
eq "C18. a waiting DM, the second lookup names another root: nothing" 0 "$(nsends)"
reset; brief "$TD"; post prompt "$NOTIFICATION"; LOOKUP_ROOT2="$T_TMP/cloud" answer_lookup 0 "$FINDINGS"
eq "C18. CONTROL: the second lookup names the same root: it posts" "1 $TD" "$(nsends) $(send_arg 0 --task)"
reset; brief "$TD"; dm_turn "PRIVATE answer"; post prompt "$NOTIFICATION"; LOOKUP_ROOT2="$T_TMP/cloud" answer_lookup 0 "$FINDINGS"
eq "C18. CONTROL: the same root, a hold: only the DM answer" "1 $TM" "$(nsends) $(send_arg 0 --task)"
# A seat whose env is off is not live, and its DM holds all the same.
OFF="$T_TMP/cloud/prd/desk/t9/box-desk"; mkdir -p "$OFF/spool/$ID/inbox"
reset; brief "$TD"; post prompt "$NOTIFICATION"; LOOKUP_GONE="$OFF" answer_lookup 0 "$FINDINGS"
eq "C18. the second lookup misses a seat that is not live: nothing" 0 "$(nsends)"
rm -rf "${OFF:?}.gone" "$T_TMP/cloud/prd"

# Mode bits do not stop root: name the gap rather than pass on a lock that held nothing.
LOCKS=1; mkdir "$T_TMP/lock-probe"; chmod 000 "$T_TMP/lock-probe"
if ls "$T_TMP/lock-probe" >/dev/null 2>&1; then LOCKS=0; echo "skip - C19, C20: mode bits do not bind this user ($(id -u))"; fi
chmod 755 "$T_TMP/lock-probe"
locked() {  # MODE PATH CMD...: run CMD with PATH at MODE, and put it back
  local mode="$1" path="$2"; shift 2
  chmod "$mode" "$path"; "$@"; chmod 755 "$path"
}
hold_on_a2() { mkdir -p "$A2/inbox" "$A2/.mirror"; python3 -c 'import json,sys,time; json.dump({"ts":time.time()},open(sys.argv[1],"w"))' "$A2/.mirror/dm-turn"; }

if [ "$LOCKS" = 1 ]; then
# --- C19 a seat that cannot be listed ------------------------------------------
for lock in "$T_TMP/cloud/dev/desk/t2" "$SEAT2" "$SEAT2/spool"; do
  name="${lock#"$T_TMP"/cloud/dev/desk/}"
  reset; brief "$TD"; hold_on_a2; locked 000 "$lock" turn_notification
  eq "C19. a dm-turn behind $name at mode 000: nothing" 0 "$(nsends)"
  has "C19. ... and the log says it" "the seats cannot be read" "$(tail -1 "$A/.mirror/mirror.log")"
  reset; brief "$TD"; mkdir -p "$A2/inbox"; locked 000 "$lock" turn_notification
  eq "C19. no record, $name still cannot be listed: nothing" 0 "$(nsends)"
done
reset; brief "$TD"; hold_on_a2; turn_notification
eq "C19. CONTROL: the same dm-turn, listable: the hold reads it" 0 "$(nsends)"
has "C19. CONTROL: ... as a hold" "a DM turn in the last hour" "$(tail -1 "$A/.mirror/mirror.log")"
reset; brief "$TD"; mkdir -p "$A2/inbox"; turn_notification
eq "C19. CONTROL: no record, listable: it posts" "1 $TD" "$(nsends) $(send_arg 0 --task)"
reset; brief "$TD"; mkdir -p "$A2/inbox"
chmod 000 "$T_TMP/cloud/dev/desk/t2"; dm_turn "PRIVATE answer"; chmod 755 "$T_TMP/cloud/dev/desk/t2"
eq "C19. a DM answer still goes out past an unlistable seat" "1 $TM" "$(nsends) $(send_arg 0 --task)"
# What the lookup never needed: none of these can hold a seat of this agent.
reset; brief "$TD"; printf 'x' >"$T_TMP/cloud/a-file"; mkdir -p "$T_TMP/cloud/nodesk" "$T_TMP/cloud/dev/desk/empty"
mkdir -p "$T_TMP/cloud/.hidden"; chmod 000 "$T_TMP/cloud/.hidden"; turn_notification
eq "C19. CONTROL: a file, a dir with no desk, an empty workspace, a hidden dir: it posts" "1 $TD" "$(nsends) $(send_arg 0 --task)"
chmod 755 "$T_TMP/cloud/.hidden"; rm -rf "$T_TMP/cloud/a-file" "$T_TMP/cloud/nodesk" "$T_TMP/cloud/dev/desk/empty" "$T_TMP/cloud/.hidden"

# --- C20 a trigger dir that cannot be read -------------------------------------
for m in 000 300; do
  reset; brief "$TD"; post prompt "$NOTIFICATION"; mkdir -p "$A/.mirror/trigger"; locked "$m" "$A/.mirror/trigger" post answer "$FINDINGS"
  eq "C20. the trigger dir at mode $m: nothing" 0 "$(nsends)"
  has "C20. ... and the log says it" "a person's DM has no turn yet" "$(tail -1 "$A/.mirror/mirror.log")"
done
reset; brief "$TD"; mkdir -p "$A2/.mirror/trigger"; locked 000 "$A2/.mirror/trigger" turn_notification
eq "C20. the other seat's trigger dir cannot be read: nothing" 0 "$(nsends)"
reset; brief "$TD"; trig dm HUM-9 "$TM" "a person's dm"; chmod 000 "$A/.mirror/trigger"
post prompt "a person's dm"; post answer "PRIVATE answer"; chmod 755 "$A/.mirror/trigger"
eq "C20. a DM behind that dir, which no prompt can take: nothing reaches the channel" 0 "$(grep -l -- "$TD" "$SENDS"/* 2>/dev/null | wc -l | tr -d ' ')"
fi
reset; brief "$TD"; post prompt "$NOTIFICATION"; mkdir -p "$A/.mirror/trigger"; post answer "$FINDINGS"
eq "C20. CONTROL: an empty trigger dir: it posts" "1 $TD" "$(nsends) $(send_arg 0 --task)"
reset; brief "$TD"; post prompt "$NOTIFICATION"; rm -rf "$A/.mirror/trigger"; post answer "$FINDINGS"
eq "C20. CONTROL: an absent trigger dir is no hold: it posts" "1 $TD" "$(nsends) $(send_arg 0 --task)"
eq "C20. CONTROL: an absent agent dir is no hold" "False" "$(python3 -c 'import sys,time; sys.path.insert(0,sys.argv[1]); import spool_discussion as sd; print(sd.dm_waiting(sys.argv[2],time.time()))' "$T_SCRIPTS/../lib" "$T_TMP/no-such-agent")"
# A record a prompt takes between the listing and the read is gone, not unread.
reset; mkdir -p "$A/.mirror/trigger"; printf '{"kind":"dm"}' >"$A/.mirror/trigger/taken"
eq "C20. CONTROL: a record taken since the listing is no hold" "False" "$(python3 - "$T_SCRIPTS/../lib" "$A" <<'TAKEN'
import os, sys, time
sys.path.insert(0, sys.argv[1])
import spool_discussion as sd
real = os.path.getmtime
def taken(p):
    os.unlink(p)
    return real(p)
os.path.getmtime = taken
print(sd.dm_waiting(sys.argv[2], time.time()))
TAKEN
)"

# --- C14 a corrupt seen-list --------------------------------------------------
reset; mkdir -p "$A/.mirror"; printf '{"x":"not a number"}' >"$A/.mirror/discussions"
trig channel HUM-9 "$TD" "line one"
printf '%s' "line one" | python3 "$MIRROR" post --agent "$ID" --event prompt --session "$S" >/dev/null 2>&1
eq "C14. a corrupt seen-list does not fail the prompt" 0 "$?"
if [ -f "$A/.mirror/turn" ]; then ok "C14. ... the turn is still recorded"; else nok "C14. the turn was lost"; fi
has "C14. ... and the log says it" "discussion: FAIL" "$(cat "$A/.mirror/mirror.log")"

# --- C15 the role-seat pin ----------------------------------------------------
eq "C15. is_role_seat agrees with SPL_ROLE_SEAT_RX" "agree" "$(python3 - "$T_SCRIPTS/../lib" <<'PIN'
import re, string, sys
sys.path.insert(0, sys.argv[1])
import spool_discussion as sd
rx = next(l.split("'")[1] for l in open(sys.argv[1] + "/spool-env.inc.sh") if l.startswith("SPL_ROLE_SEAT_RX='"))
ids = ["%s-%03d" % (c, n) for c in string.ascii_lowercase for n in range(0, 12)]
bad = [i for i in ids if bool(re.fullmatch(rx, i)) != sd.is_role_seat(i)]
print("agree" if not bad else "differ: " + " ".join(bad))
PIN
)"

# --- C11 the rate cap ---------------------------------------------------------
switch true 2; reset; brief "$TD"
for i in 1 2 3 4; do turn_notification "$FINDINGS number $i"; done
eq "C11. the cap holds" 2 "$(nsends)"
eq "C11. ... and logs each skip" 2 "$(grep -c 'discussion: rate cap' "$A/.mirror/mirror.log")"
python3 -c 'import json,sys,time
p=sys.argv[1]; d=json.load(open(p)); d["posts"]=[time.time()-3700 for _ in d["posts"]]; json.dump(d,open(p,"w"))' "$A/.mirror/discussion-rate"
turn_notification "$FINDINGS number 5"
eq "C11. the hour passes: it posts again" 3 "$(nsends)"
has "C11. ... and says what it skipped" "2 turns" "$(send_body 2)"
switch true

t_done
