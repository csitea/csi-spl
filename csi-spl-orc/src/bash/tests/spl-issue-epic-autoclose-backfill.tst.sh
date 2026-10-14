#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_issue_epic_autoclose_backfill (SPL-1729) against a stub hub.
# Planned: an open epic whose issues are all closed (done when any is done,
# diss when all dismissed). Kept: an epic with an open issue, with an open
# subtask, with no issue at all, and one already closed. A dry run writes
# nothing; DRY_RUN=0 comments then sets the status on each planned epic and
# writes a 0600 undo file; ISSUE_KEYS narrows it; a bad ISSUE_KEYS is refused
# before any hub call.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

mkdir -p "$T/state/dev/desk/t1/box-desk/spool/CLE-00" "$T/fix"
iss() { printf '{"key":"%s","kind":"%s","status":"%s","epic":"%s","title":"title %s"}' "$1" "$2" "$3" "$4" "$1"; }
page() { local s="$1"; shift; { echo '{"issues":['; local first=1 x; for x in "$@"; do (( first )) || echo ,; first=0; printf '%s' "$x"; done; echo '],"next_cursor":""}'; } >"$T/fix/$s.json"; }
# SPL-1 all done/diss -> done; SPL-4 all diss -> diss; SPL-6 an open issue;
# SPL-8 an open subtask (its epic field is SPL-8 too); SPL-11 no issue;
# SPL-12 already done; SPL-14 a feature, all done -> done.
page eval "$(iss SPL-1 epic eval "")" "$(iss SPL-6 epic eval "")" "$(iss SPL-11 epic eval "")"
page wip "$(iss SPL-4 epic wip "")" "$(iss SPL-8 epic wip "")" "$(iss SPL-7 issue wip SPL-6)" "$(iss SPL-14 feature wip "")"
page todo "$(iss SPL-10 issue todo SPL-8)"
page "done" "$(iss SPL-2 issue "done" SPL-1)" "$(iss SPL-9 issue "done" SPL-8)" "$(iss SPL-12 epic "done" "")" "$(iss SPL-13 issue "done" SPL-12)" \
  "$(iss SPL-15 issue "done" SPL-14)"
page diss "$(iss SPL-3 issue diss SPL-1)" "$(iss SPL-5 issue diss SPL-4)"

cat >"$T/fakeissue" <<'FAKE'
#!/bin/sh
printf '%s|' "$@" >>"$FAKE_LOG"
echo >>"$FAKE_LOG"
op=$2
status=""
prev=""
for a in "$@"; do
  if [ "$prev" = --status ]; then status=$a; fi
  prev=$a
done
if [ "$op" = list ]; then
  if [ -f "$FIX/$status.json" ]; then cat "$FIX/$status.json"; else echo '{"issues":[],"next_cursor":""}'; fi
  exit 0
fi
echo '{"ok":true}'
FAKE
chmod +x "$T/fakeissue"
ISS='spl_host_spool() { SPL_SPOOL="$FAKE"; }; '
base=(FAKE="$T/fakeissue" FAKE_LOG="$T/issue.log" FIX="$T/fix" TENANT_ID=t1 DESK_AGENT=CLE-00)

run() {
  : >"$T/issue.log"
  SNIPPET="${ISS}do_spl_issue_epic_autoclose_backfill" in_orc "${base[@]}" ISSUE_PLAN="$T/plan.tsv" "$@" >"$T/o" 2>&1
  RC=$?
  cut -f1,2 "$T/plan.tsv" 2>/dev/null | tr '\t\n' ': ' >"$T/keys"
}

run
[[ $RC -eq 0 && "$(cat "$T/keys")" == "SPL-1:done SPL-4:diss SPL-14:done " ]] && ! grep -qE '\|(comment|update)\|' "$T/issue.log" &&
  pass "dry run plans the open epics with only closed issues (done if any done, else diss); kept: open issue, open subtask, no issue, closed epic; no write" ||
  fail "dry run (rc=$RC) '$(cat "$T/keys")': $(cat "$T/o") / $(cat "$T/issue.log")"
