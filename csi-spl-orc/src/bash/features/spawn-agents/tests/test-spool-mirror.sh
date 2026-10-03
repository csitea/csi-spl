#!/usr/bin/env bash
# test-spool-mirror.sh — the terminal -> web UI mirror (specs/036).
#
#   1. redaction: every secret class is replaced, and the counts name it.
#      CONTROL: ordinary prose passes through byte for byte
#   2. the hook reads Claude Code's snake_case AND grok's camelCase payloads,
#      skips subagents and grok's session-end Stop, and exits 0 on garbage
#   3. spec 067 L2: a prompt is NEVER posted (echo kinds A-D); it records the
#      turn's trigger from the notifier's trigger record. A DM-triggered turn's
#      answer goes into THAT DM; a channel-triggered, agent-poked, terminal or
#      task-notification turn posts nothing. CONTROL: the same answer after a
#      DM trigger is posted (the check can fail)
#   4. the echo kinds: a typed web UI line (A), a peer's poke line (B), a
#      terminal prompt (C) and a task notification (D) are not posted
#   4b. owner no-filler rule: a status-only answer (watcher, lease, poll,
#      inbox, waiting) is not posted even on a DM-triggered turn; spinner and
#      tool-progress lines are cut from a real answer. CONTROL: a real answer
#      that mentions a lease is posted
#   5. an answer is posted once per session: the same text again is skipped;
#      one DM trigger answers one turn
#   6. the topic and the human come from the trigger, not from the last DM
#      (.mirror/peer) nor the desk's mirror-to
#   7. a planted secret in an answer reaches `spool send` redacted
#   8. .no-mirror opts a seat out; an agent with no seat posts nothing
#   9. the notifier's records: a HUMAN's DIRECT message sets the peer; a
#      channel broadcast (to ALL-0) and an agent's message do not; each typed
#      line gets a trigger record: dm, channel or task
#  10. hook -> post end to end, through SPOOL_MIRROR_POST, notifier records
#      included: a DM's answer reaches that DM, a channel post's answer nothing
#  12. operator: the subcommand still records the desk's operator; no post
#      ever carries --typed-by
#  13. the hook's box user comes from SPOOL_BOX_USER / the checkout root, not
#      the script's file owner (an agent-side git op makes that the agent)
#  14. no literal human id: no DM trigger -> skipped + logged, whatever the
#      desk's mirror-to / SPOOL_MIRROR_TO say
#  15. agy: prompt/answer read from the transcript the hook names; prints {}
#  16. CLI-injected content (system-reminder, task-notification, restart
#      notices) is stripped; an injection-only prompt still starts a turn, as
#      no DM's
#  17. a FIXTURE claude session end to end, hook -> post: the answer to a DM
#      arrives in the DM, the prompt and tool output (PreToolUse/PostToolUse)
#      do not, a password in the answer is redacted; $SPOOL_ROOT/.mirror-off
#      stops every post, live sessions included
#  11. two hook configs reaching one session (shared settings + a wrapper's
#      --settings) record one prompt and post one answer once
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.inc.sh"
t_sandbox
# The test names every id and mirror knob it uses. A session started through
# spool-agent exports SPOOL_AGENT_ID (it wins over MCP_BOT_AGENT_ID in the
# hook), so ambient values made case 10 post as the CALLER's agent (measured by
# CLE-34980, tree 591a893f, run as the agent user).
unset SPOOL_AGENT_ID MCP_BOT_AGENT_ID SPOOL_MIRROR_TO SPOOL_MIRROR_POST SPOOL_MIRROR_SYNC SPOOL_MIRROR_DRY SPOOL_MIRROR_SPOOL

MIRROR="$T_SCRIPTS/spool-mirror.py"
REDACT="$T_FEAT/lib/spool_redact.py"
SEAT="$T_TMP/cloud/dev/desk/t1/box-desk"
A="$SEAT/spool/CLE-7"
mkdir -p "$A/inbox" "$SEAT/spool/.hub" "$SEAT/keys" "$T_TMP/cloud/dev/bin"
echo HUM-9 >"$SEAT/mirror-to"   # the desk's human: ids are per env, never a literal default
T1=11111111-1111-4111-8111-111111111111
T2=22222222-2222-4222-8222-222222222222
T3=33333333-3333-4333-8333-333333333333

