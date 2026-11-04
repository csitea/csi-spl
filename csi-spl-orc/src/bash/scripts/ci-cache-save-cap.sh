#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: decide whether a CI cache directory is small enough to save
# (SPL-4790). The hub-pg Go race cache of wf 10 grew to 6.26 GiB compressed
# (2026-11-04, `gh cache list`), 63% of the repo's 10 GB cache store, and its
# restore filled the hosted runner's disk. SPL-4777 trims it to what a run
# used (2.1 G uncompressed, 405 MB compressed on run 41813241775); this cap
# is the backstop: above CI_CACHE_SAVE_MAX_MB the save is skipped with one
# ::warning:: line, so an oversize entry is never written, and the job stays
# green (a skipped save costs the next run a cold build, not a red).
#
# Usage: ci-cache-save-cap.sh <dir>
# Env:   CI_CACHE_SAVE_MAX_MB (required, whole MB: wf 10 states it in its env)
#        GITHUB_OUTPUT        when set, `mb=<n>` and `save=true|false` go to it
# Out:   the same `mb=<n>` and `save=true|false` lines on stdout.
# Exit:  0 a decision was made (either way); 2 usage.
#------------------------------------------------------------------------------
set -uo pipefail

max="${CI_CACHE_SAVE_MAX_MB:-}"
dir="${1:-}"
[[ "$max" =~ ^[0-9]+$ && -n "$dir" ]] || { echo "usage: CI_CACHE_SAVE_MAX_MB=<whole MB> $0 <dir> (got max='$max' dir='$dir')" >&2; exit 2; }

out() {
  echo "$1"
  [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "$1" >>"$GITHUB_OUTPUT"
  return 0
}

mb=""
[[ -d "$dir" ]] && mb=$(du -sm "$dir" 2>/dev/null | awk '{print $1}')
if ! [[ "$mb" =~ ^[0-9]+$ ]]; then
  echo "::warning::cache save skipped: cannot measure $dir"
  out "mb=0"
  out "save=false"
  exit 0
fi
out "mb=$mb"
if ((mb > max)); then
  echo "::warning::cache save skipped: $dir is ${mb} MB > cap ${max} MB (CI_CACHE_SAVE_MAX_MB)"
  out "save=false"
else
  echo "ok - cache $dir is ${mb} MB <= cap ${max} MB: saved"
  out "save=true"
fi
exit 0
