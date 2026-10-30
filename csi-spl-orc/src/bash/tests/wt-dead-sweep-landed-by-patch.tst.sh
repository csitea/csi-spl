#!/usr/bin/env bash
# wt-dead-sweep-landed-by-patch.tst.sh - hermetic test of wt-dead-sweep.sh on
# a dead lane's clean worktree whose commits landed on trunk by patch, not by
# sha (the lane rebased before its push; SPL-4287).
#
# Under a temp worktree root, trunk holds P' (the same patch as P, other sha):
#   m-901  branch lane-901 = trunk-base + P              -> REMOVED landed-by-patch,
#                                                           branch lane-901 deleted
#   m-902  branch lane-902 = trunk-base + Q (not landed) -> KEPT not-on-trunk
#   m-903  branch lane-903 = trunk-base + P + Q          -> KEPT not-on-trunk
#   m-904  branch lane-904 = P plus a merge commit       -> KEPT not-on-trunk
#   m-905  like m-901, a file changed 1 h ago            -> KEPT recent
# The dry run plans only m-901 and removes nothing.
#
# Red control: origin/master's script (before SPL-4287) keeps m-901 as
# not-on-trunk, so "PLAN remove .*/m-901 ... landed-by-patch" FAILs.
set -euo pipefail

self_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
sweep="${WT_SWEEP_SCRIPT:-$self_dir/../scripts/wt-dead-sweep.sh}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
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
base="$(git -C "$repo" rev-parse HEAD)"

# lane <id> <branch> <commit spec...>: a worktree on a new branch from base;
# p = the landed patch, q = a patch not on trunk, m = a merge of a side
# branch whose one commit is also on trunk by patch (only the merge is off)
lane() {
  local id="$1" br="$2" c; shift 2
  gq -C "$repo" worktree add -b "$br" "$root/$id" "$base"
  for c in "$@"; do
    case "$c" in
      p) echo p >"$root/$id/p"; gq -C "$root/$id" add p; gq -C "$root/$id" commit -m P ;;
      q) echo "q $id" >"$root/$id/q"; gq -C "$root/$id" add q; gq -C "$root/$id" commit -m Q ;;
      m) gq -C "$repo" worktree add -b "side-$id" "$tmp/side-$id" "$base"
         echo y >"$tmp/side-$id/g"; gq -C "$tmp/side-$id" add g; gq -C "$tmp/side-$id" commit -m later
         gq -C "$repo" worktree remove "$tmp/side-$id"
         gq -C "$root/$id" merge --no-ff -m merge "side-$id" ;;
    esac
  done
}
lane m-901 lane-901 p
lane m-902 lane-902 q
lane m-903 lane-903 p q
lane m-904 lane-904 p m
lane m-905 lane-905 p

# trunk lands P by patch: a later commit first, so P' gets another sha
echo y >"$repo/g"; gq -C "$repo" add g; gq -C "$repo" commit -m later
echo p >"$repo/p"; gq -C "$repo" add p; gq -C "$repo" commit -m "P landed"
gq -C "$repo" update-ref refs/remotes/origin/master HEAD

for id in m-901 m-902 m-903 m-904 m-905; do old "$root/$id"; done
touch -d '1 hour ago' "$root/m-905/p"

run() {
  WT_REPO="$repo" WT_ROOT="$root" WT_SWEEP_AGE_H=24 SPOOL_ROOT="$spool" WT_SALVAGE=0 DRY_RUN="$1" \
    bash "$sweep" >"$tmp/$1.out" 2>&1 || true
}

run 1
D="$tmp/1.out"
check "dry run plans m-901, landed by patch" has "$D" "PLAN remove [0-9]+KB .*/m-901 branch lane-901 landed-by-patch$"
check "dry run plans nothing else" [ "$(grep -c 'PLAN remove' "$D")" = 1 ]
check "dry run removes nothing" [ -d "$root/m-901" ]

run 0
R="$tmp/0.out"
check "real run removes m-901" [ ! -e "$root/m-901" ]
check "real run logs REMOVE m-901 landed-by-patch" has "$R" "REMOVE [0-9]+KB .*/m-901 branch lane-901 landed-by-patch$"
check "real run deletes branch lane-901" [ -z "$(git -C "$repo" branch --list lane-901)" ]
check "a patch not on trunk is KEPT not-on-trunk" has "$R" "KEEP not-on-trunk .*/m-902$"
check "a landed patch plus one more is KEPT not-on-trunk" has "$R" "KEEP not-on-trunk .*/m-903$"
check "a merge commit is KEPT not-on-trunk" has "$R" "KEEP not-on-trunk .*/m-904$"
check "a recent landed tree is KEPT recent" has "$R" "KEEP recent .*/m-905$"
for id in m-902 m-903 m-904 m-905; do check "$id still exists" [ -d "$root/$id" ]; done
for b in lane-902 lane-903 lane-904 lane-905; do check "branch $b kept" [ -n "$(git -C "$repo" branch --list "$b")" ]; done
check "real run DONE removed=1" has "$R" 'DONE removed=1 '

if (( fails )); then
  echo "--- dry run"; cat "$D"; echo "--- real run"; cat "$R"
  echo "FAILED: $fails of $n"; exit 1
fi
echo "OK: $n of $n"
