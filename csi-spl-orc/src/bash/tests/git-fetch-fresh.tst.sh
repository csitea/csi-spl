#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: git-fetch-fresh.sh (fleet-hot-commands-2026-10-07.md 3.6): a fetch
#          of origin/master is skipped only while the last one is < max-age s
#          old, and the "landed" check always fetches. A local bare origin, a
#          clone with two worktrees, and a `git` shim on PATH that counts every
#          `fetch` it passes on to the real git.
#   1. fresh stamp (10 s) -> skip, 0 fetches; control: 61 s old -> 1 fetch
#   2. no stamp and no FETCH_HEAD -> fetch; the stamp is then written
#   3. FETCH_HEAD naming the branch, 10 s old -> skip; FETCH_HEAD of another
#      branch only -> fetch; a missing origin/master ref -> fetch
#   4. the stamp is shared: a fetch in worktree A makes worktree B skip
#   5. --max-age / FETCH_FRESH_MAX_AGE: 90 s old skips under 120, 0 = always
#   6. --landed fetches even when fresh, and sees a push the stale ref missed
#      (control: a plain call with the same fresh stamp skips and the ref
#      stays stale); an unpushed commit is NOT-LANDED (exit 1)
#   7. a failed fetch returns non-zero and writes no stamp; --landed exit 2
#   8. five callers at once with no stamp make exactly 1 fetch (n=3 rounds)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
H="$PROJ_ROOT/src/bash/features/spawn-agents/scripts/git-fetch-fresh.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

REAL_GIT="$(command -v git)"
mkdir -p "$T/bin"
cat >"$T/bin/git" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = fetch ] && { echo x >>"$T/fetches"; break; }; done
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$T/bin/git"
export PATH="$T/bin:$PATH"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { "$REAL_GIT" -c user.name=t -c user.email=t@example.com "$@"; }

g init -q --bare -b master "$T/origin.git"
g clone -q "$T/origin.git" "$T/seed" 2>/dev/null
g -C "$T/seed" commit -q --allow-empty -m c1
g -C "$T/seed" push -q origin master
g clone -q "$T/origin.git" "$T/a"
g -C "$T/a" worktree add -q -b lane-b "$T/b" origin/master 2>/dev/null
COMMON="$T/a/.git"
STAMP="$COMMON/fetch-fresh/origin.master"
NOW=$(date +%s)
export FETCH_FRESH_NOW="$NOW"

reset() { rm -f "$T/fetches" "$STAMP" "$COMMON/FETCH_HEAD" "$COMMON/worktrees/b/FETCH_HEAD"; }
n() { [ -f "$T/fetches" ] && wc -l <"$T/fetches" | tr -d ' ' || echo 0; }
stamp_at() { mkdir -p "$COMMON/fetch-fresh"; touch -d "@$1" "$STAMP"; }

