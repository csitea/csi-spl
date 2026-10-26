#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-3520 (grade fix C) - do_spl_desk_reply refuses the FIRST agent
#          reply in a topic from a seat that does not hold the dispatch lease
#          right now, for every vendor (owner HUM-10, t1 99ffa592 msg
#          ce2045be; grok-dispatch-grade-2026-10-25.md section 5: g-001 wrote
#          14 first replies outside the lease). The desk spool is stubbed:
#          every call is logged, `hub-tail` prints $TAIL (or fails with
#          TAIL_FAIL=1), `topics` fails (no #lobby welcome topic), `send` ok.
#   1. a non-holder's first reply -> refused, exit 8, nothing sent, the
#      FATAL names the holder; an RSP-* responder post is not an agent reply
#   2. the holder (its box matched) and the orchestrator lease holder ->
#      sent; the holder's id on ANOTHER machine -> refused
#   3. not the first reply: an agent already answered in the topic -> sent
#   4. the human addressed the seat (@<id>, a DM to it) -> sent
#   5. a channel seat of the workspace (brief `Channel: t1 #<ch>`) and a
#      workspace seat on a box claimed by it -> sent; a channel seat of
#      another workspace -> refused
#   6. no lease file (a box without dispatchers) -> sent, no hub-tail read;
#      a hub-tail that fails -> refused
#   7. the picker path (no DESK_TASK) is gated too
#   8. SPL-3542: a channel seat passes only in the topic's own channel when
#      hub-tail --with-channel names it; a sole-seat channel (channel-rules
#      map column 6) takes a first reply from that seat only, the dispatch
#      and orch lease holders refused; a malformed column 6 refuses; not a
#      first reply, or another channel: the holder still posts; a spool
#      without --with-channel: the rule is not checked (WARN)
# The stub's hub-tail prints $TAIL; with --with-channel and NO_WITH_CH=1 it
# fails as an old binary does. Until cr_sole_seat is on the tree (c-834,
# SPL-3542) the snippet defines a stand-in with its contract (column 6).
# The red control: without the gate call in do_spl_desk_reply, 7 of 16 fail:
# 1 (both), 2 (other machine), 4 (the control), 5 (other workspace), 6 (tail
# fails) and 7 (the picker). Without rule 0 (the sole-seat block in
# spl_desk_lease_gate) 6 of 8 fail: holder, orch, other machine, malformed,
# unread topic, old binary. Matching the tenant only (the old rule 3): 1 of 8
# fails (another channel's topic).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux
TK=44444444-4444-4444-8444-444444444444
R="$T/root"
mkdir -p "$R/dispatch"
for a in c-002 g-001 c-001 c-423; do mkdir -p "$T/state/dev/desk/t1/box-desk/spool/$a"; done
HUMPOST='{"v":1,"msg_id":"h-1","task_id":"'"$TK"'","ts":"2026-10-26T08:00:00Z","from":"HUM-10","to":"ALL-0","kind":"note","body":"the menu is gone","files":[]}'
python3 - "$T/inbox.json" "$TK" <<'EOF_PY'
import json, sys
json.dump([{"v": 1, "msg_id": "h-1", "task_id": sys.argv[2], "ts": "2026-10-26T08:00:00Z",
            "from": "HUM-10", "to": "ALL-0", "kind": "note", "body": "the menu is gone", "files": []}],
          open(sys.argv[1], "w"))
EOF_PY

# lease <dispatch holder> [orch holder] - the lease files ("" = no file)
lease() {
  rm -f "$R/dispatch/lease" "$R/dispatch/lease.orch"
  [[ -n "$1" ]] && echo "$1 1793011942" >"$R/dispatch/lease"
  [[ -n "${2:-}" ]] && echo "$2 1793011942" >"$R/dispatch/lease.orch"
  return 0
}

