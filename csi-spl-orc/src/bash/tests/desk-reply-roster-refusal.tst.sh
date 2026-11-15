#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-5644 - a desk reply the hub STORED, while the spool CLI reported
#          the refusal of this box's roster write (an announce's error frame
#          has no msg_id, so the send in flight took it as its own answer;
#          prd csitea 2026-11-15, msg 0a7efcb5), is reported as posted: exit
#          0, a WARN naming the stored msg id and the refusal, no second post.
#          The desk spool is stubbed: `send` fails with SEND_ERR, `hub-tail`
#          prints TAIL (NDJSON); every call is logged.
#   1. roster refusal + the post in the topic's tail -> exit 0, WARN with its
#      msg id, the summary carries it, one send
#   2. a DM about a topic (spec 067): the post landed in the topic -> exit 0,
#      no DM fallback (one send)
#   3. CONTROL: roster refusal but no such post in the tail -> exit 1
#   4. CONTROL: another refusal with the post in the tail -> exit 1, the tail
#      is not read
#   5. CONTROL: an older (> 15 min) post with the same body -> exit 1
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux
DM=44444444-4444-4444-8444-444444444444
TOPIC=55555555-5555-4555-8555-555555555555
BODY="Dev and prd serve 1.4.2."
ROSTER_ERR="hub refused: vendor_cap_exceeded (refused: grok agent cap reached for workspace t1: max 0 live, requested 1 live: roster not updated)"
mkdir -p "$T/state/dev/desk/t1/box-desk/spool/c-002"
echo pub >"$T/state/dev/desk/t1/box-desk/pinned"
python3 - "$T/inbox.json" "$DM" "$TOPIC" <<'EOF_PY'
import json, sys
json.dump([{"v": 1, "msg_id": "m-1", "task_id": sys.argv[2], "ts": "2026-10-19T08:52:00Z",
            "from": "HUM-10", "to": "c-002", "kind": "note", "ref_task_id": sys.argv[3],
            "body": "is this deployed?", "files": []}], open(sys.argv[1], "w"))
EOF_PY

# tail_line <msg id> <body> [age minutes]: one hub-tail --json line from c-002.
tail_line() {
  python3 - "$1" "$2" "${3:-1}" <<'EOF_PY'
import datetime as dt, json, sys
ts = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=int(sys.argv[3]))).strftime("%Y-%m-%dT%H:%M:%SZ")
print(json.dumps({"v": 1, "msg_id": sys.argv[1], "from": "c-002", "to": "HUM-10", "ts": ts, "body": sys.argv[2]}))
EOF_PY
}

# reply [VAR=value]... - DRY_RUN=0 against the stubbed spool; calls in
# $T/calls (args joined by "|"), the output in $T/o, the exit code in $T/rc.
reply() {
  : >"$T/calls"
  rm -f "$T/state/dev/desk/t1/box-desk/answered"
  SNIPPET='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; SPL_CNF=/dev/null; }
spl_host_spool() { :; }
spl_desk_spool() {
  while [[ $# -gt 0 && "$1" != -- ]]; do shift; done; shift
  local IFS="|"; echo "$*" >>"$CALLS"
  case "$1" in
    recv) cat "$INBOX" ;;
    topics) return 1 ;;
    hub-tail) [[ "${!#}" == --json && -n "${TAIL:-}" ]] && printf "%s\n" "$TAIL" || echo "{\"msg_id\":\"r-1\"}" ;;
    send) [[ -n "${SEND_ERR:-}" ]] && { echo "spool: $SEND_ERR" >&2; return 1; }
      echo "{\"msg_id\":\"s-1\",\"delivery\":\"sent\"}" ;;
  esac
}
do_spl_desk_reply' in_orc TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT=c-002 DESK_BODY="$BODY" DRY_RUN=0 \
    CALLS="$T/calls" INBOX="$T/inbox.json" "$@" >"$T/o" 2>&1
  echo $? >"$T/rc"
}
sends() { grep -c '^send|' "$T/calls"; }
tails() { grep -c '^hub-tail|.*--json' "$T/calls"; }

# --- 1. stored despite the roster refusal ----------------------------------------------
reply DESK_TO=HUM-10 DESK_TASK="$DM" SEND_ERR="$ROSTER_ERR" TAIL="$(tail_line 0a7efcb5-0000-4000-8000-000000000001 "$BODY")"
[[ "$(cat "$T/rc")" == 0 && "$(sends)" == 1 ]] &&
  grep -q "WARN the post IS stored in topic $DM as msg 0a7efcb5-0000-4000-8000-000000000001" "$T/o" &&
  grep -q 'roster not updated' "$T/o" && grep -q '"msg_id": "0a7efcb5-0000-4000-8000-000000000001"' "$T/o" &&
  ! grep -q 'FATAL send' "$T/o" &&
  pass "1. stored post, roster write refused: exit 0, WARN with the msg id, summary carries it, one send" ||
  fail "1. rc=$(cat "$T/rc") calls=$(cat "$T/calls") out=$(cat "$T/o")"

# --- 2. a DM about a topic: landed in the topic, no DM fallback ------------------------
reply SEND_ERR="$ROSTER_ERR" TAIL="$(tail_line s-9 "@HUM-10 $BODY")"
[[ "$(cat "$T/rc")" == 0 && "$(sends)" == 1 ]] && grep -q -- "--task|$TOPIC|" "$T/calls" &&
  ! grep -q 'spec 067 edge 2' "$T/o" && grep -q "stored in topic $TOPIC as msg s-9" "$T/o" &&
  pass "2. landed in the referenced topic: exit 0, no DM fallback" ||
  fail "2. rc=$(cat "$T/rc") calls=$(cat "$T/calls") out=$(cat "$T/o")"

# --- 3. CONTROL: roster refusal, the post is not in the tail ---------------------------
reply DESK_TO=HUM-10 DESK_TASK="$DM" SEND_ERR="$ROSTER_ERR" TAIL="$(tail_line s-8 "another text")"
[[ "$(cat "$T/rc")" == 1 ]] && grep -q "FATAL send c-002 -> HUM-10 in task $DM" "$T/o" && ! grep -q 'IS stored' "$T/o" &&
  pass "3. CONTROL: roster refusal with no such post: exit 1" || fail "3. rc=$(cat "$T/rc") out=$(cat "$T/o")"

# --- 4. CONTROL: another refusal is never checked against the tail ---------------------
reply DESK_TO=HUM-10 DESK_TASK="$DM" SEND_ERR="hub refused: unpinned_box" TAIL="$(tail_line s-7 "$BODY")"
[[ "$(cat "$T/rc")" == 1 && "$(tails)" == 0 ]] && ! grep -q 'IS stored' "$T/o" &&
  pass "4. CONTROL: another refusal stays exit 1, the tail is not read" ||
  fail "4. rc=$(cat "$T/rc") calls=$(cat "$T/calls") out=$(cat "$T/o")"

# --- 5. CONTROL: an old post with the same body is not this one ------------------------
reply DESK_TO=HUM-10 DESK_TASK="$DM" SEND_ERR="$ROSTER_ERR" TAIL="$(tail_line s-6 "$BODY" 30)"
[[ "$(cat "$T/rc")" == 1 ]] && ! grep -q 'IS stored' "$T/o" &&
  pass "5. CONTROL: a 30-min-old post with the same body: exit 1" || fail "5. rc=$(cat "$T/rc") out=$(cat "$T/o")"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "ALL PASSED"
