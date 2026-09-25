#!/usr/bin/env bash
# test-spool-mirror.sh — the terminal -> web UI mirror (specs/036).
#
#   1. redaction: every secret class is replaced, and the counts name it.
#      CONTROL: ordinary prose passes through byte for byte
#   2. the hook reads Claude Code's snake_case AND grok's camelCase payloads,
#      skips subagents and grok's session-end Stop, and exits 0 on garbage
#   3. a prompt the desk TYPED (a web UI message) is not posted back - whole,
#      or as one line of a merged queue - and its marker is consumed, so the
#      same words typed later by a person ARE posted. CONTROL: a prompt with no
#      marker is posted, prefixed [terminal]
#   4. doorbell lines (: 'SPOOL …, INBOX <ID>:) are machine text, never posted
#   5. an answer is posted once per session: the same text again is skipped
#   6. the topic: the peer file (the human's last DM) wins; else the mirror's
#      own topic; else none, and the minted one is remembered
#   7. a planted secret in an answer reaches `spool send` redacted
#   8. .no-mirror opts a seat out; an agent with no seat posts nothing
#   9. the notifier's records: a HUMAN's DIRECT message sets the peer; a
#      channel broadcast (to ALL-0) and an agent's message do not
#  10. hook -> post end to end, through SPOOL_MIRROR_POST
#  11. two hook configs reaching one session (shared settings + a wrapper's
#      --settings) post one prompt once
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.inc.sh"
t_sandbox

MIRROR="$T_SCRIPTS/spool-mirror.py"
REDACT="$T_FEAT/lib/spool_redact.py"
SEAT="$T_TMP/cloud/dev/desk/t1/box-desk"
A="$SEAT/spool/CLE-7"
mkdir -p "$A/inbox" "$SEAT/spool/.hub" "$SEAT/keys" "$T_TMP/cloud/dev/bin"
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
printf '{"hook_event_name":"UserPromptSubmit","prompt":"x"}' | env -u MCP_BOT_AGENT_ID -u SPOOL_AGENT_ID SPOOL_MIRROR_DISCOVER=0 python3 "$MIRROR" hook
eq "2. no agent id: exit 0, nothing sent" "0 0" "$? $(nsends)"
python3 -c '
import importlib.util, sys
s = importlib.util.spec_from_file_location("m", sys.argv[1])
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
rows = ["2712855 pane: GRK-333 ! title", "9 pane: CLE-1 x"]
assert m.agent_from_window_rows([1, 2712855], rows) == "GRK-333"
assert m.agent_from_window_rows([1, 2], rows) == ""
' "$MIRROR"
eq "2. a window name yields its agent id" 0 $?

# --- 3. the web UI's own words are not echoed ---------------------------------
mkdir -p "$A/.mirror/typed"
printf '%s' "hello from the web ui" >"$A/.mirror/typed/1-1"
post prompt "hello from the web ui" >/dev/null
eq "3. a typed web UI prompt is not posted" 0 "$(nsends)"
check "3. its marker is consumed" test ! -e "$A/.mirror/typed/1-1"
printf '%s' "second web line" >"$A/.mirror/typed/2-1"
post prompt $'second web line\nand my own terminal words' >/dev/null
eq "3. a merged queue posts only the terminal line" "[terminal] and my own terminal words" "$(body_of_last)"
post prompt "hello from the web ui" >/dev/null
eq "3. CONTROL: the same words typed later are posted" "[terminal] hello from the web ui" "$(body_of_last)"
old="$A/.mirror/typed/3-1"; printf '%s' "stale words" >"$old"; touch -d '2 hours ago' "$old"
post prompt "stale words" >/dev/null
eq "3. an expired marker no longer suppresses" "[terminal] stale words" "$(body_of_last)"

