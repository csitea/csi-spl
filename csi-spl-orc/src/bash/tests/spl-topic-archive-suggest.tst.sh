#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_topic_archive_suggest (spec 041 section 7, SPL-5520) posts
# one archive poll to a finished, quiet owner topic, and acts on the answer.
# A stub hub: the idle list, the ask book, the topic tails, the desk reply and
# the archive are functions replaced here.
#   1. four candidates, each failing one condition but one: only the free one
#      is polled, addressed to its human; the keep lines name each reason
#   2. one poll per topic: a second run (forced past the day stamp) posts
#      nothing; without force the day stamp alone stops it
#   3. red controls: a code variant without condition 1 (result), 2 (ask) or
#      3 (24 h quiet) polls the topic that condition kept
#   4. the answer: A archives through do_spl_topic_archive, B keeps and mutes
#      the topic 7 days, after which it may be polled again; no answer: nothing
#   5. DRY_RUN=1 (the default) posts and archives nothing, plans the poll and
#      the archive, writes no ledger row and no stamp
#   6. not the dispatch holder's box: nothing read; an ask book with hub off
#      stops the polls; a bad ARCHIVE_SUGGEST_MAX is refused
#   7. a topic with no human post is no owner topic; ARCHIVE_SUGGEST_MAX caps
#      the polls, newest first
#   8. the cron: its script refuses a worktree and passes
#      ARCHIVE_SUGGEST_DRY_RUN from lease.conf (default 1: off)
#   9. do_spl_topic_archive_suggest_install_cron: dry diff, one exact hourly
#      line, idempotent, check, remove
#  10. R7 W1: a person's post after the result, or a post younger than 24 h
#      in the tail (it came after the list), keeps the topic; red control
#  11. R7 W2: two polls to one person are two texts (the hub's
#      duplicate_to_human); a failed poll still stamps the day, rc 1
#  12. R7 W3: a held run lock does nothing; a live run needs this box to be
#      ARCHIVE_SUGGEST_BOX; an archive poll as the last post is polled already
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
FUNC="$PROJ_ROOT/src/bash/run/spl-topic-archive-suggest.func.sh"
A=a1a1a1a1-0000-4000-8000-000000000001
B=b2b2b2b2-0000-4000-8000-000000000002
C=c3c3c3c3-0000-4000-8000-000000000003
D=d4d4d4d4-0000-4000-8000-000000000004
E=e5e5e5e5-0000-4000-8000-000000000005
NOW=2026-11-14T08:00:00Z
OLD=2026-11-12T10:00:00Z
FRESH=2026-11-14T02:00:00Z

mkdir -p "$T/spool/dispatch" "$T/tails"
echo "c-002@box-a 1793464017" >"$T/spool/dispatch/lease"
printf 'LEASE_ORCH=c-001\nLEASE_ENV=dev\nLEASE_TENANT=t1\n' >"$T/spool/dispatch/lease.conf"

# topic <uuid> <last_at> [last_msg_id]: a hub list row; with no third
# argument the stub hub names the tail's newest line (the hub sees every box).
topic() { printf '{"task_id": "%s", "last_at": "%s"%s}' "$1" "$2" "${3:+, \"last_msg_id\": \"$3\"}"; }
line() { printf '{"msg_id": "%s", "from": "%s", "kind": "%s", "ts": "%s", "body": "%s"}\n' "$@"; }
# tail_of <uuid> <last agent kind> <last agent body> [human]: a topic where the
# human asks and an agent answers last.
tail_of() {
  { [[ "${4:-HUM-10}" == none ]] || line "m1-$1" "${4:-HUM-10}" msg 2026-11-12T09:00:00Z "please check"
    line "m2-$1" c-002@box-a "$2" 2026-11-12T10:00:00Z "$3"; } >"$T/tails/$1.ndjson"
}
asks() { printf '{"fleet": "main", "hub": "%s", "asks": %s}\n' "${ASKS_HUB:-ok}" "$1" >"$T/asks.json"; }
cands() { printf '{"topics": [%s]}\n' "$1" >"$T/cands.json"; }

