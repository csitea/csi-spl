#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_done_claim_check (SPL-2265, owner t1 b61851fb row D2): a
# lane result with no sha, or a sha not on a trunk, 15 min after it was sent,
# is ONE note to the dispatch lease holder; a landed sha is not. A short (9
# hex) sha resolves; a sha of another repo is checked in that repo. Two
# throwaway repos with bare origins play the trunks; the spool is a temp dir;
# the sender is a stub that logs. SPL-2313: a seat / reviewer / plan lane, known
# by its slug (its worktree branch, or the retired row in workdirs.tsv), is
# verdict seat with no note; a sha on a remote branch of a lane still in the
# registry is pending until that lane is gone. SPL-2327: a sha that is no
# object in any repo is rewritten (landed, no note) when exactly one trunk
# commit after the lane's spawn (else 48 h) carries the result's SPL key;
# else it alerts "not an object in any repository". SPL-2332: a 32-hex md5,
# or a token after an "md5" label, is no sha. SPL-2338: a body with a sha line
# claims only that line's shas; a sha quoted on another line raises nothing.
# SPL-2420: a sha on the trunk of a cnf customer repo (env.box.landed_repos,
# LANE_LANDED_CNF in the sandbox) whose clone is on this box is landed; a sha
# in no known repo still alerts; a clone on another box is skipped. SPL-2560:
# a commit reachable from origin's refs/notes/* (the release notes) is no sha.
# SPL-2706: an all-digit short sha that is a commit (c-597's "sha: 704617890")
# is a sha; an all-digit token that is no commit is still a run id.
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
# is a sha only when it is a commit (SPL-2706, case 12): the fixture never quotes one.
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
# SPL-2327 trunk commits: a rebased landing per key, SPL-9003 twice, SPL-9004
# 3 days old (outside 48 h), SPL-9005 2 h old (before c-575's spawn, after 48 h)
T0=$(date +%s)
for k in 9001 9003 9003; do rg spl commit -q --allow-empty -m "fix(x, SPL-$k): landed under a new sha"; done
GIT_COMMITTER_DATE="@$((T0 - 3 * 86400))" rg spl commit -q --allow-empty -m "fix(x, SPL-9004): old"
GIT_COMMITTER_DATE="@$((T0 - 7200))" rg spl commit -q --allow-empty -m "fix(x, SPL-9005): before the spawn"
rg spl commit -q --allow-empty -m "fix(x, SPL-90011): a longer key that holds the shorter one"
rg spl push -q origin HEAD:master
rg spl commit -q --allow-empty -m "never pushed"
LOCAL=$(rg spl rev-parse HEAD)
rg other commit -q --allow-empty -m "other repo" && lettered other 12 "other repo" && rg other push -q origin HEAD:master
OTHER=$(rg other rev-parse HEAD)
# SPL-2313 slugs: a live reviewer worktree and a code-lane worktree of the spl repo
rg spl worktree add -q -b a-560-c002-x-i18n-review-agy "$T/wt/a-560" origin/master 2>/dev/null
rg spl worktree add -q -b c-563-c002-fix-thing "$T/wt/c-563" origin/master 2>/dev/null
# a plan lane's commit on a review branch of origin, never on master
rg spl checkout -q -b c-565-plan origin/master && rg spl commit -q --allow-empty -m "plan only" && lettered spl 9 "plan only"
PLANSHA=$(rg spl rev-parse HEAD)
rg spl push -q origin HEAD:refs/heads/review/c-565-c002-radar-step4
rg spl checkout -q -b c-566-wip origin/master && rg spl commit -q --allow-empty -m "wip of a gone lane" && lettered spl 9 "wip of a gone lane"
WIPSHA=$(rg spl rev-parse HEAD)
rg spl push -q origin HEAD:refs/heads/wip/c-566-c002-gone
rg spl checkout -q master

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
msg c-002/inbox  rev   a-560 c-002 30 "review: FAIL, nothing to land"
msg c-002/inbox  revsha a-560 c-002 25 "review of $LOCAL: PASS"
msg c-002/inbox  seat  c-561 c-002 30 "seat verdict: go"
msg c-002/inbox  plan  m-562 c-002 30 "plan ready on $LOCAL"
msg c-002/inbox  code  c-563 c-002 30 "done, all green"
msg c-002/inbox  noslug c-564 c-002 30 "done, all green"
msg c-002/inbox  pend  c-565 c-002 30 "plan on ${PLANSHA:0:9}, waiting for a go"
msg c-002/inbox  gone  c-566 c-002 30 "wip on ${WIPSHA:0:9}"
msg c-002/inbox  topic m-567 c-002 30 "done, all green"
msg c-002/inbox  rew   c-570 c-002 30 "SPL-9001 landed feedface0123 (fix(x))"
msg c-002/inbox  nokey c-571 c-002 30 "SPL-9002 landed feedface0124"
msg c-002/inbox  twokey c-572 c-002 30 "SPL-9003 landed feedface0125"
msg c-002/inbox  md5   c-573 c-002 30 "landed $LANDED; files md5 d99415cbcf6b5c881b92d0846c5ec4ef 32aab288f7b1648d40275f7c76886015, md5sum=abc123def456"
msg c-002/inbox  old48 c-574 c-002 30 "SPL-9004 landed feedface0126"
msg c-002/inbox  prespawn c-575 c-002 30 "SPL-9005 landed feedface0127"
msg c-002/inbox  rew48 c-576 c-002 30 "SPL-9005 landed feedface0128, see SPL-9002 for the next step"
printf '# path\tkind\tagent\tbox\tbranch\tfinished_at\n%s\n%s\n%s\n' \
  "$T/wt/c-561	worktree	c-561	box-a	c-561-c002-rel-seat2-claude	$(iso "$NOW")" \
  "$T/wt/m-562	worktree	m-562	box-a	m-562-c002-test-reflection-round-plan	$(iso "$NOW")" \
  "$T/wt/m-567	worktree	m-567	box-a	m-567-c002-done-claim-skip-seat-lanes	$(iso "$NOW")" >"$SP/workdirs.tsv"
