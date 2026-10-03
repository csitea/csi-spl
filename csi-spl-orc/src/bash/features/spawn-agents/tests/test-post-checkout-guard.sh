#!/usr/bin/env bash
# test-post-checkout-guard.sh — the nested-worktree guard (hooks/post-checkout)
# and its install by install-pre-push-hook.sh.
# 2026-10-03 09:10Z: `git worktree add -q --detach $W origin/master` with $W
# expanded empty by an outer `sudo -i` shell left a full repo copy at
# <main>/origin/master/ -- the main checkout went unclean and lanes skipped
# their `merge --ff-only`.
#   1. the installer puts the guard in the COMMON hooks dir
#   2. `git worktree add --detach origin/master` (ref read as path) -> refused,
#      nothing left behind, main checkout clean, not registered
#   3. the same through an outer shell that expands an unset $W
#   4. a nested relative path (sub/dir) in a LANE worktree -> refused
#   5. a sibling worktree outside every checkout -> allowed
#   6. an ordinary checkout inside a worktree -> untouched (exit 0)
#   7. a foreign post-checkout is never overwritten
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="$(cd "$HERE/../scripts" && pwd)/install-pre-push-hook.sh"

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1 ${2:+:: $2}"; fails=$((fails + 1)); }
eq()   { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
nwt() { git -C "$1" worktree list --porcelain | grep -c '^worktree '; }

MAIN="$ROOT/main"
git init -q "$MAIN"; echo seed >"$MAIN/seed"; git -C "$MAIN" add seed; git -C "$MAIN" commit -qm seed
git -C "$MAIN" update-ref refs/remotes/origin/master HEAD

# 1.
bash "$INSTALL" "$MAIN" >/dev/null 2>&1; eq "1. installer -> exit 0" 0 "$?"
[ -x "$MAIN/.git/hooks/post-checkout" ] && pass "1. guard installed in the common hooks dir" \
  || fail "1. guard installed in the common hooks dir"

# 2.
( cd "$MAIN" && git worktree add -q --detach origin/master ) >/dev/null 2>&1
eq "2. ref read as path -> worktree add fails" 1 "$?"
[ ! -e "$MAIN/origin" ] && pass "2. no origin/ left in the checkout" || fail "2. no origin/ left in the checkout"
eq "2. main checkout clean" "" "$(git -C "$MAIN" status --short)"
eq "2. not registered as a worktree" 1 "$(nwt "$MAIN")"

# 3.
( unset W; cd "$MAIN" && bash -c "W=$ROOT/proof && git worktree add -q --detach $W origin/master" ) >/dev/null 2>&1
eq "3. empty \$W from an outer shell -> refused" 1 "$?"
{ [ ! -e "$MAIN/origin" ] && [ "$(nwt "$MAIN")" = 1 ]; } && pass "3. nothing left behind" || fail "3. nothing left behind"

# 4.
git -C "$MAIN" worktree add -q -b lane "$ROOT/lane" >/dev/null 2>&1
( cd "$ROOT/lane" && git worktree add -q --detach sub/dir HEAD ) >/dev/null 2>&1
eq "4. nested path in a lane -> refused" 1 "$?"
{ [ ! -e "$ROOT/lane/sub" ] && [ -z "$(git -C "$ROOT/lane" status --short)" ]; } \
  && pass "4. lane clean, empty parents removed" || fail "4. lane clean, empty parents removed"

# 5.
git -C "$MAIN" worktree add -q --detach "$ROOT/sib" origin/master >/dev/null 2>&1
eq "5. sibling worktree -> exit 0" 0 "$?"
[ -f "$ROOT/sib/seed" ] && pass "5. sibling checked out" || fail "5. sibling checked out"

# 6.
git -C "$ROOT/lane" checkout -q -b lane2 >/dev/null 2>&1; eq "6. ordinary checkout -> exit 0" 0 "$?"
git -C "$ROOT/sib" checkout -q --detach origin/master >/dev/null 2>&1; eq "6. detach checkout -> exit 0" 0 "$?"

# 7.
F="$ROOT/foreign"; git init -q "$F"; git -C "$F" commit -q --allow-empty -m x
printf '#!/bin/sh\necho mine\n' >"$F/.git/hooks/post-checkout"
bash "$INSTALL" "$F" >/dev/null 2>&1
eq "7. a foreign post-checkout is left alone" mine "$(sh "$F/.git/hooks/post-checkout")"

echo "-- test-post-checkout-guard.sh: $fails failed"
[ "$fails" -eq 0 ]
