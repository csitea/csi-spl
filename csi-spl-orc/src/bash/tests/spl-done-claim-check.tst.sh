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
# SPL-2930: a sha on the trunk of the sender lane's OWN repo (its worktree in
# registry.tsv or workdirs.tsv; no cnf list) is landed; a failed fetch of that
# repo judges on its last fetched trunk and says so, never "not an object".
# SPL-3020: a sha the check could not judge (only in a repo whose fetch
# failed; no object anywhere while a repo failed its fetch or the lane's own
# repo was never read) is "not checked", no note; a local-trunk repo (`git
# config spool.localTrunk <branch>`) is judged on that local branch. A lane
# citing a no-object sha below has a registry worktree, as a live lane does.
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
msg c-002/inbox  grcmd c-577 c-002 30 "Verify gr-cmd-f628a3a8773b **exit 0**; landed $LANDED. Step 1 (gr-cmd-890b4562175b) was exit 0; zip gr-cmd-ab12cd34ef56.zip, request id: cafe0123beef, req=bead4567cafe, gr-cmd dead89abcdef"
printf '# path\tkind\tagent\tbox\tbranch\tfinished_at\n%s\n%s\n%s\n' \
  "$T/wt/c-561	worktree	c-561	box-a	c-561-c002-rel-seat2-claude	$(iso "$NOW")" \
  "$T/wt/m-562	worktree	m-562	box-a	m-562-c002-test-reflection-round-plan	$(iso "$NOW")" \
  "$T/wt/m-567	worktree	m-567	box-a	m-567-c002-done-claim-skip-seat-lanes	$(iso "$NOW")" >"$SP/workdirs.tsv"
printf 'c-565\tclaude\t%%1\t%s\t20261017T000000Z\nc-575\tclaude\t%%2\t%s\t%s\n' "$T/wt/c-565" "$T/wt/c-563" \
  "$(date -u -d "@$((NOW - 3600))" +%Y%m%dT%H%M%SZ)" >"$SP/registry.tsv"
for l in c-571 c-572 c-574; do printf '%s\tclaude\t%%9\t%s\t-\n' "$l" "$T/wt/c-563" >>"$SP/registry.tsv"; done
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
v="$(for k in m595 land short other local rebased young role self uuid sat old note rev revsha seat plan code noslug pend gone topic rew nokey twokey md5 old48 prespawn rew48 grcmd; do printf '%s=%s ' "$k" "$(verdict $k)"; done)"
want="m595=would-alert land=landed short=landed other=landed local=would-alert rebased=landed young= role= self= uuid=would-alert sat= old= note= rev=seat revsha=seat seat=seat plan=seat code=would-alert noslug=would-alert pend=pending gone=would-alert topic=would-alert rew=rewritten nokey=would-alert twokey=would-alert md5=landed old48=would-alert prespawn=would-alert rew48=rewritten grcmd=landed "
[ "$rc" = 0 ] && [ "$v" = "$want" ] && [ ! -s "$T/calls.log" ] && [ ! -e "$ST/seen.tsv" ] &&
  pass "1. dry run: no sha (m-595's shape) and an unpushed sha would alert; a full, a 9-hex, another repo's and a rebased sha whose patch is on trunk (git cherry -) are landed; young, role seat, self-sent, other box, old and non-result skipped; a reviewer / seat / plan slug (live worktree or retired row, sha or not) is seat, a code slug or none alerts (also one whose topic only mentions seats); a sha on a live lane's review branch is pending, a gone lane's wip branch alerts; nothing sent" ||
  fail "1. dry run (rc $rc) got '$v' want '$want': $(cat "$T/o") // $(cat "$T/calls.log")"
[ "$(grep -c '^local	' "$T/o")" = 1 ] && grep -q '^uuid	.*no-sha$' "$T/o" &&
  pass "2. one row per msg_id (inbox + outbox copies); a UUID and an all-digit run id are not shas" || fail "2. dedupe / uuid: $(cat "$T/o")"
[ "$(awk -F'\t' '$1 == "md5" { print $4 }' "$T/o")" = "$LANDED" ] && grep -q '^OK done-claim-check: .* 2 rewritten,' "$T/o" &&
  pass "2b. SPL-2332: a 32-hex md5 and a token after an md5 label are no shas (only the landed sha is read); SPL-2327: the OK line counts the rewritten ones" ||
  fail "2b. md5 / rewritten count: $(cat "$T/o")"