printf 'c-565\tclaude\t%%1\t%s\t20261017T000000Z\nc-575\tclaude\t%%2\t%s\t%s\n' "$T/wt/c-565" "$T/wt/c-575" \
  "$(date -u -d "@$((NOW - 3600))" +%Y%m%dT%H%M%SZ)" >"$SP/registry.tsv"
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
v="$(for k in m595 land short other local rebased young role self uuid sat old note rev revsha seat plan code noslug pend gone topic rew nokey twokey md5 old48 prespawn rew48; do printf '%s=%s ' "$k" "$(verdict $k)"; done)"
want="m595=would-alert land=landed short=landed other=landed local=would-alert rebased=landed young= role= self= uuid=would-alert sat= old= note= rev=seat revsha=seat seat=seat plan=seat code=would-alert noslug=would-alert pend=pending gone=would-alert topic=would-alert rew=rewritten nokey=would-alert twokey=would-alert md5=landed old48=would-alert prespawn=would-alert rew48=rewritten "
[ "$rc" = 0 ] && [ "$v" = "$want" ] && [ ! -s "$T/calls.log" ] && [ ! -e "$ST/seen.tsv" ] &&
  pass "1. dry run: no sha (m-595's shape) and an unpushed sha would alert; a full, a 9-hex, another repo's and a rebased sha whose patch is on trunk (git cherry -) are landed; young, role seat, self-sent, other box, old and non-result skipped; a reviewer / seat / plan slug (live worktree or retired row, sha or not) is seat, a code slug or none alerts (also one whose topic only mentions seats); a sha on a live lane's review branch is pending, a gone lane's wip branch alerts; nothing sent" ||
  fail "1. dry run (rc $rc) got '$v' want '$want': $(cat "$T/o") // $(cat "$T/calls.log")"
[ "$(grep -c '^local	' "$T/o")" = 1 ] && grep -q '^uuid	.*no-sha$' "$T/o" &&
  pass "2. one row per msg_id (inbox + outbox copies); a UUID and an all-digit run id are not shas" || fail "2. dedupe / uuid: $(cat "$T/o")"
