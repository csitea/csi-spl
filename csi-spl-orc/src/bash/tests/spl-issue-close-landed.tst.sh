#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_issue_close_landed moves every OPEN issue a commit landed on
# master names to done (owner, t1 dee4081d msg ea519baa), by the rule: a
# fix / feat / perf / refactor subject scope or a "Closes:" trailer; never a
# body mention, a "Refs:" trailer, a docs subject or a revert. A reopened
# issue is never closed again by the same sha. do_spl_issue_close_check is
# the lane exit check on the same rule. A throwaway git repo plays trunk; the
# hub calls are stubbed and logged.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

R="$T/repo"
mkdir -p "$R"
g() { git -C "$R" -c user.name=t -c user.email=t@example.com "$@"; }
n=0
commit() { n=$((n + 1)); echo "$n" >>"$R/f"; g add f && g commit -q -m "$1" && g rev-parse HEAD; }
g init -q -b master
commit "chore: base" >/dev/null
S10=$(commit "fix(orc, SPL-10): a fix")
S11=$(commit "feat(api, SPL-11, SPL-12): two keys")
commit "docs(doc, SPL-13): docs never close" >/dev/null
commit "test(wui): a fixture

mentions SPL-14 in the body" >/dev/null
commit "chore(orc): a trailer that only refers

Refs: SPL-15" >/dev/null
S16=$(commit "chore(ci): closed by trailer

Closes: SPL-16, SPL-17")
commit 'Revert "fix(orc, SPL-18): reverted"' >/dev/null
commit "perf(store, SPL-19): already done" >/dev/null
commit "refactor(orc, SPL-20): an epic" >/dev/null
commit "feat(wui, SPL-21): older than its issue" >/dev/null
commit "fix(wui, SPL-22)!: the move fails" >/dev/null
commit "docs(doc): an explicit trailer closes on any type

Closes: SPL-23" >/dev/null
commit 'Revert "chore(ci): closed by trailer"

Closes: SPL-24' >/dev/null
S25=$(commit "fix(orc, SPL-25): a human asked for its review")
HEAD1=$(g rev-parse HEAD)

# The open list: SPL-19 is done (absent), SPL-20 an epic, SPL-21 created after its commit,
# SPL-25 in qas (a review a human asked for: spec 135 Q7).
issue() { printf '{"key":"%s","status":"%s","kind":"%s","created_at":"%s"}' "$1" "$2" "$3" "${4:-2000-01-01T00:00:00Z}"; }
{
  printf '{"env":"dev","result":{"next_cursor":"","issues":['
  issue SPL-10 todo issue; printf ,; issue SPL-11 todo issue; printf ,; issue SPL-12 wip issue; printf ,
  issue SPL-13 todo issue; printf ,; issue SPL-14 todo issue; printf ,; issue SPL-15 eval issue; printf ,
  issue SPL-16 todo issue; printf ,; issue SPL-17 todo issue; printf ,; issue SPL-18 todo issue; printf ,
  issue SPL-20 wip epic; printf ,; issue SPL-21 todo issue 2099-01-01T00:00:00Z; printf ,; issue SPL-22 todo issue; printf ,
  issue SPL-23 todo issue; printf ,; issue SPL-24 todo issue; printf ,; issue SPL-25 qas issue
  printf ']}}\n'
} >"$T/list.json"
python3 -m json.tool "$T/list.json" >/dev/null || { echo "FAIL: the fixture list is not JSON"; exit 1; }

STUBS='spl_issue_list_fetch() { echo "list $*" >>"$STUB_LOG"; cat "$LIST"; }
spl_desk_issue_run() {
  echo "hub $1 $3 ${5:-}" >>"$STUB_LOG"
  [[ "$1 $3" == "update ${HUB_FAIL:-none}" ]] && return 1
  [[ "$1 $3" == "update SPL-30" ]] && echo "{\"result\":{\"issue\":{\"key\":\"SPL-30\"},\"epic_closed\":{\"key\":\"SPL-31\",\"status\":\"done\",\"archived\":true}}}"
  if [[ "$1" == get ]]; then
    case "$3" in
      SPL-10) echo "{\"result\":{\"issue\":{\"status\":\"done\"}}}" ;;
      SPL-11) echo "{\"result\":{\"issue\":{\"status\":\"todo\"}}}" ;;
      SPL-12) echo "{\"result\":{\"issue\":{\"status\":\"diss\"}}}" ;;
      SPL-25) echo "{\"result\":{\"issue\":{\"status\":\"qas\"}}}" ;;
      *) echo "FATAL not found"; return 1 ;;
    esac
  fi
  return 0
}
'
ST="$T/state"
run() {
  : >"$T/calls.log"
  SNIPPET="${STUBS}do_spl_issue_close_landed" in_orc APP_PATH="$R" LIST="$T/list.json" TENANT_ID=t1 DESK_AGENT=c-684 \
    ISSUE_CLOSE_REF=master ISSUE_CLOSE_FETCH=0 ISSUE_CLOSE_STATE_DIR="$ST" ISSUE_CLOSE_WUI_URL=https://wui.example.com "$@" >"$T/o" 2>&1
}
row() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$T/o"; }