# reply <agent> [VAR=value]... - DRY_RUN=0 against the stubbed spool, into
# topic $TK for HUM-10 unless DESK_TASK / DESK_TO say otherwise; the calls land
# in $T/calls, the output in $T/o, the exit code in $T/rc.
reply() {
  local agent="$1" rc=0; shift
  : >"$T/calls"
  rm -f "$T/state/dev/desk/t1/box-desk/answered"
  SNIPPET="$STANDIN"'
do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }
spl_host_spool() { :; }
spl_desk_spool() {
  while [[ $# -gt 0 && "$1" != -- ]]; do shift; done; shift
  local IFS="|"; echo "$*" >>"$CALLS"
  case "$1" in
    recv) cat "$INBOX" ;;
    hub-tail) [[ "${TAIL_FAIL:-0}" == 1 ]] && { echo "spool: hub unreachable"; return 1; }
      [[ "${NO_WITH_CH:-0}" == 1 && "$*" == *--with-channel* ]] && { echo "flag provided but not defined: -with-channel"; return 1; }
      printf "%s\n" "$TAIL" ;;
    topics) echo "spool: no such channel"; return 1 ;;
    send) echo "{\"msg_id\":\"s-1\",\"delivery\":\"sent\"}" ;;
  esac
}
do_spl_desk_reply' in_orc SPOOL_ROOT="$R" SPL_DESK_LEASE_GATE_TEST=1 LEASE_MACHINE=box-a TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT="$agent" \
    DESK_TO=HUM-10 DESK_TASK="$TK" DESK_BODY="Here is how the menu works." DRY_RUN=0 \
    CALLS="$T/calls" INBOX="$T/inbox.json" TAIL="$HUMPOST" "$@" >"$T/o" 2>&1 || rc=$?
  echo "$rc" >"$T/rc"
}
STANDIN=""
grep -q '^cr_sole_seat()' "$PROJ_ROOT/src/bash/features/spawn-agents/lib/channel-rules.inc.sh" || STANDIN='
cr_sole_seat() {
  local seat
  [ -e "$(cr_map)" ] || return 1
  seat="$(awk -F"\t" -v t="$1" -v c="$2" '"'"'$1 !~ /^#/ && $1 == t && $2 == c { print $6; exit }'"'"' "$(cr_map)")"
  [ -n "$seat" ] && [ "$seat" != "-" ] || return 1
  [[ "$seat" =~ ^[a-z]-[0-9]{3}@[A-Za-z0-9._-]+$ ]] || { echo "FATAL channel rules: bad sole seat $seat" >&2; return 2; }
  printf "%s\n" "$seat"
}'
sent() { grep -c '^send|' "$T/calls"; }
ok_sent() { [[ "$(cat "$T/rc")" == 0 && "$(sent)" == 1 ]]; }
refused() { [[ "$(cat "$T/rc")" == 8 && "$(sent)" == 0 ]] && grep -q 'SPL-3520' "$T/o"; }
show() { echo "rc=$(cat "$T/rc") calls=$(tr '\n' ' ' <"$T/calls") out=$(tail -n 3 "$T/o")"; }

# --- 1. a non-holder's first reply ---------------------------------------------------
lease c-002@box-a c-001@box-b
reply g-001
refused && grep -q 'c-002@box-a' "$T/o" &&
  pass "a non-holder's first reply in a topic is refused (exit 8, nothing sent, the holder named)" ||
  fail "non-holder first reply not refused: $(show)"
reply g-001 TAIL="$HUMPOST"$'\n''{"v":1,"msg_id":"r-1","task_id":"'"$TK"'","ts":"2026-10-26T08:00:05Z","from":"RSP-1","to":"HUM-10","kind":"note","body":"Seen","files":[]}'
refused && pass "an RSP-* responder's post is not an agent reply: still refused" || fail "RSP post counted as a reply: $(show)"

# --- 2. the lease holders ------------------------------------------------------------
reply c-002
ok_sent && pass "the dispatch lease holder (its box matched) posts the first reply" || fail "holder refused: $(show)"
lease c-002@box-a g-001@box-a
reply g-001
ok_sent && pass "the orchestrator lease holder (the 3-minute backstop) posts the first reply" || fail "orch holder refused: $(show)"
lease c-002@box-b c-001@box-b
reply c-002
refused && pass "the holder's id on ANOTHER machine (c-002@box-b, this box box-a) is refused" || fail "other-machine id not refused: $(show)"
lease c-002@box-a c-001@box-b

