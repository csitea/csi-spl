#!/usr/bin/env bash
# graft-index-dir.sh — where a repo's graft index lives: OUTSIDE the repo.
#
#   graft-index-dir.sh [REPO]     print the index dir for REPO (default: the git
#                                 top level of the current directory); rc 1 when
#                                 there is no repo
#   . graft-index-dir.sh          (sourced) defines graft_var_root,
#                                 graft_index_root and graft_index_dir, runs nothing
#
# graft's default is <repo>/graft, a cache inside the working tree. A working
# tree holds the project's files and nothing else, so every index is written
# with graft's global `--dir` to
#
#   ${GRAFT_INDEX_ROOT:-$GRAFT_VAR_ROOT/index}/<slug>
#
# where <slug> is the repo's absolute path with the leading / dropped and every
# further / written as "__" (a repo at /a/b-c/d becomes a__b-c__d). The slug is
# derived, so two repos never share one, and the box names no repo anywhere.
#
# GRAFT_VAR_ROOT (default /var/csi/csi-spl/graft) is the box-wide graft state:
# the index, the repo list, the cron log and lock. It is box-wide, not per
# home, because one OS user builds the index and every agent user reads it.

graft_var_root() { printf '%s' "${GRAFT_VAR_ROOT:-/var/csi/csi-spl/graft}"; }

graft_index_root() {
  if [ -n "${GRAFT_INDEX_ROOT:-}" ]; then printf '%s' "$GRAFT_INDEX_ROOT"; return 0; fi
  printf '%s/index' "$(graft_var_root)"
}

graft_index_dir() {  # [REPO]
  local repo="${1:-}" root slug
  if [ -z "$repo" ]; then
    repo="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  fi
  repo="$(cd "$repo" 2>/dev/null && pwd -P)" || return 1
  root="$(graft_index_root)" && [ -n "$root" ] || return 1
  slug="${repo#/}"; slug="${slug//\//__}"
  [ -n "$slug" ] || return 1
  printf '%s/%s' "$root" "$slug"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  graft_index_dir "${1:-}"
fi