[ "$(awk -F'\t' '$1 == "grcmd" { print $4 }' "$T/o")" = "$LANDED" ] &&
  pass "2c. SPL-2953: a run-on-box request id (gr-cmd-<hex>, gr-cmd-<hex>.zip, after a gr-cmd / request id / req label) is no sha (only the landed sha is read)" ||
  fail "2c. run-on-box request id: $(cat "$T/o")"

# 3. real run: one note per alert, to the lease holder as the lease names it
run DRY_RUN=0; rc=$?
[ "$rc" = 0 ] && [ "$(grep -c '^SEND' "$T/calls.log")" = 11 ] &&
  grep -q "^SEND c-002@sat done-claim-check done-claim check: m-595 result m595 (.*): no sha not in the repository" "$T/calls.log" &&
  grep -q "^SEND c-002@sat done-claim-check done-claim check: c-543 result local .*: sha $LOCAL not in the repository" "$T/calls.log" &&
  grep -q "^SEND c-002@sat done-claim-check done-claim check: c-571 result nokey .*: sha feedface0124 not an object in any repository (a pre-rebase sha?)$" "$T/calls.log" &&
  grep -q "c-572 result twokey .*: sha feedface0125 not an object in any repository" "$T/calls.log" &&
  ! grep -q "c-540\|c-541\|c-542\|a-551\|a-560\|c-561\|m-562\|c-565\|c-570\|c-573\|c-576" "$T/calls.log" && [ "$(wc -l <"$ST/seen.tsv")" = 23 ] &&
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
for l in c-583 c-584 c-585; do printf '%s\tclaude\t%%9\t%s\t-\n' "$l" "$T/wt/c-563" >>"$SP/registry.tsv"; done
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


# 15. SPL-2916 (the other box's m-120, results f6471a6c, 6e992de7, d0a3f930, synthetic): an
# R7 reviewer whose id was used before by a code lane. Its body starts with the
# R7 line (`review: <id>@<box> <vendor> PASS <sha> ...`) naming the reviewed
# branch sha, by design not on trunk. The seat decision reads the id's LATEST
# slug: a live worktree's branch; for a detached live worktree the newest local
# <id>-<slug> branch; with no live worktree the newest retired workdirs row.
SP="$T/spool15"
mkdir -p "$SP"
rg spl fetch -q origin
OLD=$((NOW - 86400))
UNL=$(rg spl commit-tree -p origin/master -m "the reviewed branch, never on trunk" "origin/master^{tree}")
for b in m-790-c002-fix-code m-791-c002-fix-code m-792-c002-fix-code m-794-c002-r7-reviewer; do
  rg spl branch -q "$b" "$(GIT_COMMITTER_DATE="@$OLD" rg spl commit-tree -p origin/master -m "old $b" "origin/master^{tree}")"
done
rg spl worktree add -q -b m-790-c001-bug-round-3-mistral-r7-reviewer "$T/wt/m-790" origin/master 2>/dev/null
rg spl worktree add -q -b m-791-c001-bug-round-3-mistral-r7-reviewer "$T/wt/m-791" origin/master 2>/dev/null
git -C "$T/wt/m-791" checkout -q --detach "$UNL"
rg spl worktree add -q -b m-794-c002-fix-later "$T/wt/m-794" origin/master 2>/dev/null
printf '# path\tkind\tagent\tbox\tbranch\tfinished_at\n%s\n%s\n%s\n%s\n%s\n' \
  "$T/wt/m-790	worktree	m-790	box-a	m-790-c002-fix-code	$(iso "$OLD")" \
  "$T/wt/m-792	worktree	m-792	box-a	m-792-c002-fix-code	$(iso "$OLD")" \
  "$T/wt/m-792	worktree	m-792	box-a	m-792-c001-bug-round-3-mistral-r7-reviewer	$(iso $((NOW - 600)))" \
  "$T/wt/m-793	worktree	m-793	box-a	m-793-c001-old-r7-reviewer	$(iso "$OLD")" \
  "$T/wt/m-793	worktree	m-793	box-a	m-793-c002-fix-code	$(iso $((NOW - 600)))" >"$SP/workdirs.tsv"
