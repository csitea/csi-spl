#!/usr/bin/env bash
# git-fetch-fresh.sh — `git fetch <remote> <branch>` that is skipped when that
# ref was fetched in the last FETCH_FRESH_MAX_AGE seconds (default 60), on ANY
# worktree of the same clone (measurement: fleet-hot-commands-2026-10-07.md,
# section 3.6: ~20 worktrees share one object store, the integration loop
# fetches 2-3 times per push, the p90 tail is contention).
#
# Freshness = the newest of two mtimes:
#   - <git-common-dir>/fetch-fresh/<remote>.<branch>, touched after every
#     successful fetch this helper makes (shared by all worktrees), and
#   - this worktree's FETCH_HEAD, when it names `branch '<branch>' of`.
# Neither there, or the remote-tracking ref missing: fetch.
# Concurrent callers queue on one flock, and the second one re-reads the
# stamp, so twenty lanes fetching at once make one round trip, not twenty.
#
# --landed NEVER skips: it fetches, then `git merge-base --is-ancestor HEAD
# <remote>/<branch>` (the "landed" check must see the real remote).
#
# Usage: git-fetch-fresh.sh [-C <dir>] [--remote origin] [--branch master]
#                           [--max-age <s>] [--force] [--landed]
# Exit:  the fetch's exit code (0 on a skip); --landed: 0 landed, 1 not
#        landed, 2 the fetch failed; 64 a usage error.
# Env:   FETCH_FRESH_MAX_AGE (default 60; 0 = always fetch),
#        FETCH_FRESH_NOW (epoch seconds, default now; for tests).
set -uo pipefail

dir="."; remote="origin"; branch="master"; force=0; landed=0
max_age="${FETCH_FRESH_MAX_AGE:-60}"
while [ $# -gt 0 ]; do
  case "$1" in
    -C) dir="${2:-}"; shift 2 ;;
    --remote) remote="${2:-}"; shift 2 ;;
    --branch) branch="${2:-}"; shift 2 ;;
    --max-age) max_age="${2:-}"; shift 2 ;;
    --force) force=1; shift ;;
    --landed) landed=1; force=1; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "git-fetch-fresh.sh: unknown argument: $1" >&2; exit 64 ;;
  esac
done
[[ "$max_age" =~ ^[0-9]+$ ]] || { echo "git-fetch-fresh.sh: --max-age must be an integer" >&2; exit 64; }
if [ -z "$remote" ] || [ -z "$branch" ]; then echo "git-fetch-fresh.sh: --remote and --branch must be set" >&2; exit 64; fi
common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
  { echo "git-fetch-fresh.sh: $dir is not a git checkout" >&2; exit 64; }

stamp_dir="$common/fetch-fresh"
stamp="$stamp_dir/${remote}.${branch//\//_}"
fetch_head="$(git -C "$dir" rev-parse --path-format=absolute --git-path FETCH_HEAD 2>/dev/null)"

# The age in seconds of the newest fetch of <remote>/<branch>; empty = none.
_age() {
  local now t newest=""
  now="${FETCH_FRESH_NOW:-$(date +%s)}"
  git -C "$dir" rev-parse --verify -q "refs/remotes/${remote}/${branch}" >/dev/null || return 0
  if [ -f "$stamp" ]; then newest="$(stat -c %Y "$stamp" 2>/dev/null)"; fi
  if [ -n "$fetch_head" ] && [ -f "$fetch_head" ] && grep -qF "branch '${branch}' of" "$fetch_head" 2>/dev/null; then
    t="$(stat -c %Y "$fetch_head" 2>/dev/null)"
    if [ -n "$t" ] && { [ -z "$newest" ] || [ "$t" -gt "$newest" ]; }; then newest="$t"; fi
  fi
  # A stamp a second ahead of the clock is fresh, not invalid.
  [ -n "$newest" ] && { t=$((now - newest)); echo $((t < 0 ? 0 : t)); }
}

# Fresh: says so and returns 0; else returns 1.
_fresh() {
  local age
  [ "$force" = 1 ] && return 1
  [ "$max_age" -gt 0 ] || return 1
  age="$(_age)"
  [ -n "$age" ] && [ "$age" -lt "$max_age" ] || return 1
  echo "git-fetch-fresh: skip: ${remote}/${branch} fetched ${age} s ago (< ${max_age} s)" >&2
}

_fetch() {
  git -C "$dir" fetch -q "$remote" "$branch" || return $?
  mkdir -p "$stamp_dir" 2>/dev/null && touch "$stamp" 2>/dev/null
  echo "git-fetch-fresh: fetched ${remote}/${branch}" >&2
}

rc=0
if ! _fresh; then
  # One fetch per clone at a time; whoever waited re-reads the stamp.
  if mkdir -p "$stamp_dir" 2>/dev/null && command -v flock >/dev/null &&
     { exec 9>>"$stamp.lock"; } 2>/dev/null; then
    flock -w 120 9 2>/dev/null || true
    if [ "$force" = 1 ] || ! _fresh; then _fetch; rc=$?; fi
    exec 9>&-
  else
    _fetch; rc=$?
  fi
fi

if [ "$landed" = 1 ]; then
  [ "$rc" = 0 ] || { echo "git-fetch-fresh: NOT-CHECKED: the fetch of ${remote}/${branch} failed (exit $rc)" >&2; exit 2; }
  if git -C "$dir" merge-base --is-ancestor HEAD "${remote}/${branch}"; then
    echo "LANDED: HEAD is on ${remote}/${branch}"; exit 0
  fi
  echo "NOT-LANDED: HEAD is not on ${remote}/${branch}"; exit 1
fi
exit "$rc"
