#!/usr/bin/env bash
#------------------------------------------------------------------------------
# sec-deps-scope.sh <base-sha> <head-sha> - do the DEPENDENCY legs of workflow
# 15 (govulncheck, pnpm audit, trivy) have to run for <head>?
#
# Prints ONE line on stdout, `deps=true` or `deps=false`, and the reason on
# stderr. Exits 0 with a verdict; any other exit is an error the caller must
# read as true.
#
# <base> is the head sha of the last SUCCESSFUL run of workflow 15 on the ref,
# never github.event.before: the concurrency group cancels a superseded run,
# so `before` may be a deps push whose scan never ran (c81ef0110, the
# govulncheck bump, superseded 42 s later by e3d3ec2a5 whose run diffed only
# its own push and read deps=false, 2026-10-10). Diffing from the last green
# run, every deps change since the last scan that passed is in the range.
#
# deps=true when any path in <base>..<head> is a dependency input:
#   go.mod / go.sum of the hub module, the WUI LOCKFILE (not package.json: it
#   changes ~18x/day for e2e script lists, and a dependency edit without its
#   lock already fails pnpm install --frozen-lockfile), a Dockerfile,
#   terraform, .trivyignore.yaml, or the scan itself (sec-scan.func.sh,
#   workflow 15, this script).
#
# FAILS SAFE: anything it cannot prove is deps=true (every leg runs):
#   - an empty or all-zero base (no green run found, the API failed), or a
#     base or head git cannot read;
#   - a base that is not an ancestor of the head (a force-push);
#   - a git error while listing the diff.
# Gate: csi-spl-iac/src/bash/tests/sec-deps-scope.tst.sh.
#------------------------------------------------------------------------------
set -uo pipefail

verdict() {  # <true|false> <reason>
  echo "deps=$1"
  echo "sec-deps-scope: deps=$1 - $2" >&2
  exit 0
}

base="${1:-}" head="${2:-}"
[[ -n "$head" ]] || verdict true "no head sha"
[[ -n "$base" && ! "$base" =~ ^0+$ ]] || verdict true "no base sha (no green run found)"
git cat-file -e "$base^{commit}" 2>/dev/null || verdict true "base $base is not readable here"
git cat-file -e "$head^{commit}" 2>/dev/null || verdict true "head $head is not readable here"
git merge-base --is-ancestor "$base" "$head" 2>/dev/null || verdict true "base is not an ancestor of head (force-push)"

files=$(git diff --no-renames --name-only -z "$base" "$head" 2>/dev/null | tr '\0' '\n') \
  || verdict true "git diff failed"

n=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  n=$((n + 1))
  case "$f" in
    csi-spl-api/src/go/spool-hub-api/go.mod | csi-spl-api/src/go/spool-hub-api/go.sum | \
      csi-spl-wui/pnpm-lock.yaml | \
      */Dockerfile | Dockerfile | */Dockerfile.* | *.dockerfile | \
      csi-spl-iac/src/terraform/* | .trivyignore.yaml | \
      csi-spl-iac/src/bash/run/sec-scan.func.sh | .github/workflows/15_sec-deps-secrets.yml | \
      csi-spl-iac/src/bash/scripts/sec-deps-scope.sh)
      verdict true "$f changed since ${base:0:12}" ;;
  esac
done <<<"$files"
verdict false "$n path(s) since ${base:0:12}, no dependency input"
