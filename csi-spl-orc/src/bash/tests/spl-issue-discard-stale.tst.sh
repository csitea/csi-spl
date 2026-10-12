#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_issue_discard_stale against a stub hub and a temp git repo.
# A stale item is listed; a recent one, one with a fresh landed sha, one whose
# key a later commit names, one assigned to a live lane, a keep-labelled one,
# a recently active wip and an epic with an open child are not. Each guard has
# a control that switches only that guard off and must then list the item.
# DRY_RUN=0 comments and sets diss, never deletes, and writes a 0600 undo file;
# ISSUE_KEYS_FILE narrows it to the listed keys the rule also selects.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

mkdir -p "$T/state/dev/desk/t1/box-desk/spool/CLE-00" "$T/fix"

# The repo: A (base), B (the sha SPL-3 names), C (a message naming SPL-4).
git init -q "$T/repo"
gc() { GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" git -C "$T/repo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m "$2"; }
gc 2026-08-01T00:00:00Z "base"
sha_a=$(git -C "$T/repo" rev-parse HEAD)
gc 2026-09-15T00:00:00Z "a fix"
sha_b=$(git -C "$T/repo" rev-parse --short=9 HEAD)
gc 2026-09-20T00:00:00Z "fix SPL-4 at last"

old=2026-09-01T00:00:00Z
iss() { printf '{"key":"%s","kind":"%s","status":"%s","updated_at":"%s","assignee":"%s","labels":[%s],"epic":"%s","parent":"%s","title":"title %s","description":"%s"}' \
  "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$7" "$1" "$8"; }
{
  echo '{"issues":['
  iss SPL-1 issue todo "$old" "" "" "" "" ; echo ,
  iss SPL-2 issue todo 2026-10-11T00:00:00Z "" "" "" ""; echo ,
  iss SPL-3 issue todo "$old" "" "" "" "landed in $sha_b"; echo ,
  iss SPL-4 issue todo "$old" "" "" "" ""; echo ,
  iss SPL-5 issue todo "$old" c-900 "" "" ""; echo ,
  iss SPL-6 issue todo "$old" "" '"keep"' "" ""; echo ,
  iss SPL-11 issue todo 2026-10-11T00:00:00Z "" "" SPL-10 ""; echo ,
  iss SPL-13 issue todo "$old" "" "" SPL-12 ""; echo ,
  iss SPL-20 issue todo 2026-10-11T00:00:00Z "" "" "" ""; echo ,
  iss SPL-21 issue todo 2026-10-11T00:00:00Z "" "" "" ""
  echo '],"next_cursor":""}'
} >"$T/fix/todo.json"
{
  echo '{"issues":['
  iss SPL-7 issue wip 2026-10-08T00:00:00Z "" "" "" ""; echo ,
  iss SPL-8 issue wip "$old" "" "" "" ""
  echo '],"next_cursor":""}'
} >"$T/fix/wip.json"
{
  echo '{"issues":['
  iss SPL-10 epic eval "$old" "" "" "" ""; echo ,
  iss SPL-12 epic eval "$old" "" "" "" ""
  echo '],"next_cursor":""}'
} >"$T/fix/eval.json"
printf 'key\tkind\told_status\toutcome\tdiscard_votes\nSPL-20\tissue\ttodo\tDISCARD\t5\nSPL-21\tissue\ttodo\tSPLIT\t2\n' >"$T/triage.tsv"

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
base=(FAKE="$T/fakeissue" FAKE_LOG="$T/issue.log" FIX="$T/fix" TENANT_ID=t1 DESK_AGENT=CLE-00
  ISSUE_GIT_DIR="$T/repo" ISSUE_GIT_REF=HEAD ISSUE_LIVE_LANES=c-900@sat ISSUE_NOW=2026-10-12T00:00:00Z
  ISSUE_STALE_BEFORE=2026-10-10 ISSUE_TRIAGE_TSV="$T/triage.tsv")

# run [VAR=value]...: a dry run into $T/o, the plan's keys into $T/keys.
run() {
  : >"$T/issue.log"
  SNIPPET="${ISS}do_spl_issue_discard_stale" in_orc "${base[@]}" ISSUE_PLAN="$T/plan.tsv" "$@" >"$T/o" 2>&1
  RC=$?
  cut -f1 "$T/plan.tsv" 2>/dev/null | sort -V | tr '\n' ' ' >"$T/keys"
}
has() { grep -qw -- "$1" "$T/keys"; }

run
[[ $RC -eq 0 && "$(cat "$T/keys")" == "SPL-1 SPL-8 SPL-12 SPL-13 SPL-20 " ]] &&
  ! grep -qE '\|(comment|update|delete)\|' "$T/issue.log" &&
  pass "dry run lists the stale items, the stale epic with a stale child and the triage item; calls no write" ||
  fail "dry run (rc=$RC) keys '$(cat "$T/keys")': $(cat "$T/o") / $(cat "$T/issue.log")"
grep -qP '^SPL-1\ttodo\t2026-09-01T00:00:00\tSTALE\t' "$T/plan.tsv" && grep -qP '^SPL-20\ttodo\t.*\tTRIAGE\t' "$T/plan.tsv" &&
  [[ "$(stat -c %a "$T/plan.tsv")" == 600 ]] &&
  pass "plan line is key, status, last update, reason code, reason, title; the file is 0600" ||
  fail "plan shape: $(cat "$T/plan.tsv") mode $(stat -c %a "$T/plan.tsv")"
grep -q 'todo/STALE=2' "$T/o" && grep -q 'eval/STALE=1' "$T/o" && grep -q 'todo/TRIAGE=1' "$T/o" &&
  pass "the log counts by status and reason code" || fail "counts: $(cat "$T/o")"