# --- 3. not the first reply ----------------------------------------------------------
reply g-001 TAIL="$HUMPOST"$'\n''{"v":1,"msg_id":"a-1","task_id":"'"$TK"'","ts":"2026-10-26T08:01:00Z","from":"g-001","to":"HUM-10","kind":"note","body":"Taken","files":[]}'
ok_sent && pass "the topic's owner answering again is not refused" || fail "owner follow-up refused: $(show)"

# --- 4. the human addressed the seat -------------------------------------------------
reply g-001 TAIL='{"v":1,"msg_id":"h-2","task_id":"'"$TK"'","ts":"2026-10-26T08:00:00Z","from":"HUM-10","to":"ALL-0","kind":"note","body":"@g-001 what broke?","files":[]}'
ok_sent && pass "a post naming @g-001 lets g-001 answer first" || fail "@mention refused: $(show)"
reply g-001 TAIL='{"v":1,"msg_id":"h-3","task_id":"'"$TK"'","ts":"2026-10-26T08:00:00Z","from":"HUM-10","to":"g-001","kind":"note","body":"what broke?","files":[]}'
ok_sent && pass "a DM to g-001 lets g-001 answer first" || fail "DM refused: $(show)"
reply g-001 TAIL='{"v":1,"msg_id":"h-4","task_id":"'"$TK"'","ts":"2026-10-26T08:00:00Z","from":"HUM-10","to":"ALL-0","kind":"note","body":"@g-0012 and mail@g-001x","files":[]}'
refused && pass "CONTROL: a longer id (@g-0012) is not a mention of g-001" || fail "mention matched a longer id: $(show)"

# --- 5. channel and workspace seats --------------------------------------------------
mkdir -p "$R/c-423/lifetime"
printf '# Lane brief\nChannel: t1 #ops\n' >"$R/c-423/lifetime/brief.md"
reply c-423
ok_sent && pass "a channel seat of the workspace (Channel: t1 #ops) posts the first reply" || fail "channel seat refused: $(show)"
printf '# Lane brief\nChannel: other #ops\n' >"$R/c-423/lifetime/brief.md"
reply c-423
refused && pass "a channel seat of ANOTHER workspace is refused" || fail "other-workspace channel seat not refused: $(show)"
mkdir -p "$T/ws/t1"; echo t1 >"$T/ws/claim"
mkdir -p "$T/ws/t1/state/dev/desk/t1/box-desk/spool/g-001"
reply g-001 SPL_WS_BASE="$T/ws" SPL_STATE_DIR="$T/ws/t1/state/dev"
ok_sent && pass "a workspace seat on a box claimed by the workspace posts the first reply" || fail "workspace seat refused: $(show)"

# --- 6. no lease file; an unreadable topic -------------------------------------------
lease ""
reply g-001
ok_sent && ! grep -q '^hub-tail|' "$T/calls" && pass "no lease file: no gate, no hub-tail read (today's behaviour)" || fail "no-lease box gated: $(show)"
lease c-002@box-a c-001@box-b
reply g-001 TAIL_FAIL=1
refused && grep -q 'cannot read topic' "$T/o" && pass "a hub-tail that fails refuses a non-holder" || fail "tail failure not refused: $(show)"

# --- 7. the picker path --------------------------------------------------------------
reply g-001 DESK_TO= DESK_TASK=
refused && grep -q '^recv|' "$T/calls" && pass "the picker path (no DESK_TASK) is gated too" || fail "picker path not gated: $(show)"
reply c-002 DESK_TO= DESK_TASK=
ok_sent && pass "CONTROL: the picker path lets the holder answer" || fail "picker path refused the holder: $(show)"