# 1. no cursor and no ISSUE_CLOSE_SINCE: refused before any hub call
run; rc=$?
[ "$rc" -ne 0 ] && grep -q 'no cursor' "$T/o" && ! grep -q '^hub\|^list' "$T/calls.log" &&
  pass "1. the first run needs the back-fill (no cursor = refused, no hub call)" || fail "1. no cursor (rc $rc: $(cat "$T/o"))"

# 2. back-fill dry run: the rule's verdicts, no write
run ISSUE_CLOSE_SINCE=all; rc=$?
v="$(for k in 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do printf '%s=%s ' "$k" "$(row SPL-$k)"; done)"
want="10=would-move 11=would-move 12=would-move 13= 14= 15= 16=would-move 17=would-move 18= 19=noop 20=skip 21=skip 22=would-move 23=would-move 24= 25=noop "
[ "$rc" = 0 ] && [ "$v" = "$want" ] && ! grep -q '^hub' "$T/calls.log" && [ ! -e "$ST/cursor" ] && [ ! -e "$ST/closed.tsv" ] &&
  pass "2. dry back-fill: subject scope, several keys and Closes: close (on a docs subject too); docs scope, body mention, Refs: and revert (even with Closes:) do not; done = no-op; epic and reused key skipped; nothing written" ||
  fail "2. dry back-fill (rc $rc) got '$v' want '$want': $(cat "$T/o")"

# 3. real back-fill with one failed move: the others move, the cursor stays
run ISSUE_CLOSE_SINCE=all DRY_RUN=0 HUB_FAIL=SPL-22; rc=$?
[ "$rc" -ne 0 ] && [ "$(row SPL-10)" = moved ] && [ "$(row SPL-22)" = failed ] &&
  grep -q "^hub comment SPL-10 Landed on master" "$T/calls.log" && grep -q '^hub update SPL-10 done' "$T/calls.log" &&
  grep -q "https://wui.example.com/releases/$S10" "$T/calls.log" &&
  grep -qx "SPL-19	[0-9a-f]*	noop" "$ST/closed.tsv" && grep -qx "SPL-10	$S10	moved" "$ST/closed.tsv" &&
  ! grep -q '^SPL-22' "$ST/closed.tsv" && [ ! -e "$ST/cursor" ] &&
  pass "3. a failed move is reported, the others move with a sha + release link comment, the ledger keeps them, the cursor stays" ||
  fail "3. real back-fill (rc $rc): $(cat "$T/o") // $(cat "$T/calls.log")"
[ "$(row SPL-25)" = noop ] && grep -q '^SPL-25	noop	.*spec 135 Q7' "$T/o" && ! grep -q 'SPL-25' "$T/calls.log" &&
  grep -qx "SPL-25	$S25	noop" "$ST/closed.tsv" &&
  pass "3b. Q7: an issue in qas is not closed by its commit (no hub call); the sha goes to the ledger, so a send-back to wip is not closed by it either" ||
  fail "3b. qas (rc $rc): $(cat "$T/o") // $(cat "$T/calls.log")"