R7="ran: bash x.tst.sh | read: 3 PASS | log: m-790@box-a:/path/journal.jsonl"
msg c-002/archive r7live m-790 c-002 30 "review: m-790@box-a mistral PASS $UNL $R7"
msg c-002/archive r7nosha m-790 c-002 30 "sent back, nothing to land"
msg c-002/archive r7det m-791 c-002 30 "done $UNL"
msg c-002/archive r7ret m-792 c-002 30 "review of $UNL: PASS"
msg c-002/archive r7line c-795 c-002 30 "review: c-795@box-a claude FAIL $UNL $R7"
msg c-002/archive codenew m-793 c-002 30 "done $UNL"
msg c-002/archive codelive m-794 c-002 30 "done $UNL"
msg c-002/archive r7later c-796 c-002 30 "landed $UNL
review: c-796@box-a claude PASS $UNL $R7"
[[ "$(rg spl log -1 --format=%ct m-791-c002-fix-code)" -lt "$(rg spl log -1 --format=%ct m-791-c001-bug-round-3-mistral-r7-reviewer)" ]] &&
  ! rg spl merge-base --is-ancestor "$UNL" origin/master &&
  pass "15. control: the reviewed sha is on no trunk; the recycled ids' old code branches are older than their reviewer branches" || fail "15. control: fixture dates"
run DONE_CLAIM_STATE_DIR="$T/st15"; rc=$?
v="$(for k in r7live r7nosha r7det r7ret r7line codenew codelive r7later; do printf '%s=%s ' "$k" "$(verdict $k)"; done)"
[ "$rc" = 0 ] && [ "$v" = "r7live=seat r7nosha=seat r7det=seat r7ret=seat r7line=seat codenew=would-alert codelive=would-alert r7later=would-alert " ] &&
  pass "15. SPL-2916: a recycled id is judged by its latest slug (a live reviewer worktree, on a branch or detached, or the newest retired reviewer row beats an older code slug: seat, sha or not); a body whose first line is an R7 review line is seat whatever the slug; a newest code slug, a live code worktree over an older reviewer branch, and an R7 line below a landing claim still alert" ||
  fail "15. recycled reviewer id / R7 line (rc $rc) got '$v': $(cat "$T/o")"

# 16. SPL-2930 (c-179's result, sha a486355b0, and c-189's own repo,
# 10-22, synthetic): a lane whose worktree is a clone of a repo that is not
# csi-spl and not in the cnf's landed_repos. Its trunk carries the claimed sha.
# A second lane's repo cannot be fetched (its origin is gone, as an https
# origin with no credential): it is judged on its last fetched trunk.
SP="$T/spool16"
mkdir -p "$SP"
mkrepo own
rg own commit -q --allow-empty -m "own fix" && lettered own 12 "own fix" && rg own push -q origin HEAD:master
OWNSHA=$(rg own rev-parse HEAD)
rg own worktree add -q -b c-801-c001-fix-own "$T/wt/c-801" origin/master 2>/dev/null
mkrepo nof
rg nof commit -q --allow-empty -m "nof fix" && lettered nof 12 "nof fix" && rg nof push -q origin HEAD:master
NOFSHA=$(rg nof rev-parse HEAD)
rg nof commit -q --allow-empty -m "nof, never pushed" && lettered nof 12 "nof, never pushed"
NOFLOCAL=$(rg nof rev-parse HEAD)
rg nof worktree add -q --detach "$T/wt/m-802" "$NOFLOCAL" 2>/dev/null
rg nof remote set-url origin "$T/gone.git"
msg c-002/archive own c-801 c-002 30 "- sha: ${OWNSHA:0:12}"
msg c-002/archive nof m-802 c-002 30 "- sha: ${NOFSHA:0:12}"
msg c-002/archive noflocal m-802 c-002 25 "- sha: ${NOFLOCAL:0:12}"
! rg spl cat-file -e "$OWNSHA^{object}" 2>/dev/null && ! rg other cat-file -e "$OWNSHA^{object}" 2>/dev/null &&
  ! rg nof fetch -q origin 2>/dev/null &&
  pass "16. control: the own repo's sha is in neither checked repo; the second own repo's fetch fails" || fail "16. control: fixture"