# --- 8. the topic's channel; a sole-seat channel (SPL-3542) -------------------------
chtail() { sed 's/^{/{"channel":"'"$1"'",/' <<<"${2:-$HUMPOST}"; }
printf '# Lane brief\nChannel: t1 #ops\n' >"$R/c-423/lifetime/brief.md"
reply c-423 TAIL="$(chtail ops)"
ok_sent && pass "a channel seat posts the first reply in a topic of its own channel" || fail "own-channel seat refused: $(show)"
reply c-423 TAIL="$(chtail sales)"
refused && pass "a channel seat of the workspace is refused in ANOTHER channel's topic" || fail "other-channel seat not refused: $(show)"
DOC=0f0e0d0c-0b0a-4908-8706-050403020100
MAP="$T/channel-rules.tsv"
printf 't1\tsolo\t%s\tprd\tc-423\tc-423@box-a\nt1\tops\t%s\tprd\tc-423\n' "$DOC" "$DOC" >"$MAP"
printf '# Lane brief\nChannel: t1 #solo\n' >"$R/c-423/lifetime/brief.md"
reply c-002 SPOOL_CHANNEL_RULES_MAP="$MAP" TAIL="$(chtail solo)"
refused && grep -q 'sole seat, c-423@box-a' "$T/o" && grep -q 'SPL-3542' "$T/o" &&
  pass "a sole-seat channel: the dispatch lease holder's first reply is refused, the sole seat named" ||
  fail "holder passed in a sole-seat channel: $(show)"
lease c-002@box-a g-001@box-a
reply g-001 SPOOL_CHANNEL_RULES_MAP="$MAP" TAIL="$(chtail solo)"
refused && pass "a sole-seat channel: the orchestrator lease holder is refused too" || fail "orch passed in a sole-seat channel: $(show)"
lease c-002@box-a c-001@box-b
reply c-423 SPOOL_CHANNEL_RULES_MAP="$MAP" TAIL="$(chtail solo)"
ok_sent && pass "a sole-seat channel: the sole seat (its box matched) posts the first reply" || fail "sole seat refused: $(show)"
reply c-423 SPOOL_CHANNEL_RULES_MAP="$MAP" LEASE_MACHINE=box-z TAIL="$(chtail solo)"
refused && pass "the sole seat's id on ANOTHER machine is refused" || fail "sole seat on another box passed: $(show)"
reply c-002 SPOOL_CHANNEL_RULES_MAP="$MAP" TAIL="$(chtail solo "$HUMPOST"$'\n''{"v":1,"msg_id":"a-2","task_id":"'"$TK"'","ts":"2026-10-26T08:01:00Z","from":"c-423","to":"HUM-10","kind":"note","body":"Taken","files":[]}')"
ok_sent && pass "a sole-seat channel: a reply that is not the first is not refused" || fail "follow-up refused in a sole-seat channel: $(show)"
reply c-002 SPOOL_CHANNEL_RULES_MAP="$MAP" TAIL="$(chtail ops)"
ok_sent && pass "CONTROL: a mapped channel without a sole seat lets the holder post" || fail "holder refused in a channel without a sole seat: $(show)"
printf 't1\tsolo\t%s\tprd\tc-423\tc-423\n' "$DOC" >"$MAP"
reply c-002 SPOOL_CHANNEL_RULES_MAP="$MAP" TAIL="$(chtail solo)"
refused && grep -q 'cannot tell the sole seat' "$T/o" && pass "a malformed sole seat (no @<box>) refuses: fail closed" || fail "malformed sole seat passed: $(show)"
printf 't1\tsolo\t%s\tprd\tc-423\tc-423@box-a\n' "$DOC" >"$MAP"
reply c-002 SPOOL_CHANNEL_RULES_MAP="$MAP" TAIL="$(chtail solo)" TAIL_FAIL=1
refused && grep -q 'cannot read topic' "$T/o" && pass "a map and a topic that cannot be read: the holder is refused (fail closed)" || fail "unread topic passed the holder: $(show)"
reply c-002 SPOOL_CHANNEL_RULES_MAP="$MAP" TAIL="$HUMPOST" NO_WITH_CH=1
ok_sent && grep -q 'sole-seat rule is not checked' "$T/o" && grep -q 'hub-tail|--task|'"$TK"'|--json' "$T/calls" &&
  pass "a spool without --with-channel: plain --json, the rule not checked, a WARN" || fail "old binary path: $(show)"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "ALL PASSED"
