#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: WUI orc actions exist, point at csi-spl-wui, and do not bake a
#          product hostname (domain-single-source lives in csi-spl-iac).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

for a in wui-dev wui-build wui-test wui-up wui-down; do
  f="$PROJ_ROOT/src/bash/run/${a}.func.sh"
  [[ -f "$f" ]] && pass "$a action exists" || fail "missing $f"
done
grep -q 'csi-spl-wui' "$PROJ_ROOT/src/bash/run/wui-dev.func.sh" && pass "wui-dev uses csi-spl-wui" || fail "wui-dev path"
grep -q 'lde_compose up -d hub wui' "$PROJ_ROOT/src/bash/run/wui-up.func.sh" && pass "wui-up starts the wui compose service" || fail "wui-up compose"
grep -q 'docker-compose-wui.yaml' "$PROJ_ROOT/lib/bash/funcs/lde-cnf.func.sh" && pass "lde_compose includes docker-compose-wui.yaml (teardown covers it)" || fail "lde_compose misses the wui file"
grep -q 'pnpm generate' "$PROJ_ROOT/src/bash/run/wui-build.func.sh" && pass "wui-build generates static" || fail "wui-build generate"
grep -q 'pnpm test:unit' "$PROJ_ROOT/src/bash/run/wui-test.func.sh" && pass "wui-test runs unit tests" || fail "wui-test unit"
[[ -x "$PROJ_ROOT/src/bash/scripts/render-wui-firebase-json.sh" || -f "$PROJ_ROOT/src/bash/scripts/render-wui-firebase-json.sh" ]] \
  && pass "render-wui-firebase-json.sh exists" || fail "missing render script"
# spec 010 T016: the deployed Hosting config sends /api/v1/auth/** to the hub
# before the SPA fallback, which stays last
R="$PROJ_ROOT/src/bash/scripts/render-wui-firebase-json.sh"
auth_ln=$(grep -n '"/api/v1/auth/\*\*"' "$R" | head -1 | cut -d: -f1)
spa_ln=$(grep -n '"source": "\*\*", "destination"' "$R" | head -1 | cut -d: -f1)
[[ -n "$auth_ln" && -n "$spa_ln" && "$auth_ln" -lt "$spa_ln" ]] \
  && pass "render: /api/v1/auth/** rewrite precedes the SPA fallback" || fail "render: auth rewrite missing or after '**'"
[[ -f "$APP_ROOT/csi-spl-wui/package.json" ]] && pass "csi-spl-wui/package.json exists" || fail "missing WUI package.json"
grep -q '"@pinia/nuxt"' "$APP_ROOT/csi-spl-wui/package.json" && pass "WUI depends on Pinia" || fail "Pinia missing"
grep -q 'nuxt generate' "$APP_ROOT/csi-spl-wui/package.json" && pass "WUI has generate script" || fail "generate script"
# no shop pages in the WUI tree. The card vendor may be named ONLY by the
# copied card step (006 T021w) and its unit test: the allow-list and its
# CONTROLS live in csi-spl-api/src/bash/tests/no-payment-vendor-wui.tst.sh.
if grep -rqiE 'wordpress|recaptcha|add.to.basket' "$APP_ROOT/csi-spl-wui" \
     --exclude-dir=node_modules --exclude-dir=.nuxt --exclude-dir=.output 2>/dev/null ||
   grep -rqiE 'stripe' "$APP_ROOT/csi-spl-wui" --exclude-dir=node_modules --exclude-dir=.nuxt --exclude-dir=.output \
     --exclude=card-element.mjs --exclude=card-element.test.mjs 2>/dev/null ||
   ! bash "$APP_ROOT/csi-spl-api/src/bash/tests/no-payment-vendor-wui.tst.sh" >/dev/null 2>&1; then
  fail "WUI tree still mentions shop entities"
else
  pass "WUI tree has no shop entities"
fi
[[ -f "$APP_ROOT/csi-spl-cnf/csi-spl/lde.env.yaml" ]] \
  && grep -q 'host_port: 3000' "$APP_ROOT/csi-spl-cnf/csi-spl/lde.env.yaml" \
  && pass "lde WUI port is 3000" || fail "lde WUI port"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
