#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_responder_run (SPL-1265 / epic SPL-1238) — the non-AI
#          responder. It validates its ids, stays offline in a dry run, and
#          treats every HUM-* message in RSP-01's channel-less inbox as an
#          escalation to answer (and nothing else). No cloud call, no spool
#          binary: the desk spool + reply legs are stubbed.
#   1. a bad DESK_AGENT / RESP_FORWARD_TO is refused; the defaults pass
#   2. dry run: for a canned inbox of two HUM escalations + one box message,
#      it says it WOULD reply+file+ack the TWO humans only, and makes NO real
#      reply/send (the stub reply is never called)
#   3. DRY_RUN=0: it calls do_spl_desk_reply once per escalation
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/state/dev/desk/t1/box-rsp/spool"

# in_resp sources the funcs with every cloud/spool leg stubbed. spl_desk_spool
# emits a canned inbox on recv; do_spl_desk_reply logs a call instead of posting.
in_resp() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" \
    REPLY_LOG="$T/reply.log" SEND_LOG="$T/send.log" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_STATE_DIR="'"$T"'/state/dev"; SPL_CNF="'"$T"'/env.yaml"; SPL_ORG_APP="csi-spl"; export SPL_STATE_DIR SPL_CNF SPL_ORG_APP; return 0; }
    yq() { echo "api.example.net"; }
    spl_host_spool() { return 0; }
    spl_desk_spool() { case "$*" in *"-- recv"*) cat "'"$T"'/inbox.json";; *) echo "{}";; esac; }
    do_spl_desk_reply() { echo "reply DESK_TO=$DESK_TO DESK_TASK=$DESK_TASK" >>"$REPLY_LOG"; return 0; }
    eval "$SNIPPET"'
}

echo '{}' >"$T/env.yaml"

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

# --- 3. DRY_RUN=0: one reply per escalation ----------------------------------------
: >"$T/reply.log"
SNIPPET='do_spl_responder_run' TENANT_ID=t1 DRY_RUN=0 in_resp >"$T/o" 2>&1
if [ "$(grep -c '^reply ' "$T/reply.log")" = "2" ] && grep -q "DESK_TO=HUM-10 DESK_TASK=t-aaa" "$T/reply.log"; then
  pass "DRY_RUN=0 replies once per escalation, in the right topic"
else
  fail "DRY_RUN=0 reply set wrong: $(cat "$T/reply.log")"
fi

echo "----"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