run DONE_CLAIM_STATE_DIR="$T/st16"; rc=$?
v="$(for k in own nof noflocal; do printf '%s=%s ' "$k" "$(verdict $k)"; done)"
[ "$rc" = 0 ] && [ "$v" = "own=unchecked nof=unchecked noflocal=unchecked " ] &&
  [ "$(grep -c '	not checked (own repo not found' "$T/o")" = 3 ] &&
  pass "16. with the lanes' worktrees unknown (the 10-22 gap) a sha of the lane's own repo is not checked (SPL-3020: that repo was never read), no alert" ||
  fail "16. no worktree (rc $rc) got '$v': $(cat "$T/o")"
printf 'c-801\tclaude\t%%1\t%s\t20261022T000000Z\n' "$T/wt/c-801" >"$SP/registry.tsv"
printf '# path\tkind\tagent\tbox\tbranch\tfinished_at\n%s\n%s\n' \
  "$T/wt/m-802	worktree	m-802	box-a		$(iso "$NOW")" \
  "$T/wt/m-802-old	worktree	m-802	box-a	m-802-c001-old	$(iso "$OLD")" >"$SP/workdirs.tsv"
run DONE_CLAIM_STATE_DIR="$T/st16"; rc=$?
v="$(for k in own nof noflocal; do printf '%s=%s ' "$k" "$(verdict $k)"; done)"
[ "$rc" = 0 ] && [ "$v" = "own=landed nof=landed noflocal=unchecked " ] &&
  [ "$(awk -F'\t' '$1 == "own" { print NF }' "$T/o")" = 4 ] &&
  [ "$(awk -F'\t' '$1 == "nof" || $1 == "noflocal"' "$T/o" | grep -c "[	 ]own repo $T/nof not fetched, judged on its last fetched origin/master$")" = 2 ] &&
  grep -q "WARN git fetch origin failed in $T/nof (m-802's own repo)" "$T/o" &&
  grep -q "^noflocal	m-802	unchecked	${NOFLOCAL:0:12}	not checked (git fetch failed in $T/nof): " "$T/o" &&
  pass "16. a sha on the trunk of the lane's own repo (registry worktree) is landed; a retired lane's repo whose fetch fails is judged on its last fetched trunk (landed) and the row says so; a sha off that stale trunk is not checked (SPL-3020, alert 5bc7078d)" ||
  fail "16. own repo (rc $rc) got '$v': $(cat "$T/o")"
run DRY_RUN=0 DONE_CLAIM_TO=c-009 DONE_CLAIM_STATE_DIR="$T/st16"; rc=$?
[ "$rc" = 0 ] && [ ! -s "$T/calls.log" ] && ! grep -q '^noflocal	' "$T/st16/seen.tsv" && grep -q '^nof	m-802	landed' "$T/o" &&
  pass "16. DRY_RUN=0: the sha off the unfetched own repo's stale trunk sends no note and stays out of the ledger (SPL-3020; it was ONE 'not in the repository' note before)" ||
  fail "16. note (rc $rc): $(cat "$T/o") // $(cat "$T/calls.log")"

