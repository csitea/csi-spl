#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_done_claim_check (SPL-2265, owner t1 b61851fb row D2): a
# lane result with no sha, or a sha not on a trunk, 15 min after it was sent,
# is ONE note to the dispatch lease holder; a landed sha is not. A short (9
# hex) sha resolves; a sha of another repo is checked in that repo. Two
# throwaway repos with bare origins play the trunks; the spool is a temp dir;
# the sender is a stub that logs.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# mkrepo <name>: a clone of a bare origin with one pushed commit; prints nothing.
mkrepo() {
  git init -q --bare -b master "$T/$1.git"
  git clone -q "$T/$1.git" "$T/$1" 2>/dev/null
  rg "$1" commit -q --allow-empty -m "base $1" && rg "$1" push -q origin HEAD:master
}
rg() { local r="$1"; shift; git -C "$T/$r" -c user.name=t -c user.email=t@example.com "$@"; }
mkrepo spl
mkrepo other
# lettered <repo> <n> <msg>: commit (or amend) HEAD until its first <n> chars hold a
# letter. A body quotes a 9- or 12-char prefix; an all-digit one (1 run in ~70 for 9)
# reads as a run id and is dropped on purpose, so the fixture never quotes one.
lettered() {
  local i
  for i in $(seq 1 50); do
    [[ "$(rg "$1" rev-parse HEAD | cut -c1-"$2")" =~ [a-f] ]] && return 0
    rg "$1" commit -q --amend --allow-empty -m "$3 $i"
  done
  echo "FAIL: the fixture's $3 sha has an all-digit $2-char prefix"; exit 1
}
rg spl commit -q --allow-empty -m landed
lettered spl 9 landed
LANDED=$(rg spl rev-parse HEAD)
rg spl push -q origin HEAD:master
# a review-branch commit whose patch lands on trunk under another sha (a rebase)
rg spl checkout -q -b review HEAD~1
echo fix >"$T/spl/f" && rg spl add f && rg spl commit -q -m "reviewed fix"
lettered spl 9 "reviewed fix"
REVIEW=$(rg spl rev-parse HEAD)
rg spl checkout -q master && rg spl cherry-pick "$REVIEW" >/dev/null && rg spl commit -q --amend -m "reviewed fix, rebased"
rg spl push -q origin HEAD:master
[ "$(rg spl rev-parse HEAD)" != "$REVIEW" ] || { echo "FAIL: the fixture's rebased sha equals the review sha"; exit 1; }
rg spl commit -q --allow-empty -m "never pushed"
LOCAL=$(rg spl rev-parse HEAD)
rg other commit -q --allow-empty -m "other repo" && lettered other 12 "other repo" && rg other push -q origin HEAD:master
OTHER=$(rg other rev-parse HEAD)

