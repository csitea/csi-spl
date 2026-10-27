#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-3819 (how-to-post.md rule 15; owner HUM-10, csitea topic
#          a1ae72a7, msg a6c87420) - do_spl_desk_reply refuses a body that
#          says a lane is working NOW ("is checking", "is working on", "is
#          building", "a lane ... now", or **In progress** with an ask id)
#          while the named ask is not placed in the hub ask book. The
#          dispatcher's post 00109478 said "a lane (ask ec43caa4) is checking
#          every item of this topic ... now" while the ask waited in line.
#   1. RED CONTROL: "a lane (ask <queued>) is checking ... now" is refused,
#      the FATAL names the id, its position, its hold reason and "queued";
#      the same post saying "queued" is sent
#   2. each running claim ("is working on", "is building", "is checking",
#      "a lane ... now", **In progress** + id) on a queued ask -> refused
#   3. the ask is placed (done "placed: <ID>@<box>") -> sent
#   4. no hold reason recorded on this machine -> the FATAL says so
#   5. an open / declined ask said running -> refused; an id the book lacks
#      (a msg id, a sha) -> sent; a quote or a fence -> sent, book not read
#   6. no claim, or a claim naming no 8-hex id -> sent, the book never read
#   7. the hub does not answer and the journal has no such ask: one WARN, sent
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux
TOPIC=a1ae72a7-e540-4b7a-b6b8-47eb65fe1e49
Q=ec43caa4-0000-4000-8000-000000000001   # queued, held
R=1b2c3d4e-0000-4000-8000-000000000002   # queued, no hold reason here
P=2c3d4e5f-0000-4000-8000-000000000003   # done placed
O=3d4e5f60-0000-4000-8000-000000000004   # open
X=4e5f6071-0000-4000-8000-000000000005   # declined

cat >"$T/book.json" <<EOF
[{"ask_id":"$Q","state":"queued","reason":"","position":2,"queue_len":5},
 {"ask_id":"$R","state":"queued","reason":"","position":4,"queue_len":5},
 {"ask_id":"$P","state":"done","reason":"placed: c-773@box-a"},
 {"ask_id":"$O","state":"open","reason":""},
 {"ask_id":"$X","state":"declined","reason":"no room"}]
EOF
printf '#!/bin/sh\necho read >>"%s"\ncat "%s"\n' "$T/book.reads" "$T/book.json" >"$T/book.sh"
chmod +x "$T/book.sh"
printf '%s\t%s\t%s\n' "$Q" "$(date +%s)" "waiting: claude weekly >= 90% on box-a" >"$T/place.wait"

