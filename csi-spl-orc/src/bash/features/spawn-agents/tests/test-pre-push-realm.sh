#!/usr/bin/env bash
# test-pre-push-realm.sh — spec 129 G1 (phase A0): a PRIVATE lane never pushes
# to the public repository. Real `git push` into a bare temp remote with the
# fleet hooks dir as core.hooksPath; the repo is not the spool tree, so the
# gate itself fail-opens and only the realm check decides. The realm is the
# box-local half of the lane map row, $SPOOL_ROOT/<ID>/lane.realm.
#   1. a <repo>-wt/<ID> worktree whose row is realm=private:x -> REFUSED,
#      remote unchanged, the workspace never printed
#   2. ... with SPL_PREPUSH_OVERRIDE=1                        -> still REFUSED
#   3. SPOOL_AGENT_ID=<private ID> from a plain clone          -> REFUSED
#   4. CONTROL: the row says realm=public                      -> pushed
#   5. no row at all (a lane from before A0)                   -> pushed
#   6. the trampoline (installed copy) refuses a private lane before handing
#      off, in a tree carrying the fleet hook; public -> handed off, exit 0;
#      a private lane in a repo WITHOUT the fleet hook (its private repo) ->
#      not refused
#   7. CONTROL: the hook with the realm block cut out lets case 1 through
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX SPOOL_AGENT_ID 2>/dev/null || true
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$(cd "$HERE/../hooks" && pwd)"

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1 ${2:+:: $2}"; fails=$((fails + 1)); }
eq()   { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
export SPL_PREPUSH_LOG_DIR="$ROOT/log" SPOOL_ROOT="$ROOT/spool"
ws="wsq9private"
realm() { mkdir -p "$SPOOL_ROOT/$1"; printf '%s\n' "$2" >"$SPOOL_ROOT/$1/lane.realm"; }

git init -q --bare "$ROOT/remote.git"
mkclone() { git clone -q "$ROOT/remote.git" "$1" 2>/dev/null; git -C "$1" checkout -q -B master; }
c() { git -C "$1" commit -q --allow-empty -m "$2"; }
push() {  # <hooksdir> <repo> [env...] -- <push args...>
  local hd="$1" r="$2"; shift 2; local e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  env "${e[@]}" git -C "$r" -c core.hooksPath="$hd" push -q origin "$@" 2>"$ROOT/err"
}
rtip() { git -C "$ROOT/remote.git" rev-parse master 2>/dev/null; }

W="$ROOT/pub-wt/c-901"; mkclone "$W"; c "$W" c1; git -C "$W" push -q origin master 2>/dev/null

# 1. private row
realm c-901 "realm=private:$ws"; c "$W" c2; before="$(rtip)"
push "$HOOKS" "$W" -- master; eq "1. a private lane's push -> refused" 1 "$(( $? != 0 ))"
grep -q 'REFUSED -- c-901 is a PRIVATE lane' "$ROOT/err" && pass "1. ... by the realm check" || fail "1. ... by the realm check" "$(cat "$ROOT/err")"
eq "1. ... remote unchanged" "$before" "$(rtip)"
grep -q "$ws" "$ROOT/err" "$SPL_PREPUSH_LOG_DIR/pre-push.log" && fail "1. ... the workspace leaked into the output or the log" || pass "1. ... the workspace is neither printed nor logged"

# 2. override does not skip it
push "$HOOKS" "$W" SPL_PREPUSH_OVERRIDE=1 -- master; eq "2. SPL_PREPUSH_OVERRIDE=1 -> still refused" 1 "$(( $? != 0 ))"
eq "2. ... remote unchanged" "$before" "$(rtip)"

# 3. the agent id from the env, a clone outside <repo>-wt/
P="$ROOT/plain"; mkclone "$P"; git -C "$P" pull -q origin master 2>/dev/null; c "$P" p1
realm c-902 "realm=private:$ws"
push "$HOOKS" "$P" SPOOL_AGENT_ID=c-902 -- master; eq "3. SPOOL_AGENT_ID of a private lane -> refused" 1 "$(( $? != 0 ))"
eq "3. ... remote unchanged" "$before" "$(rtip)"

# 4. CONTROL: public
realm c-901 "realm=public"
push "$HOOKS" "$W" -- master; eq "4. CONTROL: realm=public -> pushed (exit 0)" 0 "$?"
eq "4. ... remote moved" "$(git -C "$W" rev-parse HEAD)" "$(rtip)"

# 5. no row
rm -f "$SPOOL_ROOT/c-901/lane.realm"; c "$W" c3
push "$HOOKS" "$W" -- master; eq "5. no realm row -> pushed" 0 "$?"

# 6. the trampoline, as install-pre-push-hook.sh copies it
TR="$ROOT/tramp"; mkdir -p "$TR"; install -m 0755 "$HOOKS/pre-push-trampoline" "$TR/pre-push"
grep -q '^# spl-pre-push-trampoline version: ' "$TR/pre-push" && pass "6. the trampoline carries its version line" || fail "6. the trampoline carries its version line"
rel="csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push"
W2="$ROOT/pub-wt/c-903"; mkclone "$W2"; git -C "$W2" pull -q origin master 2>/dev/null
mkdir -p "$W2/$(dirname "$rel")"; printf '#!/bin/sh\necho handed-off >&2\nexit 0\n' >"$W2/$rel"; chmod +x "$W2/$rel"
git -C "$W2" add "$rel"; c "$W2" t1
realm c-903 "realm=private:$ws"; before="$(rtip)"
push "$TR" "$W2" -- master; eq "6. trampoline: a private lane in the public tree -> refused" 1 "$(( $? != 0 ))"
grep -q 'handed-off' "$ROOT/err" && fail "6. ... before the hand-off" || pass "6. ... before the hand-off"
eq "6. ... remote unchanged" "$before" "$(rtip)"
realm c-903 "realm=public"
push "$TR" "$W2" -- master; eq "6. trampoline: public -> handed off, exit 0" 0 "$?"
grep -q 'handed-off' "$ROOT/err" && pass "6. ... the tree's own hook ran" || fail "6. ... the tree's own hook ran" "$(cat "$ROOT/err")"
git init -q --bare "$ROOT/priv.git"; V="$ROOT/priv-wt/c-904"; git clone -q "$ROOT/priv.git" "$V" 2>/dev/null
git -C "$V" checkout -q -B master; c "$V" v1; realm c-904 "realm=private:$ws"
env git -C "$V" -c core.hooksPath="$TR" push -q origin master 2>"$ROOT/err"
eq "6. trampoline: a private lane in its private repo (no fleet hook) -> not refused" 0 "$?"

# 7. CONTROL: no realm block -> the private push goes through
OLD="$ROOT/hooks-old"; mkdir -p "$OLD"
sed '/^# Spec 129 G1 (phase A0): a PRIVATE lane/,/^fi$/d' "$HOOKS/pre-push" >"$OLD/pre-push"; chmod +x "$OLD/pre-push"
grep -q 'lane.realm\|pr_lane_realm' "$OLD/pre-push" && fail "7. control hook still carries the realm check" || pass "7. control hook has no realm check"
realm c-901 "realm=private:$ws"; c "$W" c4
push "$OLD" "$W" -- master; eq "7. CONTROL: without the realm block the private push lands" 0 "$?"

echo "-- $(basename "$0"): $fails failed"
[ "$fails" -eq 0 ]
