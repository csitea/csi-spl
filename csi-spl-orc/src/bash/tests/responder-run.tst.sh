#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_responder_run (SPL-1265 / epic SPL-1238) — the non-AI
#          responder. It validates its ids, stays offline in a dry run, and
#          treats every HUM-* message in the responder's channel-less inbox as an
#          escalation to answer (and nothing else). No cloud call, no spool
#          binary: the desk spool + reply legs are stubbed.
#   1. a bad DESK_AGENT / RESP_FORWARD_TO is refused; the defaults pass
#   2. dry run: for a canned inbox of two HUM escalations + one box message,
#      it says it WOULD reply+file+ack the TWO humans only, and makes NO real
#      reply/send (the stub reply is never called)
#   3. RESP_SEEN_REPLY=1 DRY_RUN=0: it calls do_spl_desk_reply once per topic
#   4. (RESP_SEEN_REPLY=1) CLE-77847: five posts in ONE topic, swept 4 times (the inbox re-delivered
#      each time) -> exactly ONE "Seen" reply; a lost ledger with the "Seen"
#      still in the outbox -> no second reply; a held lock -> no reply at all
#   5. the DEFAULT (owner HUM-10, 2026-10-03, t1 02800102: an ack-only post
#      adds nothing for the human): DRY_RUN=0 posts NO reply in the topic,
#      still files each escalation to the orchestrator; a bad
#      RESP_SEEN_REPLY is refused
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
# shellcheck source=../../../lib/bash/funcs/spl-desk-agents.func.sh
. "$PROJ_ROOT/lib/bash/funcs/spl-desk-agents.func.sh"
fails=0
mkdir -p "$T/state/dev/desk/t1/box-rsp/spool"

# The forward to the orchestrator (b) is a stub that logs its argv. Before
# CLE-77923 it was the real spool-send.sh against the real spool root: every
# run filed the t-aaa/t-bbb/t-ddd fixtures into c-001's live inbox and rang
# its pane. SPOOL_TEST=1 + a sandbox SPOOL_ROOT are the second fence, so a
# send that escapes the stub is refused rather than delivered.
cat >"$T/send.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SEND_LOG"
SH
mkdir -p "$T/spool"

# in_resp sources the funcs with every cloud/spool leg stubbed. spl_desk_spool
# emits a canned inbox on recv and 0 RSP rows on hub-rsp (no other machine:
# the cross-machine case is responder-cross-box.tst.sh); do_spl_desk_reply
# logs a call instead of posting.
in_resp() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" \
    SPOOL_TEST=1 SPOOL_ROOT="$T/spool" SPOOL_BOX_ENV="$T/spool/box.env" SPOOL_TMUX_SOCKET="$T/no-tmux.sock" \
    SPOOL_FLEET_RELAY=0 RESP_SEND="$T/send.sh" \
    REPLY_LOG="$T/reply.log" SEND_LOG="$T/send.log" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_STATE_DIR="'"$T"'/state/dev"; SPL_CNF="'"$T"'/env.yaml"; SPL_ORG_APP="csi-spl"; export SPL_STATE_DIR SPL_CNF SPL_ORG_APP; return 0; }
    yq() { echo "api.example.net"; }
    spl_host_spool() { return 0; }
    spl_desk_spool() { case "$*" in *"-- recv"*) cat "'"$T"'/inbox.json";; *"-- hub-rsp"*) echo "{\"rsp\": 0}";; *) echo "{}";; esac; }
    do_spl_desk_reply() { echo "reply DESK_TO=$DESK_TO DESK_TASK=$DESK_TASK" >>"$REPLY_LOG"; return 0; }
    eval "$SNIPPET"'
}

echo '{}' >"$T/env.yaml"
: >"$T/send.log"

# --- 1. id rules -------------------------------------------------------------------
: >"$T/reply.log"
SNIPPET='do_spl_responder_run' TENANT_ID=t1 DESK_AGENT=cle-00 in_resp >"$T/o" 2>&1 &&
  fail "a lower-case DESK_AGENT reached work" || pass "refuses a bad DESK_AGENT"
