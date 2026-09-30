#!/usr/bin/env bash
# install-pre-push-hook.sh (SPL-1252) — install the deploy-gate pre-push hook
# into ONE git worktree, in ISOLATION.
#
# Git resolves hooks from a single common dir for every worktree unless a
# worktree sets its OWN core.hooksPath, which needs extensions.worktreeConfig.
# This installer therefore:
#   1. enables extensions.worktreeConfig (backward-compatible: it only makes
#      per-worktree settings POSSIBLE; nothing already set changes meaning), and
#   2. sets core.hooksPath FOR THIS WORKTREE ONLY (writes .git/worktrees/<w>/
#      config.worktree) to the version-controlled hooks dir in the SHARED
#      checkout -- never a path inside a worktree that could be removed.
# No other worktree and not the shared checkout is gated by this call; run it per
# worktree to opt each one in. Idempotent.
#
# Usage: install-pre-push-hook.sh <worktree-dir>
# Exit: 0 installed/already, 2 usage / not a worktree, 1 no hook payload found.
set -uo pipefail

wt="${1:-}"
[ -n "$wt" ] || { echo "usage: install-pre-push-hook.sh <worktree-dir>" >&2; exit 2; }
git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "install-pre-push-hook: $wt is not a git worktree" >&2; exit 2; }

# The hooks dir lives in the SHARED checkout (permanent), resolved from the
# common git dir so it is stable even when this worktree is later removed.
common="$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null)"
case "$common" in
  /*) ;;                                        # already absolute
  *)  common="$(cd "$wt" && cd "$common" && pwd)" ;;
esac
repo="$(cd "$(dirname "$common")" && pwd)"
hooks_dir="$repo/csi-spl-orc/src/bash/features/spawn-agents/hooks"

[ -x "$hooks_dir/pre-push" ] \
  || { echo "install-pre-push-hook: no executable hook at $hooks_dir/pre-push" >&2; exit 1; }

git -C "$wt" config extensions.worktreeConfig true
git -C "$wt" config --worktree core.hooksPath "$hooks_dir"
echo "install-pre-push-hook: $wt -> core.hooksPath=$hooks_dir (worktree-local)"