# 4. retry: only the failed one acts again; the cursor is written
run ISSUE_CLOSE_SINCE=all DRY_RUN=0; rc=$?
[ "$rc" = 0 ] && [ "$(row SPL-22)" = moved ] && [ "$(row SPL-10)" = skip ] && [ "$(grep -c '^hub update' "$T/calls.log")" = 1 ] &&
  [ "$(cat "$ST/cursor")" = "$HEAD1" ] &&
  pass "4. a retry moves only what failed (the ledger stops the rest) and sets the cursor" || fail "4. retry (rc $rc): $(cat "$T/o")"

# 5. reopened by hand (still in the open list): never closed again by the same sha, even on a back-fill
run ISSUE_CLOSE_SINCE=all DRY_RUN=0; rc=$?
[ "$rc" = 0 ] && [ "$(row SPL-11)" = skip ] && grep -q 'reopened by hand' "$T/o" && ! grep -q '^hub' "$T/calls.log" &&
  [ "$(row SPL-19)" = noop ] && ! grep -q '^SPL-19	.*reopened' "$T/o" &&
  pass "5. an issue reopened by hand is not closed again by the same sha; a done one in the ledger stays a no-op, not 'reopened'" || fail "5. reopen guard (rc $rc): $(cat "$T/o")"

# 6. the cursor run reads only the new commits; a NEW commit naming the reopened issue closes it
S11B=$(commit "fix(api, SPL-11): the rest of it")
run DRY_RUN=0; rc=$?
[ "$rc" = 0 ] && [ "$(wc -l <"$T/o" | tr -d ' ')" -ge 1 ] && [ "$(row SPL-11)" = moved ] && [ -z "$(row SPL-10)" ] &&
  [ "$(grep -c '^hub update' "$T/calls.log")" = 1 ] && grep -q "${S11B:0:12}" "$T/calls.log" && ! grep -q "${S11:0:12}" "$T/calls.log" &&
  [ "$(cat "$ST/cursor")" = "$S11B" ] &&
  pass "6. the cursor run reads only new commits; a newer commit closes a reopened issue, naming only itself" || fail "6. cursor run (rc $rc): $(cat "$T/o") // $(cat "$T/calls.log")"

# 7. the exit check: closed by the rule, by hand, still open, unknown
chk() {
  : >"$T/calls.log"
  SNIPPET="${STUBS}do_spl_issue_close_check" in_orc APP_PATH="$R" TENANT_ID=t1 DESK_AGENT=c-684 ISSUE_CLOSE_STATE_DIR="$ST" "$@" >"$T/o" 2>&1
}
chk ISSUE_CLOSE_SHAS="$S10 $S11" DRY_RUN=0; rc=$?
[ "$rc" = 3 ] && grep -qx "SPL-10	closed-by-rule	$S10" "$T/o" && grep -q "^SPL-11	OPEN	todo (reopened after the rule closed it by ${S11B:0:12})" "$T/o" &&
  grep -qx 'SPL-12	diss' "$T/o" &&
  pass "7. the exit check names closed-by-rule, closed by hand and OPEN (reopened), and refuses (3)" || fail "7. check (rc $rc): $(cat "$T/o")"
chk ISSUE_CLOSE_SHAS="$S16" DRY_RUN=0; rc=$?
[ "$rc" = 1 ] && grep -q '^SPL-16	unknown' "$T/o" && pass "8. a failed hub read is unknown, rc 1, never a pass" || fail "8. unknown (rc $rc): $(cat "$T/o")"
chk ISSUE_CLOSE_SHAS="$(g log -1 --format=%H --grep='docs never close') $(g log -1 --format=%H --grep='Refs: SPL-15')" DRY_RUN=0; rc=$?
[ "$rc" = 0 ] && ! grep -q '^hub' "$T/calls.log" && pass "9. commits that name nothing by the rule pass with no hub call" || fail "9. none named (rc $rc): $(cat "$T/o")"

