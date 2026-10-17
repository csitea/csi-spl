#!/usr/bin/env bash
# test-stale-dirs.sh - hermetic test for wt-dead-sweep.sh: .stale-* dirs
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
touch -d "200 days ago" "$wt_root/m-999.stale-20260101T000000Z"

# Setup: a .stale-* dir (recent, kept)
mkdir -p "$wt_root/m-998.stale-20261016T000000Z"
echo "recent stale file" >"$wt_root/m-998.stale-20261016T000000Z/recent.txt"
touch -d "1 hour ago" "$wt_root/m-998.stale-20261016T000000Z"

# Run the sweep (dry run)
WT_REPO="$repo" WT_ROOT="$wt_root" WT_SWEEP_AGE_H=24 DRY_RUN=1 \
  bash "$self_dir/../../scripts/wt-dead-sweep.sh" 2>&1 | tee "$test_dir/dry-run.out" | grep -E '^(PLAN|KEEP|DONE)' > "$test_dir/dry-run-filtered.out"

# Run the sweep (real)
WT_REPO="$repo" WT_ROOT="$wt_root" WT_SWEEP_AGE_H=24 DRY_RUN=0 \
  bash "$self_dir/../../scripts/wt-dead-sweep.sh" 2>&1 | tee "$test_dir/real-run.out" | grep -E '^(REMOVE|KEEP|DONE)' > "$test_dir/real-run-filtered.out"

# Assertions

# Dry run: old .stale-* dir is PLANned for removal, recent is kept
dry_run_output="$(cat "$test_dir/dry-run-filtered.out")"
if ! echo "$dry_run_output" | grep -q "PLAN remove.*m-999.stale-20260101T000000Z"; then
  echo "FAIL: dry run did not PLAN to remove the old .stale-* dir"
  echo "Dry run output:"
  cat "$test_dir/dry-run.out"
  exit 1
fi
if ! echo "$dry_run_output" | grep -q "KEEP.*m-998.stale-20261016T000000Z"; then
  echo "FAIL: dry run did not KEEP the recent .stale-* dir"
  echo "Dry run output:"
  cat "$test_dir/dry-run.out"
  exit 1
fi

# Real run: old .stale-* dir is REMOVEd, recent is kept
real_run_output="$(cat "$test_dir/real-run-filtered.out")"
if ! echo "$real_run_output" | grep -q "REMOVE.*m-999.stale-20260101T000000Z"; then
  echo "FAIL: real run did not REMOVE the old .stale-* dir"
  echo "Real run output:"
  echo "$real_run_output"
  exit 1
fi
if ! echo "$real_run_output" | grep -q "KEEP.*m-998.stale-20261016T000000Z"; then
  echo "FAIL: real run did not KEEP the recent .stale-* dir"
  echo "Real run output:"
  echo "$real_run_output"
  exit 1
fi

# Real run: old .stale-* dir is gone, recent still exists
test ! -d "$wt_root/m-999.stale-20260101T000000Z" || {
  echo "FAIL: old .stale-* dir still exists after real run"
  exit 1
}
test -d "$wt_root/m-998.stale-20261016T000000Z" || {
  echo "FAIL: recent .stale-* dir was removed"
  exit 1
}

# Real run: dirty worktree is kept
test -d "$wt_root/dirty-lane" || {
  echo "FAIL: dirty worktree was removed"
  exit 1
}

echo "PASS: all assertions met"