mkdir -p "$T/state/dev/desk/t1/box-desk/spool/CLE-00"
STUBS='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }
spl_host_spool() { :; }
spl_desk_spool() {
  while [[ $# -gt 0 && "$1" != -- ]]; do shift; done; shift
  local a prev=""; for a in "$@"; do [[ "$prev" == --body ]] && printf "%s" "$a" >"$SENT_BODY"; prev="$a"; done
  echo "{\"msg_id\":\"m1\"}"
}'

# send <body> [VAR=value]... -> rc; output in $T/o, the sent body in $T/sent
send() {
  local body="$1"; shift
  rm -f "$T/sent" "$T/book.reads"
  SNIPPET="$STUBS"$'\n'"${EXTRA:-}"$'\n''do_spl_desk_reply' in_orc TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT=CLE-00 DESK_TO=HUM-10 \
    DESK_TASK="$TOPIC" DESK_BODY="$body" DRY_RUN=0 SENT_BODY="$T/sent" PLANNED_ASKS_CMD="$T/book.sh" \
    SPL_DESK_PLACE_WAIT="$T/place.wait" "$@" >"$T/o" 2>&1
}
refused() { # <label> [must-name]...: rc != 0, nothing sent, the FATAL names the rule
  local label="$1" n ok=1; shift
  (( rc != 0 )) && [[ ! -e "$T/sent" ]] && grep -q 'FATAL nothing was sent: the post says a lane is working now' "$T/o" &&
    grep -q 'how-to-post.md rule 15, SPL-3819' "$T/o" || ok=0
  for n in "$@"; do grep -qF -- "$n" "$T/o" || ok=0; done
  (( ok )) && pass "$label" || fail "$label (rc $rc): $(cat "$T/o")"
}
sent() { # <label> <body>: rc 0 and the body reached the spool byte for byte
  (( rc == 0 )) && [[ -f "$T/sent" && "$(cat "$T/sent")" == "$2" ]] && ! grep -q FATAL "$T/o" &&
    pass "$1" || fail "$1 (rc $rc, sent '$(cat "$T/sent" 2>/dev/null)'): $(cat "$T/o")"
}
unread() { [[ ! -e "$T/book.reads" ]] && pass "$1 ... and the book is not read" || fail "$1: the book was read"; }

# --- 1. RED CONTROL ---------------------------------------------------------------
B="A lane (ask ${Q:0:8}) is checking every item of this topic against the served build now."
send "$B"; rc=$?
refused "1. 'a lane (ask <queued>) is checking ... now' is refused, nothing sent" \
  "FATAL ask ${Q:0:8} is queued (position 2 of 5, held: waiting: claude weekly >= 90% on box-a), not running: say 'queued' and why"
B="A lane (ask ${Q:0:8}) is queued (position 2): it will check every item once claude has quota."
send "$B"; rc=$?
sent "1. CONTROL: the same post saying queued is sent" "$B"

# --- 2. every running claim -------------------------------------------------------
for B in "Ask ${Q:0:8} is working on the cards." "The lane for ask ${Q:0:8} is building the fix." \
  "c-500 (ask ${Q:0:8}) is checking the lobby." "A lane of ask ${Q:0:8} reads every post now." \
  $'**In progress** (since 10:00Z): the cards.\n\nAsk '"${Q:0:8}"' carries it.' "**In progress** (ask $Q): cards."; do
  send "$B"; rc=$?
  refused "2. '${B:0:40}' on a queued ask is refused" "FATAL ask ${Q:0:8} is queued"
done

# --- 3. placed --------------------------------------------------------------------
B="A lane (ask ${P:0:8}, c-773) is checking every item now."
send "$B"; rc=$?
sent "3. the ask is placed: sent" "$B"
B="**In progress** (c-773, ask ${P:0:8}, since 10:00Z): the cards."
send "$B"; rc=$?
sent "3. In progress on a placed ask: sent" "$B"

# --- 4. no hold reason here -------------------------------------------------------
send "Ask ${R:0:8} is building it now."; rc=$?
refused "4. queued, no hold reason on this machine" "FATAL ask ${R:0:8} is queued (position 4 of 5, held: no reason recorded on this machine)"

# --- 5. other states, ids the book lacks, quotes ----------------------------------
send "Ask ${O:0:8} is working on it."; rc=$?
refused "5. an open ask said running is refused" "FATAL ask ${O:0:8} is open, not running"
send "Ask ${X:0:8} is working on it."; rc=$?
refused "5. a declined ask said running is refused" "FATAL ask ${X:0:8} is declined, not running"
B="c-500 is working on it (your msg 7a8b9c0d, sha 9f8e7d6c)."
send "$B"; rc=$?
sent "5. 8-hex ids the book lacks (a msg id, a sha): sent" "$B"
for B in "> a lane (ask ${Q:0:8}) is checking it now" $'```\nask '"${Q:0:8}"' is building\n```'; do
  send "$B"; rc=$?
  sent "5. '${B:0:20}' (quote / fence) is sent" "$B"
  unread "5. '${B:0:20}'"
done

# --- 6. no claim, no id -----------------------------------------------------------
for B in "Ask ${Q:0:8} waits in line at position 2." "c-500 is checking every item now." \
  "**In progress** (c-500, since 10:00Z): cards."; do
  send "$B"; rc=$?
  sent "6. '${B:0:30}' is sent" "$B"
  unread "6. '${B:0:30}'"
done

# --- 7. the hub does not answer ---------------------------------------------------
EXTRA='spl_desk_planned_book() { echo unreachable; echo "[]"; }' send "Ask ${Q:0:8} is building it now."; rc=$?
(( rc == 0 )) && [[ -f "$T/sent" ]] && grep -q "WARN the running claim's ask was not checked" "$T/o" &&
  pass "7. the hub does not answer: one WARN, the post is sent" || fail "7. hub unreachable (rc $rc): $(cat "$T/o")"

echo "desk-running-ask: $fails failure(s)"
((fails == 0))
