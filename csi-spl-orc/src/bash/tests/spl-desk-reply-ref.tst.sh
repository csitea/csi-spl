#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 067 row L5 (rule 2, edge 2) - do_spl_desk_reply answering a DM
#          about a channel topic T replies IN T, tagging the person, and falls
#          back to the DM (carrying --ref T) when T cannot be read or written.
#          The desk spool is stubbed: every call is logged, hub-tail answers
#          per READABLE, a send into T fails with T_SEND_FAIL=1.
#   1. a poke DM ("needs you in <wui>/t/<T>") -> the answer is sent in T,
#      body "@HUM-n <body>", no --ref; CONTROL: a plain DM (no topic) stays
#      in the DM, untagged
#   2. a DM carrying ref_task_id T -> answered in T the same way
#   3. T unreadable (hub-tail returns nothing) -> the answer stays in the DM
#      with --ref T, untagged; CONTROL: the same DM with T readable is NOT
#      answered in the DM
#   4. the post into T is refused -> the answer is sent in the DM with --ref T;
#      CONTROL: an accepted post sends nothing to the DM
#   5. a channel post (to ALL-0) that quotes a topic link is not moved; a body
#      that already tags the person is not tagged twice
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux
AGENT=c-001
DM=11111111-1111-4111-8111-111111111111
TOPIC=22222222-2222-4222-8222-222222222222
mkdir -p "$T/state/dev/desk/t1/box-desk/spool/$AGENT"

# inbox <to> <body> [ref] - one human message from HUM-10 in the DM thread
inbox() {
  python3 - "$T/inbox.json" "$DM" "$1" "$2" "${3:-}" <<'EOF_PY'
import json, sys
path, dm, to, body, ref = sys.argv[1:]
m = {"v": 1, "msg_id": "m-1", "task_id": dm, "ts": "2026-10-03T19:00:00Z",
     "from": "HUM-10", "to": to, "kind": "note", "body": body, "files": []}
if ref:
    m["ref_task_id"] = ref
json.dump([m], open(path, "w"))
EOF_PY
}

# reply <body> [VAR=value]... - DRY_RUN=0 against the stubbed spool; the calls
# land in $T/calls (one per line, args joined by "|"), the output in $T/o.
reply() {
  local body="$1"; shift
  : >"$T/calls"
  rm -f "$T/state/dev/desk/t1/box-desk/answered" # each case answers afresh
  SNIPPET='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }
spl_host_spool() { :; }
spl_desk_spool() {
  while [[ $# -gt 0 && "$1" != -- ]]; do shift; done; shift
  local IFS="|"; echo "$*" >>"$CALLS"
  case "$1" in
    recv) cat "$INBOX" ;;
    hub-tail) [[ "${READABLE:-1}" == 1 ]] && echo "{\"msg_id\":\"t-1\"}"; return 0 ;;
    send)
      [[ "${T_SEND_FAIL:-0}" == 1 && "$*" == *"--task|$TOPIC|"* ]] && { echo "spool: unknown_channel (403)"; return 1; }
      echo "{\"msg_id\":\"s-1\",\"delivery\":\"sent\"}" ;;
  esac
}
do_spl_desk_reply' in_orc TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT="$AGENT" DESK_BODY="$body" DRY_RUN=0 \
    CALLS="$T/calls" INBOX="$T/inbox.json" TOPIC="$TOPIC" "$@" >"$T/o" 2>&1
}
sends() { grep '^send|' "$T/calls"; }
sent_in() { sends | grep -c -- "--task|$1|"; }
sent_body() { sends | sed -n 's/.*|--body|\([^|]*\).*/\1/p'; }
has_ref() { sends | grep -c -- "--ref|$TOPIC"; }

POKE="HUM-10 needs you in https://wui.example.com/t/$TOPIC: \"can you look?\""