chk ISSUE_CLOSE_SHAS="$S25" DRY_RUN=0; rc=$?
[ "$rc" = 0 ] && grep -qx 'SPL-25	qas	review-asked' "$T/o" &&
  pass "9b. Q7: the exit check lets a lane go when its issue waits in a review a human asked for" || fail "9b. qas exit (rc $rc): $(cat "$T/o")"

# 10. evidence: a cited landing closes an issue no commit names by the rule (no reused-key check); an unknown sha is skipped
CHORE=$(g log -1 --format=%H --grep='docs never close')
printf 'SPL-13\t%s\tthe triage cites it\nSPL-14\tdeadbeef\tbad sha\n' "${CHORE:0:9}" >"$T/ev.tsv"
run DRY_RUN=0 ISSUE_CLOSE_EVIDENCE="$T/ev.tsv"; rc=$?
[ "$rc" = 0 ] && [ "$(row SPL-13)" = moved ] && [ "$(row SPL-14)" = skip ] && grep -q "hub comment SPL-13 .*cited: the triage cites it" <(tr '\n' ' ' <"$T/calls.log") &&
  grep -qx "SPL-13	$CHORE	moved" "$ST/closed.tsv" &&
  pass "10. a cited landing (ISSUE_CLOSE_EVIDENCE) closes with the same comment and ledger; an unknown sha is skipped" || fail "10. evidence (rc $rc): $(cat "$T/o")"

# 11. the cron runs the action in holder mode on every box (SPL-2631): the
# action, not a local cursor, decides which box sweeps. A fake orc tree whose
# ./run logs its call; the state dir is empty, as on a box that never ran the
# back-fill. RED on the old cron: "no cursor" and ./run never called.
F="$T/fake/x-y-orc"
mkdir -p "$F/src/bash/scripts" "$F/lib/bash/funcs"
cp "$PROJ_ROOT/src/bash/scripts/issue-close-landed-cron.sh" "$F/src/bash/scripts/"
cp "$PROJ_ROOT/lib/bash/funcs/spl-desk-agents.func.sh" "$F/lib/bash/funcs/"
printf '#!/bin/sh\necho "run $* ENV=$ENV TENANT_ID=$TENANT_ID HOLDER=$ISSUE_CLOSE_HOLDER STATE=$ISSUE_CLOSE_STATE_DIR DRY_RUN=$DRY_RUN DESK=$DESK_AGENT@$DESK_BOX" >>"$CRON_LOG"\nexit "${FAKE_RC:-0}"\n' >"$F/run"
chmod +x "$F/run"
mkdir -p "$T/root11"
out="$(CRON_LOG="$T/cron.log" SPOOL_ROOT="$T/root11" ISSUE_CLOSE_STATE_DIR="$T/empty" bash "$F/src/bash/scripts/issue-close-landed-cron.sh")"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$T/cron.log" 2>/dev/null)" = "run -a do_spl_issue_close_landed ENV=prd TENANT_ID=t1 HOLDER=1 STATE=$T/empty DRY_RUN=0 DESK=c-684@box-rsp" ] &&
  pass "11. the cron runs do_spl_issue_close_landed in holder mode (ISSUE_CLOSE_HOLDER=1) on a box with no cursor too" ||
  fail "11. cron (rc $rc: $out // $(cat "$T/cron.log" 2>/dev/null))"

grep -qE '^issue-close-landed +\| \*/5 \* \* \* \* +\| src/bash/scripts/issue-close-landed-cron.sh ' "$PROJ_ROOT/cnf/box-crons/box-crons.manifest" &&
  pass "12. the box-crons manifest carries the 5-minute issue-close-landed row" || fail "12. no issue-close-landed row in box-crons.manifest"

# 13. SPL-2508: the move closes the issue's epic with it (SPL-1729: its last
# open issue), and a queued spawn ask's brief here names that epic: the epic
# is reopened (unarchive, wip, a comment naming the ask). CONTROL: the same
# move with the queued brief naming another epic leaves it closed.
git init -q --bare "$T/specs.git" && git init -q -b master "$T/specs"
mkdir -p "$T/specs/csi-spl-doc/specs/135-work-process" && echo '# Spec 135' >"$T/specs/csi-spl-doc/specs/135-work-process/spec.md"
git -C "$T/specs" add -A && git -C "$T/specs" -c user.name=t -c user.email=t@example.com commit -q -m s &&
  git -C "$T/specs" remote add origin "$T/specs.git" && git -C "$T/specs" push -q origin master 2>/dev/null
