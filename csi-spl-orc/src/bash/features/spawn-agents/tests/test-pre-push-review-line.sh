#!/usr/bin/env bash
# test-pre-push-review-line.sh — the pre-push hook REFUSES a round row commit
# (`<type>(rNN-NN-...`, a bug `bNN-NN` or perf `pNN-NN` round too) pushed to master without a valid R7 review line, the
# check do_spl_push_master runs (row r11-04), so a hand `git push` cannot skip
# it (row r11-05). Real `git push` into a bare temp remote with the hook as
# core.hooksPath; the scratch repo carries the real spl-push-master.func.sh at
# its tree path (the hook sources it from there; it sources its sibling
# spl-review-line-check.func.sh, copied too), no csi-spl-iac/run, so the
# gate itself fail-opens and only the review-line block decides.
#   1. a row commit with no review line              -> REFUSED, remote unchanged
#   2. ... with a typed sha that does not resolve    -> REFUSED
#   3. ... no line, SPL_PREPUSH_OVERRIDE=1           -> still REFUSED
#   4. ... line with no '| log:'                     -> REFUSED
#   5. ... the full line, sha only on review/r11-99  -> fetched, pushed
#  5a. ... ran: names tests only as a brace token     -> REFUSED by the retro
#      checker's syntax path (SPL-4066: c-585's r36-02 line)
#   6. a commit that is not a round row, no line     -> pushed
#   7. a row commit to a non-master branch           -> pushed
#   8. the hook carries no second copy of the regex
#   9. CONTROL: the hook without the block lets the no-line row commit through
#  10. a bug round row (b11-99) / perf round row (p11-99), no line -> REFUSED
#  11. CONTROL: the rNN-only regex (before SPL-2616) lets the b11-99 row through
#  12. a subject with another round letter (x11-99), no line -> pushed
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(cd "$HERE/../hooks" && pwd)/pre-push"
HELPER="$(cd "$HERE/../../../run" && pwd)/spl-push-master.func.sh"
CHECKER="${HELPER%/*}/spl-review-line-check.func.sh"

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1 ${2:+:: $2}"; fails=$((fails + 1)); }
eq()   { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
export SPL_PREPUSH_LOG_DIR="$ROOT/log"
# the checker's registry lookup reads a temp spool root, never the box's
export SPOOL_ROOT="$ROOT/spool"

NEW="$ROOT/hooks-new"; OLD="$ROOT/hooks-old"; mkdir -p "$NEW" "$OLD"
install -m 0755 "$HOOK" "$NEW/pre-push"
# the control: the same hook with the review-line block cut out
sed '/^# R7 review line on round rows/,/^fi$/d' "$HOOK" >"$OLD/pre-push"; chmod +x "$OLD/pre-push"
grep -q '_spl_push_master_unreviewed' "$OLD/pre-push" && fail "control hook still carries the block" || pass "control hook has no block"

git init -q --bare "$ROOT/remote.git"
A="$ROOT/a"; git clone -q "$ROOT/remote.git" "$A" 2>/dev/null
git -C "$A" checkout -q -b master
mkdir -p "$A/csi-spl-orc/src/bash/run"; cp "$HELPER" "$CHECKER" "$A/csi-spl-orc/src/bash/run/"
git -C "$A" add csi-spl-orc; git -C "$A" commit -q -m "base"; git -C "$A" push -q origin master 2>/dev/null
c() { git -C "$A" commit -q --allow-empty -m "$1" ${2:+-m "$2"}; }
push() {  # <hooksdir> [env...] -- <push args...>
  local hd="$1"; shift; local e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  env "${e[@]}" git -C "$A" -c core.hooksPath="$hd" push -q origin "$@" 2>"$ROOT/err"
}
rtip() { git -C "$ROOT/remote.git" rev-parse "$1" 2>/dev/null; }
redo() { git -C "$A" reset -q --hard origin/master; }  # drop the refused commit

ROW="ci(r11-99-scratch, SPL-1): a row commit"
LOG="| read: ok | log: m-000@box:/tmp/journal.jsonl"
before="$(rtip master)"

# 1. no review line
c "$ROW"; push "$NEW" -- master; eq "1. row commit, no review line -> refused" 1 "$(( $? != 0 ))"
grep -q 'REFUSED -- a round row commit has no valid R7 review line' "$ROOT/err" \
  && pass "1. ... by the hook" || fail "1. ... by the hook" "$(cat "$ROOT/err")"
grep -q "review line: none of the form" "$ROOT/err" && pass "1. ... names the reason" || fail "1. ... names the reason" "$(cat "$ROOT/err")"
eq "1. ... remote unchanged" "$before" "$(rtip master)"
grep -q 'REFUSE .*round row' "$SPL_PREPUSH_LOG_DIR/pre-push.log" && pass "1. ... logged" || fail "1. ... logged"

# 2. a typed sha: 40 hex, resolves to nothing
redo; c "$ROW" "review: m-000@box mistral PASS $(printf 'ab%.0s' {1..20}) ran: x $LOG"
push "$NEW" -- master; eq "2. typed sha -> refused" 1 "$(( $? != 0 ))"
grep -q 'does not resolve (fetched review/r11-99)' "$ROOT/err" && pass "2. ... sha does not resolve" || fail "2. ... sha does not resolve" "$(cat "$ROOT/err")"
eq "2. ... remote unchanged" "$before" "$(rtip master)"

# 3. the override does not skip it
redo; c "$ROW"; push "$NEW" SPL_PREPUSH_OVERRIDE=1 -- master; eq "3. SPL_PREPUSH_OVERRIDE=1, no line -> still refused" 1 "$(( $? != 0 ))"
eq "3. ... remote unchanged" "$before" "$(rtip master)"

# the reviewed sha lives only on origin review/r11-99, not on the local branch
git -C "$A" checkout -q -b review/r11-99 origin/master; c "the reviewed tree"
rev="$(git -C "$A" rev-parse HEAD)"; git -C "$A" push -q origin review/r11-99 2>/dev/null
git -C "$A" checkout -q master; git -C "$A" branch -q -D review/r11-99
git -C "$A" update-ref -d refs/remotes/origin/review/r11-99; git -C "$A" reflog expire --expire=now --all; git -C "$A" gc -q --prune=now
git -C "$A" cat-file -e "$rev^{commit}" 2>/dev/null && fail "the reviewed sha is still local" || pass "the reviewed sha is not local"

# 4. full sha, no '| log:'
redo; c "$ROW" "review: m-000@box mistral PASS $rev ran: x | read: ok"
push "$NEW" -- master; eq "4. no '| log:' -> refused" 1 "$(( $? != 0 ))"
grep -q "no '| log: <id>@<box>:<path>'" "$ROOT/err" && pass "4. ... names the missing log" || fail "4. ... names the missing log" "$(cat "$ROOT/err")"

# 5a. a brace-token ran: names no test for the checker
redo; before="$(rtip master)"
c "$ROW" "review: m-000@box mistral PASS $rev ran: bash check-{a,b}.tst.sh $LOG"
push "$NEW" -- master; eq "5a. brace-token ran: -> refused" 1 "$(( $? != 0 ))"
grep -q "review line: checker: ran: names no test" "$ROOT/err" && pass "5a. ... names the checker's reason" || fail "5a. ... names the checker's reason" "$(cat "$ROOT/err")"
eq "5a. ... remote unchanged" "$before" "$(rtip master)"

# 5. the full line
redo; c "$ROW" "review: m-000@box mistral PASS $rev ran: bash x.tst.sh $LOG"
push "$NEW" -- master; eq "5. full review line -> exit 0" 0 "$?"
eq "5. ... remote moved to the local tip" "$(git -C "$A" rev-parse HEAD)" "$(rtip master)"
git -C "$A" fetch -q origin

# 6. not a round row
c "fix(orc, SPL-2): not a row"; push "$NEW" -- master; eq "6. non-row commit, no line -> exit 0" 0 "$?"
git -C "$A" fetch -q origin

# 7. a row commit to a non-master branch
c "$ROW"; push "$NEW" -- HEAD:refs/heads/feat; eq "7. row commit to a non-master branch -> exit 0" 0 "$?"

# 8. one copy of the check: the hook sources it, no review-line regex of its own
eq "8. the hook has no copy of the review-line regex" 0 "$(grep -cE 'review: \\S|r\[0-9\]\+-|0-9a-f\]\{40\}' "$HOOK")"
grep -q 'spl-push-master.func.sh' "$HOOK" && pass "8. ... it sources spl-push-master.func.sh" || fail "8. ... it sources spl-push-master.func.sh"

# 9. CONTROL: without the block the no-line row commit (still HEAD, case 7) lands
before="$(rtip master)"
push "$OLD" -- master; eq "9. CONTROL: old hook lets the no-line row commit through" 0 "$?"
[ "$(rtip master)" != "$before" ] && pass "9. CONTROL: ... and the remote moved" || fail "9. CONTROL: ... and the remote moved"

# 10. bug and perf round rows are checked the same way as refactor rows
git -C "$A" fetch -q origin
for r in b11-99 p11-99; do
  redo; before="$(rtip master)"
  c "fix($r-scratch, SPL-1): a $r row commit"; push "$NEW" -- master; eq "10. $r row commit, no review line -> refused" 1 "$(( $? != 0 ))"
  grep -q "review line: none of the form" "$ROOT/err" && pass "10. ... $r names the reason" || fail "10. ... $r names the reason" "$(cat "$ROOT/err")"
  eq "10. ... $r remote unchanged" "$before" "$(rtip master)"
done

# 11. CONTROL: the same hook over the rNN-only regex lets the b11-99 row through
redo; RL="$A/csi-spl-orc/src/bash/run/spl-push-master.func.sh"
sed 's/(\[rbp\]\[0-9\]/(r[0-9]/' "$HELPER" >"$RL"
grep -q '\[rbp\]' "$RL" && fail "11. control helper still has [rbp]" || pass "11. control helper is rNN-only"
c "fix(b11-99-scratch, SPL-1): a b11-99 row commit"; push "$NEW" -- master; eq "11. CONTROL: rNN-only regex lets the b11-99 row through" 0 "$?"
cp "$HELPER" "$RL"; git -C "$A" fetch -q origin

# 12. another letter is not a round row
redo; c "fix(x11-99-scratch, SPL-1): not a row"; push "$NEW" -- master; eq "12. x11-99 commit, no line -> exit 0" 0 "$?"

echo "-- test-pre-push-review-line.sh: $fails failed"
[ "$fails" -eq 0 ]