SNIPPET='do_spl_responder_run' TENANT_ID=t1 RESP_FORWARD_TO="not-an-id" in_resp >"$T/o" 2>&1 &&
  fail "a bad RESP_FORWARD_TO reached work" || pass "refuses a bad RESP_FORWARD_TO"

# --- 2. dry run: two HUM escalations + one box message -----------------------------
cat >"$T/inbox.json" <<'JSON'
[
 {"v":1,"msg_id":"a1","from":"HUM-10","task_id":"t-aaa","to":"ALL-0","kind":"note","body":"upload an image?"},
 {"v":1,"msg_id":"a2","from":"HUM-27","task_id":"t-bbb","to":"ALL-0","kind":"note","body":"anyone?"},
 {"v":1,"msg_id":"a3","from":"CLE-9","task_id":"t-ccc","to":"ALL-0","kind":"note","body":"a box message"}
]
JSON
: >"$T/reply.log"
SNIPPET='do_spl_responder_run' TENANT_ID=t1 in_resp >"$T/o" 2>&1
if grep -q "would.*HUM-10" "$T/o" && grep -q "would.*HUM-27" "$T/o" && ! grep -q "CLE-9" "$T/o"; then
  pass "dry run would answer the two humans, not the box message"
else
  fail "dry run escalation set wrong: $(cat "$T/o")"
fi
if [ ! -s "$T/reply.log" ]; then
  pass "dry run made no real reply"
else
  fail "dry run posted a real reply: $(cat "$T/reply.log")"
fi

# --- 3. RESP_SEEN_REPLY=1 DRY_RUN=0: one reply per escalation -----------------------
unset RESP_SEEN_REPLY
: >"$T/reply.log"
SNIPPET='do_spl_responder_run' TENANT_ID=t1 DRY_RUN=0 RESP_SEEN_REPLY=1 in_resp >"$T/o" 2>&1
if [ "$(grep -c '^reply ' "$T/reply.log")" = "2" ] && grep -q "DESK_TO=HUM-10 DESK_TASK=t-aaa" "$T/reply.log"; then
  pass "DRY_RUN=0 replies once per escalation, in the right topic"
else
  fail "DRY_RUN=0 reply set wrong: $(cat "$T/reply.log")"
fi
if [ "$(grep -c -- '--to c-001 --kind note --task t-' "$T/send.log" 2>/dev/null)" = "2" ]; then
  pass "DRY_RUN=0 files each escalation to the orchestrator through the stubbed send"
else
  fail "forward set wrong (want 2 stub sends): $(cat "$T/send.log" 2>/dev/null)"
fi

# --- 4. one "Seen" per topic, ever (CLE-77847) ---------------------------------------
cat >"$T/inbox.json" <<'JSON'
[
 {"v":1,"msg_id":"b1","from":"HUM-10","task_id":"t-ddd","ts":"2026-10-01T08:17:11Z","to":"ALL-0","kind":"note","body":"the counter is off"},
 {"v":1,"msg_id":"b2","from":"HUM-10","task_id":"t-ddd","ts":"2026-10-01T08:17:17Z","to":"ALL-0","kind":"note","body":"see this one"},
 {"v":1,"msg_id":"b3","from":"HUM-10","task_id":"t-ddd","ts":"2026-10-01T08:17:25Z","to":"ALL-0","kind":"note","body":"this one"},
 {"v":1,"msg_id":"b4","from":"HUM-10","task_id":"t-ddd","ts":"2026-10-01T08:17:35Z","to":"ALL-0","kind":"note","body":"and this one"},
 {"v":1,"msg_id":"b5","from":"HUM-10","task_id":"t-ddd","ts":"2026-10-01T08:17:42Z","to":"ALL-0","kind":"note","body":"a minute ago"}
]
JSON
D="$T/state/dev/desk/t1/box-rsp"
rm -f "$D/seen-topics"; : >"$T/reply.log"
for i in 1 2 3 4; do
  SNIPPET='do_spl_responder_run' TENANT_ID=t1 DRY_RUN=0 RESP_SEEN_REPLY=1 in_resp >"$T/o" 2>&1
