#!/usr/bin/env bash
# graft-index-update.sh — re-index the box's repos into their out-of-tree index.
#
#   graft-index-update.sh                 every repo in the box repo list
#   graft-index-update.sh <repo>...       exactly these repos
#
# The repo list: GRAFT_REGISTRY, else $GRAFT_VAR_ROOT/repos.list
# (graft-common.inc.sh). Re-asserts the safety wrapper and the language layer
# first - a graft reinstall silently reverts both. Skips a repo whose
# git-visible content, graft code and layer are unchanged since its last
# successful build; GRAFT_INDEX_FORCE=1 rebuilds anyway.
#
# Exit 0 done, 11 a FATAL (no graft, no repo list), else the failing build's rc.

set -uo pipefail

do_log() { printf '%s\n' "$*"; }
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/graft-common.inc.sh"

graft_index_update() {
  local bin repos repo rv=0 n=0 skipped=0 stamp t0
  for repo in "$@"; do
    case "$repo" in --*) do_log "FATAL unknown flag '$repo' - this takes repo paths only"; return 11 ;; esac
  done
  bin="$(_graft_bin)" || return 11

  repos="$*"
  if [ -z "${repos// /}" ]; then
    _graft_registry_resolve
    [ -r "$GRAFT_REGISTRY" ] || {
      do_log "FATAL no repos given and no repo list at $GRAFT_REGISTRY (source: $GRAFT_REGISTRY_SRC)"
      do_log "FATAL create it (one absolute repo path per line), or pass repo paths"
      return 11
    }
    repos="$(_graft_registry_repos "$GRAFT_REGISTRY" | tr '\n' ' ')"
    do_log "INFO  repo list $GRAFT_REGISTRY (source: $GRAFT_REGISTRY_SRC): ${repos% }"
  else
    do_log "INFO  repo list: explicit arguments: $repos"
  fi

  # A reinstall silently reverts the extension layer, so assert it every time
  # rather than trusting that the last install still holds. Idempotent.
  _graft_apply_safe_wrapper
  _graft_apply_langs
  rv=$?
  [ $rv -eq 0 ] || return $rv

  for repo in $repos; do
    if [ ! -d "$repo/.git" ] && [ ! -f "$repo/.git" ]; then do_log "WARN  skipping '$repo' - not a git repo"; continue; fi
    _graft_purge_if_stale "$repo" || return 11
    # Taken BEFORE the build: an edit landing mid-build moves the stamp, so the
    # next run rebuilds rather than trusting an index that may predate it.
    stamp="$(_graft_source_stamp "$repo")" || stamp=""
    if [ "${GRAFT_INDEX_FORCE:-0}" != 1 ] && _graft_index_current "$repo" "$stamp"; then
      do_log "INFO  unchanged since the last build - skipping $repo (GRAFT_INDEX_FORCE=1 rebuilds)"
      skipped=$((skipped + 1))
      continue
    fi
    do_log "INFO  re-indexing $repo"
    t0=$SECONDS
    _graft_build_repo "$bin" "$repo"
    rv=$?
    if [ $rv -ne 0 ]; then do_log "ERROR graft build FAILED in $repo (rv=$rv)"; return $rv; fi
    _graft_stamp_layer "$repo"
    _graft_record_source_stamp "$repo" "$stamp"
    do_log "INFO  re-indexed $repo in $((SECONDS - t0))s"
    n=$((n + 1))
  done
  do_log "OK    re-indexed $n repo(s), $skipped unchanged and skipped"
  return 0
}

graft_index_update "$@"
