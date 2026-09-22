#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the repo-root .version must equal hub.image.tag in EVERY env file.
#
#          Two different sources decide what a deployed hub says it is:
#          .version is baked into the binary by csi-spl-api/src/bash/build.sh
#          as `-X main.version` and is what GET /version reports as `version`;
#          hub.image.tag in csi-spl-cnf/csi-spl/<env>.env.yaml decides which
#          container image actually runs. Nothing kept them in step, so a
#          release that bumps the tag and forgets .version leaves the running
#          hub naming a release it is not.
#
#          This has now happened twice: 2e4c1ce ("realign .version with the
#          image tag", CLE-3436) and dd86875 (CLE-3443), which touched six of
#          the seven files 039c2df touched. Both times the drift was invisible
#          because no check compared the two, and both times someone verifying
#          a roll by "does it report the new version" would have concluded a
#          successful deploy had failed.
#
#          It runs in the 10 quality gate, which has NO paths: filter. That is
#          deliberate and is the point: a commit that bumps the tag and forgets
#          .version touches the cnf paths anyway, so a path filter would have
#          run this check and still let the drift through on a technicality of
#          which files changed. Every push, no exceptions.
#
#          CONTROLS: a guard that finds nothing proves nothing unless it is
#          shown to find something. Control 1 plants a mismatched .version in
#          a scratch tree and requires the check to name that env. Control 2
#          requires a missing/empty .version to FAIL rather than pass
#          vacuously by comparing two empty strings.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# parity <root> -> prints "<env> <tag> <version>" per MISMATCHED env; rc 2 when
# .version is absent or empty (a comparison against nothing is not a pass).
parity() {
  local root="$1" ver f env tag
  ver=$(tr -d '[:space:]' <"$root/.version" 2>/dev/null)
  [[ -n "$ver" ]] || return 2
  for f in "$root"/csi-spl-cnf/csi-spl/*.env.yaml; do
    [[ -f "$f" ]] || continue
    env=$(basename "$f" .env.yaml)
    [[ "$env" != "all" ]] || continue
    tag=$(yq -r '.env.hub.image.tag // ""' "$f" 2>/dev/null)
    # An env file that pins no tag inherits all.env.yaml; nothing to compare.
    [[ -n "$tag" && "$tag" != null ]] || continue
    [[ "$tag" == "$ver" ]] || echo "$env $tag $ver"
  done
}

command -v yq >/dev/null || { echo "SKIP: yq not installed"; exit 0; }

# ---- the real tree ----------------------------------------------------------
out=$(parity "$APP_ROOT"); rc=$?
if [[ $rc -eq 2 ]]; then
  fail "repo-root .version is missing or empty (build.sh bakes it as -X main.version)"
elif [[ -n "$out" ]]; then
  fail "hub.image.tag != .version; GET /version would name a release the image is not:"
  while read -r env tag ver; do
    [[ -n "$env" ]] && echo "      $env.env.yaml hub.image.tag=$tag  but .version=$ver"
  done <<<"$out"
else
  pass "every env's hub.image.tag equals the repo-root .version ($(tr -d '[:space:]' <"$APP_ROOT/.version"))"
fi

# ---- CONTROL 1: a planted mismatch is caught, and the env is named ----------
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/csi-spl-cnf/csi-spl"
cp "$APP_ROOT"/csi-spl-cnf/csi-spl/*.env.yaml "$scratch/csi-spl-cnf/csi-spl/" 2>/dev/null
printf '9.9.9\n' >"$scratch/.version"
planted=$(parity "$scratch")
if [[ -n "$planted" ]] && grep -q '^dev .* 9\.9\.9$' <<<"$planted" && grep -q '^prd .* 9\.9\.9$' <<<"$planted"; then
  pass "CONTROL: a planted .version=9.9.9 is caught and names dev and prd"
else
  fail "CONTROL: a planted mismatch was NOT caught (got: '$planted')"
fi

# ---- CONTROL 2: an empty .version fails, it does not pass vacuously ---------
printf '\n' >"$scratch/.version"
parity "$scratch" >/dev/null 2>&1
if [[ $? -eq 2 ]]; then
  pass "CONTROL: an empty .version is rc 2 (refused), not an empty-string match"
else
  fail "CONTROL: an empty .version did not fail"
fi

[[ "$fails" -eq 0 ]] && echo "PASS: all hub-version-tag-parity.tst.sh assertions"
exit "$fails"
