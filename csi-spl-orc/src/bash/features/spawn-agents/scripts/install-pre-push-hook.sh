#!/usr/bin/env bash
# install-pre-push-hook.sh (SPL-1252) — make the deploy-gate pre-push hook fire
# for a git checkout, WITHOUT writing any git config.
#
# An earlier version set a per-worktree core.hooksPath, which needs
# extensions.worktreeConfig. Enabling that made git honour a latent
# core.bare=true in the COMMON config and mis-detect the MAIN checkout as bare,
# and it fought a config watchdog in a loop that repeatedly broke every
# worktree ("must be run in a work tree"). Git already resolves hooks from the
# ONE common hooks dir for every linked worktree, so a single hook there gates
# them all -- no config is touched, and the whole core.bare landmine is gone.
#
# Idempotent: (re)points $GIT_COMMON_DIR/hooks/pre-push at the version-controlled
# hook in the shared checkout, so an update to the hook propagates to everyone.
#
# Usage: install-pre-push-hook.sh <checkout-dir>
# Exit: 0 installed/already, 2 usage / not a worktree, 1 no hook payload found.
set -uo pipefail

wt="${1:-}"
[ -n "$wt" ] || { echo "usage: install-pre-push-hook.sh <checkout-dir>" >&2; exit 2; }
git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "install-pre-push-hook: $wt is not a git worktree" >&2; exit 2; }

# The common git dir (shared by every linked worktree) and the shared checkout
# that holds the version-controlled hook payload.
common="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
  || common="$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null)"
case "$common" in
  /*) ;;
  *)  common="$(cd "$wt" && cd "$common" && pwd)" ;;
esac
repo="$(cd "$(dirname "$common")" && pwd)"
hook_src="$repo/csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push"

[ -x "$hook_src" ] \
  || { echo "install-pre-push-hook: no executable hook at $hook_src" >&2; exit 1; }

mkdir -p "$common/hooks" 2>/dev/null || true
dest="$common/hooks/pre-push"
ln -sfn "$hook_src" "$dest"
echo "install-pre-push-hook: $dest -> $hook_src (common hooks dir; gates every worktree, no git config)"
