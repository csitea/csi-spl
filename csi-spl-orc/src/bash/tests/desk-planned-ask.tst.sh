#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-3525 (how-to-post.md rule 15, fix E of the grok dispatch grade,
#          grok-dispatch-grade-2026-10-25.md section 5) - do_spl_desk_reply
#          refuses a body whose state line is **Planned, not built yet.**
#          unless it names an ask id the hub ask book shows queued or placed.
#          The grade lost points on feature asks answered "not built" with
#          nothing placed or queued.
#   1. RED CONTROL: Planned with no ask id is refused, the FATAL names the
#      rule and how to queue, nothing reaches the spool; the same text with
#      a queued ask's id is sent
#   2. an id that is open, acked, declined, done without "placed: ", or not
#      in the book at all -> refused
#   3. queued (8 hex or the whole id) and done "placed: <ID>@<box>" -> sent
#   4. other state lines, and "Planned" that is not the state line -> sent,
#      the book never read
#   5. a reply tagged @HUM-n before **Planned** is still checked
#   6. DESK_PLANNED_CHECK=0 (the issue-filing post) -> sent unchecked
#   7. the hub does not answer and the journal has no such ask: one WARN,
#      sent; with no fleet the journal is the whole book (real asks code)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux
TOPIC=99ffa592-3717-4b9e-8a80-62c70456ceff
Q=1a2b3c4d-0000-4000-8000-000000000001   # queued
P=2b3c4d5e-0000-4000-8000-000000000002   # done placed
O=3c4d5e6f-0000-4000-8000-000000000003   # open
A=4d5e6f70-0000-4000-8000-000000000004   # acked
D=5e6f7081-0000-4000-8000-000000000005   # done, not placed
X=6f708192-0000-4000-8000-000000000006   # declined

cat >"$T/book.json" <<EOF
[{"ask_id":"$Q","state":"queued","reason":""},
 {"ask_id":"$P","state":"done","reason":"placed: c-773@box-a"},
 {"ask_id":"$O","state":"open","reason":""},
 {"ask_id":"$A","state":"acked","reason":""},
 {"ask_id":"$D","state":"done","reason":"answered in the topic"},
 {"ask_id":"$X","state":"declined","reason":"no room"}]
EOF
printf '#!/bin/sh\necho read >>"%s"\ncat "%s"\n' "$T/book.reads" "$T/book.json" >"$T/book.sh"
chmod +x "$T/book.sh"

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
    DESK_TASK="$TOPIC" DESK_BODY="$body" DRY_RUN=0 SENT_BODY="$T/sent" PLANNED_ASKS_CMD="$T/book.sh" "$@" >"$T/o" 2>&1
}
refused() { # <label> [must-name]...: rc != 0, nothing sent, the FATAL names the rule and how to queue
  local label="$1" n ok=1; shift
  (( rc != 0 )) && [[ ! -e "$T/sent" ]] && grep -q 'FATAL nothing was sent: a \*\*Planned, not built yet.\*\* answer names the ask' "$T/o" &&
    grep -q 'how-to-post.md rule 15, SPL-3525' "$T/o" && grep -q 'FATAL queue the lane first' "$T/o" || ok=0
  for n in "$@"; do grep -qF -- "$n" "$T/o" || ok=0; done
  (( ok )) && pass "$label" || fail "$label (rc $rc): $(cat "$T/o")"
}
sent() { # <label> <body>: rc 0 and the body reached the spool byte for byte
  (( rc == 0 )) && [[ -f "$T/sent" && "$(cat "$T/sent")" == "$2" ]] && ! grep -q FATAL "$T/o" &&
    pass "$1" || fail "$1 (rc $rc, sent '$(cat "$T/sent" 2>/dev/null)'): $(cat "$T/o")"
}
PL='**Planned, not built yet.**'

# --- 1. RED CONTROL ---------------------------------------------------------------
B="$PL The cards will be the same height. Tracked as SPL-1."
send "$B"; rc=$?
refused "1. Planned with no ask id is refused, nothing sent"
send "$B Queued as ask ${Q:0:8}."; rc=$?
sent "1. CONTROL: the same text naming a queued ask is sent" "$B Queued as ask ${Q:0:8}."