# 17. SPL-3020 (alerts 5bc7078d and 2d6c1619, 10-23, synthetic): a sha the
# check could not judge is "not checked (<why>)", never "not in the
# repository". (a) The lane's own repo cannot fetch and the sha is only on its
# newer origin; a lane whose repo was never scanned. (b) A repo whose trunk is
# LOCAL by design (never pushed from this box: `git config spool.localTrunk
# <branch>` in that clone) is judged on that local branch. (c) A sha absent
# from a repo read fresh still alerts.
SP="$T/spool17"
mkdir -p "$SP"
mkrepo fa
git clone -q "$T/fa.git" "$T/fa-push" 2>/dev/null
rg fa-push commit -q --allow-empty -m "fa newer" && lettered fa-push 12 "fa newer" && rg fa-push push -q origin HEAD:master
FANEW=$(rg fa-push rev-parse HEAD)
rg fa worktree add -q -b c-811-c001-fix-fa "$T/wt/c-811" origin/master 2>/dev/null
rg fa remote set-url origin "$T/gone17.git"
mkrepo lt
rg lt commit -q --allow-empty -m "local trunk only" && lettered lt 12 "local trunk only"
LTSHA=$(rg lt rev-parse HEAD)
rg lt checkout -q -b side && rg lt commit -q --allow-empty -m "side, not on the local trunk" && lettered lt 12 "side"
LTSIDE=$(rg lt rev-parse HEAD)
rg lt checkout -q master
rg lt worktree add -q --detach "$T/wt/c-812" "$LTSHA" 2>/dev/null
mkrepo fr
rg fr commit -q --allow-empty -m "fresh, never pushed" && lettered fr 12 "fresh, never pushed"
FRLOCAL=$(rg fr rev-parse HEAD)
rg fr worktree add -q --detach "$T/wt/c-813" "$FRLOCAL" 2>/dev/null
printf 'c-811\tclaude\t%%1\t%s\t-\nc-812\tclaude\t%%2\t%s\t-\nc-813\tclaude\t%%3\t%s\t-\n' "$T/wt/c-811" "$T/wt/c-812" "$T/wt/c-813" >"$SP/registry.tsv"
msg c-002/archive fanew c-811 c-002 30 "- sha: ${FANEW:0:12}"
msg c-002/archive ltsha c-812 c-002 30 "- sha: ${LTSHA:0:12}"
msg c-002/archive ltside c-812 c-002 25 "- sha: ${LTSIDE:0:12}"
msg c-002/archive frlocal c-813 c-002 30 "- sha: ${FRLOCAL:0:12}"
msg c-002/archive nolane c-814 c-002 30 "- sha: ${FANEW:0:12}"
! rg fa cat-file -e "$FANEW^{object}" 2>/dev/null && ! rg fa fetch -q origin 2>/dev/null &&
  ! rg lt merge-base --is-ancestor "$LTSHA" origin/master && rg lt merge-base --is-ancestor "$LTSHA" master &&
  pass "17. control: the fa clone cannot fetch and lacks its origin's newer sha; lt's sha is on its local master, not on origin/master" ||
  fail "17. control: fixture"
git -C "$T/lt" config spool.localTrunk master
run DONE_CLAIM_STATE_DIR="$T/st17"; rc=$?
v="$(for k in fanew ltsha ltside frlocal nolane; do printf '%s=%s ' "$k" "$(verdict $k)"; done)"
[ "$rc" = 0 ] && [ "$v" = "fanew=unchecked ltsha=landed ltside=would-alert frlocal=would-alert nolane=unchecked " ] &&
  grep -q "^fanew	c-811	unchecked	${FANEW:0:12}	.*not checked (.*git fetch failed in $T/fa" "$T/o" &&
  grep -q "^nolane	c-814	unchecked	${FANEW:0:12}	not checked (.*own repo not found" "$T/o" &&
  grep -q '^OK done-claim-check: 1 landed, .* 2 not checked, 2 would alert' "$T/o" &&
  pass "17. (a) a sha whose candidate repo failed its fetch, or whose lane's repo was never scanned, is 'not checked (<why>)'; (b) a local-trunk repo's sha on its local master is landed, one off it alerts; (c) a sha absent from a repo read fresh alerts" ||
  fail "17. not checked / local trunk (rc $rc) got '$v': $(cat "$T/o")"
run DRY_RUN=0 DONE_CLAIM_TO=c-009 DONE_CLAIM_STATE_DIR="$T/st17"; rc=$?
[ "$rc" = 0 ] && [ "$(grep -c '^SEND' "$T/calls.log")" = 2 ] &&
  grep -q "^SEND c-009 done-claim-check done-claim check: c-812 result ltside .*: sha ${LTSIDE:0:12} not in the repository$" "$T/calls.log" &&
  grep -q "^SEND c-009 done-claim-check done-claim check: c-813 result frlocal .*: sha ${FRLOCAL:0:12} not in the repository$" "$T/calls.log" &&
  ! grep -q "c-811\|c-814" "$T/calls.log" && ! grep -q "^fanew	\|^nolane	" "$T/st17/seen.tsv" &&
  pass "17. DRY_RUN=0: no note and no ledger row for a not-checked sha (judged again next run); the fresh-repo and off-trunk shas each alert once" ||
  fail "17. note (rc $rc): $(cat "$T/o") // $(cat "$T/calls.log")"