# --- 4. doorbells ---------------------------------------------------------------
n0=$(nsends)
post prompt ": 'SPOOL CLE-7: task from CLE-1 :: ping :: run: spool recv --as CLE-7'" >/dev/null
post prompt "INBOX CLE-7: new message /var/tmp/x.md" >/dev/null
eq "4. doorbell lines are not posted" "$n0" "$(nsends)"

# --- 5. an answer once per session ------------------------------------------------
post answer "the answer" s9 >/dev/null; n1=$(nsends)
post answer "the answer" s9 >/dev/null
eq "5. the same answer in one session is posted once" "$n1" "$(nsends)"
post answer "the answer" s10 >/dev/null
eq "5. CONTROL: another session posts it" "$((n1 + 1))" "$(nsends)"
eq "5. an answer is posted verbatim" "the answer" "$(body_of_last)"

# --- 6. the topic -------------------------------------------------------------------
rm -f "$A/.mirror/topic" "$A/.mirror/peer"
post answer "a1" s20 >/dev/null
hasnt "6. no peer, no topic: no --task (the hub mints one)" "--task" "$(last_send)"
has "6. ... to the default human" $'--to\nHUM-9' "$(last_send)"
has "6. the minted topic is remembered" "$T3" "$(cat "$A/.mirror/topic")"
post answer "a2" s20 >/dev/null
has "6. the next post reuses it" $'--task\n'"$T3" "$(last_send)"
printf '{"to":"HUM-17","task":"%s"}' "$T2" >"$A/.mirror/peer"
post answer "a3" s20 >/dev/null
has "6. the peer (the human's last DM) wins: human" $'--to\nHUM-17' "$(last_send)"
has "6. the peer wins: topic" $'--task\n'"$T2" "$(last_send)"
has "6. the post goes to box-wui over the sidecar's hub" "HUB=https://hub.example.test" "$(last_send)"

# --- 7. a planted secret ---------------------------------------------------------------
post answer "deploy key is $GH ok" s30 >/dev/null
b="$(body_of_last)"
hasnt "7. the planted token never reaches spool send" "$GH" "$b"
has "7. it arrives as the redaction marker" "<redacted:github-token>" "$b"

# --- 8. opt-out and unseated ---------------------------------------------------------------
: >"$A/.no-mirror"; n2=$(nsends)
post answer "quiet" s40 >/dev/null
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

# --- 10. hook -> post end to end ------------------------------------------------------------------
n3=$(nsends)
printf '{"hook_event_name":"UserPromptSubmit","session_id":"E","prompt":"typed by the desk"}' |
  MCP_BOT_AGENT_ID=CLE-7 SPOOL_MIRROR_SYNC=1 SPOOL_MIRROR_POST="python3 $MIRROR" python3 "$MIRROR" hook
eq "10. hook: the desk's own line is not echoed" "$n3" "$(nsends)"
printf '{"hook_event_name":"Stop","session_id":"E","last_assistant_message":"all done"}' |
  MCP_BOT_AGENT_ID=CLE-7 SPOOL_MIRROR_SYNC=1 SPOOL_MIRROR_POST="python3 $MIRROR" python3 "$MIRROR" hook
eq "10. hook: the answer is posted" "all done" "$(body_of_last)"
has "10. ... into the peer's topic" $'--task\n'"$T1" "$(last_send)"
has "10. the seat log records it" "OK answer -> HUM-3 task $T1" "$(cat "$A/.mirror/mirror.log")"

# --- 11. two hook configs, one session ---------------------------------------------------------
n4=$(nsends)
post prompt "said once, heard twice" dup1 >/dev/null
post prompt "said once, heard twice" dup1 >/dev/null
eq "11. the same prompt of one session, fired by two hooks, is posted once" "$((n4 + 1))" "$(nsends)"
has "11. the second is logged as a duplicate hook" "a second hook fired" "$(cat "$A/.mirror/mirror.log")"
post prompt "said once, heard twice" dup2 >/dev/null
eq "11. CONTROL: another session posts the same words" "$((n4 + 2))" "$(nsends)"

t_done