# the four cases: A free, B last agent post a note, C an open ask, D fresh.
fixture4() {
  cands "$(topic "$A" "$OLD"), $(topic "$B" "$OLD"), $(topic "$C" "$OLD"), $(topic "$D" "$FRESH")"
  tail_of "$A" result "all done"; tail_of "$B" note "still looking"
  tail_of "$C" note "**Done** landed"; tail_of "$D" result "x"
  asks "[{\"ask_id\": \"ask-1\", \"state\": \"queued\", \"topic\": \"dispatch-${C:0:8}\", \"summary\": \"x\"}]"
}

# variant FN SED: a snippet re-defining FN with SED applied (red controls).
variant() { printf 'eval "$(declare -f %s | sed %q)"' "$1" "$2"; }

# suggest [VAR=value]... [-- SNIPPET]: the action in a fresh bash with the
# stub hub; posts land in $T/posted, archives in $T/archived, reads in $T/reads.
suggest() {
  local -a vars=(); local snip=""
  while (($#)); do [[ "$1" == -- ]] && { snip="$2"; break; }; vars+=("$1"); shift; done
  env APP_PATH="$APP_ROOT" PROJ_PATH="$PROJ_ROOT" FUNC="$FUNC" T="$T" SNIPPET="$snip" \
    SPOOL_ROOT="$T/spool" SPOOL_BOX_TAG=box-a ARCHIVE_SUGGEST_NOW="$NOW" ARCHIVE_SUGGEST_FORCE=1 \
    ENV= TENANT_ID= DESK_AGENT= DESK_BOX=box-desk "${vars[@]}" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    spl_dry_run() { local d="${DRY_RUN:-1}"; [[ "$d" == 0 || "$d" == 1 ]] || return 2; [[ "$d" == 1 ]]; }
    source "$FUNC"
    do_spl_desk_cnf() { :; }
    spl_desk_action_hop_to() { return 1; }
    spl_zombie_hub_list() { echo "hub $ZOMBIE_IDLE_DAYS ${ZOMBIE_ORDER:-} ${ZOMBIE_SCOPE:-} $ZOMBIE_LIST_LIMIT" >>"$T/reads"; hub_heads; }
    hub_heads() { python3 -c "
import json, os, sys
d = json.load(open(sys.argv[1]))
for t in d[\"topics\"]:
    p = sys.argv[2] + \"/\" + t[\"task_id\"] + \".ndjson\"
    if \"last_msg_id\" not in t and os.path.exists(p):
        ms = sorted((json.loads(x) for x in open(p) if x.strip()), key=lambda m: (m[\"ts\"], m[\"msg_id\"]))
        t[\"last_msg_id\"] = ms[-1][\"msg_id\"] if ms else None
print(json.dumps(d))" "$T/cands.json" "$T/tails"; }
    do_spl_asks_open() { echo "INFO a log line"; cat "$T/asks.json"; }
    spl_archive_suggest_tail() { cat "$T/tails/$1.ndjson"; }
    do_spl_desk_reply() {
      echo "$DESK_TASK $DESK_TO $DESK_AGENT $TENANT_ID $ENV $DESK_KIND" >>"$T/posted"
      printf "%s\n" "$DESK_BODY" >"$T/body"; sed -n 1p <<<"$DESK_BODY" >>"$T/bodies"
      [[ -z "${POST_FAIL:-}" || "$DESK_TASK" != "$POST_FAIL" ]] || { echo "FATAL 409 duplicate_to_human"; return 7; }
      echo "{\"send\": {\"msg_id\": \"poll-${DESK_TASK:0:8}\"}}"
    }
    do_spl_topic_archive() { echo "$TOPIC $MODE $DRY_RUN $DESK_AGENT $TENANT_ID" >>"$T/archived"; }
    eval "$SNIPPET"
    do_spl_topic_archive_suggest' >"$T/out" 2>&1
}
reset() { rm -f "$T/posted" "$T/archived" "$T/reads" "$T/body" "$T/bodies" "$T/spool/dispatch/archive-suggest.tsv" "$T/spool/dispatch/archive-suggest.last"; }
posted() { [[ -f "$T/posted" ]] && cut -d' ' -f1 "$T/posted" | tr '\n' ' ' | sed 's/ $//'; }
LED="$T/spool/dispatch/archive-suggest.tsv"

# --- 1. only the topic that meets all three conditions is polled ---------------------
reset; fixture4
suggest DRY_RUN=0; rc=$?
[[ $rc == 0 && "$(posted)" == "$A" ]] && pass "1. only $A is polled (B: note last, C: open ask, D: 3 h quiet)" ||
  fail "1. posted '$(posted)' rc=$rc: $(cat "$T/out")"
grep -q "^$A HUM-10 c-002 t1 dev note$" "$T/posted" 2>/dev/null &&
  pass "1. the poll goes to the topic's human, posted by the dispatch holder in the lease's tenant and env" || fail "1. post call: $(cat "$T/posted" 2>/dev/null)"
grep -q "keep.$B.last agent post is no result" "$T/out" && grep -q "keep.$C.ask ask-1" "$T/out" && grep -q "keep.$D.quiet .*under 24 h" "$T/out" &&
  pass "1. one keep line per excluded topic, with its condition" || fail "1. keep lines: $(cat "$T/out")"
grep -q '^```poll$' "$T/body" && grep -q '^(A) Archive$' "$T/body" && grep -q '^(B) Keep (no suggestion for 7 days)$' "$T/body" &&
  pass "1. the body is a poll form: (A) Archive, (B) Keep" || fail "1. body: $(cat "$T/body" 2>/dev/null)"
grep -q "^$A	asked	$NOW	poll-a1a1a1a1	t1$" "$LED" 2>/dev/null && pass "1. the ledger holds the asked row with the poll id" || fail "1. ledger: $(cat "$LED" 2>/dev/null)"
grep -q '^hub 1 newest open 500$' "$T/reads" && pass "1. the hub list is read with idle_days=1 (24 h), order=newest, scope=open (R7 W4), limit 500" || fail "1. reads: $(cat "$T/reads" 2>/dev/null)"
[[ "$(cat "$T/spool/dispatch/archive-suggest.last" 2>/dev/null)" == 2026-11-14 ]] && pass "1. the day is stamped" || fail "1. stamp"

# --- 2. one poll per topic ---------------------------------------------------------
rm -f "$T/posted"
suggest DRY_RUN=0; rc=$?
[[ $rc == 0 && ! -e "$T/posted" ]] && grep -q "keep.$A.polled $NOW" "$T/out" &&
  pass "2. a second run (forced past the stamp) posts nothing: $A is polled already" || fail "2. second run: rc=$rc $(cat "$T/posted" "$T/out" 2>/dev/null)"
rm -f "$T/posted" "$T/reads"; sed -i "/^$A	/d" "$LED"
suggest DRY_RUN=0 ARCHIVE_SUGGEST_FORCE=0 ARCHIVE_SUGGEST_BOX=box-a; rc=$?
[[ $rc == 0 && ! -e "$T/posted" && ! -e "$T/reads" ]] && grep -q 'polls of 2026-11-14 were already posted' "$T/out" &&
  pass "2. without force the day stamp alone stops a second run" || fail "2. stamp: rc=$rc $(cat "$T/out")"

# --- 3. red controls: drop one condition, its case is polled -----------------------
reset; fixture4
suggest DRY_RUN=0 -- "$(variant spl_archive_suggest_judge 's/not result(msgs\[-1\])/False/')"
grep -q "^$B " "$T/posted" 2>/dev/null && pass "3. red control: without condition 1 (result) $B is polled" || fail "3. cond 1 red: $(cat "$T/posted" 2>/dev/null)"
reset; fixture4
suggest DRY_RUN=0 -- "$(variant spl_archive_suggest_pick 's/or ask_on(u) //')"
grep -q "^$C " "$T/posted" 2>/dev/null && pass "3. red control: without condition 2 (open ask) $C is polled" || fail "3. cond 2 red: $(cat "$T/posted" 2>/dev/null)"
reset; fixture4
suggest DRY_RUN=0 -- "$(variant spl_archive_suggest_pick 's/ or quiet(t)//')"
grep -q "^$D " "$T/posted" 2>/dev/null && pass "3. red control: without condition 3 (24 h quiet) $D is polled" || fail "3. cond 3 red: $(cat "$T/posted" 2>/dev/null)"
reset; fixture4
suggest DRY_RUN=0 -- "$(variant spl_archive_suggest_pick 's/if st == "asked":/if False:/')"
suggest DRY_RUN=0 -- "$(variant spl_archive_suggest_pick 's/if st == "asked":/if False:/')"
[[ "$(grep -c "^$A " "$T/posted" 2>/dev/null)" == 2 ]] && pass "3. red control: without the ledger check a second run polls $A again" || fail "3. ledger red: $(cat "$T/posted" 2>/dev/null)"

# --- 4. the answers -------------------------------------------------------------------
answer() {  # <uuid> <key> [poll id]
  line "a-$1" HUM-10@box-wui msg 2026-11-14T09:00:00Z "Poll: ${3:-poll-${1:0:8}}\\nAnswer: $2 — x" >>"$T/tails/$1.ndjson"
}
reset; fixture4; suggest DRY_RUN=0
answer "$A" A
rm -f "$T/posted"; suggest DRY_RUN=0 ARCHIVE_SUGGEST_NOW=2026-11-14T10:00:00Z; rc=$?
grep -q "^$A archive 0 c-002 t1$" "$T/archived" 2>/dev/null && grep -q "^$A	archived	" "$LED" && [[ ! -e "$T/posted" ]] &&
  pass "4. answer A archives through do_spl_topic_archive as the holder; ledger archived; no new poll" || fail "4. A: rc=$rc $(cat "$T/archived" "$T/out" 2>/dev/null)"
rm -f "$T/archived"; suggest DRY_RUN=0 ARCHIVE_SUGGEST_NOW=2026-11-14T11:00:00Z
[[ ! -e "$T/archived" ]] && pass "4. an archived topic is not archived twice" || fail "4. twice: $(cat "$T/archived")"
reset; fixture4; suggest DRY_RUN=0
answer "$A" B
suggest DRY_RUN=0 ARCHIVE_SUGGEST_NOW=2026-11-14T10:00:00Z
[[ ! -e "$T/archived" ]] && grep -q "^$A	keep	2026-11-14T10:00:00Z	" "$LED" && pass "4. answer B keeps: no archive, a keep row" || fail "4. B: $(cat "$LED" "$T/out")"
sed -i "s/Answer: B/x/" "$T/tails/$A.ndjson"; line "r-$A" c-002@box-a result 2026-11-15T10:00:00Z "done again" >>"$T/tails/$A.ndjson"
rm -f "$T/posted"; suggest DRY_RUN=0 ARCHIVE_SUGGEST_NOW=2026-11-20T10:00:00Z
! grep -q "^$A " "$T/posted" 2>/dev/null && grep -q "keep.$A.muted" "$T/out" && pass "4. 6 days after Keep the topic is muted" || fail "4. muted: $(cat "$T/out")"
suggest DRY_RUN=0 ARCHIVE_SUGGEST_NOW=2026-11-21T10:00:01Z
grep -q "^$A " "$T/posted" 2>/dev/null && pass "4. 7 days after Keep, with a new result as its last post, it may be polled again" || fail "4. unmuted: $(cat "$T/out")"
reset; fixture4; suggest DRY_RUN=0
line "c-$A" HUM-10 msg 2026-11-14T09:00:00Z "Chat: wants to discuss\\nPoll: poll-a1a1a1a1" >>"$T/tails/$A.ndjson"
line "o-$A" HUM-10 msg 2026-11-14T09:01:00Z "Poll: other\\nAnswer: A" >>"$T/tails/$A.ndjson"
suggest DRY_RUN=0 ARCHIVE_SUGGEST_NOW=2026-11-14T10:00:00Z
[[ ! -e "$T/archived" ]] && [[ "$(tail -1 "$LED" | cut -f2)" == asked ]] &&
  pass "4. a chat reply or an answer to another poll is no answer: nothing archived" || fail "4. no answer: $(cat "$T/archived" "$LED" 2>/dev/null)"

# --- 5. DRY_RUN=1 ----------------------------------------------------------------------
reset; fixture4
suggest; rc=$?
[[ $rc == 0 && ! -e "$T/posted" && ! -e "$LED" && ! -e "$T/spool/dispatch/archive-suggest.last" ]] &&
  grep -q "PLAN poll $A to HUM-10" "$T/out" && grep -q 'would post 1 poll' "$T/out" &&
  pass "5. the default DRY_RUN=1 posts nothing, writes no ledger or stamp, plans $A" || fail "5. dry: rc=$rc $(cat "$T/out")"
printf '%s\tasked\t%s\tpoll-a1a1a1a1\tt1\n' "$A" "$NOW" >"$LED"; answer "$A" A
suggest; rc=$?
[[ ! -e "$T/archived" ]] && grep -q "PLAN archive $A" "$T/out" && [[ "$(wc -l <"$LED")" == 1 ]] &&
  pass "5. a dry run plans the archive of an answered topic and archives nothing" || fail "5. dry A: $(cat "$T/out")"

# --- 6. gates ---------------------------------------------------------------------------
reset; fixture4
suggest DRY_RUN=0 ARCHIVE_SUGGEST_FORCE=0 SPOOL_BOX_TAG=box-b; rc=$?
[[ $rc == 0 && ! -e "$T/reads" && ! -e "$T/posted" ]] && grep -q 'not on this box' "$T/out" &&
  pass "6. not the dispatch holder's box: nothing read, nothing posted" || fail "6. box: rc=$rc $(cat "$T/out")"
reset; fixture4; ASKS_HUB=off asks '[]'
suggest DRY_RUN=0; rc=$?
[[ $rc != 0 && ! -e "$T/posted" && ! -e "$T/spool/dispatch/archive-suggest.last" ]] && grep -q 'ask book was not read' "$T/out" &&
  pass "6. an ask book with hub off: no poll, no stamp, rc $rc" || fail "6. asks off: rc=$rc $(cat "$T/out")"
reset; fixture4
suggest ARCHIVE_SUGGEST_MAX=0; rc=$?
[[ $rc != 0 ]] && grep -q 'ARCHIVE_SUGGEST_MAX must be 1..100' "$T/out" && pass "6. ARCHIVE_SUGGEST_MAX=0 is refused" || fail "6. max: rc=$rc $(cat "$T/out")"

# --- 7. owner topics, the cap -----------------------------------------------------------
reset
cands "$(topic "$A" "$OLD"), $(topic "$B" 2026-11-12T11:00:00Z), $(topic "$E" 2026-11-11T10:00:00Z)"
tail_of "$A" result "done" none; tail_of "$B" result "done"; tail_of "$E" note "## Result\\nall green"
asks '[]'
suggest DRY_RUN=0 ARCHIVE_SUGGEST_MAX=1
[[ "$(posted)" == "$B" ]] && grep -q "keep.$A.no human post" "$T/out" && grep -q "keep.$E.poll cap" "$T/out" &&
  pass "7. no human post: no owner topic; the cap keeps the older $E (a ## Result note counts as a result)" || fail "7. cap: '$(posted)' $(cat "$T/out")"

# --- 10. R7 W1: a person still using the topic ------------------------------------------
reset; asks '[]'
cands "$(topic "$A" "$OLD"), $(topic "$B" "$OLD")"
tail_of "$A" result "all done"; line "f-$A" HUM-10 msg 2026-11-12T11:00:00Z "wait, X is still broken" >>"$T/tails/$A.ndjson"
tail_of "$B" result "all done"; line "f-$B" HUM-10 msg 2026-11-14T07:59:00Z "one more thing" >>"$T/tails/$B.ndjson"
suggest DRY_RUN=0; rc=$?
[[ $rc == 0 && ! -e "$T/posted" ]] && grep -q "keep.$A.last post is a person's" "$T/out" && grep -q "keep.$B.quiet 2026-11-14T07:59:00Z in the tail, under 24 h" "$T/out" &&
  pass "10. a person's follow-up after the result, or a post since the list, keeps the topic" || fail "10. W1: rc=$rc '$(posted)' $(cat "$T/out")"
reset; asks '[]'
cands "$(topic "$A" "$OLD")"
tail_of "$A" result "all done"; line "f-$A" HUM-10 msg 2026-11-12T11:00:00Z "wait, X is still broken" >>"$T/tails/$A.ndjson"
suggest DRY_RUN=0 -- "$(variant spl_archive_suggest_judge 's/elif str(msgs\[-1\].get("from", "")).startswith(people):/elif False:/; s/not result(msgs\[-1\])/not any(map(result, agents[-1:]))/')"
grep -q "^$A " "$T/posted" 2>/dev/null && pass "10. red control: judged on the last agent post (the old code), the follow-up topic $A is polled" || fail "10. W1 red: $(cat "$T/out")"

# --- 11. R7 W2: one text per poll; a failed poll waits a day -------------------------------
reset; asks '[]'
cands "$(topic "$A" "$OLD"), $(topic "$B" "$OLD")"
tail_of "$A" result "all done"; tail_of "$B" result "done too"
suggest DRY_RUN=0 ARCHIVE_SUGGEST_FORCE=0 ARCHIVE_SUGGEST_BOX=box-a; rc=$?
[[ $rc == 0 && "$(sort -u "$T/bodies" 2>/dev/null | wc -l)" == 2 ]] && grep -q "topic \`${A:0:8}\`: its last post is the result \`m2-a1a1a\`" "$T/bodies" &&
  pass "11. two polls to HUM-10, two texts: each names its topic and its result" || fail "11. bodies: rc=$rc $(cat "$T/bodies" "$T/out" 2>/dev/null)"
reset; asks '[]'
cands "$(topic "$A" "$OLD"), $(topic "$B" "$OLD")"
tail_of "$A" result "all done"; tail_of "$B" result "done too"
suggest DRY_RUN=0 ARCHIVE_SUGGEST_FORCE=0 ARCHIVE_SUGGEST_BOX=box-a POST_FAIL="$B"; rc=$?
[[ $rc == 1 && "$(cat "$T/spool/dispatch/archive-suggest.last" 2>/dev/null)" == 2026-11-14 ]] && grep -q "^$A	asked" "$LED" && ! grep -q "^$B	" "$LED" &&
  grep -q 'posted 1 poll(s), failed 1' "$T/out" &&
  pass "11. a failed poll: rc 1, the day stamped all the same (no hourly retry), no ledger row for it" || fail "11. W2 stamp: rc=$rc $(cat "$T/out")"
rm -f "$T/posted" "$T/reads"
suggest DRY_RUN=0 ARCHIVE_SUGGEST_FORCE=0 ARCHIVE_SUGGEST_BOX=box-a ARCHIVE_SUGGEST_NOW=2026-11-14T09:00:00Z; rc=$?
[[ $rc == 0 && ! -e "$T/reads" && ! -e "$T/posted" ]] && pass "11. the next hourly run reads nothing: the day is done" || fail "11. hourly: rc=$rc $(cat "$T/out")"

# --- 12. R7 W3: one run, one box -----------------------------------------------------------
reset; fixture4
( exec 8>>"$T/spool/dispatch/archive-suggest.lock"; flock -n 8; suggest DRY_RUN=0; echo "rc=$?" >"$T/lockrc" )
[[ "$(cat "$T/lockrc")" == rc=0 && ! -e "$T/reads" && ! -e "$T/posted" ]] && grep -q 'another run holds' "$T/out" &&
  pass "12. a run while another holds the lock reads and posts nothing" || fail "12. lock: $(cat "$T/lockrc") $(cat "$T/out")"
reset; fixture4
suggest DRY_RUN=0 ARCHIVE_SUGGEST_FORCE=0; rc=$?
[[ $rc == 0 && ! -e "$T/reads" && ! -e "$T/posted" ]] && grep -q 'no ARCHIVE_SUGGEST_BOX' "$T/out" &&
  pass "12. no ARCHIVE_SUGGEST_BOX: no live run" || fail "12. no pin: rc=$rc $(cat "$T/out")"
reset; fixture4
suggest DRY_RUN=0 ARCHIVE_SUGGEST_FORCE=0 ARCHIVE_SUGGEST_BOX=box-b; rc=$?
[[ $rc == 0 && ! -e "$T/reads" && ! -e "$T/posted" ]] && grep -q 'ARCHIVE_SUGGEST_BOX is box-b, not this box' "$T/out" &&
  pass "12. ARCHIVE_SUGGEST_BOX another box: the holder's box posts nothing" || fail "12. other pin: rc=$rc $(cat "$T/out")"
reset; fixture4; echo ARCHIVE_SUGGEST_BOX=box-a >>"$T/spool/dispatch/lease.conf"
suggest DRY_RUN=0 ARCHIVE_SUGGEST_FORCE=0; rc=$?
sed -i '/^ARCHIVE_SUGGEST_BOX=/d' "$T/spool/dispatch/lease.conf"
[[ $rc == 0 && "$(posted)" == "$A" ]] && pass "12. ARCHIVE_SUGGEST_BOX=this box in lease.conf: the live run posts" || fail "12. pin: rc=$rc $(cat "$T/out")"
reset; fixture4
suggest ARCHIVE_SUGGEST_FORCE=0; rc=$?
[[ $rc == 0 ]] && grep -q "PLAN poll $A" "$T/out" && pass "12. a dry run needs no ARCHIVE_SUGGEST_BOX" || fail "12. dry: rc=$rc $(cat "$T/out")"
reset; asks '[]'
cands "$(topic "$A" "$OLD")"
tail_of "$A" result "all done"; line "p-$A" c-003@box-a note 2026-11-12T12:00:00Z "**Archive suggestion** for topic x" >>"$T/tails/$A.ndjson"
suggest DRY_RUN=0
[[ ! -e "$T/posted" ]] && grep -q "keep.$A.already polled" "$T/out" && pass "12. an archive poll as the last post: polled already" || fail "12. polled: $(cat "$T/out")"

# --- 13. R7 delta W1: the box tail misses another box's last post -----------------------
# hub-tail is box-scoped (BoxTaskEnvelopes): an untagged desk reply or poll
# from another box, or a post delivered only there, is not in this box's
# tail. The hub list names the topic's real last post (topic_heads).
reset; asks '[]'
cands "$(topic "$A" "$OLD" p-other-box), $(topic "$B" "$OLD" n-other-box)"
tail_of "$A" result "all done"; tail_of "$B" result "all done"
suggest DRY_RUN=0; rc=$?
[[ $rc == 0 && ! -e "$T/posted" ]] && grep -q "keep.$A.the box tail misses the last post p-other-" "$T/out" && grep -q "keep.$B.the box tail misses" "$T/out" &&
  pass "13. a last post this box's tail does not hold (another box's poll or note) keeps the topic" || fail "13. W1: rc=$rc '$(posted)' $(cat "$T/out")"
suggest DRY_RUN=0 -- "$(variant spl_archive_suggest_judge 's/elif not msgs or str(msgs\[-1\].get("msg_id", "")) != last:/elif False:/')"
grep -q "^$A " "$T/posted" 2>/dev/null && pass "13. red control: without the last-post check the topic is polled again" || fail "13. W1 red: $(cat "$T/out")"
reset; asks '[]'
cands '{"task_id": "'"$A"'", "last_at": "'"$OLD"'", "last_msg_id": null}'
tail_of "$A" result "all done"
suggest DRY_RUN=0; rc=$?
[[ $rc == 0 && ! -e "$T/posted" ]] && grep -q "keep.$A.the hub list names no last post" "$T/out" &&
  pass "13. a hub list without last_msg_id (an older hub) polls nothing" || fail "13. no last id: rc=$rc $(cat "$T/out")"

# --- 8. the cron script -----------------------------------------------------------------
CRON="$PROJ_ROOT/src/bash/scripts/topic-archive-suggest-cron.sh"
[[ -x "$CRON" ]] && pass "8. the cron script is executable" || fail "8. $CRON is not executable"
out="$(bash "$CRON" 2>&1)"; rc=$?
if [[ "$PROJ_ROOT" == *-wt/* ]]; then
  [[ $rc == 2 ]] && grep -q 'agent worktree' <<<"$out" && pass "8. the cron refuses an agent worktree" || fail "8. worktree: rc=$rc $out"
fi
mkdir -p "$T/orc/src/bash/scripts"; cp "$CRON" "$T/orc/src/bash/scripts/"
printf '#!/bin/bash\necho "archive-suggest: DRY_RUN=$DRY_RUN $*"\n' >"$T/orc/run"; chmod +x "$T/orc/run"
out="$(SPOOL_ROOT="$T/spool" bash "$T/orc/src/bash/scripts/topic-archive-suggest-cron.sh" 2>&1)"
grep -q 'DRY_RUN=1 -a do_spl_topic_archive_suggest' <<<"$out" && pass "8. lease.conf without the switch: the cron runs dry (default off)" || fail "8. dry default: $out"
echo ARCHIVE_SUGGEST_DRY_RUN=0 >>"$T/spool/dispatch/lease.conf"
out="$(SPOOL_ROOT="$T/spool" bash "$T/orc/src/bash/scripts/topic-archive-suggest-cron.sh" 2>&1)"
grep -q 'DRY_RUN=0 -a do_spl_topic_archive_suggest' <<<"$out" && pass "8. ARCHIVE_SUGGEST_DRY_RUN=0 in lease.conf turns it on" || fail "8. on: $out"

# --- 9. the install cron -----------------------------------------------------------------
mkdir -p "$T/bin"
cat >"$T/bin/crontab" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi
cp "$1" "$FAKE_CRONTAB"
EOF
chmod +x "$T/bin/crontab"
SRC="$T/shared"; mkdir -p "$SRC/csi-spl-orc/src/bash/scripts"; printf '#!/bin/sh\n' >"$SRC/csi-spl-orc/run"; chmod +x "$SRC/csi-spl-orc/run"
touch "$SRC/csi-spl-orc/src/bash/scripts/topic-archive-suggest-cron.sh"
printf '*/3 * * * * other job # csi-spl:desk-reconcile\n' >"$T/crontab"
cron() {
  # shellcheck disable=SC2016 # the script is single-quoted on purpose
  env PATH="$T/bin:$PATH" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" FAKE_CRONTAB="$T/crontab" DESK_CRON_SRC="$SRC" \
    ARCHIVE_SUGGEST_CRON_LOG_DIR="$T/log" "$@" bash -c '
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_topic_archive_suggest_install_cron' >"$T/o" 2>&1
}
before="$(md5sum <"$T/crontab")"
cron; rc=$?
[[ $rc -eq 0 && "$(md5sum <"$T/crontab")" == "$before" ]] && grep -q 'topic-archive-suggest-cron.sh >> .*/cron.log 2>&1 # csi-spl:topic-archive-suggest$' "$T/o" &&
  pass "9. installer dry run: the diff, nothing written" || fail "9. dry rc=$rc $(cat "$T/o")"
cron ARCHIVE_SUGGEST_CRON_ACTION=check && fail "9. check passed with no line" || pass "9. check fails while not installed"
cron DRY_RUN=0; rc=$?
want="17 * * * * flock -n $T/log/topic-archive-suggest.cron.lock /bin/bash $SRC/csi-spl-orc/src/bash/scripts/topic-archive-suggest-cron.sh >> $T/log/cron.log 2>&1 # csi-spl:topic-archive-suggest"
[[ $rc -eq 0 ]] && grep -qxF "$want" "$T/crontab" && grep -q 'desk-reconcile$' "$T/crontab" &&
  pass "9. DRY_RUN=0: one exact hourly line, the other lines kept" || fail "9. install rc=$rc: $(cat "$T/crontab") $(cat "$T/o")"
cp "$T/crontab" "$T/ct.1"; cron DRY_RUN=0
cmp -s "$T/crontab" "$T/ct.1" && pass "9. a second install changes nothing" || fail "9. idempotent: $(cat "$T/crontab")"
cron ARCHIVE_SUGGEST_CRON_ACTION=check && grep -q 'OK the archive suggestion is installed' "$T/o" && pass "9. check passes once installed" || fail "9. check: $(cat "$T/o")"
cron DRY_RUN=0 ARCHIVE_SUGGEST_CRON_ACTION=remove
! grep -q '# csi-spl:topic-archive-suggest$' "$T/crontab" && grep -q 'desk-reconcile$' "$T/crontab" &&
  pass "9. remove takes only its line" || fail "9. remove: $(cat "$T/crontab")"

echo "---"
[[ $fails == 0 ]] && echo "spl-topic-archive-suggest: all passed" || echo "spl-topic-archive-suggest: $fails FAILED"
exit $((fails > 0))