# 18. SPL-3116 (msg b494ec3c: 4 of 4 notes 20:25-20:45Z 10-23 were false,
# c-912/c-913/c-915's review requests 5dd951765, e829b0e06, 2f285d74e,
# 82b3db2ac, synthetic): a sha on origin/review/<topic>-... with no lane id is
# the sending lane's, pending while it is in registry.tsv. A retired sender with
# the same shape, a live sender whose sha is on another (retired) id's branch,
# and a live sender's sha on no branch still alert.
SP="$T/spool18"
mkdir -p "$SP"
rg spl fetch -q origin
# park <msg> <branch>: a commit off trunk, pushed to origin's <branch> only; its
# 9-char prefix holds a letter (as lettered).
park() {
  local c i
  for i in $(seq 1 50); do
    c=$(rg spl commit-tree -p origin/master -m "$1 $i" "origin/master^{tree}")
    [[ "${c:0:9}" =~ [a-f] ]] && break
  done
  rg spl push -q origin "$c:refs/heads/$2" && echo "$c"
}
T21=$(park "s107 T021" review/s107-v2-t021)
T20=$(park "s107 T020" review/s107-v2-t020)
T20X=$(park "s107 T020 expand" review/s107-v2-t020-expand)
T22=$(park "s107 T022" wip/s107-v2-t022)
R21=$(park "retired T021" review/s107-v2-r021)
OID=$(park "another id's review" review/c-899-c002-other)
for i in $(seq 1 50); do
  NOB=$(rg spl commit-tree -p origin/master -m "on no branch $i" "origin/master^{tree}")
  [[ "${NOB:0:9}" =~ [a-f] ]] && break
done
rg spl fetch -q origin
for l in c-821 c-822 c-823 c-825 c-826; do printf '%s\tclaude\t%%9\t%s\t-\n' "$l" "$T/wt/c-563" >>"$SP/registry.tsv"; done
msg c-002/archive rq21 c-821 c-002 30 "review request: ${T21:0:9} on review/s107-v2-t021"
msg c-002/archive rq20 c-822 c-002 30 "review request: ${T20:0:9} and ${T20X:0:9}"
msg c-002/archive rq22 c-823 c-002 30 "- sha: ${T22:0:9} (wip)"
msg c-002/archive rqret c-824 c-002 30 "review request: ${R21:0:9}"
msg c-002/archive rqoid c-825 c-002 30 "review request: ${OID:0:9}"
msg c-002/archive rqnob c-826 c-002 30 "done ${NOB:0:9}"
[[ "$(rg spl branch -r --contains "$T21" --format='%(refname:short)')" == origin/review/s107-v2-t021 ]] &&
  ! rg spl merge-base --is-ancestor "$T21" origin/master && [ -z "$(rg spl branch -r --contains "$NOB")" ] &&
  pass "18. control: ${T21:0:9} sits only on origin/review/s107-v2-t021 (no lane id), ${NOB:0:9} on no branch" ||
  fail "18. control: fixture"
run DONE_CLAIM_STATE_DIR="$T/st18"; rc=$?
v="$(for k in rq21 rq20 rq22 rqret rqoid rqnob; do printf '%s=%s ' "$k" "$(verdict $k)"; done)"
[ "$rc" = 0 ] && [ "$v" = "rq21=pending rq20=pending rq22=pending rqret=would-alert rqoid=would-alert rqnob=would-alert " ] &&
  pass "18. SPL-3116: a live lane's sha on origin/review/<topic> or origin/wip/<topic> (no lane id) is pending (the four-sha shape, two shas in one body too); a retired sender's, one on another id's branch, and one on no branch still alert" ||
  fail "18. review branch without the lane id (rc $rc) got '$v': $(cat "$T/o")"
run DRY_RUN=0 DONE_CLAIM_TO=c-009 DONE_CLAIM_STATE_DIR="$T/st18"; rc=$?
[ "$rc" = 0 ] && [ "$(grep -c '^SEND' "$T/calls.log")" = 3 ] && ! grep -q 'c-821\|c-822\|c-823' "$T/calls.log" &&
  grep -q "c-824 result rqret .*: sha ${R21:0:9} not in the repository$" "$T/calls.log" &&
  ! grep -q '^rq21	\|^rq20	\|^rq22	' "$T/st18/seen.tsv" &&
  pass "18. DRY_RUN=0: no note and no ledger row for the pending review requests; the three others alert once" ||
  fail "18. note (rc $rc): $(cat "$T/o") // $(cat "$T/calls.log")"
