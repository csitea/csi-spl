#!/usr/bin/env bash
# wt-dead-sweep-stale-dirs.tst.sh - hermetic test of wt-dead-sweep.sh on the
# <ID>.stale-<UTC> dirs spawn moves aside (SPL-2309).
#
# Under a temp worktree root:
#   m-999.stale-<UTC>  dead lane, all old                -> REMOVED
#   m-998.stale-<UTC>  dead lane, a file changed 1 h ago -> KEPT recent
#   m-997.stale-<UTC>  old, but agents/m-997.json alive  -> KEPT alive
#   c-001.stale-<UTC>  old, a role seat                  -> KEPT role-seat
#   m-996.stale-<UTC>  old, a process has its cwd there  -> KEPT in-use
#   m-995.stale-<UTC>  old, holds a .git                 -> never touched
#   m-994.stale-junk   old, not a <UTC> suffix           -> never touched
#   dirty-lane         a dirty linked worktree           -> KEPT dirty
# The dry run plans only m-999 and removes nothing; the real run removes
# only m-999 and its DONE line counts 1.
#
# Red control: the script as of f38eaf514^ (no .stale-* handling) keeps
# m-999, and 995cb4773's (inverted age check) removes m-998: both FAIL here.
set -euo pipefail

self_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
sweep="${WT_SWEEP_SCRIPT:-$self_dir/../scripts/wt-dead-sweep.sh}"
tmp="$(mktemp -d)"; pid=""
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; rm -rf "$tmp"' EXIT
repo="$tmp/repo"; root="$tmp/wt"; spool="$tmp/spool"
fails=0 n=0

ok() { n=$((n + 1)); echo "PASS: $1"; }
ko() { n=$((n + 1)); fails=$((fails + 1)); echo "FAIL: $1"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else ko "$what"; fi; }
has() { grep -qE -- "$2" "$1"; }
old() { find "$1" -exec touch -h -d '10 days ago' {} +; }
gq() { git -c user.name=t -c user.email=t@example.com "$@" >/dev/null 2>&1; }

mkdir -p "$repo" "$root" "$spool/agents"
gq -C "$repo" init --initial-branch=master
echo x >"$repo/f"; gq -C "$repo" add f; gq -C "$repo" commit -m init
gq -C "$repo" update-ref refs/remotes/origin/master HEAD
gq -C "$repo" worktree add -b dirty-lane "$root/dirty-lane"
echo dirty >"$root/dirty-lane/dirty.txt"

ts=20260101T000000Z
for id in m-999 m-998 m-997 c-001 m-996 m-995; do
  mkdir -p "$root/$id.stale-$ts/.claude"; echo t >"$root/$id.stale-$ts/.claude/transcript.jsonl"
done
mkdir -p "$root/m-995.stale-$ts/.git" "$root/m-994.stale-junk"
for d in "$root"/*.stale-*; do old "$d"; done
touch -d '1 hour ago' "$root/m-998.stale-$ts/.claude/transcript.jsonl"
printf '{"id":"m-997","alive":true}\n' >"$spool/agents/m-997.json"
printf '{"id":"m-999","alive":false}\n' >"$spool/agents/m-999.json"
(cd "$root/m-996.stale-$ts/.claude" && exec sleep 60) & pid=$!
sleep 0.3

run() {
  WT_REPO="$repo" WT_ROOT="$root" WT_SWEEP_AGE_H=24 SPOOL_ROOT="$spool" DRY_RUN="$1" \
    bash "$sweep" >"$tmp/$1.out" 2>&1 || true
}

run 1
D="$tmp/1.out"
check "dry run plans the old dead m-999" has "$D" "PLAN remove .*/m-999\.stale-$ts$"
check "dry run plans nothing else" [ "$(grep -c 'PLAN remove' "$D")" = 1 ]
check "dry run removes nothing" [ -d "$root/m-999.stale-$ts" ]
check "dry run DONE would-remove=1" has "$D" 'DONE would-remove=1 '

run 0
R="$tmp/0.out"
check "real run removes the old dead m-999" [ ! -e "$root/m-999.stale-$ts" ]
check "real run logs REMOVE m-999" has "$R" "REMOVE .*/m-999\.stale-$ts$"
check "a recently changed .stale dir is KEPT recent" has "$R" "KEEP recent .*/m-998\.stale-$ts$"
check "a live lane's .stale dir is KEPT alive" has "$R" "KEEP alive .*/m-997\.stale-$ts$"
check "a role seat's .stale dir is KEPT role-seat" has "$R" "KEEP role-seat .*/c-001\.stale-$ts$"
check "a .stale dir in use is KEPT in-use" has "$R" "KEEP in-use .*/m-996\.stale-$ts$"
for id in m-998 m-997 c-001 m-996 m-995; do
  check "$id.stale-$ts still exists" [ -f "$root/$id.stale-$ts/.claude/transcript.jsonl" ]
done
check "a .stale dir holding .git is never touched" [ -d "$root/m-995.stale-$ts/.git" ]
check "a .stale dir without a <UTC> suffix is never touched" [ -d "$root/m-994.stale-junk" ]
check "the dirty worktree is KEPT dirty" has "$R" "KEEP dirty .*/dirty-lane$"
check "the dirty worktree still exists" [ -f "$root/dirty-lane/dirty.txt" ]
check "real run removes nothing else" [ "$(grep -c ' REMOVE ' "$R")" = 1 ]
check "real run DONE removed=1" has "$R" 'DONE removed=1 '

if (( fails )); then
  echo "--- dry run"; cat "$D"; echo "--- real run"; cat "$R"
  echo "FAILED: $fails of $n"; exit 1
fi
echo "OK: $n of $n"
