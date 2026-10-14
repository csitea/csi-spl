#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the forward-only decision of workflow 30's deploy job (SPL-1829):
#          never put an OLDER commit on a site than the one it serves.
#
# The deploy job is serialised per env (concurrency, cancel-in-progress
# false), but the lock is taken in the order the jobs reach it, not in commit
# order: an older run whose plan ended later, or whose suite wait was
# shorter, can deploy after a newer one and roll the site back. csi-web did
# exactly that on 2026-10-14 (9a001f1 over 240c6cf, cards hidden ~1 h).
# Workflow 20 has its own guard (hub-deploy-guard.sh, against /version); this
# is the WUI one, against the site's build.json.
#
# Stand down only when SHA is a strict ancestor of SERVED. The same commit (a
# re-run), a newer or sibling commit, or a served commit that is unreadable or
# unknown to this clone all deploy: the guard never blocks a forward deploy.
#
# Usage: wui-deploy-guard.sh decide  -> "deploy|stand-down <why>";
#                                       exit 0 deploy, 10 stand down, 2 bad input
# Env:
#   APP_PATH - optional: the repo root (default: the git top level of $PWD)
#   SHA      - required: the commit this run would deploy
#   SERVED   - optional: build.json .commit the site serves now, "" if unread
#------------------------------------------------------------------------------
set -uo pipefail

app="${APP_PATH:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[[ -n "$app" && -d "$app" ]] || { echo "::error::APP_PATH is not a repo"; exit 2; }

is_commit() { git -C "$app" cat-file -e "$1^{commit}" 2>/dev/null; }

decide() {
  local sha="${SHA:-}" served="${SERVED:-}"
  is_commit "$sha" || { echo "::error::SHA '$sha' is not a commit"; return 2; }
  sha="$(git -C "$app" rev-parse "$sha^{commit}")"
  if ! [[ "$served" =~ ^[0-9a-f]{40}$ ]] || ! is_commit "$served"; then
    echo "deploy ${sha:0:8} (the served commit '${served:0:12}' is unknown: no rollback check)"
    return 0
  fi
  if [[ "$served" == "$sha" ]]; then
    echo "deploy ${sha:0:8} (already served: a re-run)"
    return 0
  fi
  if git -C "$app" merge-base --is-ancestor "$sha" "$served"; then
    echo "stand-down ${sha:0:8} is older than the served ${served:0:8}: deploying it would roll the site back"
    return 10
  fi
  echo "deploy ${sha:0:8} (not older than the served ${served:0:8})"
  return 0
}

case "${1:-}" in
  decide) decide ;;
  *) echo "usage: $0 decide"; exit 2 ;;
esac