done
if [ "$(grep -c '^reply ' "$T/reply.log")" = "1" ] && grep -q "DESK_TO=HUM-10 DESK_TASK=t-ddd" "$T/reply.log"; then
  pass "five posts in one topic, four sweeps: exactly one Seen reply"
else
  fail "one-topic sweep reply set wrong: $(cat "$T/reply.log")"
fi
grep -q "1 already seen" "$T/o" && pass "a re-delivered topic is logged as already seen" ||
  fail "the repeat sweep did not say already seen: $(cat "$T/o")"

rm -f "$D/seen-topics"; : >"$T/reply.log"
mkdir -p "$D/spool/$SPL_RSP_AGENT/outbox"
echo '{"v":1,"msg_id":"s1","from":"'"$SPL_RSP_AGENT"'","to":"HUM-10","task_id":"t-ddd","kind":"note","body":"Seen: routed to the team."}' >"$D/spool/$SPL_RSP_AGENT/outbox/s1.json"
SNIPPET='do_spl_responder_run' TENANT_ID=t1 DRY_RUN=0 RESP_SEEN_REPLY=1 in_resp >"$T/o" 2>&1
[ ! -s "$T/reply.log" ] && pass "a lost ledger: the outbox Seen still blocks a second reply" ||
  fail "replied again although the outbox holds the Seen: $(cat "$T/reply.log")"
rm -f "$D/spool/$SPL_RSP_AGENT/outbox/s1.json" "$D/seen-topics"

: >"$T/reply.log"
( exec 9>"$D/responder.lock"; flock -n 9; SNIPPET='do_spl_responder_run' TENANT_ID=t1 DRY_RUN=0 RESP_SEEN_REPLY=1 in_resp >"$T/o" 2>&1 )
if [ ! -s "$T/reply.log" ] && grep -q "another responder run holds" "$T/o"; then
  pass "a concurrent run (lock held) does not answer"
else
  fail "answered under a held lock: $(cat "$T/reply.log") / $(cat "$T/o")"
fi

# --- 5. the default: no visible reply, every escalation still filed -----------------
cat >"$T/inbox.json" <<'JSON'
[
 {"v":1,"msg_id":"c1","from":"HUM-10","task_id":"t-eee","to":"ALL-0","kind":"note","body":"the selected msg adds nothing"},
 {"v":1,"msg_id":"c2","from":"HUM-27","task_id":"t-fff","to":"ALL-0","kind":"note","body":"anyone?"}
]
JSON
rm -f "$D/seen-topics"; : >"$T/reply.log"; : >"$T/send.log"
SNIPPET='do_spl_responder_run' TENANT_ID=t1 DRY_RUN=0 in_resp >"$T/o" 2>&1
[ ! -s "$T/reply.log" ] && pass "default: no Seen (or any) reply is posted in the topic" ||
  fail "default posted a reply: $(cat "$T/reply.log")"
if [ "$(grep -c -- '--to c-001 --kind note --task t-' "$T/send.log" 2>/dev/null)" = "2" ] && grep -q "2 filed without a reply" "$T/o"; then
  pass "default: each escalation is still filed to the orchestrator"
else
  fail "default forward set wrong: $(cat "$T/send.log" 2>/dev/null) / $(cat "$T/o")"
fi
SNIPPET='do_spl_responder_run' TENANT_ID=t1 RESP_SEEN_REPLY=yes in_resp >"$T/o" 2>&1 &&
  fail "a bad RESP_SEEN_REPLY reached work" || pass "refuses a bad RESP_SEEN_REPLY"

# Nothing reached a spool root: the sandbox one holds no inbox, no outbox.
if [ -z "$(find "$T/spool" -mindepth 1 -not -name box.env 2>/dev/null)" ]; then
  pass "no message was written to any spool root (the forward stayed in the stub)"
else
  fail "a send escaped into the sandbox spool root: $(find "$T/spool" -mindepth 1)"
fi

echo "----"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