: >"$SP/registry.tsv"
run DRY_RUN=0 DONE_CLAIM_TO=c-009 DONE_CLAIM_STATE_DIR="$T/st18"; rc=$?
[ "$rc" = 0 ] && [ "$(grep -c '^SEND' "$T/calls.log")" = 3 ] && grep -q "c-822 result rq20 .*: sha ${T20:0:9}, ${T20X:0:9} not in the repository$" "$T/calls.log" &&
  pass "18. the lanes retired, their review-branch shas alert once" || fail "18. retired (rc $rc): $(cat "$T/o") // $(cat "$T/calls.log")"

# 19. SPL-3261 (notes 68215ba2 and d72ab6e0, 10-24; bug round 9 row 01,
# fixtures of reviewer c-962, synthetic): A = a-709's shape, a retired R7
# reviewer whose last branch is <id>-rotate, its R7 line nested below "##
# Result"; A0 the same with its reviewer slug; R a rotate SUFFIX on a reviewer
# slug; R2 a rotate row over an older local reviewer branch; B c-913's
# 12472906 layout ("- Landed: <sha9>", "Range-diff, reviewed <rev9> vs landed
# <sha9>"); B2 "Landed sha:" + "range-diff:" lines; B3 a FALSE claim, a
# Landed line plus the lane's own unlanded sha on a range-diff line (the
# accepted cost of the Landed rule); C a retired code-slug reviewer citing the
# sha on origin/review/<topic> of a live author whose branch ends in -<topic>.
SP="$T/spool19"
mkdir -p "$SP/c-002/archive"
mkrepo rr
rg rr checkout -q -b rv origin/master && echo a >"$T/rr/x" && rg rr add x && rg rr commit -q -m "feat(rdb, SPL-9102): t021 (rdb 0215)" && lettered rr 9 rv
REV2=$(rg rr rev-parse HEAD) && rg rr push -q origin HEAD:refs/heads/review/s107-v2-t021
rg rr checkout -q master && echo b >"$T/rr/x" && rg rr add x && rg rr commit -q -m "feat(rdb, SPL-9102): t021 (rdb 0216)" && lettered rr 9 landed
LAND19=$(rg rr rev-parse HEAD) && rg rr push -q origin HEAD:master
rg rr checkout -q -b r4 origin/master && rg rr commit -q --allow-empty -m "r19-04 decompose" && lettered rr 9 r4
REV4=$(rg rr rev-parse HEAD) && rg rr push -q origin HEAD:refs/heads/review/r19-04-wui-decompose-message-card-pointer
rg rr checkout -q -b r5 origin/master && rg rr commit -q --allow-empty -m "unlanded code of the sender" && lettered rr 9 r5
UNL19=$(rg rr rev-parse HEAD) && rg rr push -q origin HEAD:refs/heads/review/b3-topic
rg rr checkout -q master
for b in a-709-c002-r19-reviewer-agy a-709-rotate a-713-c002-r19-reviewer-agy; do rg rr branch -q "$b" origin/master; done
rg rr worktree add -q -b c-906-c296-r19-04-wui-decompose-message-card-pointer "$T/wt/c-906" origin/master 2>/dev/null
# m19 <id> <from> <body>: one result in c-002's archive, 30 min old.
m19() { msg c-002/archive "$1" "$2" c-002 30 "$3"; }
R7="review: a-709@box-b agy PASS $REV4 ran: x | read: y | log: a-709@box-b:/x/transcript.jsonl"
m19 A a-709 "## Result: R7 review round 19 rows 01, 02, 03, 04 complete (SPL-9139)

Reviewed all 4 rows.

