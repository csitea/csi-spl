#!/usr/bin/env bash
# retrofit-pre-push-hooks.sh (SPL-1252) — install the deploy-gate pre-push hook
# into every EXISTING agent worktree under <repo>-wt/, in isolation
# (per-worktree core.hooksPath via install-pre-push-hook.sh).
#
# It writes ONLY each worktree's config.worktree; it never touches working
# files, the index, the branch or HEAD, so it does not disturb work in progress.
# The shared checkout (the main worktree) is skipped: agents never push from it,
# they fast-forward it, so gating it would only get in the way. Idempotent.
#
# Usage: retrofit-pre-push-hooks.sh [<repo>]   (default: this checkout's repo)
# Exit: 0 always (per-worktree failures are reported, not fatal).
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

repo="${1:-}"
[ -n "$repo" ] || repo="$(git -C "$here" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$repo" ] || { echo "retrofit-pre-push-hooks: no git repo (pass one)" >&2; exit 2; }

# The main worktree (shared checkout) is the one whose path is the common dir's
# parent; everything else under <repo>-wt/ is an agent worktree.
common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
  || common="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null)"
main="$(cd "$(dirname "$common")" && pwd)"

installed=0 skipped=0 failed=0
while IFS= read -r line; do
  case "$line" in worktree\ *) wt="${line#worktree }" ;; *) continue ;; esac
  if [ "$wt" = "$main" ]; then
    echo "skip (shared checkout): $wt"; skipped=$((skipped + 1)); continue
  fi
  if bash "$here/install-pre-push-hook.sh" "$wt" >/dev/null 2>&1; then
    echo "installed: $wt"; installed=$((installed + 1))
  else
    echo "FAILED:    $wt"; failed=$((failed + 1))
  fi
done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)

echo "retrofit-pre-push-hooks: $installed installed, $skipped skipped, $failed failed"
exit 0
