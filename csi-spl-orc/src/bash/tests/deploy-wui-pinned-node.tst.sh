#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: Test that do_deploy_wui uses the pinned node version for firebase-tools.
#   1. FIREBASE_NODE_VERSION is documented in the header.
#   2. FIREBASE_NODE_VERSION is used in the function.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
orc_stub 0 pnpm

# --- 1. FIREBASE_NODE_VERSION is documented ----------------------------------------------
grep -q "@param FIREBASE_NODE_VERSION (optional)" "$PROJ_ROOT/src/bash/run/deploy-wui.func.sh" \
  && pass "1. FIREBASE_NODE_VERSION is documented" || fail "1. FIREBASE_NODE_VERSION is not documented"

# --- 2. FIREBASE_NODE_VERSION is used in the function -------------------------------------
grep -q "FIREBASE_NODE_VERSION" "$PROJ_ROOT/src/bash/run/deploy-wui.func.sh" \
  && pass "2. FIREBASE_NODE_VERSION is used in the function" || fail "2. FIREBASE_NODE_VERSION is not used in the function"

if [[ $fails -eq 0 ]]; then echo "ALL PASS"; else echo "$fails FAIL(S)"; exit 1; fi