# --- 2. not queued, not placed ------------------------------------------------------
for id in "$O" "$A" "$D" "$X" 7a8b9c0d; do
  send "$PL Ask ${id:0:8}."; rc=$?
  refused "2. ask ${id:0:8} ($(jq -r --arg i "$id" '[.[] | select(.ask_id == $i) | .state][0] // "not in the book"' "$T/book.json")) is refused" "none is: ${id:0:8}"
done

# --- 3. queued / placed ---------------------------------------------------------------
send "$PL Queued: $Q (position 3)."; rc=$?
sent "3. a queued ask's whole id is sent" "$PL Queued: $Q (position 3)."
send "$PL Ask ${O:0:8} was answered; lane ask ${P:0:8} is placed."; rc=$?
sent "3. one placed ask among others is enough" "$PL Ask ${O:0:8} was answered; lane ask ${P:0:8} is placed."

# --- 4. other states ------------------------------------------------------------------
for B in '**In progress** (c-1, since 10:00Z): cards.' '**Landed, not live yet.** On master.' \
  $'Answer first.\n\n**Planned, not built yet.** for the rest.' 'Planned, not built yet (no bold: no state line).'; do
  send "$B"; rc=$?
  sent "4. '${B:0:30}' is sent" "$B"
  [[ ! -e "$T/book.reads" ]] && pass "4. ... and the book is not read" || fail "4. the book was read for '${B:0:30}'"
done

# --- 5. tagged reply --------------------------------------------------------------------
send $'\n@HUM-10 **Planned, not built:** cards.'; rc=$?
refused "5. '@HUM-10 **Planned, not built:**' is checked like Planned"

# --- 6. the issue-filing post -----------------------------------------------------------
send "$PL Tracked as **SPL-9**: cards (lane c-1)." DESK_PLANNED_CHECK=0; rc=$?
sent "6. DESK_PLANNED_CHECK=0 sends the filing post unchecked" "$PL Tracked as **SPL-9**: cards (lane c-1)."
grep -q 'DESK_PLANNED_CHECK=0 DESK_TASK=' "$PROJ_ROOT/src/bash/run/spl-lane-issue.func.sh" &&
  pass "6. spl_lane_issue_post sets it" || fail "6. spl_lane_issue_post does not set DESK_PLANNED_CHECK=0"

# --- 7. the real book -------------------------------------------------------------------
EXTRA='spl_desk_planned_book() { echo unreachable; echo "[]"; }' send "$PL Ask ${Q:0:8}."; rc=$?
(( rc == 0 )) && [[ -f "$T/sent" ]] && grep -q "WARN the Planned post's ask was not checked" "$T/o" &&
  pass "7. the hub does not answer: one WARN, the post is sent" || fail "7. hub unreachable (rc $rc): $(cat "$T/o")"
mkdir -p "$T/spool/asks"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"ask_id":"%s","role":"orch","kind":"task","from":"c-1@box-a","topic":"%s","summary":"cards","state":"queued","reason":"","created_at":"%s","updated_at":"%s","synced":true}\n' \
  "$Q" "$TOPIC" "$NOW" "$NOW" >"$T/spool/asks/$Q.json"
send "$PL Ask ${Q:0:8}." PLANNED_ASKS_CMD= SPOOL_ROOT="$T/spool" LANE_FLEET= ASKS_FLEET=; rc=$?
sent "7. no fleet: a queued ask in the journal is sent" "$PL Ask ${Q:0:8}."
send "$PL Ask ${O:0:8}." PLANNED_ASKS_CMD= SPOOL_ROOT="$T/spool" LANE_FLEET= ASKS_FLEET=; rc=$?
refused "7. no fleet: an ask the journal lacks is refused" "none is: ${O:0:8}"

echo "desk-planned-ask: $fails failure(s)"
((fails == 0))
