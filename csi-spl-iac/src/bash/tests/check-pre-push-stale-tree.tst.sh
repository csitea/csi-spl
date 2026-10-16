#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the stale-tree part of the pre-push gate (refactor round 6, row 05).
#          A push from a stale tree set 26 paths of other lanes back to old
#          content (8bb97690e, r5-02); this part REFUSES an outgoing commit that
#          sets 3 or more paths back to a blob they held before one of their
#          last 40 commits (not the parent's), unless its subject names a
#          restore. SPL-2253 adds deletions of other commits' recent paths to
#          the count, and refuses ONE path of another lane's last 24 h.
#          Throwaway repos; the real history only in case 9. In mkrepo the
#          other lane's commits are 3 days old, so only 10..15 meet the 24 h.
#     1. a stale tree: 3 paths of another lane set back -> REFUSED, names all 3
#     2. 2 paths set back                                 -> PASS (under the limit)
#     3. subject 'Revert ...' and '... Restore ...'       -> PASS (named restore)
#     4. a normal rebase-and-push over other lanes' work  -> PASS
#     5. a blob older than the last 40 commits of a path  -> not counted
#     6. 2 deletes + a rename + an add -> PASS; 3 deletes -> REFUSED; a delete
#        of a path last changed beyond the last 40 commits -> not counted
#     7. a merge commit                                   -> not checked
#     8. through do_check_pre_push: every tier and mode plans stale-tree right
#        after hygiene, a lint-only run does not; a stale commit FAILs the gate
#        with 'PART stale-tree FAIL' logged; a clean one PASSes
#     9. RED CONTROL on the real history when its objects are here:
#        8bb97690e on 9fefb364d -> REFUSED naming 26 paths; d4fa39b61 -> PASS
#        (subject); 70e1eb26b -> PASS; m-260's stale copy (aea648fbe's tree on
#        97a636405, in a shared throwaway clone) -> REFUSED naming 4 paths
#    10. the m-260 shape: another lane (SPL-2083) adds an e2e test and edits a
#        page within 24 h; the outgoing commit (SPL-2086) deletes the test and
#        sets the page back -> REFUSED, each path named with that commit
#    11. a normal lane push over another lane's work of the last hour, and a
#        set-back of the lane's OWN landed commit (same SPL key)  -> PASS
#    12. a real `git revert` of another lane's recent commit -> PASS (its quoted
#        key is that lane's); the same with no key -> PASS (Revert subject)
#    13. 'Undoes: <sha>' naming the undone commit -> PASS; a wrong sha -> REFUSED
#    14. another lane's commit 25 h old, 1 path set back          -> PASS
#    15. a path added and deleted inside the outgoing range       -> PASS
#    16. speed: a 20-commit range over 30 paths of recent history, timed
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
unset PRE_PUSH_BASE PRE_PUSH_MODE PRE_PUSH_TIER PRE_PUSH_ONLY PRE_PUSH_PLAN PRE_PUSH_LINT PRE_PUSH_LINT_ONLY PRE_PUSH_SKIP_PASSED 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/check-pre-push.func.sh"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }

do_log() { :; }
# shellcheck source=../run/check-pre-push.func.sh
. "$FUNC"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
NOW="$(date +%s)"
OLD="@$((NOW - 3 * 86400)) +0000"

