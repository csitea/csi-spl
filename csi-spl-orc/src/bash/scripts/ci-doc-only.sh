#!/usr/bin/env bash
#------------------------------------------------------------------------------
# ci-doc-only.sh <base-sha> <head-sha> - classify a push for workflow 10's
# express docs lane (owner, t1 a477c187, msgs 50a349f4 + 31e00aee: "a bypass
# lane for those purely doc changes", "integrated in the CICD").
#
# Prints ONE line on stdout, `doc_only=true` or `doc_only=false`, and the
# reason on stderr. Exits 0 with a verdict; any other exit is an error the
# caller must read as false.
#
# DOC-ONLY = every changed path in <base>..<head> is a *.md OUTSIDE
# csi-spl-wui/** and .github/** (the set workflow 32 publishes). By FILES,
# never by author. A rename counts both sides (--no-renames lists it as the
# old path deleted + the new one added), a deleted .md counts as a doc path.
#
# FAILS SAFE: anything it cannot prove is a code push (full gate):
#   - an empty or all-zero base (a new branch, a first push), or a base or
#     head git cannot read (a force-push past a commit the clone lacks);
#   - a base that is not an ancestor of the head (a force-push);
#   - a merge commit anywhere in the range;
#   - an empty diff, or a git error while listing it.
# Gate: csi-spl-iac/src/bash/tests/ci-doc-only.tst.sh.
#------------------------------------------------------------------------------
set -uo pipefail

verdict() {  # <true|false> <reason>
  echo "doc_only=$1"
  echo "ci-doc-only: doc_only=$1 - $2" >&2
  exit 0
}

base="${1:-}" head="${2:-}"
[[ -n "$head" ]] || verdict false "no head sha"
[[ -n "$base" && ! "$base" =~ ^0+$ ]] || verdict false "no base sha (new branch or first push)"
git cat-file -e "$base^{commit}" 2>/dev/null || verdict false "base $base is not readable here"
git cat-file -e "$head^{commit}" 2>/dev/null || verdict false "head $head is not readable here"
git merge-base --is-ancestor "$base" "$head" 2>/dev/null || verdict false "base is not an ancestor of head (force-push)"

merges=$(git rev-list --min-parents=2 "$base..$head" 2>/dev/null) || verdict false "git rev-list failed"
[[ -z "$merges" ]] || verdict false "a merge commit is in the range"

files=$(git diff --no-renames --name-only -z "$base" "$head" 2>/dev/null | tr '\0' '\n') \
  || verdict false "git diff failed"
[[ -n "$files" ]] || verdict false "empty diff"

n=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  n=$((n + 1))
  case "$f" in
    csi-spl-wui/* | .github/*) verdict false "$f is under csi-spl-wui/ or .github/" ;;
    *.md) ;;
    *) verdict false "$f is not a .md" ;;
  esac
done <<<"$files"
verdict true "$n .md path(s), none under csi-spl-wui/ or .github/"