NOW=$(date +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
SP="$T/spool"
# msg <dir> <id> <from> <to> <age min> <body>: one v:1 result in <dir>.
msg() {
  mkdir -p "$SP/$1"
  jq -n --arg id "$2" --arg from "$3" --arg to "$4" --arg ts "$(iso $((NOW - $5 * 60)))" --arg body "$6" \
    '{v:1, msg_id:$id, from:$from, to:$to, kind:"result", task_id:"dispatch-b61851fb", ts:$ts, body:$body, files:[]}' \
    >"$SP/$1/$2.json"
}
msg c-002/archive m595 m-595 c-002 30 "closing: all done, tests green, ready"
msg c-002/archive land c-540 c-002 30 "SPL-1 landed: $LANDED fix(orc) - run 38686777677"
msg c-002/inbox  short c-541 c-002 30 "landed ${LANDED:0:9} fix(orc)"
msg c-001/archive other c-542 c-002 30 "landed in the other repo: ${OTHER:0:12}"
msg c-001/inbox  local c-543 c-002 30 "landed $LOCAL"
msg c-543/outbox local c-543 c-002 30 "landed $LOCAL"
msg c-002/inbox  rebased a-551 c-002 30 "review: PASS ${REVIEW:0:9}"
msg c-002/inbox  young c-544 c-002 5 "no sha yet"
msg c-002/inbox  role  c-002 c-001 30 "no sha from a role seat"
msg c-545/outbox self  c-545 c-545 30 "ACK rotation x: c-545 read the handoff"
msg c-002/inbox  uuid  c-546 c-002 30 "task 6b7e8a54-a896-4f24-9c83-80e9722daaa0, run 123456789012"
msg c-002/inbox  sat   c-547@sat c-002 30 "no sha, another box"
msg c-002/inbox  old   c-548 c-002 2000 "no sha, older than the window"
jq -n '{v:1, msg_id:"note", from:"c-549", to:"c-002", kind:"note", ts:"x", body:"no sha, a note"}' >"$SP/c-002/inbox/note.json"

cat >"$T/send.sh" <<'EOF'
#!/bin/bash
to="" task="" f=""
while [ $# -gt 0 ]; do case "$1" in --to) to="$2"; shift 2 ;; --task) task="$2"; shift 2 ;; --body-file) f="$2"; shift 2 ;; *) shift ;; esac; done
[ "$to" = "${SEND_FAIL:-none}" ] && exit 1
printf 'SEND %s %s %s\n' "$to" "$task" "$(head -1 "$f")" >>"$STUB_LOG"
EOF
ST="$T/state"
mkdir -p "$SP/dispatch" && echo "c-002@sat $NOW" >"$SP/dispatch/lease"
run() {
  : >"$T/calls.log"
  SNIPPET="do_spl_done_claim_check" in_orc SPOOL_ROOT="$SP" DONE_CLAIM_REPO_DIRS="$T/spl $T/other" DONE_CLAIM_STATE_DIR="$ST" \
    DONE_CLAIM_BOX=box-a DONE_CLAIM_NOW="$NOW" DONE_CLAIM_SEND="$T/send.sh" "$@" >"$T/o" 2>&1
}
verdict() { awk -F'\t' -v k="$1" '$1 == k { print $3 }' "$T/o"; }

# 1. dry run: the verdicts, nothing sent, no ledger
run; rc=$?
v="$(for k in m595 land short other local rebased young role self uuid sat old note; do printf '%s=%s ' "$k" "$(verdict $k)"; done)"
want="m595=would-alert land=landed short=landed other=landed local=would-alert rebased=landed young= role= self= uuid=would-alert sat= old= note= "
[ "$rc" = 0 ] && [ "$v" = "$want" ] && [ ! -s "$T/calls.log" ] && [ ! -e "$ST/seen.tsv" ] &&
  pass "1. dry run: no sha (m-595's shape) and an unpushed sha would alert; a full, a 9-hex, another repo's and a rebased sha whose patch is on trunk (git cherry -) are landed; young, role seat, self-sent, other box, old and non-result skipped; nothing sent" ||
  fail "1. dry run (rc $rc) got '$v' want '$want': $(cat "$T/o") // $(cat "$T/calls.log")"
[ "$(grep -c '^local	' "$T/o")" = 1 ] && grep -q '^uuid	.*no-sha$' "$T/o" &&
  pass "2. one row per msg_id (inbox + outbox copies); a UUID and an all-digit run id are not shas" || fail "2. dedupe / uuid: $(cat "$T/o")"

# 3. real run: one note per alert, to the lease holder as the lease names it
run DRY_RUN=0; rc=$?
[ "$rc" = 0 ] && [ "$(grep -c '^SEND' "$T/calls.log")" = 3 ] &&
  grep -q "^SEND c-002@sat done-claim-check done-claim check: m-595 result m595 (.*): no sha not in the repository" "$T/calls.log" &&
  grep -q "^SEND c-002@sat done-claim-check done-claim check: c-543 result local .*: sha $LOCAL not in the repository" "$T/calls.log" &&
  ! grep -q "c-540\|c-541\|c-542\|a-551" "$T/calls.log" && [ "$(wc -l <"$ST/seen.tsv")" = 7 ] &&
  pass "3. DRY_RUN=0: one note per alerting message to the holder (lane, msg id, sha, 'not in the repository'); landed ones send none; all seven go to the ledger" ||
  fail "3. real run (rc $rc): $(cat "$T/o") // $(cat "$T/calls.log")"

# 4. once per message: a second run sends nothing
run DRY_RUN=0; rc=$?
[ "$rc" = 0 ] && [ ! -s "$T/calls.log" ] && grep -q 'no lane result older than 15 min left to judge' "$T/o" &&
  pass "4. a judged message is never judged again (no second note)" || fail "4. once (rc $rc): $(cat "$T/o") // $(cat "$T/calls.log")"

# 5. 15 min later the young one is due; a failed send is retried next run, not lost
NOW=$((NOW + 15 * 60))
run DRY_RUN=0 DONE_CLAIM_TO=c-009 SEND_FAIL=c-009; rc=$?
[ "$rc" = 1 ] && ! grep -q '^young' "$ST/seen.tsv" && pass "5. a failed send is rc 1 and stays out of the ledger" ||
  fail "5. failed send (rc $rc): $(cat "$T/o")"
run DRY_RUN=0 DONE_CLAIM_TO=c-009; rc=$?
[ "$rc" = 0 ] && grep -q '^SEND c-009 done-claim-check .*c-544 result young' "$T/calls.log" && [ "$(grep -c '^SEND' "$T/calls.log")" = 1 ] &&
  pass "6. after 15 min the young result alerts, once, retried after the failed send; DONE_CLAIM_TO overrides the holder" ||
  fail "6. young (rc $rc): $(cat "$T/o") // $(cat "$T/calls.log")"

# 7. a repo that is not a clone is a FATAL, never an alert for every sha
msg c-002/inbox fresh c-550 c-002 20 "landed $LANDED"
run DRY_RUN=0 DONE_CLAIM_REPO_DIRS="$T/nope"; rc=$?
[ "$rc" = 1 ] && grep -q 'FATAL .*nope is not a git repo' "$T/o" && [ ! -s "$T/calls.log" ] &&
  pass "7. a missing clone refuses the run (no note)" || fail "7. missing repo (rc $rc): $(cat "$T/o")"

# 8. the cron row and its script
grep -qE '^done-claim-check +\| \*/5 \* \* \* \* +\| src/bash/scripts/done-claim-check-cron.sh +\|' "$PROJ_ROOT/cnf/box-crons/box-crons.manifest" &&
  [ -x "$PROJ_ROOT/src/bash/scripts/done-claim-check-cron.sh" ] && bash -n "$PROJ_ROOT/src/bash/scripts/done-claim-check-cron.sh" &&
  pass "8. the box-crons manifest runs done-claim-check-cron.sh every 5 min" || fail "8. cron row or script missing"

exit "$fails"