mkdir -p "$T/briefs"
printf 'Spec: csi-spl-doc/specs/135-work-process\nEpic: SPL-31\n' >"$T/briefs/tokens-tab.md"
printf 'Spec: csi-spl-doc/specs/135-work-process\nEpic: SPL-99\n' >"$T/briefs/other-epic.md"
printf '#!/usr/bin/env bash\necho "{\\"queue\\":[{\\"ask_id\\":\\"43b0dd6b-0000-4000-8000-000000000001\\",\\"state\\":\\"queued\\",\\"placement\\":\\"agy:$QSLUG\\"}]}"\n' >"$T/queue"
chmod +x "$T/queue"
printf '{"env":"dev","result":{"next_cursor":"","issues":[%s]}}\n' "$(issue SPL-30 wip issue)" >"$T/list30.json"
S30=$(commit "fix(orc, SPL-30): the last open issue of epic SPL-31")
run DRY_RUN=0 LIST="$T/list30.json" ISSUE_CLOSE_QUEUE_CMD="$T/queue" QSLUG=tokens-tab SPAWN_PLACE_BRIEF_DIR="$T/briefs" LI_SPEC_REPO="$T/specs"; rc=$?
[ "$rc" = 0 ] && [ "$(row SPL-30)" = moved ] && grep -q '^hub unarchive SPL-31 ' "$T/calls.log" && grep -q '^hub update SPL-31 wip' "$T/calls.log" &&
  grep -q '^hub comment SPL-31 Reopened by do_spl_issue_close_landed: SPL-30 closed it' "$T/calls.log" && grep -q 'OK SPL-31 reopened: queued spawn asks 43b0dd6b' "$T/o" &&
  pass "13. a move that auto-closes an epic a queued brief names reopens the epic (unarchive, wip, comment naming ask 43b0dd6b)" ||
  fail "13. keep epic (rc $rc): $(cat "$T/o") // $(cat "$T/calls.log")"
S30B=$(commit "fix(orc, SPL-30): again, the brief names another epic")
run DRY_RUN=0 LIST="$T/list30.json" ISSUE_CLOSE_QUEUE_CMD="$T/queue" QSLUG=other-epic SPAWN_PLACE_BRIEF_DIR="$T/briefs" LI_SPEC_REPO="$T/specs"; rc=$?
[ "$rc" = 0 ] && grep -q "^hub update SPL-30 done" "$T/calls.log" && ! grep -q 'SPL-31' "$T/calls.log" &&
  grep -q 'INFO SPL-30 closed its epic SPL-31 (SPL-1729); no queued spawn brief here names it' "$T/o" &&
  pass "13. control: the same auto-close with no queued brief naming SPL-31 leaves it closed (no unarchive, no reopen)" ||
  fail "13. control (rc $rc, ${S30:0:7} ${S30B:0:7}): $(cat "$T/o") // $(cat "$T/calls.log")"