# A repo where 'trunk' carries four files a..d, each edited by another lane
# once (v1 -> v2) 3 days ago, and the branch 'lane' starts at trunk.
mkrepo() {  # <dir>
  local R="$1" f
  git init -q "$R"; mkdir -p "$R/src"
  for f in a b c d; do echo v1 >"$R/src/$f"; done
  git -C "$R" add -A; GIT_COMMITTER_DATE="$OLD" git -C "$R" commit -qm seed
  for f in a b c d; do echo v2 >"$R/src/$f"; GIT_COMMITTER_DATE="$OLD" git -C "$R" commit -qam "other lane: $f v2"; done
  git -C "$R" branch -q trunk; git -C "$R" checkout -q -b lane
}
# Commit <files> set back to v1 (their content before the other lane's commit).
setback() {  # <repo> <subject> <files...>
  local R="$1" s="$2" f; shift 2
  for f in "$@"; do echo v1 >"$R/src/$f"; done
  echo "own change $RANDOM" >"$R/src/own"; git -C "$R" add -A; git -C "$R" commit -qm "$s"
}
check() {  # <repo> -> rc, output in $OUT
  OUT="$(PRE_PUSH_BASE=trunk _pp_part_stale_tree "$1" 2>&1)"
}

# 1. a stale tree: 3 paths set back
R="$ROOT/r1"; mkrepo "$R"; setback "$R" "feat: my change" a b c
check "$R"; eq "1. 3 paths set back -> REFUSED (rc 1)" 1 "$?"
n="$(grep -cE '^  stale-tree: sets back src/[abc] -- undoes [0-9a-f]{9} other lane: [abc] v2$' <<<"$OUT")"
eq "1. ... names the 3 paths and the commit each undoes" 3 "$n"
grep -q 'REFUSED .* undoes 3 paths (0 deleted, 0 of' <<<"$OUT" && pass "1. ... says REFUSED and the count" || fail "1. ... says REFUSED and the count" "$OUT"
grep -q "subject starting 'Revert' or containing 'restore'" <<<"$OUT" \
  && pass "1. ... and how to say an intended restore" || fail "1. ... how to say an intended restore" "$OUT"

# 2. 2 paths set back -> under the limit
R="$ROOT/r2"; mkrepo "$R"; setback "$R" "feat: my change" a b
check "$R"; eq "2. 2 paths set back -> PASS" 0 "$?"

# 3. a named restore
R="$ROOT/r3"; mkrepo "$R"; setback "$R" 'Revert "other lane: a v2"' a b c
check "$R"; eq "3. subject 'Revert ...' -> PASS" 0 "$?"
R="$ROOT/r3b"; mkrepo "$R"; setback "$R" "fix(trunk): Restore 3 paths clobbered by x" a b c
check "$R"; eq "3. subject containing 'Restore' -> PASS" 0 "$?"
R="$ROOT/r3c"; mkrepo "$R"; setback "$R" "feat: not a revert, restores nothing" a b c
check "$R"; eq "3. CONTROL: 'restores' in the subject also contains 'restore' -> PASS" 0 "$?"

# 4. a normal rebase-and-push: the lane edits a..d forward; trunk moved on
R="$ROOT/r4"; mkrepo "$R"
for f in a b c d; do echo v3 >"$R/src/$f"; done; git -C "$R" commit -qam "lane: a..d v3"
git -C "$R" checkout -q trunk; echo x >"$R/src/x"; git -C "$R" add -A; git -C "$R" commit -qm "other lane: x"
git -C "$R" checkout -q lane; git -C "$R" rebase -q trunk
check "$R"; eq "4. a rebase-and-push that moves paths forward -> PASS" 0 "$?"
grep -q 'PASS 1 outgoing commit' <<<"$OUT" && pass "4. ... counts the outgoing commits" || fail "4. ... counts the outgoing commits" "$OUT"

# 5. depth: a blob held before the 41st-last commit of a path is not counted
R="$ROOT/r5"; mkrepo "$R"
for i in $(seq 1 40); do for f in a b c; do echo "n$i" >"$R/src/$f"; done; git -C "$R" commit -qam "churn $i"; done
git -C "$R" branch -qf trunk; setback "$R" "feat: my change" a b c
check "$R"; eq "5. set back to a blob 41 commits back -> PASS (not counted)" 0 "$?"
R="$ROOT/r5b"; mkrepo "$R"
for i in $(seq 1 38); do for f in a b c; do echo "n$i" >"$R/src/$f"; done; git -C "$R" commit -qam "churn $i"; done
git -C "$R" branch -qf trunk; setback "$R" "feat: my change" a b c
check "$R"; eq "5. CONTROL: 39 commits back -> REFUSED" 1 "$?"

