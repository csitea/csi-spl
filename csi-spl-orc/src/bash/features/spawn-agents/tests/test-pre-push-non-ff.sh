#!/usr/bin/env bash
# test-pre-push-non-ff.sh — the pre-push hook REFUSES a non-fast-forward push to
# master (m-713's --force-with-lease, 2026-10-10 06:26Z, dropped a lane's commit;
# master has no server-side protection). Real `git push` into a bare temp remote
# with the hook as core.hooksPath; the repo is not the spool tree, so the gate
# itself fail-opens and only the non-ff guard decides.
#   1. a fast-forward push to master            -> passes, remote moves
#   2. --force rewinding master                 -> REFUSED, remote unchanged
#   3. --force-with-lease rewinding master      -> REFUSED, remote unchanged
#   4. SPL_PREPUSH_OVERRIDE=1 + --force         -> still REFUSED
#   5. deleting master                          -> REFUSED
#   6. --force to a non-master branch           -> passes
#   7. a remote sha missing locally is fetched first; a true ff still passes
#   8. CONTROL: the hook without the guard lets the forced push through
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(cd "$HERE/../hooks" && pwd)/pre-push"

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1 ${2:+:: $2}"; fails=$((fails + 1)); }
eq()   { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
export SPL_PREPUSH_LOG_DIR="$ROOT/log"

NEW="$ROOT/hooks-new"; OLD="$ROOT/hooks-old"; mkdir -p "$NEW" "$OLD"
install -m 0755 "$HOOK" "$NEW/pre-push"
# the control: the same hook with the guard block cut out
sed '/^# Non-fast-forward guard on trunk/,/^done <<<"\$_pp_refs"$/d' "$HOOK" >"$OLD/pre-push"; chmod +x "$OLD/pre-push"
grep -q 'merge-base --is-ancestor' "$OLD/pre-push" && fail "control hook still carries the guard" || pass "control hook has no guard"

git init -q --bare "$ROOT/remote.git"
A="$ROOT/a"; git clone -q "$ROOT/remote.git" "$A" 2>/dev/null
git -C "$A" checkout -q -b master
c() { git -C "$1" commit -q --allow-empty -m "$2"; }
c "$A" c1; c "$A" c2; git -C "$A" push -q origin master 2>/dev/null
push() {  # <hooksdir> <repo> [env...] -- <push args...>
  local hd="$1" r="$2"; shift 2; local e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  env "${e[@]}" git -C "$r" -c core.hooksPath="$hd" push -q origin "$@" 2>"$ROOT/err"
}
rtip() { git -C "$ROOT/remote.git" rev-parse "$1" 2>/dev/null; }

# 1. fast-forward
c "$A" c3; push "$NEW" "$A" -- master; eq "1. fast-forward push to master -> exit 0" 0 "$?"
eq "1. ... remote moved to the local tip" "$(git -C "$A" rev-parse HEAD)" "$(rtip master)"

# a second clone lands c4; A rewinds and rewrites (the raced-rebase shape)
B="$ROOT/b"; git clone -q "$ROOT/remote.git" "$B" 2>/dev/null; c "$B" c4; push "$NEW" "$B" -- master
git -C "$A" fetch -q origin; git -C "$A" reset -q --hard HEAD~1; c "$A" c3-rewritten
before="$(rtip master)"

# 2. --force
push "$NEW" "$A" -- --force master; eq "2. --force rewinding master -> refused (exit != 0)" 1 "$(( $? != 0 ))"
grep -q 'REFUSED -- non-fast-forward push to master (would drop 2 commit(s): ' "$ROOT/err" \
  && pass "2. ... names the dropped commits" || fail "2. ... names the dropped commits" "$(cat "$ROOT/err")"
eq "2. ... remote unchanged" "$before" "$(rtip master)"
grep -q 'REFUSE .*non-fast-forward' "$SPL_PREPUSH_LOG_DIR/pre-push.log" && pass "2. ... logged" || fail "2. ... logged"

# 3. --force-with-lease (lease is current: A fetched)
push "$NEW" "$A" -- --force-with-lease master; eq "3. --force-with-lease rewinding master -> refused" 1 "$(( $? != 0 ))"
grep -q 'non-fast-forward push to master' "$ROOT/err" && pass "3. ... by the hook" || fail "3. ... by the hook" "$(cat "$ROOT/err")"
eq "3. ... remote unchanged" "$before" "$(rtip master)"

# 4. the override does not skip it
push "$NEW" "$A" SPL_PREPUSH_OVERRIDE=1 -- --force master; eq "4. SPL_PREPUSH_OVERRIDE=1 + --force -> still refused" 1 "$(( $? != 0 ))"
eq "4. ... remote unchanged" "$before" "$(rtip master)"

# 5. delete of master
push "$NEW" "$A" -- --delete master; eq "5. deleting master -> refused" 1 "$(( $? != 0 ))"
grep -q 'a delete of master' "$ROOT/err" && pass "5. ... by the hook" || fail "5. ... by the hook" "$(cat "$ROOT/err")"
eq "5. ... remote master still there" "$before" "$(rtip master)"

# 6. a forced push to a non-master branch
git -C "$A" push -q origin HEAD~1:refs/heads/feat 2>/dev/null
push "$NEW" "$A" -- --force HEAD~2:refs/heads/feat; eq "6. --force to a non-master branch -> exit 0" 0 "$?"
eq "6. ... feat rewound" "$(git -C "$A" rev-parse HEAD~2)" "$(rtip feat)"

# 7. remote sha missing locally: C clones at c4, B lands c5, C (never fetched c5)
#    force-pushes c6 -- the hook fetches c5 and names it as dropped
C="$ROOT/cc"; git clone -q "$ROOT/remote.git" "$C" 2>/dev/null; c "$B" c5; push "$NEW" "$B" -- master
c "$C" c6; tip5="$(rtip master)"
push "$NEW" "$C" -- --force master; eq "7. unknown remote sha is fetched, then the rewind is refused" 1 "$(( $? != 0 ))"
grep -q "would drop 1 commit(s): $(git -C "$ROOT/remote.git" rev-parse --short "$tip5")" "$ROOT/err" \
  && pass "7. ... the fetched sha is named as dropped" || fail "7. ... the fetched sha is named as dropped" "$(cat "$ROOT/err")"
eq "7. ... remote unchanged" "$tip5" "$(rtip master)"
git -C "$C" fetch -q origin; git -C "$C" rebase -q origin/master 2>/dev/null
push "$NEW" "$C" -- master; eq "7. after fetch + rebase the push is a ff -> exit 0" 0 "$?"

# 8. CONTROL: without the guard the same forced rewind lands
before="$(rtip master)"
push "$OLD" "$A" -- --force master; eq "8. CONTROL: old hook lets --force through" 0 "$?"
[ "$(rtip master)" != "$before" ] && pass "8. CONTROL: ... and the remote was rewound" || fail "8. CONTROL: ... and the remote was rewound"

echo "-- test-pre-push-non-ff.sh: $fails failed"
[ "$fails" -eq 0 ]