# 14. SPL-2631 (sat alone, row 03): the cursor and the ledger follow the
# dispatch holder through the box state store. Box A holds them and is not the
# holder: it only publishes them. Box B is the holder with an empty state dir:
# it adopts A's snapshot, closes what landed since, and publishes its own.
# RED on master: B has no cursor, so it closes nothing. The store is a dir;
# ls / get / put are stubbed the way gcloud storage prints and copies.
STORE="$T/store"; mkdir -p "$STORE" "$T/root/dispatch"
STORE_STUBS='spl_icl_store_ls() { echo "ls $1" >>"$STUB_LOG"; [ -d "$STORE/$1" ] || return 0; local c; for c in $(ls -1 "$STORE/$1"); do echo "gs://b/shared/$1$c/"; done; }
spl_icl_store_get() { echo "get $1" >>"$STUB_LOG"; mkdir -p "$2" && cp -r "$STORE/$1/." "$2/"; }
spl_icl_store_put() { echo "put $2/${1##*/}" >>"$STUB_LOG"; mkdir -p "$STORE/$2" && cp -r "$1" "$STORE/$2/"; }
'
hrun() {
  : >"$T/calls.log"
  SNIPPET="${STUBS}${STORE_STUBS}do_spl_issue_close_landed" in_orc APP_PATH="$R" LIST="$T/list40.json" TENANT_ID=t1 DESK_AGENT=c-684 \
    ISSUE_CLOSE_REF=master ISSUE_CLOSE_FETCH=0 ISSUE_CLOSE_WUI_URL=https://wui.example.com STORE="$STORE" SPOOL_ROOT="$T/root" \
    ISSUE_CLOSE_HOLDER=1 DRY_RUN=0 "$@" >"$T/o" 2>&1
}
echo "c-002@boxb 1792447777" >"$T/root/dispatch/lease"
ACUR="$(cat "$ST/cursor")"
hrun ISSUE_CLOSE_STATE_DIR="$ST" SPOOL_BOX_TAG=boxa; rc=$?
snapA="$(find "$STORE" -name cursor -path "*-$ACUR/cursor" | sed -n 1p)"
[ "$rc" = 0 ] && grep -q 'holder c-002@boxb is not on this box (boxa)' "$T/o" && ! grep -q '^hub\|^list' "$T/calls.log" &&
  [ -n "$snapA" ] && [ "$(cat "$snapA")" = "$ACUR" ] && cmp -s "${snapA%/cursor}/closed.tsv" "$ST/closed.tsv" &&
  pass "14a. a box that is not the holder sweeps nothing and publishes its cursor + ledger to the box state store" ||
  fail "14a. publish (rc $rc): $(cat "$T/o") // $(cat "$T/calls.log")"
hrun ISSUE_CLOSE_STATE_DIR="$ST" SPOOL_BOX_TAG=boxa; rc=$?
[ "$rc" = 0 ] && ! grep -q '^put' "$T/calls.log" && pass "14a. control: published once, the next tick puts nothing" || fail "14a. republish (rc $rc): $(cat "$T/calls.log")"

printf '{"env":"dev","result":{"next_cursor":"","issues":[%s]}}\n' "$(issue SPL-40 wip issue)" >"$T/list40.json"
S40=$(commit "fix(orc, SPL-40): landed while box A is off")
SB="$T/stateB"
hrun ISSUE_CLOSE_STATE_DIR="$SB" SPOOL_BOX_TAG=boxb; rc=$?
[ "$rc" = 0 ] && [ "$(row SPL-40)" = moved ] && grep -q '^hub update SPL-40 done' "$T/calls.log" && [ "$(grep -c '^hub update' "$T/calls.log")" = 1 ] &&
  [ "$(cat "$SB/cursor" 2>/dev/null)" = "$S40" ] && grep -qx "SPL-10	$S10	moved" "$SB/closed.tsv" && grep -qx "SPL-40	$S40	moved" "$SB/closed.tsv" &&
  grep -q "^put .*-$S40\$" "$T/calls.log" &&
  pass "14b. the holder box with no cursor adopts the store's cursor + ledger, closes only what landed since, and publishes its own" ||
  fail "14b. holder adopt (rc $rc): $(cat "$T/o") // $(cat "$T/calls.log") // cursor $(cat "$SB/cursor" 2>/dev/null)"

rm -rf "$STORE"; mkdir -p "$STORE"
hrun ISSUE_CLOSE_STATE_DIR="$T/stateC" SPOOL_BOX_TAG=boxb; rc=$?
[ "$rc" -ne 0 ] && grep -q 'no cursor' "$T/o" && ! grep -q '^hub\|^put' "$T/calls.log" &&
  pass "14c. control: a holder box with no cursor and an empty store is refused, closes nothing" ||
  fail "14c. empty store (rc $rc): $(cat "$T/o") // $(cat "$T/calls.log")"