# A live "sidecar" whose environment carries the hub url, as the real one does.
env SPOOL_HUB_URL=https://hub.example.test SPOOL_TENANT=t1 SPOOL_BOX_ID=box-desk sleep 300 &
SIDECAR=$!
echo "$SIDECAR" >"$SEAT/spool/.hub/hub-run.pid"
trap 'kill $SIDECAR 2>/dev/null; t_cleanup' EXIT

# The spool stub: records argv (one per line) and the hub env, prints send JSON.
SENDS="$T_TMP/sends"; mkdir -p "$SENDS"
cat >"$T_TMP/cloud/dev/bin/spool" <<EOF
#!/usr/bin/env bash
n=\$(ls "$SENDS" | wc -l)
{ printf '%s\n' "\$@"; echo "HUB=\$SPOOL_HUB_URL ROOT=\$SPOOL_ROOT"; } >"$SENDS/\$n"
task=$T3
prev=""; for a in "\$@"; do [ "\$prev" = --task ] && task="\$a"; prev="\$a"; done
case " \$* " in *" --typed-by "*)
  [ "\${STUB_TYPED:-}" = unbound ] && { echo "spool: hub refused: typed_by_not_bound (403)" >&2; exit 1; }
  [ "\${STUB_TYPED:-}" = oldbin ] && { echo "flag provided but not defined: -typed-by" >&2; exit 2; } ;;
esac
printf '{"msg_id":"m-%s","task_id":"%s"}\n' "\$n" "\$task"
EOF
chmod +x "$T_TMP/cloud/dev/bin/spool"
export SPOOL_MIRROR_SEATS="$T_TMP/cloud/*/desk/*/*"

post() {  # EVENT TEXT [SESSION]
  printf '%s' "$2" | python3 "$MIRROR" post --agent CLE-7 --event "$1" --session "${3:-s1}"
}
nsends() { ls "$SENDS" | wc -l | tr -d ' '; }
last_send() { cat "$SENDS/$(( $(nsends) - 1 ))"; }
body_of_last() { last_send | awk 'p{print; exit} $0=="--body"{p=1}'; }
# The notifier's trigger record for LINE, as spool_notify_mark_trigger writes it.
trig() {  # KIND FROM TASK LINE
  mkdir -p "$A/.mirror/trigger"
  python3 -c 'import json,sys; print(json.dumps(dict(zip(("kind","from","task","msg","line"), sys.argv[1:]))))' \
    "$1" "$2" "$3" "m-$RANDOM" "$4" >"$A/.mirror/trigger/$(date +%s%N)-$RANDOM"
}
# One whole turn: the desk types LINE (with its trigger), the agent answers.
turn() {  # KIND FROM TASK LINE ANSWER SESSION
  trig "$1" "$2" "$3" "$4"
  post prompt "$4" "$6" >/dev/null
  post answer "$5" "$6" >/dev/null
}

# --- 1. redaction -------------------------------------------------------------
GH="ghp_$(printf 'a%.0s' {1..24})"; SL="xoxb-$(printf '1%.0s' {1..12})"
AWS="AKIA$(printf 'B%.0s' {1..16})"; JWT="eyJ$(printf 'x%.0s' {1..12}).$(printf 'y%.0s' {1..12}).$(printf 'z%.0s' {1..12})"
in="gh $GH slack $SL aws $AWS jwt $JWT dsn postgres://u:hunter2x@db pw=supersecret1"
out="$(printf '%s' "$in" | python3 "$REDACT" 2>"$T_TMP/counts")"
for s in "$GH" "$SL" "$AWS" "$JWT" hunter2x supersecret1; do hasnt "1. redacts ${s:0:6}…" "$s" "$out"; done
has "1. names the github class" '"github-token": 1' "$(cat "$T_TMP/counts")"
has "1. names the assignment class" '"assignment": 1' "$(cat "$T_TMP/counts")"
prose="Ship it on Friday: the PR is green, 3 files changed."
eq "1. CONTROL: prose is untouched" "$prose" "$(printf '%s' "$prose" | python3 "$REDACT" 2>/dev/null)"