- **r19-04** (SPL-9091, \`$REV4\`, author c-906@box-a): PASS sent to c-906.
  - Review line:
    \`$R7\`"
m19 A0 a-710 "## Result: R7 review done

- **r19-04** (\`$REV4\`): PASS
    \`${R7//a-709/a-710}\`"
m19 R a-711 "Reviewed r19-04 ${REV4:0:9}: PASS, sent to c-906"
m19 R2 a-713 "Reviewed r19-04 ${REV4:0:9}: PASS, sent to c-906"
m19 B c-913 "**Live**: s107-v2 T021, people and plan tables (SPL-9102), slot 1.

- Landed: ${LAND19:0:9} on origin/master at 00:49Z (\`git-fetch-fresh.sh --landed\` rc 0).

Range-diff, reviewed ${REV2:0:9} vs landed ${LAND19:0:9} (\`git range-diff ${REV2:0:9}~1..${REV2:0:9} ${LAND19:0:9}~1..${LAND19:0:9}\`):
- rename only."
m19 B2 c-914 "**Live**: t021.

Landed sha: ${LAND19:0:9}
range-diff: reviewed ${REV2:0:9} vs landed ${LAND19:0:9}"
m19 B3 c-915 "**Live**: my fix.

Landed sha: ${LAND19:0:9}
1:  ${UNL19:0:9} = 1:  ${UNL19:0:9} fix(x): the fix"
m19 C a-712 "Reviewed r19-04 ${REV4:0:9}: PASS, sent to c-906"
printf '# path\tkind\tagent\tbox\tbranch\tfinished_at\n' >"$SP/workdirs.tsv"
for r in "a-709	a-709-rotate" "a-710	a-710-c002-r19-reviewer-agy" "a-711	a-711-c002-x-reviewer-agy-rotate" "a-713	a-713-rotate" \
  "c-913	c-913-c002-s107-v2-t021" "c-914	c-914-c002-t021" "c-915	c-915-c002-fix" "a-712	a-712-c002-code"; do
  printf '%s\tworktree\t%s\tbox-a\t%s\t%s\n' "$T/wt/${r%%	*}" "${r%%	*}" "${r#*	}" "$(iso "$NOW")" >>"$SP/workdirs.tsv"
done
printf 'c-906\tclaude\t%%1\t%s\t20261024T000000Z\n' "$T/wt/c-906" >"$SP/registry.tsv"
! rg rr merge-base --is-ancestor "$REV2" origin/master && ! rg rr merge-base --is-ancestor "$REV4" origin/master &&
  [[ "$(rg rr branch -r --contains "$REV4" --format='%(refname:short)')" == origin/review/r19-04-wui-decompose-message-card-pointer ]] &&
  pass "19. control: the reviewed shas ${REV2:0:9} and ${REV4:0:9} are on review branches only, ${REV4:0:9} on one with no lane id" ||
  fail "19. control: fixture"
k19="A A0 R R2 B B2 B3 C"
run DONE_CLAIM_REPO_DIRS="$T/rr" DONE_CLAIM_STATE_DIR="$T/st19"; rc=$?
v="$(for k in $k19; do printf '%s=%s ' "$k" "$(verdict $k)"; done)"
[ "$rc" = 0 ] && [ "$v" = "A=seat A0=seat R=pending R2=seat B=landed B2=landed B3=landed C=pending " ] &&
  [ "$(awk -F'\t' '$1 == "B" { print $4 }' "$T/o")" = "${LAND19:0:9}" ] &&
  grep -q '^OK done-claim-check: 3 landed, 0 rewritten, 3 seat, 2 pending, 0 not checked, 0 would alert' "$T/o" &&
  pass "19. SPL-3261: a rotation branch <id>-rotate[-N] is no slug (a retired reviewer keeps its reviewer slug from its local branch: seat); a reviewer citing its live author's sha on origin/review/<topic> is pending (the author's branch ends in -<topic>); a Landed: / Landed sha: line is the claim ahead of the range-diff's reviewed sha (c-913's 12472906 shape: landed)" ||
  fail "19. rotation / review topic / Landed line (rc $rc) got '$v': $(cat "$T/o")"
run DRY_RUN=0 DONE_CLAIM_TO=c-009 DONE_CLAIM_REPO_DIRS="$T/rr" DONE_CLAIM_STATE_DIR="$T/st19"; rc=$?
[ "$rc" = 0 ] && [ ! -s "$T/calls.log" ] && ! grep -q '^R	\|^C	' "$T/st19/seen.tsv" &&
  pass "19. DRY_RUN=0: no alert note for any of the eight; the two pending ones stay out of the ledger" ||
  fail "19. note (rc $rc): $(cat "$T/o") // $(cat "$T/calls.log")"
: >"$SP/registry.tsv"
run DONE_CLAIM_REPO_DIRS="$T/rr" DONE_CLAIM_STATE_DIR="$T/st19"; rc=$?
v="$(for k in R C; do printf '%s=%s ' "$k" "$(verdict $k)"; done)"
[ "$rc" = 0 ] && [ "$v" = "R=would-alert C=would-alert " ] &&
  pass "19. the author retired, the reviewers' review-branch shas alert again (the -<topic> match needs a live lane)" ||
  fail "19. author retired (rc $rc) got '$v': $(cat "$T/o")"

exit "$fails"