# 15. SPL-2688 fault 1: the cron's desk is THIS box's responder desk
# (SPOOL_RSP_BOX of the box config), never a fixed box-rsp a box may not seat.
# RED on the old cron: DESK=c-684@box-rsp on a box whose responder is sat-rsp.
mkdir -p "$T/root15"; printf 'SPOOL_BOX_TAG=sat\nSPOOL_RSP_BOX=sat-rsp\n' >"$T/root15/box.env"; : >"$T/cron.log"
out="$(CRON_LOG="$T/cron.log" SPOOL_ROOT="$T/root15" ISSUE_CLOSE_STATE_DIR="$T/s15" bash "$F/src/bash/scripts/issue-close-landed-cron.sh")"; rc=$?
[ "$rc" = 0 ] && grep -q ' DESK=c-684@sat-rsp$' "$T/cron.log" &&
  pass "15. the cron seats the closer on this box's responder desk (SPOOL_RSP_BOX=sat-rsp), not a fixed box-rsp" ||
  fail "15. desk (rc $rc: $out // $(cat "$T/cron.log"))"
: >"$T/cron.log"
out="$(CRON_LOG="$T/cron.log" SPOOL_ROOT="$T/root15" ISSUE_CLOSE_BOX=box-x ISSUE_CLOSE_STATE_DIR="$T/s15" bash "$F/src/bash/scripts/issue-close-landed-cron.sh")"; rc=$?
[ "$rc" = 0 ] && grep -q ' DESK=c-684@box-x$' "$T/cron.log" && pass "15. control: ISSUE_CLOSE_BOX still overrides it" || fail "15. override (rc $rc: $(cat "$T/cron.log"))"

# 16. SPL-2688 fault 2: a store error (an HTTP 403 as on prd) is a failed read
# or publish with its HTTP code, never "no snapshot yet". gcloud and the
# box-state put are stubbed to answer as the 403 did.
G403_STUBS='spl_box_state_gs_begin() { SPL_BOX_STATE_BUCKET=b SPL_BOX_STATE_RW_PREFIX=shared GCP_ACCOUNT=sa@example.com; }
gcloud() { echo "ls $*" >>"$STUB_LOG"; echo "ERROR: (gcloud.storage.ls) HTTPError 403: sa does not have storage.objects.list access" >&2; return 1; }
do_spl_box_state_put() { echo "put $PREFIX" >>"$STUB_LOG"; echo "ERROR: (gcloud.storage.cp) HTTPError 403: sa does not have storage.objects.get access"; return 1; }
'
g403() {
  : >"$T/calls.log"
  SNIPPET="${STUBS}${G403_STUBS}do_spl_issue_close_landed" in_orc APP_PATH="$R" LIST="$T/list40.json" TENANT_ID=t1 DESK_AGENT=c-684 \
    ISSUE_CLOSE_REF=master ISSUE_CLOSE_FETCH=0 ISSUE_CLOSE_WUI_URL=https://wui.example.com SPOOL_ROOT="$T/root" \
    ISSUE_CLOSE_HOLDER=1 DRY_RUN=0 "$@" >"$T/o" 2>&1
}
g403 ISSUE_CLOSE_STATE_DIR="$SB" SPOOL_BOX_TAG=boxb; rc=$?
[ "$rc" = 0 ] && grep -q 'WARN issue-close-landed: store read failed (HTTP 403)' "$T/o" && ! grep -q 'no snapshot yet' "$T/o" &&
  grep -q '^ls ' "$T/calls.log" &&
  pass "16. a 403 on the store read logs 'store read failed (HTTP 403)', never 'no snapshot yet'; the holder goes on with its cursor" ||
  fail "16. read 403 (rc $rc): $(cat "$T/o") // $(cat "$T/calls.log")"
