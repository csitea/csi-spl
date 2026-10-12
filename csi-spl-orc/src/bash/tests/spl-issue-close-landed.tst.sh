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
HEAD1=$(g rev-parse HEAD)

# The open list: SPL-19 is done (absent), SPL-20 an epic, SPL-21 created after its commit.
issue() { printf '{"key":"%s","status":"%s","kind":"%s","created_at":"%s"}' "$1" "$2" "$3" "${4:-2000-01-01T00:00:00Z}"; }
{
  printf '{"env":"dev","result":{"next_cursor":"","issues":['
  issue SPL-10 todo issue; printf ,; issue SPL-11 qas issue; printf ,; issue SPL-12 wip issue; printf ,
  issue SPL-13 todo issue; printf ,; issue SPL-14 todo issue; printf ,; issue SPL-15 eval issue; printf ,
  issue SPL-16 todo issue; printf ,; issue SPL-17 todo issue; printf ,; issue SPL-18 todo issue; printf ,
  issue SPL-20 wip epic; printf ,; issue SPL-21 todo issue 2099-01-01T00:00:00Z; printf ,; issue SPL-22 todo issue; printf ,
  issue SPL-23 todo issue; printf ,; issue SPL-24 todo issue
  printf ']}}\n'
} >"$T/list.json"
python3 -m json.tool "$T/list.json" >/dev/null || { echo "FAIL: the fixture list is not JSON"; exit 1; }

STUBS='spl_issue_list_fetch() { echo "list $*" >>"$STUB_LOG"; cat "$LIST"; }
spl_desk_issue_run() {
  echo "hub $1 $3 ${5:-}" >>"$STUB_LOG"
  [[ "$1 $3" == "update ${HUB_FAIL:-none}" ]] && return 1
  if [[ "$1" == get ]]; then
    case "$3" in
      SPL-10) echo "{\"result\":{\"issue\":{\"status\":\"done\"}}}" ;;
      SPL-11) echo "{\"result\":{\"issue\":{\"status\":\"todo\"}}}" ;;
      SPL-12) echo "{\"result\":{\"issue\":{\"status\":\"diss\"}}}" ;;
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
v="$(for k in 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24; do printf '%s=%s ' "$k" "$(row SPL-$k)"; done)"
want="10=would-move 11=would-move 12=would-move 13= 14= 15= 16=would-move 17=would-move 18= 19=noop 20=skip 21=skip 22=would-move 23=would-move 24= "
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

# 10. evidence: a cited landing closes an issue no commit names by the rule (no reused-key check); an unknown sha is skipped
CHORE=$(g log -1 --format=%H --grep='docs never close')
printf 'SPL-13\t%s\tthe triage cites it\nSPL-14\tdeadbeef\tbad sha\n' "${CHORE:0:9}" >"$T/ev.tsv"
run DRY_RUN=0 ISSUE_CLOSE_EVIDENCE="$T/ev.tsv"; rc=$?
[ "$rc" = 0 ] && [ "$(row SPL-13)" = moved ] && [ "$(row SPL-14)" = skip ] && grep -q "hub comment SPL-13 .*cited: the triage cites it" <(tr '\n' ' ' <"$T/calls.log") &&
  grep -qx "SPL-13	$CHORE	moved" "$ST/closed.tsv" &&
  pass "10. a cited landing (ISSUE_CLOSE_EVIDENCE) closes with the same comment and ledger; an unknown sha is skipped" || fail "10. evidence (rc $rc): $(cat "$T/o")"

# 11. the cron acts only on the box that holds the cursor
out="$(ISSUE_CLOSE_ALLOW_WORKTREE=1 ISSUE_CLOSE_STATE_DIR="$T/empty" bash "$PROJ_ROOT/src/bash/scripts/issue-close-landed-cron.sh")"; rc=$?
[ "$rc" = 0 ] && grep -q 'no cursor' <<<"$out" && pass "11. the cron is a no-op on a box with no cursor" || fail "11. cron (rc $rc: $out)"

grep -qE '^issue-close-landed +\| [0-9]+ \* \* \* \* +\| src/bash/scripts/issue-close-landed-cron.sh ' "$PROJ_ROOT/cnf/box-crons/box-crons.manifest" &&
  pass "12. the box-crons manifest carries the hourly issue-close-landed row" || fail "12. no issue-close-landed row in box-crons.manifest"

[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