grep -qP '^SPL-1\tdone\t2\t1\t1\teval\ttitle SPL-1$' "$T/plan.tsv" && [[ "$(stat -c %a "$T/plan.tsv")" == 600 ]] &&
  pass "plan line is key, new status, issues, done, diss, old status, title; 0600" || fail "plan shape: $(cat "$T/plan.tsv")"

run DRY_RUN=0
upd=$(grep '|update|' "$T/issue.log" | sed -n 's/.*|--ref|\([^|]*\)|--status|\([^|]*\)|.*/\1:\2/p' | tr '\n' ' ')
com=$(grep -c '|comment|' "$T/issue.log")
[[ $RC -eq 0 && "$upd" == "SPL-1:done SPL-4:diss SPL-14:done " && $com -eq 3 ]] &&
  pass "a real run comments, then sets the status on each planned epic" || fail "real run (rc=$RC) '$upd' $com: $(cat "$T/o")"
undo="$T/plan.undo.sh"
[[ "$(stat -c %a "$undo")" == 600 && "$(grep -c do_spl_issue_update "$undo")" -eq 3 ]] && grep -q 'ISSUE_REF=SPL-4 ISSUE_STATUS=wip' "$undo" &&
  grep -q do_spl_issue_unarchive "$undo" && [[ "$(tr '\n' ' ' <"$T/plan.keys")" == "SPL-1 SPL-4 SPL-14 " ]] &&
  pass "the undo file (0600) unarchives the closed keys, then sets each old status" || fail "undo: $(cat "$undo" 2>/dev/null)"

# The default plan path reads SPL_STATE_DIR, which only do_spl_desk_cnf sets
# when the caller did not (the prd run 2026-10-14: "SPL_STATE_DIR: unbound").
: >"$T/issue.log"
rm -rf "$T/state/dev/epic-autoclose"
SNIPPET="${ISS}"'unset SPL_STATE_DIR; do_spl_desk_cnf() { SPL_STATE_DIR="$T_STATE"; SPL_HUB_URL=http://hub.invalid; }; do_spl_issue_epic_autoclose_backfill' \
  in_orc "${base[@]}" T_STATE="$T/state/dev" >"$T/o" 2>&1
RC=$?
[[ $RC -eq 0 ]] && compgen -G "$T/state/dev/epic-autoclose/t1-*.plan.tsv" >/dev/null &&
  pass "with no SPL_STATE_DIR set by the caller, the plan lands under the desk cnf's state dir" || fail "default plan path (rc=$RC): $(cat "$T/o")"

run ISSUE_KEYS=SPL-4,SPL-6
[[ $RC -eq 0 && "$(cat "$T/keys")" == "SPL-4:diss " ]] &&
  pass "ISSUE_KEYS narrows to the listed epics the rule selects (SPL-6 has an open issue: kept)" || fail "keys (rc=$RC) '$(cat "$T/keys")'"
run ISSUE_KEYS='SPL-4;rm'
[[ $RC -ne 0 ]] && grep -q 'ISSUE_KEYS must be' "$T/o" && ! grep -q '|list|' "$T/issue.log" &&
  pass "a bad ISSUE_KEYS is refused before any hub call" || fail "bad keys (rc=$RC): $(cat "$T/o")"

run ISSUE_EMPTY_KEYS=SPL-11,SPL-12
[[ $RC -eq 0 && "$(cat "$T/keys")" == "SPL-1:done SPL-4:diss SPL-11:done SPL-14:done " ]] &&
  pass "ISSUE_EMPTY_KEYS adds a named open epic with no issue (SPL-11), never a closed one (SPL-12)" || fail "empty keys (rc=$RC) '$(cat "$T/keys")'"
run DRY_RUN=0 ISSUE_KEYS=SPL-11 ISSUE_EMPTY_KEYS=SPL-11
grep -q 'it has no live issue' "$T/issue.log" && grep -q '|--ref|SPL-11|--status|done|' "$T/issue.log" &&
  pass "an empty epic's comment says why it closed" || fail "empty comment: $(cat "$T/issue.log")"

echo "spl-issue-epic-autoclose-backfill: $fails failure(s)"
(( fails == 0 ))