mkdir -p "$T/state16"; cp "$SB/cursor" "$SB/closed.tsv" "$T/state16/"
g403 ISSUE_CLOSE_STATE_DIR="$T/state16" SPOOL_BOX_TAG=boxa; rc=$?
[ "$rc" = 0 ] && grep -q 'WARN issue-close-landed: store publish failed (HTTP 403)' "$T/o" && [ ! -e "$T/state16/published" ] &&
  pass "16. a 403 on the publish logs 'store publish failed (HTTP 403)' and leaves it unpublished for the next tick" ||
  fail "16. put 403 (rc $rc): $(cat "$T/o") // $(cat "$T/calls.log")"
[ "$(SNIPPET='spl_icl_http_code "AccessDeniedException: 403 denied"; spl_icl_http_code "network is unreachable"' in_orc 2>&1 | tr '\n' ' ')" = "403 unknown " ] &&
  pass "16. the HTTP code is read from either gcloud form; none printed = unknown" || fail "16. http code parse"

# 17. SPL-2688 fault 3: after ISSUE_CLOSE_ALERT_AFTER (default 6) red ticks in
# a row ONE blocker goes to the orchestrator (task dispatch-issue-closer), again
# at most once an hour while still red; a green tick resets the count.
# RED on the old cron: a red tick sent nothing, for hours.
printf '#!/bin/sh\necho "$*" >>"$SEND_LOG"\n' >"$T/send"
mkdir -p "$T/root17/dispatch"; echo "c-002@sat 1792478752" >"$T/root17/dispatch/lease"; printf 'SPOOL_BOX_TAG=sat\n' >"$T/root17/box.env"
tick17() { CRON_LOG="$T/cron.log" SEND_LOG="$T/send.log" SPOOL_ROOT="$T/root17" ISSUE_CLOSE_SEND="$T/send" ISSUE_CLOSE_STATE_DIR="$T/s17" "$@" \
  bash "$F/src/bash/scripts/issue-close-landed-cron.sh" >>"$T/o17" 2>&1; }
: >"$T/send.log"; sends() { grep -c . "$T/send.log"; }
for _ in 1 2 3 4 5; do tick17 env FAKE_RC=1; done; s5="$(sends)"
tick17 env FAKE_RC=1; rc6=$?; s6="$(sends)"
tick17 env FAKE_RC=1; s7="$(sends)"
[ "$s5" = 0 ] && [ "$rc6" = 1 ] && [ "$s6" = 1 ] && [ "$s7" = 1 ] &&
  grep -q -- '--from c-002 --to orchestrator --kind blocker --task dispatch-issue-closer --body ISSUE CLOSER RED on box sat: the last 6 ticks' "$T/send.log" &&
  pass "17. the 6th red tick in a row sends ONE blocker to the orchestrator (dispatch-issue-closer), the 7th none" ||
  fail "17. alert (sends after 5/6/7: $s5/$s6/$s7, rc6 $rc6): $(cat "$T/send.log") // $(tail -n 5 "$T/o17")"
echo $(( $(date -u +%s) - 3601 )) >"$T/s17/red.alerted"
tick17 env FAKE_RC=1; s8="$(sends)"
tick17 env FAKE_RC=0; rcg=$?
tick17 env FAKE_RC=1; s9="$(sends)"
[ "$s8" = 2 ] && [ "$rcg" = 0 ] && [ "$s9" = 2 ] && [ "$(cat "$T/s17/red.count")" = 1 ] && [ ! -e "$T/s17/red.alerted" ] &&
  pass "17. still red an hour later: one more blocker; a green tick resets the count (the next red is 1 of 6, no send)" ||
  fail "17. repeat/reset (sends $s8/$s9, rc green $rcg, count $(cat "$T/s17/red.count" 2>/dev/null))"
: >"$T/send.log"; rm -rf "$T/s17"
for _ in 1 2; do tick17 env FAKE_RC=1 ISSUE_CLOSE_ALERT_AFTER=2 ISSUE_CLOSE_ALERT_FROM=c-009; done
grep -q -- '--from c-009 --to orchestrator .*the last 2 ticks' "$T/send.log" &&
  pass "17. control: ISSUE_CLOSE_ALERT_AFTER and ISSUE_CLOSE_ALERT_FROM set the count and the sender" || fail "17. knobs: $(cat "$T/send.log")"

[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