# 1. fresh -> skip; control 61 s -> fetch
reset; stamp_at $((NOW - 10))
out=$(bash "$H" -C "$T/a" 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$(n)" = 0 ] && grep -q "skip: origin/master fetched 10 s ago" <<<"$out"; then pass "1 fresh (10 s): skipped, 0 fetches"; else fail "1 fresh: rc=$rc fetches=$(n) out=$out"; fi
reset; stamp_at $((NOW - 61))
bash "$H" -C "$T/a" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && [ "$(n)" = 1 ]; then pass "1 control (61 s): fetched once"; else fail "1 control: rc=$rc fetches=$(n)"; fi

# 2. nothing recorded -> fetch, stamp written
reset
bash "$H" -C "$T/a" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && [ "$(n)" = 1 ] && [ -f "$STAMP" ]; then pass "2 no stamp, no FETCH_HEAD: fetched, stamp written"
else fail "2 missing: rc=$rc fetches=$(n) stamp=$([ -f "$STAMP" ] && echo y || echo n)"; fi

# 3. FETCH_HEAD as the record
reset; printf 'abc\t\tbranch '"'"'master'"'"' of x\n' >"$COMMON/FETCH_HEAD"; touch -d "@$((NOW - 10))" "$COMMON/FETCH_HEAD"
bash "$H" -C "$T/a" 2>/dev/null
if [ "$(n)" = 0 ]; then pass "3 FETCH_HEAD naming master (10 s): skipped"; else fail "3 FETCH_HEAD master: fetches=$(n)"; fi
reset; printf 'abc\t\tbranch '"'"'other'"'"' of x\n' >"$COMMON/FETCH_HEAD"; touch -d "@$((NOW - 10))" "$COMMON/FETCH_HEAD"
bash "$H" -C "$T/a" 2>/dev/null
if [ "$(n)" = 1 ]; then pass "3 FETCH_HEAD of another branch only: fetched"; else fail "3 FETCH_HEAD other: fetches=$(n)"; fi
reset; stamp_at $((NOW - 10)); g -C "$T/a" update-ref -d refs/remotes/origin/master
bash "$H" -C "$T/a" 2>/dev/null
if [ "$(n)" = 1 ] && g -C "$T/a" rev-parse -q --verify refs/remotes/origin/master >/dev/null; then pass "3 missing origin/master ref: fetched"; else fail "3 missing ref: fetches=$(n)"; fi

# 4. shared across worktrees
reset
bash "$H" -C "$T/a" 2>/dev/null; bash "$H" -C "$T/b" 2>/dev/null
if [ "$(n)" = 1 ]; then pass "4 worktree A fetched, worktree B skipped (1 fetch for 2 calls)"; else fail "4 shared: fetches=$(n)"; fi

# 5. configurable age
reset; stamp_at $((NOW - 90))
bash "$H" -C "$T/a" --max-age 120 2>/dev/null
FETCH_FRESH_MAX_AGE=120 bash "$H" -C "$T/a" 2>/dev/null
if [ "$(n)" = 0 ]; then pass "5 90 s old under max-age 120 (flag and env): skipped"; else fail "5 max-age 120: fetches=$(n)"; fi
reset; stamp_at $((NOW - 1))
FETCH_FRESH_MAX_AGE=0 bash "$H" -C "$T/a" 2>/dev/null
if [ "$(n)" = 1 ]; then pass "5 max-age 0: always fetches"; else fail "5 max-age 0: fetches=$(n)"; fi

# 6. --landed always fetches and sees the real remote
g -C "$T/b" commit -q --allow-empty -m lane-commit
g -C "$T/seed" fetch -q "$T/b" lane-b && g -C "$T/seed" push -q origin FETCH_HEAD:master
reset; stamp_at $((NOW - 5))
bash "$H" -C "$T/b" 2>/dev/null
"$REAL_GIT" -C "$T/b" merge-base --is-ancestor HEAD origin/master; stale=$?
if [ "$(n)" = 0 ] && [ "$stale" = 1 ]; then pass "6 control: a plain call with a fresh stamp skips, origin/master stays stale"
else fail "6 control: fetches=$(n) ancestor=$stale"; fi
out=$(bash "$H" -C "$T/b" --landed 2>/dev/null); rc=$?
if [ "$rc" = 0 ] && [ "$(n)" = 1 ] && grep -q '^LANDED' <<<"$out"; then pass "6 --landed with a fresh stamp: fetched, LANDED"; else fail "6 landed: rc=$rc fetches=$(n) out=$out"; fi
g -C "$T/b" commit -q --allow-empty -m unpushed
out=$(bash "$H" -C "$T/b" --landed 2>/dev/null); rc=$?
if [ "$rc" = 1 ] && [ "$(n)" = 2 ] && grep -q '^NOT-LANDED' <<<"$out"; then pass "6 --landed, unpushed commit: fetched, NOT-LANDED (exit 1)"; else fail "6 not landed: rc=$rc fetches=$(n) out=$out"; fi

# 7. a failed fetch
reset
bash "$H" -C "$T/a" --remote nowhere 2>/dev/null; rc=$?
if [ "$rc" != 0 ] && [ ! -e "$COMMON/fetch-fresh/nowhere.master" ]; then pass "7 failed fetch: exit $rc, no stamp"
else fail "7 failed fetch: rc=$rc"; fi
g -C "$T/a" remote add broken "$T/missing.git"
bash "$H" -C "$T/a" --remote broken --landed >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then pass "7 --landed with a failed fetch: exit 2 (not judged)"; else fail "7 landed failed: rc=$rc"; fi

# 8. concurrent callers share one fetch (real clock)
ok=0
for _ in 1 2 3; do
  reset
  for _ in 1 2 3 4 5; do FETCH_FRESH_NOW='' bash "$H" -C "$T/a" 2>/dev/null & done
  wait
  [ "$(n)" = 1 ] && ok=$((ok + 1))
done
if [ "$ok" = 3 ]; then pass "8 five concurrent callers: 1 fetch per round (n=3 rounds)"; else fail "8 concurrent: $ok/3 rounds made exactly 1 fetch"; fi

echo "---"
[ "$fails" = 0 ] && { echo "git-fetch-fresh: all passed"; exit 0; }
echo "git-fetch-fresh: $fails failed"; exit 1
