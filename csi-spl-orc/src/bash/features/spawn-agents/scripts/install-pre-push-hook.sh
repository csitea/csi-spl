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

# Enabling extensions.worktreeConfig makes git read core.bare / core.worktree
# PER WORKTREE. If a repo carries core.bare=true in its COMMON config (a latent
# misconfiguration git ignored for the main checkout while the extension was
# off), turning the extension on makes git treat the non-bare MAIN checkout as
# bare -- `status` / `merge --ff-only` then fail there. Git's documented
# migration is to pin those settings in the MAIN worktree's own config.worktree.
# Do it here, idempotently, so enabling the extension is always safe.
main_wt="$(git -C "$wt" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"

git -C "$wt" config extensions.worktreeConfig true

# A genuinely non-bare main worktree has a .git entry at its root; a bare repo
# does not. Once core.bare=true is honoured, `worktree list` reports the main as
# "bare", so it cannot be the signal -- the .git entry is. Pin core.bare=false
# in the main worktree's own config.worktree only when the main is really
# non-bare, or `status` / `merge --ff-only` there break.
if [ -n "$main_wt" ] && [ -e "$main_wt/.git" ] \
   && [ "$(git -C "$wt" config --get core.bare 2>/dev/null)" = true ]; then
  git -C "$main_wt" config --worktree core.bare false
  cw="$(git -C "$wt" config --get core.worktree 2>/dev/null || true)"
  [ -n "$cw" ] && git -C "$main_wt" config --worktree core.worktree "$cw"
  echo "install-pre-push-hook: migrated core.bare=false into the main worktree ($main_wt) config.worktree"
fi

git -C "$wt" config --worktree core.hooksPath "$hooks_dir"
echo "install-pre-push-hook: $wt -> core.hooksPath=$hooks_dir (worktree-local)"

# Guard: this installer must NEVER leave core.worktree in the COMMON config -- it
# would point every worktree at one tree. It only ever writes core.worktree with
# --worktree (to the main worktree's own config.worktree), so a common
# core.worktree here would be a leak; remove it and warn rather than leave the
# shared tree poisoned. (The control test asserts the common config is untouched.)
if git config -f "$common/config" --get core.worktree >/dev/null 2>&1; then
  echo "install-pre-push-hook: WARNING the COMMON config has core.worktree -- removing it (it must never be common)" >&2
  git config -f "$common/config" --unset-all core.worktree 2>/dev/null || true
fi
