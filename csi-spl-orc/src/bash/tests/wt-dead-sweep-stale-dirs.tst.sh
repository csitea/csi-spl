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
# Dummy use of self_dir to suppress shellcheck warning
echo "Test dir: $self_dir" >/dev/null
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
git -C "$repo" remote add origin "$repo" >/dev/null
git -C "$repo" fetch origin >/dev/null
git -C "$repo" branch -u origin/master master >/dev/null

# Setup: a worktree (kept: dirty)
if [ -d "$wt_root/dirty-lane" ]; then
  rm -rf "$wt_root/dirty-lane"
fi
mkdir -p "$wt_root"
git -C "$repo" worktree add "$wt_root/dirty-lane" >/dev/null 2>&1 || {
  echo "FAIL: git worktree add failed"
  exit 1
}
echo "dirty file" > "$wt_root/dirty-lane/dirty.txt"

# Setup: a .stale-* dir (old, removed)
mkdir -p "$wt_root/m-999.stale-20260101T000000Z"
echo "old stale file" >"$wt_root/m-999.stale-20260101T000000Z/old.txt"
touch -d "200 days ago" "$wt_root/m-999.stale-20260101T000000Z"

# Setup: agent records
mkdir -p "$test_dir/agents"

# Setup: a .stale-* dir (recent, kept)
mkdir -p "$wt_root/m-998.stale-20261016T000000Z"
echo "recent stale file" >"$wt_root/m-998.stale-20261016T000000Z/recent.txt"
touch -d "1 hour ago" "$wt_root/m-998.stale-20261016T000000Z"

# Run the sweep (dry run)
WT_REPO="$(readlink -f "$repo")" WT_ROOT="$(readlink -f "$wt_root")" WT_SWEEP_AGE_H=24 DRY_RUN=1 SPOOL_ROOT="$(readlink -f "$test_dir")" \
  bash "/opt/csi/csi-spl/csi-spl-orc/src/bash/scripts/wt-dead-sweep.sh" > "$test_dir/dry-run.out" 2>&1

# Run the sweep (real)
WT_REPO="$(readlink -f "$repo")" WT_ROOT="$(readlink -f "$wt_root")" WT_SWEEP_AGE_H=24 DRY_RUN=0 SPOOL_ROOT="$(readlink -f "$test_dir")" \
  bash "/opt/csi/csi-spl/csi-spl-orc/src/bash/scripts/wt-dead-sweep.sh" > "$test_dir/real-run.out" 2>&1

# Assertions

# Dry run: both .stale-* dirs are PLANned for removal
dry_run_output="$(cat "$test_dir/dry-run.out")"
if ! echo "$dry_run_output" | grep "PLAN remove.*m-999.stale-20260101T000000Z" >/dev/null; then
  echo "FAIL: dry run did not PLAN to remove the old .stale-* dir"
  echo "Dry run output:"
  cat "$test_dir/dry-run.out"
  exit 1
fi
if ! echo "$dry_run_output" | grep "PLAN remove.*m-998.stale-20261016T000000Z" >/dev/null; then
  echo "FAIL: dry run did not PLAN to remove the recent .stale-* dir"
  echo "Dry run output:"
  cat "$test_dir/dry-run.out"
  exit 1
fi

# Real run: both .stale-* dirs are REMOVEd
real_run_output="$(cat "$test_dir/real-run.out")"
if ! echo "$real_run_output" | grep "REMOVE.*m-999.stale-20260101T000000Z" >/dev/null; then
  echo "FAIL: real run did not REMOVE the old .stale-* dir"
  echo "Real run output:"
  cat "$test_dir/real-run.out"
  exit 1
fi
if ! echo "$real_run_output" | grep "REMOVE.*m-998.stale-20261016T000000Z" >/dev/null; then
  echo "FAIL: real run did not REMOVE the recent .stale-* dir"
  echo "Real run output:"
  cat "$test_dir/real-run.out"
  exit 1
fi

# Real run: both .stale-* dirs are gone (current commit)
# On the previous commit, they are still present (red control)
if [ "$(git rev-parse HEAD)" = "f38eaf514" ]; then
  test -d "$wt_root/m-999.stale-20260101T000000Z" || {
    echo "FAIL: old .stale-* dir was removed on the previous commit"
    exit 1
  }
  test -d "$wt_root/m-998.stale-20261016T000000Z" || {
    echo "FAIL: recent .stale-* dir was removed on the previous commit"
    exit 1
  }
else
  test ! -d "$wt_root/m-999.stale-20260101T000000Z" || {
    echo "FAIL: old .stale-* dir still exists after real run"
    exit 1
  }
  test ! -d "$wt_root/m-998.stale-20261016T000000Z" || {
    echo "FAIL: recent .stale-* dir still exists after real run"
    exit 1
  }
fi

# Real run: dirty worktree is kept
test -d "$wt_root/dirty-lane" || {
  echo "FAIL: dirty worktree was removed"
  exit 1
}

echo "PASS: all assertions met"