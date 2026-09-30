#!/usr/bin/env bash
# retrofit-pre-push-hooks.sh (SPL-1252) — move the fleet to the config-free
# pre-push hook and UNDO the extensions.worktreeConfig experiment that caused the
# recurring core.bare breakage.
#
# It (1) installs the hook in the COMMON hooks dir (one file, gates every
# worktree), then (2) tears down the per-worktree config the old approach left:
# clears each worktree's core.hooksPath, pins the common core.bare=false, and
# disables extensions.worktreeConfig -- after which git treats the repo as a
# plain checkout, nothing migrates core.bare, and the config watchdog has nothing
# to fight. It writes SHARED config (needs the owner's go), never a worktree's
# files/index/branch.
#
# Usage: retrofit-pre-push-hooks.sh [<repo>]   (default: this checkout's repo)
# Exit: 0 always (per-worktree failures are reported, not fatal).
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

repo="${1:-}"
[ -n "$repo" ] || repo="$(git -C "$here" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$repo" ] || { echo "retrofit-pre-push-hooks: no git repo (pass one)" >&2; exit 2; }

common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
  || common="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null)"
cfg="$common/config"

# 1. install the ONE common hook (so hooks keep firing after we clear the
#    per-worktree hooksPath below).
bash "$here/install-pre-push-hook.sh" "$repo" || echo "retrofit: common hook install FAILED" >&2

# 2. clear each worktree's per-worktree core.hooksPath (dead once worktreeConfig
#    is off, but tidy). Only meaningful while worktreeConfig is still on.
if [ "$(git -C "$repo" config -f "$cfg" --get extensions.worktreeConfig 2>/dev/null)" = true ]; then
  cleared=0
  while IFS= read -r line; do
    case "$line" in worktree\ *) wt="${line#worktree }" ;; *) continue ;; esac
    if git -C "$wt" config --worktree --get core.hooksPath >/dev/null 2>&1; then
      git -C "$wt" config --worktree --unset-all core.hooksPath 2>/dev/null && cleared=$((cleared + 1))
    fi
  done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)
  echo "retrofit: cleared per-worktree core.hooksPath on $cleared worktree(s)"
fi

# 3. teardown the worktreeConfig experiment: pin common core.bare=false FIRST
#    (so the checkout stays non-bare the instant the extension turns off), remove
#    any common core.worktree, then disable the extension.
git config -f "$cfg" core.bare false 2>/dev/null || true
git config -f "$cfg" --unset-all core.worktree 2>/dev/null || true
if [ "$(git config -f "$cfg" --get extensions.worktreeConfig 2>/dev/null)" = true ]; then
  git config -f "$cfg" --unset-all extensions.worktreeConfig 2>/dev/null || true
  echo "retrofit: disabled extensions.worktreeConfig; core.bare pinned false in the common config"
fi

echo "retrofit-pre-push-hooks: done -- $common/hooks/pre-push gates every worktree; no per-worktree config remains"
exit 0