# 6. a delete of another commit's path of the last 40 commits counts; a
#    rename and an add do not
R="$ROOT/r6"; mkrepo "$R"
git -C "$R" rm -q src/a src/b; git -C "$R" mv src/c src/c2; echo n >"$R/src/new"; git -C "$R" add -A
git -C "$R" commit -qm "feat: drop a b, rename c, add new"
check "$R"; eq "6. 2 deletes + a rename + an add -> PASS (under the limit)" 0 "$?"
R="$ROOT/r6b"; mkrepo "$R"
git -C "$R" rm -q src/a src/b src/c; git -C "$R" commit -qm "feat: drop a b c"
check "$R"; eq "6. 3 deletes of the other lane's paths -> REFUSED" 1 "$?"
eq "6. ... each named as deleted" 3 "$(grep -cE '^  stale-tree: deletes src/[abc] -- undoes ' <<<"$OUT")"
R="$ROOT/r6c"; mkrepo "$R"
for i in $(seq 1 40); do echo "n$i" >"$R/src/d"; GIT_COMMITTER_DATE="$OLD" git -C "$R" commit -qam "churn $i"; done
git -C "$R" branch -qf trunk; git -C "$R" rm -q src/a src/b src/c; git -C "$R" commit -qm "feat: drop a b c"
check "$R"; eq "6. 3 deletes of paths last changed 41+ commits back -> PASS (not counted)" 0 "$?"

# 7. a merge commit is not checked (its first-parent diff is the other side's work)
R="$ROOT/r7"; mkrepo "$R"; git -C "$R" checkout -q -b side trunk~4
git -C "$R" commit -q --allow-empty -m "side"; git -C "$R" checkout -q lane
# a merge whose tree is the seed's: against its first parent it sets a..d back
m="$(git -C "$R" commit-tree "$(git -C "$R" rev-parse 'trunk~4^{tree}')" -p HEAD -p side -m "merge side")"
git -C "$R" reset -q --hard "$m"
check "$R"; eq "7. a merge commit that sets 4 paths back vs its first parent -> PASS (not checked)" 0 "$?"

# 8. through the gate
R="$ROOT/r8"; mkrepo "$R"; setback "$R" "feat: my change" a b c
plan() {  # [env...] -> the parts= field
  ( for kv in "$@"; do export "${kv?}"; done; PRE_PUSH_PLAN=1 PRE_PUSH_TREE="$R" PRE_PUSH_BASE=trunk do_check_pre_push 2>/dev/null ) \
    | sed -n 's/^PRE_PUSH_PLAN .* parts=//p'
}
for m in "PRE_PUSH_MODE=fast PRE_PUSH_TIER=fast" "PRE_PUSH_MODE=fast PRE_PUSH_TIER=full" \
         "PRE_PUSH_MODE=full PRE_PUSH_TIER=fast" "PRE_PUSH_MODE=full PRE_PUSH_TIER=full"; do
  # shellcheck disable=SC2086
  p="$(plan $m)"
  case "$p" in "hygiene stale-tree"*) pass "8. $m plans stale-tree after hygiene" ;; *) fail "8. $m plans stale-tree after hygiene" "$p" ;; esac