[ "$(awk -F'\t' '$1 == "md5" { print $4 }' "$T/o")" = "$LANDED" ] && grep -q '^OK done-claim-check: .* 2 rewritten,' "$T/o" &&
  pass "2b. SPL-2332: a 32-hex md5 and a token after an md5 label are no shas (only the landed sha is read); SPL-2327: the OK line counts the rewritten ones" ||
  fail "2b. md5 / rewritten count: $(cat "$T/o")"

# 3. real run: one note per alert, to the lease holder as the lease names it
run DRY_RUN=0; rc=$?
[ "$rc" = 0 ] && [ "$(grep -c '^SEND' "$T/calls.log")" = 11 ] &&
  grep -q "^SEND c-002@sat done-claim-check done-claim check: m-595 result m595 (.*): no sha not in the repository" "$T/calls.log" &&
  grep -q "^SEND c-002@sat done-claim-check done-claim check: c-543 result local .*: sha $LOCAL not in the repository" "$T/calls.log" &&
  grep -q "^SEND c-002@sat done-claim-check done-claim check: c-571 result nokey .*: sha feedface0124 not an object in any repository (a pre-rebase sha?)$" "$T/calls.log" &&
  grep -q "c-572 result twokey .*: sha feedface0125 not an object in any repository" "$T/calls.log" &&
  ! grep -q "c-540\|c-541\|c-542\|a-551\|a-560\|c-561\|m-562\|c-565\|c-570\|c-573\|c-576" "$T/calls.log" && [ "$(wc -l <"$ST/seen.tsv")" = 22 ] &&
  [ "$(grep -c '	rewritten	' "$ST/seen.tsv")" = 2 ] &&
  [ "$(grep -c '	seat	' "$ST/seen.tsv")" = 4 ] && ! grep -q '^pend	' "$ST/seen.tsv" &&
  pass "3. DRY_RUN=0: one note per alerting message to the holder (lane, msg id, sha, 'not in the repository'); landed, seat and pending ones send none; all but the pending one go to the ledger; SPL-2327: a no-object sha with no trunk commit of its key, with two, with one older than 48 h or older than the lane's spawn alerts 'not an object in any repository (a pre-rebase sha?)'; one after the spawn (a longer key SPL-90011 is not SPL-9001) is rewritten, no note" ||
  fail "3. real run (rc $rc): $(cat "$T/o") // $(cat "$T/calls.log")"

# 4. once per message: a second run sends nothing; only the pending one is judged again
run DRY_RUN=0; rc=$?
[ "$rc" = 0 ] && [ ! -s "$T/calls.log" ] && [ "$(grep -c '	' "$T/o")" = 1 ] && [ "$(verdict pend)" = pending ] &&
  pass "4. a judged message is never judged again (no second note); a pending one is" || fail "4. once (rc $rc): $(cat "$T/o") // $(cat "$T/calls.log")"

# 4b. once the plan lane is gone from the registry, its pending sha alerts
: >"$SP/registry.tsv"
run DRY_RUN=0; rc=$?
[ "$rc" = 0 ] && [ "$(grep -c '^SEND' "$T/calls.log")" = 1 ] && grep -q "c-565 result pend .*: sha ${PLANSHA:0:9} not in the repository" "$T/calls.log" &&
  pass "4b. the lane gone, the pending sha alerts once" || fail "4b. gone (rc $rc): $(cat "$T/o") // $(cat "$T/calls.log")"

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

# 9. SPL-2338 (c-355's result 88580b2e, synthetic): a body with a sha line claims
# only that line's shas. A quoted unknown sha elsewhere raises nothing; an
# unlanded sha on the sha line alerts, though a landed one is quoted elsewhere;
# "sha: none" or no sha line reads every sha, as before.
SP="$T/spool9"
msg c-002/archive quoted c-580 c-002 30 "**Landed, not live yet**

