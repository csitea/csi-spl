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
# What it installs (CLE-77824): a COPY of hooks/pre-push-trampoline, which execs
# the pre-push hook of whichever worktree is pushing. It used to be a symlink
# into the shared checkout's working tree, and that checkout is fetch-only for
# every lane (often behind and dirty), so the whole fleet ran a stale hook.
# The trampoline is taken from THIS script's tree, so running the installer
# from an up-to-date worktree installs the current one. Idempotent.
#
# Usage: install-pre-push-hook.sh <checkout-dir>
# Exit: 0 installed/already, 2 usage / not a worktree, 1 no hook payload found.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

wt="${1:-}"
[ -n "$wt" ] || { echo "usage: install-pre-push-hook.sh <checkout-dir>" >&2; exit 2; }
git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "install-pre-push-hook: $wt is not a git worktree" >&2; exit 2; }

# The common git dir, shared by every linked worktree.
common="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
  || common="$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null)"
case "$common" in
  /*) ;;
  *)  common="$(cd "$wt" && cd "$common" && pwd)" ;;
esac
src="$here/../hooks/pre-push-trampoline"

[ -r "$src" ] \
  || { echo "install-pre-push-hook: no trampoline at $src" >&2; exit 1; }

mkdir -p "$common/hooks" 2>/dev/null || true
dest="$common/hooks/pre-push"
# Replace atomically; rm first so a symlink's TARGET is never written through.
tmp="$dest.tmp.$$"
cp "$src" "$tmp" && chmod 0755 "$tmp" && rm -f "$dest" && mv -f "$tmp" "$dest" \
  || { rm -f "$tmp"; echo "install-pre-push-hook: could not install $dest" >&2; exit 1; }
echo "install-pre-push-hook: $dest <- $src (trampoline into the pushing worktree's hook; gates every worktree, no git config)"