# A log line the spool resolution prints on stdout must not reach a page.
: >"$T/issue.log"
SNIPPET='spl_host_spool() { do_log "WARN keeping $FAKE: built from a newer tree"; SPL_SPOOL="$FAKE"; }; do_spl_issue_discard_stale' \
  in_orc "${base[@]}" ISSUE_PLAN="$T/plan.tsv" >"$T/o" 2>&1
RC=$?
[[ $RC -eq 0 && "$(cut -f1 "$T/plan.tsv" | sort -V | tr '\n' ' ')" == "SPL-1 SPL-8 SPL-12 SPL-13 SPL-20 " ]] &&
  pass "a WARN the spool resolution logs on stdout does not break the issue pages" ||
  fail "spool WARN on stdout (rc=$RC): $(cat "$T/o")"

# Controls: switch off one guard each; its item must now be listed.
run ISSUE_STALE_BEFORE=2026-10-12
has SPL-2 && has SPL-10 && pass "control: a later cutoff lists the recent item and the epic whose child became stale" ||
  fail "control cutoff: '$(cat "$T/keys")'"
run
! has SPL-2 && ! has SPL-10 && pass "a recent item and an epic with an open child are kept" || fail "recent/epic kept: '$(cat "$T/keys")'"

run ISSUE_GIT_REF="$sha_a"
has SPL-3 && has SPL-4 && pass "control: without the later commits the sha and key-named items are listed" ||
  fail "control sha: '$(cat "$T/keys")'"
run ISSUE_LIVE_LANES=
has SPL-5 && pass "control: with no live lanes the assigned item is listed" || fail "control lane: '$(cat "$T/keys")'"
run ISSUE_KEEP_LABELS=
has SPL-6 && pass "control: with no keep labels the labelled item is listed" || fail "control label: '$(cat "$T/keys")'"
run ISSUE_WIP_DAYS=0 ISSUE_STALE_BEFORE=2026-10-09
has SPL-7 && pass "control: with no wip window the recent wip is listed" || fail "control wip: '$(cat "$T/keys")'"
run ISSUE_STALE_BEFORE=2026-10-09
! has SPL-7 && pass "a wip active in the last 7 days is kept past the cutoff" || fail "wip kept: '$(cat "$T/keys")'"
run ISSUE_TRIAGE_MIN_VOTES=2
has SPL-21 && pass "control: a lower vote floor lists the split item" || fail "control triage: '$(cat "$T/keys")'"

run ISSUE_STALE_BEFORE=yesterday
[[ $RC -ne 0 ]] && grep -q 'ISSUE_STALE_BEFORE must be' "$T/o" && ! grep -q '|list|' "$T/issue.log" &&
  pass "a bad cutoff is refused before any hub call" || fail "bad cutoff (rc=$RC): $(cat "$T/o")"

run DRY_RUN=0 ISSUE_UNDO="$T/undo.sh"
upd=$(grep '|update|' "$T/issue.log" | sed -n 's/.*|--ref|\([^|]*\)|--status|diss|.*/\1/p' | sort -V | tr '\n' ' ')
com=$(grep -c '|comment|.*Discarded as outdated' "$T/issue.log")
[[ $RC -eq 0 && "$upd" == "SPL-1 SPL-8 SPL-12 SPL-13 SPL-20 " && $com -eq 5 ]] && ! grep -q '|delete|' "$T/issue.log" &&
  pass "a real run comments and sets diss on each planned item, deletes none" ||
  fail "real run (rc=$RC) diss '$upd' comments $com: $(cat "$T/o") / $(cat "$T/issue.log")"
[[ "$(stat -c %a "$T/undo.sh")" == 600 && "$(grep -c 'do_spl_issue_update' "$T/undo.sh")" -eq 5 ]] &&
  grep -q 'ISSUE_REF=SPL-8 ISSUE_STATUS=wip DRY_RUN=0' "$T/undo.sh" && grep -q "UNDO $T/undo.sh" "$T/o" &&
  pass "the undo file is 0600 with one command per item, back to its old status" ||
  fail "undo: mode $(stat -c %a "$T/undo.sh" 2>/dev/null) $(cat "$T/undo.sh" 2>/dev/null)"

printf 'SPL-1\nSPL-2 recent, not stale\nSPL-8\n' >"$T/only.keys"
run DRY_RUN=0 ISSUE_KEYS_FILE="$T/only.keys" ISSUE_UNDO="$T/undo2.sh"
upd=$(grep '|update|' "$T/issue.log" | sed -n 's/.*|--ref|\([^|]*\)|--status|diss|.*/\1/p' | sort -V | tr '\n' ' ')
[[ $RC -eq 0 && "$upd" == "SPL-1 SPL-8 " && "$(cat "$T/keys")" == "SPL-1 SPL-8 " ]] &&
  pass "ISSUE_KEYS_FILE narrows the discard to the listed keys the rule also selects (SPL-2 is recent: kept)" ||
  fail "keys file (rc=$RC) diss '$upd' plan '$(cat "$T/keys")': $(cat "$T/o")"
run ISSUE_KEYS_FILE="$T/missing.keys"
[[ $RC -ne 0 ]] && grep -q 'ISSUE_KEYS_FILE is not a readable file' "$T/o" && ! grep -q '|list|' "$T/issue.log" &&
  pass "a missing keys file is refused before any hub call" || fail "missing keys file (rc=$RC): $(cat "$T/o")"

echo "spl-issue-discard-stale: $fails failure(s)"
(( fails == 0 ))
