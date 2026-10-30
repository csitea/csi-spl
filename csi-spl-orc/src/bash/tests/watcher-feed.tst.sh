#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_watcher_feed (spec 165 row B5, section 3.2) writes the feed
#          an agy watcher reads, and its filter is the data rule's boundary:
#          a planted secret-kind lane, a planted orchestration-kind lane, the
#          orch seat (the lease holder, and a role seat) and lanes it cannot
#          classify (no brief, no Kind:, an unknown kind, a "Data: secret"
#          marker) leave NOTHING in the feed. Each planted lane carries a
#          unique token in its brief, pane and messages, and the check greps
#          the whole feed for it: a ban list cannot prove absence (global
#          CLAUDE.md), a token that is never written can. Also: the kept lane
#          is complete, per-message rules (no inbox mail from a dropped lane,
#          no outbox mail to one), DRY_RUN=1 writes nothing, a rerun replaces
#          the feed whole. A scratch spool root and feed dir only.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: no jq"; exit 1; }

S="$T/spool"; FEED="$T/out/feed"
mkdir -p "$S/dispatch" "$T/out" "$T/panes"
: >"$S/registry.tsv"

# lane <id> <pane> <brief text>: a registered lane whose brief, pane and
# outbox carry the token TOK-<id>
lane() {
  local id="$1" pane="$2"
  mkdir -p "$S/$id/lifetime" "$S/$id/inbox" "$S/$id/outbox" "$S/$id/archive"
  [[ -n "$3" ]] && printf '%s\nTOK-%s brief\n' "$3" "$id" >"$S/$id/lifetime/brief.md"
  printf '%s\tclaude\t%s\t/w/%s\t20261030T000000Z\t-\n' "$id" "$pane" "$id" >>"$S/registry.tsv"
  printf 'TOK-%s pane\n' "$id" >"$T/panes/${pane#%}.txt"
  msg "$id" outbox "$id" orchestrator "TOK-$id outbox"
}
# msg <lane> <sub> <from> <to> <body>
msg() {
  jq -n --arg f "$3" --arg t "$4" --arg b "$5" \
    '{v:1, msg_id:("m-" + $b | gsub(" "; "-")), from:$f, to:$t, kind:"note", task_id:"t", ts:"2026-10-30T00:00:00Z", body:$b}' \
    >"$S/$1/$2/20261030T00000$((RANDOM % 10))Z--$3--$(printf '%s' "$5" | tr -c 'A-Za-z0-9' -).json"
}

lane c-501 %1 "Kind: simple_coding"
lane c-502 %2 "Kind: secret"
lane c-503 %3 "Class: feature
Kind: orchestration"
lane c-504 %4 "Kind: complex_coding"
printf 'c-504@box-a 1761782400\n' >"$S/dispatch/lease.orch"
lane c-001 %5 "Kind: specs_and_docs"
lane c-505 %6 "no kind line here"
lane c-506 %7 ""
lane c-507 %8 "Kind: frobnicate"
lane c-508 %9 "Kind: tests
Data: secret"
lane c-509 %10 "Kind: **i18n**"
# an id re-registers: its last row's pane is the one captured
printf 'c-509\tclaude\t%%11\t/w/c-509\t20261030T010000Z\t-\n' >>"$S/registry.tsv"
printf 'TOK-c-509-oldpane\n' >"$T/panes/10.txt"; printf 'c-509 new pane\n' >"$T/panes/11.txt"
# per-message rules on the kept lane c-501
msg c-501 inbox c-502 c-501 "TOK-c-502 to-kept-inbox"
msg c-501 archive c-001@box-a c-501 "TOK-c-001 orch-to-kept"
msg c-501 inbox c-509 c-501 "c-509 says hi"
msg c-501 outbox c-501 c-503 "TOK-c-503 kept-to-secret"
msg c-501 outbox c-501 c-002@box-a "c-501 to dispatch"
msg c-501 outbox c-502 c-509 "TOK-c-502 forged-from"

printf '#!/bin/sh\ncat "%s/panes/$(printf %%s "$1" | tr -d %%).txt"\n' "$T" >"$T/cap.sh"; chmod +x "$T/cap.sh"

feed() {
  env -u WATCHER_FEED_DIR -u WATCHER_FEED_LEASE -u WATCHER_FEED_REGISTRY -u WATCHER_FEED_MSGS \
    PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_TEST=1 WATCHER_FEED_DIR="$FEED" \
    WATCHER_FEED_CAPTURE="$T/cap.sh" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { command -v "$1" >/dev/null; }
    for f in "$PROJ_PATH"/src/bash/run/{spl-watcher-feed,spl-lane-mix,spl-spawn-place}.func.sh; do source "$f"; done
    do_spl_watcher_feed' >"$T/log" 2>&1 </dev/null
}