done
p="$(plan PRE_PUSH_ONLY=lint)"
case " $p " in *" stale-tree "*) fail "8. a lint-only run has no stale-tree part" "$p" ;; *) pass "8. a lint-only run has no stale-tree part" ;; esac
LOG="$ROOT/r8.log"
gate() {
  ( env PRE_PUSH_TREE="$R" PRE_PUSH_BASE=trunk PRE_PUSH_LOG="$LOG" PRE_PUSH_CACHE="$ROOT/r8.cache" \
      PRE_PUSH_PASS="$ROOT/r8.pass" PRE_PUSH_EXTRA_PATH='' \
      bash -c '. "$0"; do_log() { :; }; do_check_dist_hygiene() { :; }
        _pp_missing_tools() { :; }; _ppl_plan() { _PPL_SELECTED=""; }; _ppl_typos() { :; }; _pp_release_note() { :; }
        do_check_pre_push' "$FUNC" ) >/dev/null 2>&1
}
: >"$LOG"; gate; eq "8. the gate on a stale commit -> REFUSED (rc 1)" 1 "$?"
grep -q ' PART stale-tree FAIL .*trunk=.*-green' "$LOG" && pass "8. ... logged PART stale-tree FAIL (trunk green)" \
  || fail "8. ... logged PART stale-tree FAIL" "$(cat "$LOG")"
git -C "$R" reset -q --hard HEAD~1; setback "$R" "feat: my change" a
: >"$LOG"; gate; eq "8. the gate on a clean commit -> PASS" 0 "$?"
grep -q ' PART stale-tree PASS ' "$LOG" && pass "8. ... logged PART stale-tree PASS" || fail "8. ... logged PART stale-tree PASS" "$(cat "$LOG")"
git -C "$R" worktree list --porcelain | grep -c '^worktree ' | { read -r n; eq "8. ... no baseline worktree left behind" 1 "$n"; }

# 9. the red control on the real history (absent from a shallow clone: skipped)
REPO="$(cd "$PROJ_ROOT/.." && pwd)"
if git -C "$REPO" cat-file -e '8bb97690e^{commit}' 2>/dev/null && git -C "$REPO" cat-file -e 'd4fa39b61^{commit}' 2>/dev/null \
   && git -C "$REPO" cat-file -e '70e1eb26b^{commit}' 2>/dev/null; then
  OUT="$(_pps_check_range "$REPO" 9fefb364d..8bb97690e 2>&1)"; eq "9. RED CONTROL 8bb97690e on 9fefb364d -> REFUSED" 1 "$?"
  eq "9. ... naming 26 paths" 26 "$(grep -c '^  stale-tree: ' <<<"$OUT")"
  OUT="$(_pps_check_range "$REPO" 8bb97690e..d4fa39b61 2>&1)"; eq "9. d4fa39b61 -> PASS (its subject names the restore)" 0 "$?"
  grep -q 'PASS d4fa39b61 undoes 26 paths' <<<"$OUT" && pass "9. ... and says it undid 26" || fail "9. ... and says it undid 26" "$OUT"
  _pps_check_range "$REPO" 70e1eb26b^..70e1eb26b >/dev/null 2>&1; eq "9. 70e1eb26b -> PASS" 0 "$?"
else
  echo "SKIP: 9. the r5-02 commits are not in this clone (shallow?)"
fi
# m-260's stale copy: its tree committed on the master it would have pushed to,
# built in a throwaway clone sharing the objects (the real repo is not written)
if git -C "$REPO" cat-file -e 'aea648fbe^{commit}' 2>/dev/null && git -C "$REPO" cat-file -e '97a636405^{commit}' 2>/dev/null; then
  C="$ROOT/m260"; git clone -q --shared --no-checkout "$REPO" "$C" 2>/dev/null
  s="$(GIT_COMMITTER_DATE='2026-10-16T04:10:00Z' git -C "$C" commit-tree 'aea648fbe^{tree}' -p 97a636405 \
       -m 'feat(orc, SPL-2086): implement backfill and retry logic for cost rollup daily action')"
  OUT="$(_pps_check_range "$C" "97a636405..$s" 2>&1)"; eq "9. RED CONTROL m-260's stale copy on 97a636405 -> REFUSED" 1 "$?"
  eq "9. ... naming 3 deletes" 3 "$(grep -c '^  stale-tree: deletes ' <<<"$OUT")"
  grep -q '^  stale-tree: deletes csi-spl-wui/tests/e2e/monitoring-boxes-align.test.mjs -- undoes 2aa62c80e ' <<<"$OUT" \
    && pass "9. ... the e2e test, undoing 2aa62c80e" || fail "9. ... the e2e test, undoing 2aa62c80e" "$OUT"
  grep -q '^  stale-tree: sets back csi-spl-wui/src/pages/monitoring/boxes/index.vue -- undoes 2aa62c80e ' <<<"$OUT" \
    && pass "9. ... and boxes/index.vue set back" || fail "9. ... and boxes/index.vue set back" "$OUT"
else
  echo "INFO: 9. m-260's aea648fbe was never pushed, so only a box that holds it replays it; case 10 is its shape"
fi

# A repo for the 24 h cases: trunk has page.vue and old.txt from 3 days ago;
# another lane (SPL-2083) then edited page.vue and added e2e.test.mjs <age>
# seconds ago. 'lane' starts at trunk.
mk24() {  # <dir> <age seconds>
  local R="$1" t="@$((NOW - $2)) +0000"
  git init -q "$R"; echo v1 >"$R/page.vue"; echo o >"$R/old.txt"
  git -C "$R" add -A; GIT_COMMITTER_DATE="$OLD" git -C "$R" commit -qm seed
  echo v2 >"$R/page.vue"; echo t >"$R/e2e.test.mjs"; git -C "$R" add -A
  GIT_COMMITTER_DATE="$t" git -C "$R" commit -qm "fix(wui, SPL-2083): left-align rows"
  git -C "$R" branch -q trunk; git -C "$R" checkout -q -b lane
}
other_sha() { git -C "$1" rev-parse --short=9 trunk; }

# 10. the m-260 shape: one deletion + one set-back of another lane's last hour
R="$ROOT/r10"; mk24 "$R" 3600
git -C "$R" rm -q e2e.test.mjs; echo v1 >"$R/page.vue"; echo own >"$R/own.sh"; git -C "$R" add -A
git -C "$R" commit -qm "feat(orc, SPL-2086): backfill"
check "$R"; eq "10. the m-260 shape (1 delete + 1 set-back, another lane, 1 h) -> REFUSED" 1 "$?"
grep -q "^  stale-tree: deletes e2e.test.mjs -- undoes $(other_sha "$R") fix(wui, SPL-2083): left-align rows (another lane, last 24 h)$" <<<"$OUT" \
  && pass "10. ... names the deleted test and the commit it undoes" || fail "10. ... names the deleted test" "$OUT"
grep -q "^  stale-tree: sets back page.vue -- undoes $(other_sha "$R") " <<<"$OUT" \
  && pass "10. ... names the page set back" || fail "10. ... names the page set back" "$OUT"
R="$ROOT/r10b"; mk24 "$R" 3600; git -C "$R" rm -q e2e.test.mjs; git -C "$R" commit -qm "feat(orc, SPL-2086): x"
check "$R"; eq "10. ONE deletion of another lane's last hour -> REFUSED (no 3-path threshold)" 1 "$?"

# 11. a normal lane push: forward edits over another lane's last hour, and the
#     lane's own landed commit (same key) set back
R="$ROOT/r11"; mk24 "$R" 3600
echo v3 >"$R/page.vue"; echo t2 >"$R/e2e.test.mjs"; git -C "$R" rm -q old.txt; git -C "$R" commit -qam "feat(wui, SPL-2100): rows wrap"
check "$R"; eq "11. forward edits over another lane's last hour + 1 old delete -> PASS" 0 "$?"
R="$ROOT/r11b"; mk24 "$R" 3600; echo v1 >"$R/page.vue"; git -C "$R" commit -qam "fix(wui, SPL-2083): rows back to v1, redo"
check "$R"; eq "11. setting back the lane's OWN landed commit (same SPL key) -> PASS" 0 "$?"
R="$ROOT/r11c"; mk24 "$R" 3600; echo v1 >"$R/page.vue"; git -C "$R" commit -qam "fix(wui, SPL-20830): other key"
check "$R"; eq "11. CONTROL: a key that only starts with SPL-2083 is another lane -> REFUSED" 1 "$?"

# 12. a real revert of another lane's recent commit
R="$ROOT/r12"; mk24 "$R" 3600; git -C "$R" revert --no-edit HEAD >/dev/null
check "$R"; eq "12. git revert of another lane's last-hour commit (delete + set-back) -> PASS" 0 "$?"
grep -q 'PASS 1 outgoing commit' <<<"$OUT" && pass "12. ... one outgoing commit (its quoted SPL-2083 is that lane's key)" || fail "12. ... one outgoing commit" "$OUT"
git -C "$R" commit -q --amend -m 'Revert "left-align rows"'
check "$R"; eq "12. the same revert with no key in its subject -> PASS (the Revert exemption)" 0 "$?"
grep -q "PASS [0-9a-f]\{9\} undoes 2 paths (1 deleted, 2 of another lane's last 24 h), and its subject names a restore: Revert " <<<"$OUT" \
  && pass "12. ... counted both paths and passed on the subject" || fail "12. ... counted both paths" "$OUT"

# 13. a deliberate undo names the commit
R="$ROOT/r13"; mk24 "$R" 3600; o="$(other_sha "$R")"; echo v1 >"$R/page.vue"
git -C "$R" commit -qam "fix(wui, SPL-2101): the owner dropped the left align" -m "Undoes: $o"
check "$R"; eq "13. 'Undoes: <sha>' naming the undone commit -> PASS" 0 "$?"
R="$ROOT/r13b"; mk24 "$R" 3600; echo v1 >"$R/page.vue"
git -C "$R" commit -qam "fix(wui, SPL-2101): the owner dropped the left align" -m "Undoes: 1234567"
check "$R"; eq "13. CONTROL: 'Undoes:' naming another sha -> REFUSED" 1 "$?"

# 14. the 24 h edge
R="$ROOT/r14"; mk24 "$R" $((25 * 3600)); echo v1 >"$R/page.vue"; git -C "$R" commit -qam "feat(orc, SPL-2086): x"
check "$R"; eq "14. 1 set-back of another lane's commit 25 h old -> PASS (under the limit)" 0 "$?"

# 15. a path added and deleted inside the outgoing range
R="$ROOT/r15"; mk24 "$R" 3600; echo s >"$R/scratch"; git -C "$R" add -A; git -C "$R" commit -qm "feat(x, SPL-2102): a"
git -C "$R" rm -q scratch; git -C "$R" commit -qm "feat(x, SPL-2102): b"
check "$R"; eq "15. own path added then deleted in the outgoing range -> PASS" 0 "$?"

# 16. speed: 20 outgoing commits, each editing 30 paths with 40 commits of
#     recent history
R="$ROOT/r16"; git init -q "$R"; mkdir -p "$R/s"
for i in $(seq 1 40); do for f in $(seq 1 30); do echo "$i" >"$R/s/$f"; done; git -C "$R" add -A; git -C "$R" commit -qm "other $i"; done
git -C "$R" branch -q trunk; git -C "$R" checkout -q -b lane
for i in $(seq 1 20); do for f in $(seq 1 30); do echo "l$i" >"$R/s/$f"; done; git -C "$R" commit -qam "lane $i"; done
t0="$(date +%s%N)"; check "$R"; rc=$?; ms=$((($(date +%s%N) - t0) / 1000000))
eq "16. 20 commits x 30 paths -> PASS" 0 "$rc"
echo "INFO: 16. 20-commit range checked in ${ms} ms"
[[ "$ms" -lt 10000 ]] && pass "16. ... under 10 s" || fail "16. ... under 10 s" "${ms} ms"

echo ""
[[ "$fails" -eq 0 ]] && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
