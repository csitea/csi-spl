#!/usr/bin/env bash
# test-stale-dirs-simple.sh - hermetic test for wt-dead-sweep.sh: .stale-* dirs
#
# Setup: a temp repo + worktree root, a .stale-* dir (old and recent), a
# dirty worktree (kept), and a dry run (nothing removed).
#
# Red control: origin/master removes nothing (no .stale-* handling).
# Green: the fix removes the old .stale-* dir and keeps the recent one.
set -euo pipefail

self_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
test_dir="$(mktemp -d)"; trap 'rm -rf "$test_dir"' EXIT
repo="$test_dir/repo"; wt_root="$test_dir/wt"

# Setup: repo + worktree root
mkdir -p "$repo" "$wt_root"
git -C "$repo" init --initial-branch=master >/dev/null
git -C "$repo" config user.name "test"
git -C "$repo" config user.email "test@example.com"
echo "test file" >"$repo/test.txt"
git -C "$repo" add test.txt
git -C "$repo" commit -m "initial commit" >/dev/null

# Setup: a worktree (kept: dirty)
git -C "$repo" worktree add "$wt_root/dirty-lane" >/dev/null
echo "dirty file" >"$wt_root/dirty-lane/dirty.txt"

# Setup: a .stale-* dir (old, removed)
mkdir -p "$wt_root/m-999.stale-20260101T000000Z"
echo "old stale file" >"$wt_root/m-999.stale-20260101T000000Z/old.txt"
touch -d "2026-01-01 00:00:00" "$wt_root/m-999.stale-20260101T000000Z/old.txt"

# Setup: a .stale-* dir (recent, kept)
mkdir -p "$wt_root/m-998.stale-20261016T000000Z"
echo "recent stale file" >"$wt_root/m-998.stale-20261016T000000Z/recent.txt"
touch -d "1 hour ago" "$wt_root/m-998.stale-20261016T000000Z/recent.txt"

# Run the sweep (dry run)
echo "=== Dry run ==="
WT_REPO="$repo" WT_ROOT="$wt_root" WT_SWEEP_AGE_H=24 DRY_RUN=1 \
  bash "$self_dir/../../scripts/wt-dead-sweep.sh" 2>/dev/null | grep -E '^(PLAN|KEEP|DONE)'

# Run the sweep (real)
echo -e "\n=== Real run ==="
WT_REPO="$repo" WT_ROOT="$wt_root" WT_SWEEP_AGE_H=24 DRY_RUN=0 \
  bash "$self_dir/../../scripts/wt-dead-sweep.sh" 2>/dev/null | grep -E '^(REMOVE|KEEP|DONE)'

# Check results
echo -e "\n=== Checking results ==="
if [ ! -d "$wt_root/m-999.stale-20260101T000000Z" ]; then
  echo "PASS: old .stale-* dir was removed"
else
  echo "FAIL: old .stale-* dir still exists"
  exit 1
fi

if [ -d "$wt_root/m-998.stale-20261016T000000Z" ]; then
  echo "PASS: recent .stale-* dir was kept"
else
  echo "FAIL: recent .stale-* dir was removed"
  exit 1
fi

if [ -d "$wt_root/dirty-lane" ]; then
  echo "PASS: dirty worktree was kept"
else
  echo "FAIL: dirty worktree was removed"
  exit 1
fi

echo "PASS: all assertions met"