# 1. DRY_RUN unset = 1: the plan is printed, nothing written
feed; rc=$?
if [[ $rc == 0 && ! -e "$FEED" ]] && grep -q 'DRY_RUN=1, nothing written' "$T/log"; then pass "DRY_RUN default writes nothing"
else fail "DRY_RUN default (rc=$rc): $(ls "$T/out"; cat "$T/log")"; fi

# 2. the real run
feed DRY_RUN=0; rc=$?
[[ $rc == 0 && -d "$FEED/lanes" ]] && pass "DRY_RUN=0 writes the feed" || fail "write rc=$rc: $(cat "$T/log")"

# 3. nothing of a dropped lane reaches the feed: its token, its dir, its row
for id in c-502 c-503 c-504 c-001 c-505 c-506 c-507 c-508; do
  hit="$(grep -rl "TOK-$id" "$FEED" 2>/dev/null)"
  if [[ -z "$hit" && ! -e "$FEED/lanes/$id" ]] && ! grep -q "^$id"$'\t' "$FEED/registry.tsv" "$FEED/lanes.tsv"; then
    pass "$id ($(grep "^DROP $id:" "$T/log" | sed 's/^DROP [^:]*: //')) is absent from the feed"
  else fail "$id reached the feed: ${hit:-dir or row}"; fi
done
grep -q '^DROP c-502: secret-class kind secret$' "$T/log" && grep -q '^DROP c-503: secret-class kind orchestration$' "$T/log" \
  && pass "secret and orchestration are dropped as secret-class" || fail "secret-class reasons: $(grep DROP "$T/log")"
grep -q '^DROP c-504: orch lease holder$' "$T/log" && grep -q '^DROP c-001: role seat$' "$T/log" \
  && pass "the orch lease holder and a role seat are dropped" || fail "orch reasons: $(grep DROP "$T/log")"
grep -q '^DROP c-505: no readable Kind:$' "$T/log" && grep -q '^DROP c-506: no readable brief$' "$T/log" \
  && grep -q '^DROP c-507: kind frobnicate is not on the feed allow-list$' "$T/log" \
  && grep -q '^DROP c-508: data-rule marker Data: secret$' "$T/log" \
  && pass "fail closed: no Kind:, no brief, unknown kind, Data: secret" || fail "fail-closed reasons: $(grep DROP "$T/log")"

# 4. the kept lanes are whole
if [[ "$(cat "$FEED/lanes.tsv")" == $'c-501\tsimple_coding\nc-509\ti18n' ]] \
  && grep -q 'TOK-c-501 pane' "$FEED/lanes/c-501/pane.txt" && [[ "$(cat "$FEED/lanes/c-501/kind")" == simple_coding ]] \
  && grep -rq 'TOK-c-501 outbox' "$FEED/lanes/c-501/outbox" \
  && [[ "$(cut -f1 "$FEED/registry.tsv" | tr '\n' ' ')" == "c-501 c-509 c-509 " ]]; then pass "kept lanes: kind, pane, outbox, registry rows"
else fail "kept lanes: $(cat "$FEED/lanes.tsv"; find "$FEED" -type f)"; fi
grep -q 'c-509 new pane' "$FEED/lanes/c-509/pane.txt" && pass "a re-registered id captures its last pane" \
  || fail "c-509 pane: $(cat "$FEED/lanes/c-509/pane.txt")"

# 5. per-message rules: mail from a kept lane and to a role seat stays
grep -rq 'c-509 says hi' "$FEED/lanes/c-501/inbox" && grep -rq 'c-501 to dispatch' "$FEED/lanes/c-501/outbox" \
  && pass "kept lane mail: from a kept lane, to a role seat" || fail "kept mail: $(find "$FEED/lanes/c-501" -type f)"
[[ "$(find "$FEED" -name '*.json' | wc -l)" == 4 ]] && pass "exactly 4 messages in the feed" \
  || fail "messages: $(find "$FEED" -name '*.json')"

# 6. a rerun replaces the feed whole: a lane that turns secret disappears
printf 'Kind: secret\n' >"$S/c-509/lifetime/brief.md"
feed DRY_RUN=0
[[ ! -e "$FEED/lanes/c-509" && "$(cut -f1 "$FEED/lanes.tsv")" == c-501 ]] && ! ls -d "$T/out/"feed.* >/dev/null 2>&1 \
  && pass "rerun replaces the feed, no leftover dirs" || fail "rerun: $(ls -a "$T/out"; cat "$FEED/lanes.tsv")"

# 7. SPOOL_ROOT unset fails fast
env -u SPOOL_ROOT PROJ_PATH="$PROJ_ROOT" bash -c 'do_log() { echo "$*"; }
  source "$PROJ_PATH/src/bash/run/spl-watcher-feed.func.sh"; do_spl_watcher_feed' >"$T/log" 2>&1
grep -q 'SPOOL_ROOT must be set' "$T/log" && pass "SPOOL_ROOT unset fails fast" || fail "no SPOOL_ROOT: $(cat "$T/log")"

echo "watcher-feed: $fails failure(s)"
[[ $fails == 0 ]]
