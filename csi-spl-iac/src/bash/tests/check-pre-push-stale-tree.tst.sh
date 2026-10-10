#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the stale-tree part of the pre-push gate (refactor round 6, row 05).
#          A push from a stale tree set 26 paths of other lanes back to old
#          content (8bb97690e, r5-02); this part REFUSES an outgoing commit that
#          sets 3 or more paths back to a blob they held before one of their
#          last 40 commits (not the parent's), unless its subject names a
#          restore. Throwaway repos; the real history only in case 9.
#     1. a stale tree: 3 paths of another lane set back -> REFUSED, names all 3
#     2. 2 paths set back                                 -> PASS (under the limit)
#     3. subject 'Revert ...' and '... Restore ...'       -> PASS (named restore)
#     4. a normal rebase-and-push over other lanes' work  -> PASS
#     5. a blob older than the last 40 commits of a path  -> not counted
#     6. added, deleted and renamed paths                 -> not counted
#     7. a merge commit                                   -> not checked
#     8. through do_check_pre_push: every tier and mode plans stale-tree right
#        after hygiene, a lint-only run does not; a stale commit FAILs the gate
#        with 'PART stale-tree FAIL' logged; a clean one PASSes
#     9. RED CONTROL on the real history when its objects are here:
#        8bb97690e on 9fefb364d -> REFUSED naming 26 paths; d4fa39b61 -> PASS
#        (subject); 70e1eb26b -> PASS
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

# A repo where 'trunk' carries four files a..d, each edited by another lane
# once (v1 -> v2), and the branch 'lane' starts at trunk.
mkrepo() {  # <dir>
  local R="$1" f
  git init -q "$R"; mkdir -p "$R/src"
  for f in a b c d; do echo v1 >"$R/src/$f"; done
  git -C "$R" add -A; git -C "$R" commit -qm seed
  for f in a b c d; do echo v2 >"$R/src/$f"; git -C "$R" commit -qam "other lane: $f v2"; done
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
n="$(grep -cE '^  stale-tree: src/[abc]$' <<<"$OUT")"
eq "1. ... names the 3 paths" 3 "$n"
grep -q 'REFUSED .* sets 3 paths back' <<<"$OUT" && pass "1. ... says REFUSED and the count" || fail "1. ... says REFUSED and the count" "$OUT"
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

# 6. added, deleted, renamed paths are not counted
R="$ROOT/r6"; mkrepo "$R"
git -C "$R" rm -q src/a src/b; git -C "$R" mv src/c src/c2; echo n >"$R/src/new"; git -C "$R" add -A
git -C "$R" commit -qm "feat: drop a b, rename c, add new"
check "$R"; eq "6. deletes + a rename + an add -> PASS" 0 "$?"

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
  grep -q 'PASS d4fa39b61 sets 26 paths back' <<<"$OUT" && pass "9. ... and says it set 26 back" || fail "9. ... and says it set 26 back" "$OUT"
  _pps_check_range "$REPO" 70e1eb26b^..70e1eb26b >/dev/null 2>&1; eq "9. 70e1eb26b -> PASS" 0 "$?"
else
  echo "SKIP: 9. the r5-02 commits are not in this clone (shallow?)"
fi

echo ""
[[ "$fails" -eq 0 ]] && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
