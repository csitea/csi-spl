#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: workflow 20's "Mint the release version" step ships the release KEY
#          as the hub image tag (orchestrator decision, owner topic on the
#          9.9.9 -> 1.0.1 wrap): do_release_version writes version=<X.Y.Z> and
#          key=<key> to GITHUB_OUTPUT; the step tags the image with the key.
#   1. cycle 1: key 8.4.1 = version 8.4.1 -> image :8.4.1 (unchanged today)
#   2. cycle 2: key 1.0.1-c2, version 1.0.1 -> image :1.0.1-c2, and
#      SPL_HUB_IMAGE_TAG=1.0.1-c2 for build + push and do_check_hub_deploy
#   3. a key that does not belong to the version, or no key -> the step fails
#   4. the prebuilt copy is looked up by the plain version it baked
# The step's REAL script is read out of the workflow with yq and run against a
# stub ./csi-spl-orc/run, so a drift in the workflow fails here.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
wf="$APP_ROOT/.github/workflows/20_hub-build-deploy.yml"
command -v yq >/dev/null || { echo "SKIP: no yq"; exit 0; }

yq -r '.jobs[].steps[] | select(.name == "Mint the release version (do_release_version)") | .run' "$wf" >"$T/mint.sh"
[[ -s "$T/mint.sh" ]] || { fail "no mint step in $wf"; exit 1; }

# stub mint: writes what do_release_version DRY_RUN=0 writes
mkdir -p "$T/w/csi-spl-orc"
cat >"$T/w/csi-spl-orc/run" <<'SH'
#!/bin/sh
[ -n "$STUB_VERSION" ] && echo "version=$STUB_VERSION" >>"$GITHUB_OUTPUT"
[ -n "$STUB_KEY" ] && echo "key=$STUB_KEY" >>"$GITHUB_OUTPUT"
echo "$STUB_VERSION"
SH
chmod +x "$T/w/csi-spl-orc/run"

mint() { # <version> <key> -> rc; $T/out, $T/env
  : >"$T/out"; : >"$T/env"
  (cd "$T/w" && env GITHUB_OUTPUT="$T/out" GITHUB_ENV="$T/env" GITHUB_SHA=0123456789abcdef \
    CNF_REF=registry.example.com/p/r/spool-hub:8.4.0 GUARD_EVENT=push FIRST_ENV=dev ENV=dev \
    STUB_VERSION="$1" STUB_KEY="$2" bash "$T/mint.sh" >"$T/log" 2>&1)
}

mint 8.4.1 8.4.1; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'image_ref=registry.example.com/p/r/spool-hub:8.4.1' "$T/out" && grep -qx 'SPL_HUB_IMAGE_TAG=8.4.1' "$T/env" \
  && pass "cycle 1: image tag = plain version 8.4.1" || fail "cycle 1: rc=$rc $(cat "$T/out" "$T/env" "$T/log")"

mint 1.0.1 1.0.1-c2; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'image_ref=registry.example.com/p/r/spool-hub:1.0.1-c2' "$T/out" && grep -qx 'SPL_HUB_IMAGE_TAG=1.0.1-c2' "$T/env" \
  && grep -qx 'version=1.0.1' "$T/out" \
  && pass "cycle 2: image tag = key 1.0.1-c2, version output stays 1.0.1" || fail "cycle 2: rc=$rc $(cat "$T/out" "$T/env" "$T/log")"

mint 1.0.1 1.0.2-c2; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^image_ref=' "$T/out" && pass "a key of another version fails the step (rc $rc)" || fail "mismatched key: rc=$rc $(cat "$T/out")"

mint 1.0.1 ""; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^image_ref=' "$T/out" && pass "no key fails the step (rc $rc)" || fail "no key: rc=$rc $(cat "$T/out")"

# 4: the deploy's prebuilt lookup reads the plain version, not the image tag
img_step="$(yq -r '.jobs[].steps[] | select(.name == "Is the image already in the registry?") | .run' "$wf")"
[[ "$img_step" == *'pre="${IMAGE_REF%:*}:ci-${GITHUB_SHA}-v${VERSION}"'* ]] \
  && pass "prebuilt copy is looked up as ci-<sha>-v<plain version>" || fail "prebuilt lookup does not use the plain version"

[[ $fails -eq 0 ]] && echo "PASS: all hub-image-key-wf20 assertions" || { echo "FAILED: $fails"; exit 1; }
