#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-3967 - do_spl_desk_reply (and do_spl_take, which posts through
#          it) refuses, nothing sent, when the topic's newest human post since
#          the last agent post is addressed to people only: to_id HUM-n, or a
#          channel post (ALL-0) that @-mentions people and no agent
#          (csitea #csi-fina f21f5a07, 2026-10-27: HUM-24 -> HUM-10, a desk
#          answered it). The desk spool is stubbed: every call is logged,
#          `hub-tail` prints $TAIL (or fails with TAIL_FAIL=1), `send` ok.
#   1. to_id HUM-10 -> refused, exit 9, the FATAL names the msg id
#   2. ALL-0 with only @HUM-10 -> refused; mail@HUM-10 is no mention
#   3. ALL-0 with no mention, or naming an agent too -> sent
#   4. DESK_HUMAN_TO_HUMAN_OK=<msg id> (or its 8-char prefix) -> sent;
#      another id -> still refused
#   5. a later ALL-0 post opens the topic again; so does an agent post
#   6. the picker path (no DESK_TASK) and do_spl_take are gated too
#   7. a topic that cannot be read: a WARN, sent
# The red control: without the gate call in do_spl_desk_reply, 10 of 18 fail
# (1, the three refusals of 2 and 4 and 5, the picker, the take and its
# ledger, the unreadable topic's WARN).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux
TK=55555555-5555-4555-8555-555555555555
R="$T/root"
mkdir -p "$R/dispatch" "$T/state/dev/desk/t1/box-desk/spool/c-002"

# post <msg_id> <ts> <from> <to> <body> - one hub-tail NDJSON line
post() {
  python3 -c 'import json, sys; print(json.dumps({"v": 1, "msg_id": sys.argv[1], "task_id": sys.argv[6], "ts": sys.argv[2],
    "from": sys.argv[3], "to": sys.argv[4], "kind": "note", "body": sys.argv[5], "files": []}))' "$@" "$TK"
}
TO_HUM="$(post 23241cff-b804-4ff0-bffb-e5e1fb8b5fc7 2026-10-27T10:38:46Z HUM-24 HUM-10 'install the new app and we check it')"
AT_HUM="$(post h-2 2026-10-27T10:38:46Z HUM-24 ALL-0 '@HUM-10 install the new app')"
PLAIN="$(post h-3 2026-10-27T10:39:00Z HUM-24 ALL-0 'does the new app work?')"
python3 -c 'import json, sys; json.dump([json.loads(sys.argv[1])], open(sys.argv[2], "w"))' "$TO_HUM" "$T/inbox.json"

# reply [VAR=value]... - c-002 answers HUM-24 in $TK, DRY_RUN=0, against the
# stubbed spool; the calls land in $T/calls, the output in $T/o, the exit code
# in $T/rc. No lease file: the lease gate passes and reads nothing.
SNIPPET='
do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }
spl_host_spool() { :; }
spl_desk_spool() {
  while [[ $# -gt 0 && "$1" != -- ]]; do shift; done; shift
  local IFS="|"; echo "$*" >>"$CALLS"
  case "$1" in
    recv) cat "$INBOX" ;;
    hub-tail) [[ "${TAIL_FAIL:-0}" == 1 ]] && { echo "spool: hub unreachable"; return 1; }
      printf "%s\n" "$TAIL" ;;
    topics) echo "spool: no such channel"; return 1 ;;
    send) echo "{\"msg_id\":\"s-1\",\"delivery\":\"sent\"}" ;;
  esac
}
spl_take_reply() { DESK_TO="$1" DESK_TASK="$2" DESK_BODY="$3" DESK_BODY_FILE="" DESK_KIND=note DRY_RUN=0 do_spl_desk_reply; }
do_spl_desk_reply'
reply() {
  local rc=0
  : >"$T/calls"
  rm -f "$T/state/dev/desk/t1/box-desk/answered" "$R/dispatch/take.log"
  SNIPPET="$SNIPPET" in_orc SPOOL_ROOT="$R" SPL_DESK_HUMAN_GATE_TEST=1 TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT=c-002 \
    DESK_TO=HUM-24 DESK_TASK="$TK" DESK_BODY="Taken: I check the app." DRY_RUN=0 \
    CALLS="$T/calls" INBOX="$T/inbox.json" TAIL="$TO_HUM" "$@" >"$T/o" 2>&1 || rc=$?
  echo "$rc" >"$T/rc"
}
sent() { grep -c '^send|' "$T/calls"; }
ok_sent() { [[ "$(cat "$T/rc")" == 0 && "$(sent)" == 1 ]]; }
refused() { [[ "$(cat "$T/rc")" == 9 && "$(sent)" == 0 ]] && grep -q "addressed to $1, not to the agents" "$T/o"; }
show() { echo "rc=$(cat "$T/rc") calls=$(tr '\n' ' ' <"$T/calls") out=$(tail -n 3 "$T/o")"; }

# --- 1. to_id HUM-10 -----------------------------------------------------------------
reply
refused HUM-10 && grep -q 'msg 23241cff-b804-4ff0-bffb-e5e1fb8b5fc7' "$T/o" && grep -q 'DESK_HUMAN_TO_HUMAN_OK=23241cff-b804-4ff0-bffb-e5e1fb8b5fc7' "$T/o" &&
  pass "a post to HUM-10 is refused (exit 9, nothing sent, the msg id named)" || fail "to_id HUM-10 not refused: $(show)"