- **sha**: ${LANDED:0:9} \`fix(x, SPL-9101): a fix\`
- dry run: another lane's sha 9c0ffee12345 of another repo is quoted here"
msg c-002/archive unl c-581 c-002 30 "- sha: $LOCAL
- CI: wf 10 green on ${LANDED:0:9}"
msg c-002/archive none c-582 c-002 30 "sha: none
landed ${LANDED:0:9}"
msg c-002/archive nolabel c-583 c-002 30 "landed ${LANDED:0:9}, quoted 9c0ffee12345"
run; rc=$?
v="$(for k in quoted unl none nolabel; do printf '%s=%s ' "$k" "$(verdict $k)"; done)"
[ "$rc" = 0 ] && [ "$v" = "quoted=landed unl=would-alert none=landed nolabel=would-alert " ] &&
  [ "$(awk -F'\t' '$1 == "quoted" { print $4 }' "$T/o")" = "${LANDED:0:9}" ] && [ "$(awk -F'\t' '$1 == "unl" { print $4 }' "$T/o")" = "$LOCAL" ] &&
  pass "9. SPL-2338: a landed sha on the sha line plus a quoted unknown sha on another line is landed; an unlanded sha on the sha line alerts (a landed sha elsewhere does not save it); 'sha: none' and no sha line read every sha" ||
  fail "9. sha line (rc $rc) got '$v': $(cat "$T/o")"

# 10. SPL-2420 (c-578's csi-rel result bcee7e0b, synthetic): a customer repo of
# the cnf. Its clone has not fetched the landed sha; a second clone pushed it.
mkrepo cust
git clone -q "$T/cust.git" "$T/cust-push" 2>/dev/null
rg cust-push commit -q --allow-empty -m "customer fix" && lettered cust-push 12 "customer fix" && rg cust-push push -q origin HEAD:master
CUSTSHA=$(rg cust-push rev-parse HEAD)
rg cust-push commit -q --allow-empty -m "customer, never pushed" && lettered cust-push 12 "customer, never pushed"
CUSTLOCAL=$(rg cust-push rev-parse HEAD)
printf 'env:\n  box:\n    landed_repos:\n      - {name: cust-rel, src_dir: %s, trunk: master}\n      - {name: far-rel, src_dir: %s, box: box-b}\n' \
  "$T/cust" "$T/not-here" >"$T/cust.yaml"
msg c-002/archive cust c-584 c-002 30 "- sha: ${CUSTSHA:0:12} on csi-rel master"
msg c-002/archive custno c-585 c-002 30 "- sha: ${CUSTLOCAL:0:12} on csi-rel master"
! rg cust cat-file -e "$CUSTSHA^{commit}" 2>/dev/null && pass "10. control: the customer clone has not fetched the landed sha yet" ||
  fail "10. control: the customer clone already has $CUSTSHA"
run DONE_CLAIM_STATE_DIR="$T/st10" SPOOL_BOX_USER=; rc=$?
v="$(for k in cust custno; do printf '%s=%s ' "$k" "$(verdict $k)"; done)"
[ "$rc" = 0 ] && [ "$v" = "cust=would-alert custno=would-alert " ] &&
  pass "10. RED CONTROL with no cnf customer repo (the 10-17 gap) a customer sha alerts" || fail "10. no cnf (rc $rc) got '$v': $(cat "$T/o")"
run DONE_CLAIM_STATE_DIR="$T/st10" SPOOL_BOX_USER= LANE_LANDED_CNF="$T/cust.yaml"; rc=$?
v="$(for k in cust custno; do printf '%s=%s ' "$k" "$(verdict $k)"; done)"
[ "$rc" = 0 ] && [ "$v" = "cust=landed custno=would-alert " ] && [ "$(verdict quoted)" = landed ] && [ "$(verdict unl)" = would-alert ] &&
  pass "10. a sha on a cnf customer repo's fetched trunk is landed; a sha in no known repo's trunk still alerts; the csi-spl verdicts stand; a clone on another box is skipped" ||
  fail "10. cnf customer repo (rc $rc) got '$v': $(cat "$T/o")"

# 11. SPL-2560 (c-461's result 05089b84, synthetic): a body with no sha line
# quotes the refs/notes/release-notes commit next to its code sha. A second
# clone adds the note and pushes the notes ref; the checked clone has never
# fetched it. The notes commit is no claim; the code sha alone is judged.
SP="$T/spool11"
git clone -q "$T/spl.git" "$T/spl-notes" 2>/dev/null
for i in $(seq 1 50); do
  rg spl-notes notes --ref=release-notes add -f -m "Lay-What: a fix $i" HEAD 2>/dev/null
  [[ "$(rg spl-notes rev-parse refs/notes/release-notes | cut -c1-9)" =~ [a-f] ]] && break
done
rg spl-notes push -q origin refs/notes/release-notes
NOTESHA=$(rg spl-notes rev-parse refs/notes/release-notes)
msg c-002/archive notes c-586 c-002 30 "Landed ${LANDED:0:9} fix(orc). Gates: green; notes added since as \`refs/notes/release-notes\` ${NOTESHA:0:9}"
msg c-002/archive notesonly c-587 c-002 30 "notes added as ${NOTESHA:0:9}"
! rg spl cat-file -e "$NOTESHA^{object}" 2>/dev/null && pass "11. control: the checked clone has not fetched the notes commit" ||
  fail "11. control: the checked clone already has $NOTESHA"
run DONE_CLAIM_STATE_DIR="$T/st11"; rc=$?
v="$(for k in notes notesonly; do printf '%s=%s ' "$k" "$(verdict $k)"; done)"
[ "$rc" = 0 ] && [ "$v" = "notes=landed notesonly=would-alert " ] &&
  [ "$(awk -F'\t' '$1 == "notes" { print $4 }' "$T/o")" = "${LANDED:0:9}" ] &&
  grep -q '^notesonly	.*no-sha$' "$T/o" && ! rg spl rev-parse -q --verify refs/notes/release-notes >/dev/null &&
  pass "11. SPL-2560: a commit on origin's refs/notes/* is no claim (fetched to a private ref, the local notes refs untouched): the code sha beside it is landed; a body citing only a notes commit reads as no sha" ||
  fail "11. notes ref (rc $rc) got '$v': $(cat "$T/o")"

# 12. SPL-2706 (c-597's result 475cfaaa, synthetic): "sha: 704617890" named an
# all-digit 9-char prefix of a trunk commit and read as no sha. A trunk commit
# amended until its 9-char prefix is all digits (~1.5% of hashes).
SP="$T/spool12"
rg spl commit -q --allow-empty -m "digit sha"
for i in $(seq 1 3000); do
  [[ "$(rg spl rev-parse HEAD | cut -c1-9)" =~ ^[0-9]{9}$ ]] && break
  rg spl commit -q --amend --allow-empty -m "digit sha $i"
done
DIG=$(rg spl rev-parse HEAD)
rg spl push -q origin HEAD:master
msg c-002/archive digit c-597 c-002 30 "- sha: ${DIG:0:9}"
msg c-002/archive digitno c-598 c-002 30 "- sha: 123456789 (run id)"
[[ "${DIG:0:9}" =~ ^[0-9]{9}$ && "$(rg spl cat-file -t 123456789 2>/dev/null)" != commit ]] &&
  pass "12. control: ${DIG:0:9} is an all-digit trunk prefix, 123456789 no commit" || fail "12. control: fixture ${DIG:0:9}"
run DONE_CLAIM_STATE_DIR="$T/st12"; rc=$?
v="$(for k in digit digitno; do printf '%s=%s ' "$k" "$(verdict $k)"; done)"
[ "$rc" = 0 ] && [ "$v" = "digit=landed digitno=would-alert " ] &&
  [ "$(awk -F'\t' '$1 == "digit" { print $4 }' "$T/o")" = "${DIG:0:9}" ] && grep -q '^digitno	.*no-sha$' "$T/o" &&
  pass "12. SPL-2706: an all-digit short sha of a trunk commit is landed; a 9-digit number that is no commit is still no sha" ||
  fail "12. all-digit sha (rc $rc) got '$v': $(cat "$T/o")"

# 13. c-734's result e7f096f6 (synthetic): "do_check_pre_push all PASS (tree
# cefedf318)" beside its landed done sha. A tree, a blob, and a tag of a tree
# are git objects but no commit: no claim. The landed sha alone is judged.
SP="$T/spool13"
TREE=$(rg spl rev-parse "$REVIEW^{tree}")
BLOB=$(rg spl rev-parse "$REVIEW:f")
for i in $(seq 1 50); do
  rg spl tag -f -a treetag -m "tree tag $i" "$TREE" >/dev/null
  [[ "$(rg spl rev-parse refs/tags/treetag | cut -c1-9)" =~ [a-f] ]] && break
done
TTAG=$(rg spl rev-parse refs/tags/treetag)
msg c-002/archive tree c-599 c-002 30 "done ${LANDED:0:9}, do_check_pre_push all PASS (tree ${TREE:0:9}), blob ${BLOB:0:9}, tag ${TTAG:0:9}"
msg c-002/archive treeonly c-600 c-002 30 "do_check_pre_push all PASS (tree ${TREE:0:9})"
[[ "$(rg spl cat-file -t "${TREE:0:9}")/$(rg spl cat-file -t "${BLOB:0:9}")/$(rg spl cat-file -t "${TTAG:0:9}")" == tree/blob/tag &&
  "${TREE:0:9}${BLOB:0:9}${TTAG:0:9}" =~ [a-f] ]] &&
  pass "13. control: ${TREE:0:9} is a tree, ${BLOB:0:9} a blob, ${TTAG:0:9} a tag of a tree" || fail "13. control: fixture"
run DONE_CLAIM_STATE_DIR="$T/st13"; rc=$?
v="$(for k in tree treeonly; do printf '%s=%s ' "$k" "$(verdict $k)"; done)"
[ "$rc" = 0 ] && [ "$v" = "tree=landed treeonly=would-alert " ] &&
  [ "$(awk -F'\t' '$1 == "tree" { print $4 }' "$T/o")" = "${LANDED:0:9}" ] && grep -q '^treeonly	.*no-sha$' "$T/o" &&
  pass "13. a tree, a blob or a tag of a tree beside a landed sha is no claim: landed; a body citing only a tree id reads as no sha" ||
  fail "13. tree / blob id (rc $rc) got '$v': $(cat "$T/o")"

# 14. SPL-2838 (m-744's results 5e2d8ef2, b99548a9, synthetic): an R7 reviewer
# checks the reviewed sha out detached, so its worktree lists no branch and its
# retired workdirs row has an empty branch. The spawn's own local branch
# <id>-<slug> still names the slug: a reviewer one is seat; a code one, or a
# lane with no branch at all, is judged as before.
SP="$T/spool14"
rg spl fetch -q origin
rg spl worktree add -q -b m-744-c002-r17-mistral-r7-reviewer "$T/wt/m-744" origin/master 2>/dev/null
rg wt/m-744 checkout -q --detach && rg wt/m-744 commit -q --allow-empty -m "reviewed, never pushed" && lettered wt/m-744 40 "reviewed"
DET=$(rg wt/m-744 rev-parse HEAD)
rg spl worktree add -q -b c-745-c002-fix-other "$T/wt/c-745" origin/master 2>/dev/null
git -C "$T/wt/c-745" checkout -q --detach "$DET"
rg spl branch -q m-747-c002-r17-agy-r7-review-spl-9001 "$DET"
rg spl worktree add -q --detach "$T/wt/c-748" "$DET" 2>/dev/null
mkdir -p "$SP"
printf '# path\tkind\tagent\tbox\tbranch\tfinished_at\n%s\n' "$T/wt/m-747	worktree	m-747	box-a		$(iso "$NOW")" >"$SP/workdirs.tsv"
msg c-002/archive detrev m-744 c-002 30 "review of $DET: PASS"
msg c-002/archive detcode c-745 c-002 30 "done $DET"
msg c-002/archive retrev m-747 c-002 30 "review of $DET: PASS"
msg c-002/archive nobranch c-748 c-002 30 "done $DET"
[[ "$(git -C "$T/wt/m-744" worktree list --porcelain | grep -A3 "^worktree $T/wt/m-744\$" | grep -c '^detached')" = 1 ]] &&
  pass "14. control: m-744's worktree is a detached HEAD (no branch line)" || fail "14. control: fixture"
run DONE_CLAIM_STATE_DIR="$T/st14"; rc=$?
v="$(for k in detrev detcode retrev nobranch; do printf '%s=%s ' "$k" "$(verdict $k)"; done)"
[ "$rc" = 0 ] && [ "$v" = "detrev=seat detcode=would-alert retrev=seat nobranch=would-alert " ] &&
  pass "14. a detached-HEAD lane keeps the slug of its spawn branch: a live or retired reviewer is seat; a code slug or no branch at all still alerts" ||
  fail "14. detached reviewer (rc $rc) got '$v': $(cat "$T/o")"

exit "$fails"