# --- 2. the hook payloads -----------------------------------------------------
hx() { python3 -c 'import importlib.util,json,sys
s=importlib.util.spec_from_file_location("m",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(json.dumps(m.hook_extract(json.loads(sys.argv[2]))))' "$MIRROR" "$1"; }
eq "2. claude UserPromptSubmit -> prompt" '["prompt", "hi", "S"]' "$(hx '{"hook_event_name":"UserPromptSubmit","session_id":"S","prompt":"hi"}')"
eq "2. claude Stop -> answer" '["answer", "done", "S"]' "$(hx '{"hook_event_name":"Stop","session_id":"S","last_assistant_message":"done"}')"
eq "2. grok Stop (camelCase) -> answer" '["answer", "ok", "G"]' "$(hx '{"hook_event_name":"Stop","sessionId":"G","lastAssistantMessage":"ok","reason":"end_turn"}')"
eq "2. grok session-end Stop is skipped" 'null' "$(hx '{"hook_event_name":"Stop","lastAssistantMessage":"ok","reason":"shutdown"}')"
eq "2. a subagent's Stop is skipped" 'null' "$(hx '{"hook_event_name":"Stop","lastAssistantMessage":"ok","subagentType":"explore"}')"
eq "2. an empty prompt is skipped" 'null' "$(hx '{"hook_event_name":"UserPromptSubmit","prompt":"   "}')"
printf 'not json' | MCP_BOT_AGENT_ID=CLE-7 python3 "$MIRROR" hook; eq "2. garbage on stdin still exits 0" 0 "$?"
printf '{"hook_event_name":"UserPromptSubmit","prompt":"x"}' | env -u MCP_BOT_AGENT_ID -u SPOOL_AGENT_ID python3 "$MIRROR" hook
eq "2. no agent id: exit 0, nothing sent" "0 0" "$? $(nsends)"
rid() { python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("m",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.resolve_agent())' "$MIRROR"; }
eq "2. the id is the process env's SPOOL_AGENT_ID" CLE-5 "$(SPOOL_AGENT_ID=CLE-5 MCP_BOT_AGENT_ID=CLE-6 rid)"
eq "2. ...else MCP_BOT_AGENT_ID" CLE-6 "$(MCP_BOT_AGENT_ID=CLE-6 rid)"
eq "2. ...a garbled SPOOL_AGENT_ID falls through to MCP_BOT_AGENT_ID" CLE-6 "$(SPOOL_AGENT_ID=nope MCP_BOT_AGENT_ID=CLE-6 rid)"
eq "2. never a window name: no env, no id (inside tmux or not)" "" "$(TMUX_PANE=%1 rid)"

# --- 3. the answer follows the turn's trigger (spec 067 L2) ------------------
mkdir -p "$A/.mirror/typed"
printf '%s' "hello from the web ui" >"$A/.mirror/typed/1-1"
turn dm HUM-3 "$T1" "hello from the web ui" "the DM answer" t3a
eq "3. a DM-triggered turn: one post, the answer" "1 the DM answer" "$(nsends) $(body_of_last)"
has "3. ... into THAT DM: its human" $'--to\nHUM-3' "$(last_send)"
has "3. ... and its topic" $'--task\n'"$T1" "$(last_send)"
check "3. the typed marker is consumed" test ! -e "$A/.mirror/typed/1-1"
eq "3. the trigger record is consumed" 0 "$(ls "$A/.mirror/trigger" | wc -l | tr -d ' ')"
n3=$(nsends)
turn channel HUM-3 "$T2" "[channel post from HUM-3, topic 22222222] look at this" "channel answer" t3b
eq "3. a channel-triggered turn posts nothing" "$n3" "$(nsends)"
has "3. ... and the log says why" "not started by a DM (channel)" "$(tail -1 "$A/.mirror/mirror.log")"
turn task CLE-1 "$T2" "an agent's message, verbatim" "task answer" t3c
eq "3. a turn from an agent's message posts nothing" "$n3" "$(nsends)"
turn dm HUM-3 "not-a-uuid" "a dm with no topic id" "orphan answer" t3d
eq "3. a dm trigger with no topic id posts nothing" "$n3" "$(nsends)"
turn dm HUM-3 "$T1" "back to the DM" "channel answer" t3e
eq "3. CONTROL: the same answer after a DM trigger IS posted" "$((n3 + 1)) channel answer" "$(nsends) $(body_of_last)"
trig dm HUM-3 "$T1" "a line typed but never submitted"
post prompt "my own terminal words" t3f >/dev/null; post answer "terminal answer" t3f >/dev/null
eq "3. a pending DM trigger does not make a terminal turn a DM's" "$((n3 + 1))" "$(nsends)"
rm -rf "$A/.mirror/trigger"

# --- 4. the echo kinds A-D are never posted -------------------------------------
n4=$(nsends)
printf '%s' "[channel post from HUM-3, topic 11111111] A" >"$A/.mirror/typed/4-1"
post prompt "[channel post from HUM-3, topic 11111111] A" d1 >/dev/null
post prompt ": 'SPOOL CLE-7: task from CLE-1 :: ping :: run: spool recv --as CLE-7'" d2 >/dev/null
post prompt ": 'INBOX CLE-7: read and act on /var/tmp/m/CLE-7/inbox/20260101T000000Z--CLE-001--brief.md'" d3 >/dev/null
post prompt "a prompt typed in the terminal" d4 >/dev/null
post prompt $'<task-notification>\n<task-id>x</task-id>\n</task-notification>' d5 >/dev/null
eq "4. A, B, C and D prompts: nothing posted" "$n4" "$(nsends)"
has "4. a poke line's turn is an agent's" "turn: agent" "$(cat "$A/.mirror/mirror.log")"
has "4. a terminal prompt's turn is the terminal's" "turn: terminal" "$(cat "$A/.mirror/mirror.log")"
post answer "after a poke" d2 >/dev/null
eq "4. ... and their answers neither" "$n4" "$(nsends)"
check "4. the typed marker of an echoed line is still consumed" test ! -e "$A/.mirror/typed/4-1"

# --- 4b. status-only answers are never posted, even to a DM -----------------------
n4b=$(nsends)
# The traced shape: prd msg b3a233f9, 13:47:21Z, a watcher/lease status report.
turn dm HUM-3 "$T1" "q4b1" $'I restarted the watcher on my inbox and the dispatch lease, since the first one had expired. I still hold the lease (c-002@box, renewed 58 s ago), and my inbox is empty.\n\nWaiting on c-001 for five things:\n\n| topic | waiting for |\n|---|---|\n| 77540e6f | status text |' s4b1
turn dm HUM-3 "$T1" "q4b2" "Still waiting on CI for c36a92dc." s4b2
turn dm HUM-3 "$T1" "q4b3" "Inbox is empty; standing by." s4b3
turn dm HUM-3 "$T1" "q4b4" "Lease: c-001@box 12" s4b4
turn dm HUM-3 "$T1" "q4b5" $'\u280b Polling the hub\u2026\n\u23bf  Running\u2026' s4b5
eq "4b. status-only answers (watcher/lease, waiting, inbox, lease line, spinner) post nothing" "$n4b" "$(nsends)"
has "4b. ... and the log says why" "status only" "$(tail -1 "$A/.mirror/mirror.log")"
turn dm HUM-3 "$T1" "q4b6" $'\u25cf Bash(git push)\nPushed: the fix is on master.\n\u280b Working\u2026' s4b6
eq "4b. tool-progress lines are cut, the answer text goes out" "Pushed: the fix is on master." "$(body_of_last)"
turn dm HUM-3 "$T1" "q4b7" "The lease moved to c-001 because yours expired; nothing else changed." s4b7
eq "4b. CONTROL: a real answer that mentions a lease is posted" "The lease moved to c-001 because yours expired; nothing else changed." "$(body_of_last)"

# --- 5. an answer once per session; one trigger, one answer -------------------------
turn dm HUM-3 "$T1" "q5" "the answer" s9; n1=$(nsends)
turn dm HUM-3 "$T1" "q5" "the answer" s9
eq "5. the same answer in one session is posted once" "$n1" "$(nsends)"
turn dm HUM-3 "$T1" "q5" "the answer" s10
eq "5. CONTROL: another session posts it" "$((n1 + 1))" "$(nsends)"
eq "5. an answer is posted verbatim" "the answer" "$(body_of_last)"
post answer "a second answer, no new prompt" s10 >/dev/null
eq "5. one DM trigger answers one turn" "$((n1 + 1))" "$(nsends)"

# --- 6. the topic comes from the trigger ---------------------------------------------
printf '{"to":"HUM-17","task":"%s"}' "$T2" >"$A/.mirror/peer"
turn dm HUM-3 "$T1" "q6" "a6" s20
has "6. the trigger's human wins over the last DM (.mirror/peer)" $'--to\nHUM-3' "$(last_send)"
has "6. the trigger's topic wins" $'--task\n'"$T1" "$(last_send)"
has "6. the post goes to box-wui over the sidecar's hub" "HUB=https://hub.example.test" "$(last_send)"
has "6. the topic it landed in is remembered" "$T1" "$(cat "$A/.mirror/topic")"
rm -f "$A/.mirror/peer"

# --- 7. a planted secret ---------------------------------------------------------------
turn dm HUM-3 "$T1" "q7" "deploy key is $GH ok" s30
b="$(body_of_last)"
hasnt "7. the planted token never reaches spool send" "$GH" "$b"
has "7. it arrives as the redaction marker" "<redacted:github-token>" "$b"

# --- 8. opt-out and unseated ---------------------------------------------------------------
: >"$A/.no-mirror"; n2=$(nsends)
turn dm HUM-3 "$T1" "q8" "quiet" s40
eq "8. .no-mirror: nothing posted" "$n2" "$(nsends)"
rm -f "$A/.no-mirror"
printf 'x' | python3 "$MIRROR" post --agent CLE-99 --event answer >/dev/null
eq "8. an agent with no seat posts nothing" "$n2" "$(nsends)"

# --- 9. the notifier's records -----------------------------------------------------------------
# shellcheck source=../lib/spool-notify.inc.sh
. "$T_FEAT/lib/spool-notify.inc.sh"
export SPOOL_ROOT="$SEAT/spool"
rm -f "$A/.mirror/peer"
printf '{"from":"HUM-3","to":"ALL-0","task_id":"%s"}' "$T1" >"$A/inbox/20260101T000000Z--HUM-3--b-aaaaaaaa.json"
spool_notify_mark_peer CLE-7 HUM-3 "$T1" aaaaaaaa-0000-4000-8000-000000000000
check "9. a channel broadcast does not set the peer" test ! -e "$A/.mirror/peer"
printf '{"from":"CLE-1","to":"CLE-7","task_id":"%s"}' "$T1" >"$A/inbox/20260101T000001Z--CLE-1--c-bbbbbbbb.json"
spool_notify_mark_peer CLE-7 CLE-1 "$T1" bbbbbbbb-0000-4000-8000-000000000000
check "9. an agent's message does not set the peer" test ! -e "$A/.mirror/peer"
printf '{"from":"HUM-3","to":"CLE-7","task_id":"%s"}' "$T1" >"$A/inbox/20260101T000002Z--HUM-3--d-cccccccc.json"
spool_notify_mark_peer CLE-7 HUM-3 "$T1" cccccccc-0000-4000-8000-000000000000
has "9. a human's DM sets the peer" "\"to\":\"HUM-3\",\"task\":\"$T1\"" "$(cat "$A/.mirror/peer" 2>/dev/null)"
spool_notify_mark_typed CLE-7 "typed by the desk"
eq "9. mark_typed records the exact line" "typed by the desk" "$(cat "$A/.mirror/typed/"* 2>/dev/null)"
rm -rf "$A/.mirror/trigger"
SPOOL_POKE_LINE="typed by the desk" spool_notify_mark_peer CLE-7 HUM-3 "$T1" cccccccc-0000-4000-8000-000000000000
tr9="$(cat "$A/.mirror/trigger/"* 2>/dev/null)"; rm -rf "$A/.mirror/trigger"
has "9. a human's DM line: a dm trigger" '"kind":"dm","from":"HUM-3","task":"'"$T1"'"' "$tr9"
has "9. ... naming the typed line" '"line":"typed by the desk"' "$tr9"
SPOOL_POKE_LINE="[channel post from HUM-3] x" spool_notify_mark_peer CLE-7 HUM-3 "$T1" aaaaaaaa-0000-4000-8000-000000000000
has "9. a channel broadcast: a channel trigger" '"kind":"channel"' "$(cat "$A/.mirror/trigger/"* 2>/dev/null)"; rm -rf "$A/.mirror/trigger"
SPOOL_POKE_LINE="from an agent" spool_notify_mark_peer CLE-7 CLE-1 "$T1" bbbbbbbb-0000-4000-8000-000000000000
has "9. an agent's message: a task trigger" '"kind":"task"' "$(cat "$A/.mirror/trigger/"* 2>/dev/null)"; rm -rf "$A/.mirror/trigger"
SPOOL_POKE_LINE='say "hi" \ back' spool_notify_mark_peer CLE-7 HUM-3 "$T1" cccccccc-0000-4000-8000-000000000000
eq "9. the record is JSON, quotes and backslashes intact" 'say "hi" \ back' \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["line"])' "$A/.mirror/trigger/"*)"
rm -rf "$A/.mirror/trigger"
spool_notify_mark_peer CLE-7 HUM-3 "$T1" cccccccc-0000-4000-8000-000000000000
check "9. nothing typed (no SPOOL_POKE_LINE): no trigger" test ! -e "$A/.mirror/trigger"

# --- 10. hook -> post end to end ------------------------------------------------------------------
hook() { MCP_BOT_AGENT_ID=CLE-7 SPOOL_MIRROR_SYNC=1 SPOOL_MIRROR_POST="python3 $MIRROR" python3 "$MIRROR" hook; }
n3=$(nsends)
SPOOL_POKE_LINE="typed by the desk" spool_notify_mark_peer CLE-7 HUM-3 "$T1" cccccccc-0000-4000-8000-000000000000
printf '{"hook_event_name":"UserPromptSubmit","session_id":"E","prompt":"typed by the desk"}' | hook
eq "10. hook: the desk's own line is not echoed" "$n3" "$(nsends)"
printf '{"hook_event_name":"Stop","session_id":"E","last_assistant_message":"all done"}' | hook
eq "10. hook: the DM's answer is posted" "all done" "$(body_of_last)"
has "10. ... into that DM's topic" $'--task\n'"$T1" "$(last_send)"
has "10. the seat log records it" "OK answer -> HUM-3 task $T1" "$(cat "$A/.mirror/mirror.log")"
n10=$(nsends)
SPOOL_POKE_LINE="[channel post from HUM-3] ship it" spool_notify_mark_peer CLE-7 HUM-3 "$T1" aaaaaaaa-0000-4000-8000-000000000000
printf '{"hook_event_name":"UserPromptSubmit","session_id":"E","prompt":"[channel post from HUM-3] ship it"}' | hook
printf '{"hook_event_name":"Stop","session_id":"E","last_assistant_message":"shipped"}' | hook
eq "10. hook: a channel post's answer is not posted to the DM" "$n10" "$(nsends)"

# --- 11. two hook configs, one session ---------------------------------------------------------
n4=$(nsends)
trig dm HUM-3 "$T1" "said once, heard twice"
post prompt "said once, heard twice" dup1 >/dev/null
post prompt "said once, heard twice" dup1 >/dev/null
has "11. the second prompt is logged as a duplicate hook" "a second hook fired for the same prompt" "$(cat "$A/.mirror/mirror.log")"
post answer "answered once" dup1 >/dev/null
post answer "answered once" dup1 >/dev/null
eq "11. the duplicate prompt did not lose the DM; the answer is posted once" "$((n4 + 1))" "$(nsends)"
has "11. the second answer is logged as a duplicate hook" "a second hook fired for the same answer" "$(cat "$A/.mirror/mirror.log")"

# --- 12. operator: still recorded, never a --typed-by claim ---------------------------------------
MIR="$T_SCRIPTS/spool-mirror.py"
python3 "$MIR" operator "$SEAT" HUM-5 >/dev/null
eq "12. operator <desk> writes the desk operator" "HUM-5" "$(cat "$SEAT/operator")"
python3 "$MIR" operator "$A" HUM-6 >/dev/null
eq "12. operator <seat> writes the seat operator" "HUM-6" "$(cat "$A/.mirror/operator")"
turn dm HUM-3 "$T1" "q12" "answers never carry it" op3
eq "12. CONTROL: the answer is posted" "answers never carry it" "$(body_of_last)"
hasnt "12. ... with no --typed-by" "--typed-by" "$(last_send)"
python3 "$MIR" operator "$A" --clear >/dev/null; python3 "$MIR" operator "$SEAT" --clear >/dev/null
check "12. --clear removes both" test ! -e "$SEAT/operator" -a ! -e "$A/.mirror/operator"
python3 "$MIR" operator "$SEAT" CLE-1 >/dev/null 2>&1; eq "12. an agent id is refused as operator" 64 "$?"

# --- 13. the box user is not taken from the script file's owner -------------------------------------
bu() { python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("m",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.box_user(sys.argv[2]))' "$MIR" "$1"; }
mkdir -p "$T_TMP/co/.git" "$T_TMP/co/a/b"; : >"$T_TMP/co/a/b/x.py"
eq "13. SPOOL_BOX_USER wins" "someone" "$(SPOOL_BOX_USER=someone bu "$T_TMP/co/a/b/x.py")"
eq "13. else the owner of the checkout root (.git)" "$(stat -c %U "$T_TMP/co")" "$(env -u SPOOL_BOX_USER bash -c "$(declare -f bu); MIR='$MIR' bu '$T_TMP/co/a/b/x.py'")"
has "13. CONTROL: the resolver looks for .git, not the file owner" "os.path.join(d, \".git\")" "$(cat "$MIR")"

# --- 14. no literal human: no DM trigger -> skipped, never a guessed id ---------------------------------
rm -f "$A/.mirror/peer" "$A/.mirror/topic"; n6=$(nsends)
post prompt "nobody DMed" s99 >/dev/null
SPOOL_MIRROR_TO=HUM-8 post answer 'nobody to tell' s99 >/dev/null
eq "14. desk mirror-to and SPOOL_MIRROR_TO set, no DM trigger: nothing is sent" "$n6" "$(nsends)"
has "14. ... and the log says why" "not started by a DM" "$(tail -1 "$A/.mirror/mirror.log")"
has "14. CONTROL: the mirror carries no literal human id" "0" "$(grep -c '\"HUM-9\"' "$MIRROR")"

# --- 15. agy: the hook payload carries no text; the transcript does ---------------------------------------
TR="$T_TMP/agy-transcript.jsonl"
printf '%s\n' '{"type":"USER_INPUT","source":"USER_EXPLICIT","content":"<USER_REQUEST>\nold question\n</USER_REQUEST>"}' \
  '{"type":"PLANNER_RESPONSE","source":"MODEL","content":"old answer"}' \
  '{"type":"USER_INPUT","source":"USER_EXPLICIT","content":"<USER_REQUEST>\nnew question\n</USER_REQUEST>\n<ADDITIONAL_METADATA>x</ADDITIONAL_METADATA>"}' \
  '{"type":"PLANNER_RESPONSE","source":"MODEL","content":"new answer"}' >"$TR"
ax() { python3 -c 'import importlib.util,json,sys
s=importlib.util.spec_from_file_location("m",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(json.dumps(m.agy_extract(json.loads(sys.argv[2]), sys.argv[3])))' "$MIRROR" "$1" "$2"; }
eq "15. agy pre (invocation 0): the newest USER_REQUEST" '["prompt", "new question", "C1"]' "$(ax '{"conversationId":"C1","invocationNum":0,"transcriptPath":"'"$TR"'"}' pre)"
eq "15. agy pre, a later invocation of the same turn: nothing" 'null' "$(ax '{"conversationId":"C1","invocationNum":2,"transcriptPath":"'"$TR"'"}' pre)"
eq "15. agy stop: the answer after the newest USER_INPUT" '["answer", "new answer", "C1"]' "$(ax '{"conversationId":"C1","terminationReason":"NO_TOOL_CALL","error":"","transcriptPath":"'"$TR"'"}' stop)"
eq "15. agy stop on an error: nothing" 'null' "$(ax '{"conversationId":"C1","error":"boom","transcriptPath":"'"$TR"'"}' stop)"
eq "15. the agy hook prints {} for agy's loop" '{}' "$(printf '{}' | python3 "$MIRROR" hook --agy stop)"

# --- 16. CLI-injected content is never a person's words (CLE-100, 19:15Z) -----------------------
n7=$(nsends)
trig dm HUM-3 "$T1" "please ship it"
post prompt $'please ship it\n<system-reminder>\nsecret-ish memory index\n</system-reminder>' inj5 >/dev/null
has "16. a real prompt is matched by its typed words, the block stripped" "turn: dm from HUM-3" "$(tail -1 "$A/.mirror/mirror.log")"
post prompt $'<task-notification>\n<task-id>x</task-id>\n</task-notification>' inj5 >/dev/null
post answer "the task finished" inj5 >/dev/null
eq "16. an injection-only prompt starts a turn that is no DM's: nothing posted" "$n7" "$(nsends)"
has "16. ... its turn is logged as cli" "turn: cli" "$(cat "$A/.mirror/mirror.log")"
hx16() { python3 -c 'import importlib.util,json,sys
s=importlib.util.spec_from_file_location("m",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(json.dumps(m.hook_extract(json.loads(sys.argv[2]))))' "$MIRROR" "$1"; }
eq "16. the hook passes an injection-only UserPromptSubmit on EMPTY" '["prompt", "", "S"]' "$(hx16 '{"hook_event_name":"UserPromptSubmit","session_id":"S","prompt":"<task-notification>done</task-notification>"}')"
eq "16. ... and strips the block from a real one" '["prompt", "ship", "S"]' "$(hx16 '{"hook_event_name":"UserPromptSubmit","session_id":"S","prompt":"ship\n<system-reminder>x</system-reminder>"}')"

# --- 17. a fixture session, end to end ------------------------------------------------------
# tests/fixtures/mirror-session.jsonl: one claude hook payload per line, in the
# order a real session fires them (prompt, tool calls, answer). The prompt is a
# human's DM the desk typed: its trigger record is planted first.
n17=$(nsends)
trig dm HUM-3 "$T1" "$(head -1 "$T_FEAT/tests/fixtures/mirror-session.jsonl" | python3 -c 'import json,sys; print(json.load(sys.stdin)["prompt"])')"
while IFS= read -r ev; do
  printf '%s' "$ev" | SPOOL_AGENT_ID=CLE-7 SPOOL_MIRROR_SYNC=1 SPOOL_MIRROR_POST="python3 $MIRROR" python3 "$MIRROR" hook
done <"$T_FEAT/tests/fixtures/mirror-session.jsonl"
eq "17. exactly one post: the answer" "$((n17 + 1))" "$(nsends)"
all17="$(for i in $(seq "$n17" $(( $(nsends) - 1 ))); do cat "$SENDS/$i"; done)"
hasnt "17. the prompt never arrives" "deploy the hub to dev" "$all17"
has "17. the final answer arrives in the DM" "Deployed to dev; /version is current." "$all17"
has "17. ... that DM" $'--task\n'"$T1" "$all17"
hasnt "17. tool input never arrives" "gcloud run deploy" "$all17"
hasnt "17. tool output never arrives" "Service URL" "$all17"
hasnt "17. the typed password never arrives" "Tr0ub4dor" "$all17"
turn dm HUM-3 "$T1" "q17" "login: password: hunter2 and the key AKIA$(printf 'B%.0s' $(seq 16))" s17h
eq "17. OWNER RULE: password: hunter2 mirrors as password: [redacted]" "login: password: [redacted] and the key <redacted:aws-key-id>" "$(body_of_last)"
has "17. the seat log counts the redaction" "redactions {" "$(tail -1 "$A/.mirror/mirror.log")"
turn dm HUM-3 "$T1" "q17c" "password reset flow works" s17c
eq "17. CONTROL: an ordinary answer mirrors unchanged" "password reset flow works" "$(body_of_last)"
n17=$(nsends)
mkdir -p "$T_TMP/box-root"; : >"$T_TMP/box-root/.mirror-off"
trig dm HUM-3 "$T1" "q17d"
for ev in '{"hook_event_name":"UserPromptSubmit","session_id":"F17","prompt":"q17d"}' \
          '{"hook_event_name":"Stop","session_id":"F17","last_assistant_message":"switched off"}'; do
  printf '%s' "$ev" | SPOOL_ROOT="$T_TMP/box-root" SPOOL_AGENT_ID=CLE-7 SPOOL_MIRROR_SYNC=1 SPOOL_MIRROR_POST="python3 $MIRROR" python3 "$MIRROR" hook
done
eq "17. \$SPOOL_ROOT/.mirror-off: nothing posted, exit 0" "0 $n17" "$? $(nsends)"

t_done