# --- 2. ALL-0 with only @HUM-10 ------------------------------------------------------
reply TAIL="$AT_HUM"
refused HUM-10 && pass "a channel post @-mentioning only HUM-10 is refused" || fail "@HUM-10 only not refused: $(show)"
reply TAIL="$(post h-4 2026-10-27T10:38:46Z HUM-24 ALL-0 '@HUM-10 and @HUM-7: your call')"
refused 'HUM-10, HUM-7' && pass "a channel post @-mentioning two people only is refused, both named" || fail "two people not refused: $(show)"
reply TAIL="$(post h-5 2026-10-27T10:38:46Z HUM-24 ALL-0 'write to mail@HUM-10 please')"
ok_sent && pass "CONTROL: mail@HUM-10 is no mention: sent" || fail "an e-mail address counted as a mention: $(show)"

# --- 3. ALL-0 for everyone, or naming an agent ---------------------------------------
reply TAIL="$PLAIN"
ok_sent && pass "a channel post with no mention is answered" || fail "a plain channel post refused: $(show)"
reply TAIL="$(post h-6 2026-10-27T10:38:46Z HUM-24 ALL-0 '@HUM-10 @c-002 check the app')"
ok_sent && pass "a post naming a person AND an agent is answered" || fail "an agent mention refused: $(show)"
reply TAIL="$(post h-7 2026-10-27T10:38:46Z HUM-24 c-002 'check the app')"
ok_sent && pass "a DM to the agent is answered" || fail "a DM to the agent refused: $(show)"

# --- 4. the override -----------------------------------------------------------------
reply DESK_HUMAN_TO_HUMAN_OK=23241cff-b804-4ff0-bffb-e5e1fb8b5fc7
ok_sent && grep -q 'DESK_HUMAN_TO_HUMAN_OK=23241cff-b804-4ff0-bffb-e5e1fb8b5fc7 lets c-002' "$T/o" &&
  pass "DESK_HUMAN_TO_HUMAN_OK=<msg id> lets the answer through, with a WARN" || fail "override refused: $(show)"
reply DESK_HUMAN_TO_HUMAN_OK=23241cff
ok_sent && pass "the override's first 8 characters are enough" || fail "8-char override refused: $(show)"
reply DESK_HUMAN_TO_HUMAN_OK=99999999
refused HUM-10 && pass "CONTROL: an override naming another msg is still refused" || fail "wrong override passed: $(show)"

# --- 5. the topic opens again --------------------------------------------------------
reply TAIL="$TO_HUM"$'\n'"$(post h-8 2026-10-27T10:44:42Z HUM-24 ALL-0 'can the AI check it now?')"
ok_sent && pass "a later ALL-0 post opens the topic again" || fail "later ALL-0 post still refused: $(show)"
reply TAIL="$(post h-8 2026-10-27T10:30:00Z HUM-24 ALL-0 'can the AI check it?')"$'\n'"$TO_HUM"
refused HUM-10 && pass "CONTROL: an ALL-0 post OLDER than the post to HUM-10 does not open it" || fail "older ALL-0 post opened it: $(show)"
reply TAIL="$TO_HUM"$'\n'"$(post a-1 2026-10-27T10:40:00Z c-007 HUM-24 'Done')"
ok_sent && pass "an agent post after it: no newer human post is waiting, sent" || fail "post after an agent reply refused: $(show)"

# --- 6. the picker path; do_spl_take -------------------------------------------------
reply DESK_TO= DESK_TASK=
refused HUM-10 && grep -q '^recv|' "$T/calls" && pass "the picker path (no DESK_TASK) is gated too" || fail "picker path not gated: $(show)"
SNIPPET="${SNIPPET%do_spl_desk_reply}do_spl_take"
reply TAKE_PLAN='I check the app' TAKE_REPLY_CMD=stub TAKE_BOX=box-desk
[[ "$(cat "$T/rc")" != 0 && "$(sent)" == 0 ]] && grep -q 'addressed to HUM-10, not to the agents' "$T/o" &&
  pass "do_spl_take is refused through its reply, nothing sent" || fail "take not refused: $(show)"
[[ ! -s "$R/dispatch/take.log" ]] && pass "…and records no take" || fail "a refused take was recorded: $(cat "$R/dispatch/take.log")"
reply TAKE_PLAN='I check the app' TAKE_REPLY_CMD=stub TAKE_BOX=box-desk TAIL="$PLAIN"
[[ "$(cat "$T/rc")" == 0 && "$(sent)" == 1 ]] && pass "CONTROL: do_spl_take on a post for everyone posts its line" || fail "take refused on ALL-0: $(show)"
SNIPPET="${SNIPPET%do_spl_take}do_spl_desk_reply"

# --- 7. an unreadable topic ----------------------------------------------------------
reply TAIL_FAIL=1
ok_sent && grep -q 'human-to-human gate cannot read topic' "$T/o" &&
  pass "a topic that cannot be read: a WARN, sent (the lease gate guards it)" || fail "unreadable topic: $(show)"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "ALL PASSED"