# --- 1. poke DM -> answered in T, tagged ---------------------------------------------
inbox "$AGENT" "$POKE"
reply "Looking now."
if [[ "$(sent_in "$TOPIC")" == 1 && "$(sent_in "$DM")" == 0 && "$(sent_body)" == "@HUM-10 Looking now." && "$(has_ref)" == 0 ]] &&
  grep -q '"route": "topic"' "$T/o"; then
  pass "a reply to a poke DM lands in T with @HUM-10"
else
  fail "poke DM reply not in T tagged: calls=$(cat "$T/calls") out=$(cat "$T/o")"
fi
inbox "$AGENT" "can you look?"
reply "Looking now."
if [[ "$(sent_in "$DM")" == 1 && "$(sent_in "$TOPIC")" == 0 && "$(sent_body)" == "Looking now." ]] && ! grep -q '^hub-tail' "$T/calls"; then
  pass "CONTROL: a plain DM (no topic) is answered in the DM, untagged, no hub-tail"
else
  fail "plain DM moved: calls=$(cat "$T/calls")"
fi

# --- 2. ref_task_id on the message ---------------------------------------------------
inbox "$AGENT" "about that topic" "$TOPIC"
reply "On it."
[[ "$(sent_in "$TOPIC")" == 1 && "$(sent_body)" == "@HUM-10 On it." ]] &&
  pass "a DM carrying ref_task_id is answered in T, tagged" ||
  fail "ref_task_id DM not answered in T: calls=$(cat "$T/calls")"

# --- 3. T unreadable -> DM with --ref ------------------------------------------------
inbox "$AGENT" "$POKE"
reply "Looking now." READABLE=0
if [[ "$(sent_in "$DM")" == 1 && "$(sent_in "$TOPIC")" == 0 && "$(has_ref)" == 1 && "$(sent_body)" == "Looking now." ]] &&
  grep -q 'cannot read topic' "$T/o" && grep -q '"route": "dm-fallback"' "$T/o"; then
  pass "an unreadable T falls back to the DM with --ref T, untagged"
else
  fail "unreadable T did not fall back: calls=$(cat "$T/calls") out=$(cat "$T/o")"
fi
reply "Looking now." READABLE=1
[[ "$(sent_in "$DM")" == 0 && "$(sent_in "$TOPIC")" == 1 ]] && pass "CONTROL: with T readable nothing goes to the DM" ||
  fail "readable T still answered in the DM: calls=$(cat "$T/calls")"

# --- 4. the post into T is refused -> DM with --ref ----------------------------------
reply "Looking now." T_SEND_FAIL=1
if [[ "$(sent_in "$TOPIC")" == 1 && "$(sent_in "$DM")" == 1 && "$(has_ref)" == 1 ]] && grep -q 'could not post in topic' "$T/o"; then
  pass "a refused post into T falls back to the DM with --ref T"
else
  fail "refused post did not fall back: calls=$(cat "$T/calls") out=$(cat "$T/o")"
fi
reply "Looking now." T_SEND_FAIL=0
[[ "$(sends | wc -l)" == 1 && "$(sent_in "$TOPIC")" == 1 ]] && pass "CONTROL: an accepted post into T sends exactly once" ||
  fail "accepted post sent more than once: calls=$(cat "$T/calls")"

# --- 5. channel post not moved; no double tag ----------------------------------------
inbox ALL-0 "$POKE"
reply "Seen."
[[ "$(sent_in "$DM")" == 1 && "$(sent_in "$TOPIC")" == 0 ]] &&
  pass "a channel post (to ALL-0) quoting a topic link is answered where it is" ||
  fail "channel post moved: calls=$(cat "$T/calls")"
inbox "$AGENT" "$POKE"
reply "@HUM-10 already tagged."
[[ "$(sent_body)" == "@HUM-10 already tagged." ]] && pass "a body that tags the person is not tagged twice" ||
  fail "double tag: $(sent_body)"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "ALL PASSED"
