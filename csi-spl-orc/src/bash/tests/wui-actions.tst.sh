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
auth_ln=$(grep -n '"/api/v1/auth/\*\*"' "$R" | sed -n 1p | cut -d: -f1)
spa_ln=$(grep -n '"source": "\*\*", "destination"' "$R" | sed -n 1p | cut -d: -f1)
[[ -n "$auth_ln" && -n "$spa_ln" && "$auth_ln" -lt "$spa_ln" ]] \
  && pass "render: /api/v1/auth/** rewrite precedes the SPA fallback" || fail "render: auth rewrite missing or after '**'"
# SPL-1688: LinkedIn's OAuth callback lands on the WUI host and must reach the hub
li_ln=$(grep -n '"/api/v1/marketing/linkedin/callback"' "$R" | sed -n 1p | cut -d: -f1)
[[ -n "$li_ln" && -n "$spa_ln" && "$li_ln" -lt "$spa_ln" ]] \
  && pass "render: linkedin callback rewrite precedes the SPA fallback" || fail "render: linkedin callback rewrite missing or after '**'"
# spec 090 T030 (SPL-4164): the Meta connect callback, same shape as LinkedIn's
fb_ln=$(grep -n '"/api/v1/marketing/facebook/callback"' "$R" | sed -n 1p | cut -d: -f1)
[[ -n "$fb_ln" && -n "$spa_ln" && "$fb_ln" -lt "$spa_ln" ]] \
  && pass "render: facebook callback rewrite precedes the SPA fallback" || fail "render: facebook callback rewrite missing or after '**'"
# spec 090 X row (SPL-5194): the X connect callback, same shape
x_ln=$(grep -n '"/api/v1/marketing/x/callback"' "$R" | sed -n 1p | cut -d: -f1)
[[ -n "$x_ln" && -n "$spa_ln" && "$x_ln" -lt "$spa_ln" ]] \
  && pass "render: x callback rewrite precedes the SPA fallback" || fail "render: x callback rewrite missing or after '**'"
# spec 090 T041 (SPL-5258): the LinkedIn Company Page connect callback, same shape
lo_ln=$(grep -n '"/api/v1/marketing/linkedin-org/callback"' "$R" | sed -n 1p | cut -d: -f1)
[[ -n "$lo_ln" && -n "$spa_ln" && "$lo_ln" -lt "$spa_ln" ]] \
  && pass "render: linkedin-org callback rewrite precedes the SPA fallback" || fail "render: linkedin-org callback rewrite missing or after '**'"
[[ -f "$APP_ROOT/csi-spl-wui/package.json" ]] && pass "csi-spl-wui/package.json exists" || fail "missing WUI package.json"
grep -q '"@pinia/nuxt"' "$APP_ROOT/csi-spl-wui/package.json" && pass "WUI depends on Pinia" || fail "Pinia missing"
grep -q 'nuxt generate' "$APP_ROOT/csi-spl-wui/package.json" && pass "WUI has generate script" || fail "generate script"
# no shop pages in the WUI tree. The card vendor may be named ONLY by the
# copied card step (006 T021w) and its unit test: the allow-list and its
# CONTROLS live in csi-spl-api/src/bash/tests/no-payment-vendor-wui.tst.sh.
# `.output*` also skips `.output.ppe-keep`, the bundle the pre-push wui-e2e
# part parks there while this suite may scan the same tree.
if grep -rqiE 'wordpress|recaptcha|add.to.basket' "$APP_ROOT/csi-spl-wui" \
     --exclude-dir=node_modules --exclude-dir=.nuxt --exclude-dir='.output*' 2>/dev/null ||
   grep -rqiE 'stripe' "$APP_ROOT/csi-spl-wui" --exclude-dir=node_modules --exclude-dir=.nuxt --exclude-dir='.output*' \
     --exclude=card-element.mjs --exclude=card-element.test.mjs 2>/dev/null ||
   ! bash "$APP_ROOT/csi-spl-api/src/bash/tests/no-payment-vendor-wui.tst.sh" >/dev/null 2>&1; then
  fail "WUI tree still mentions shop entities"
else
  pass "WUI tree has no shop entities"
fi
[[ -f "$APP_ROOT/csi-spl-cnf/csi-spl/lde.env.yaml" ]] \
  && grep -q 'host_port: 3000' "$APP_ROOT/csi-spl-cnf/csi-spl/lde.env.yaml" \
  && pass "lde WUI port is 3000" || fail "lde WUI port"

# do_wui_up readiness loop: LDE_WUI_READY_TIMEOUT tries, one curl each. A
# non-integer means 0 tries then FATAL (as `seq 1 abc` did), never a set -u
# abort. Everything outside the loop is stubbed; curl never answers 200.
wui_ready_tries() {
  local work rc
  work=$(mktemp -d)
  mkdir -p "$work/wui/node_modules/nuxt/bin" && : >"$work/wui/node_modules/nuxt/bin/nuxt.mjs"
  : >"$work/curls"
  (
    set -u
    do_require_bin() { :; }
    do_gen_docker_env() { :; }
    do_log() { echo "$*" >>"$work/log"; }
    docker() { :; }
    ss() { :; }
    lde_compose() { :; }
    sleep() { :; }
    curl() { echo x >>"$work/curls"; printf '000'; }
    export LDE_WUI_SRC="$work/wui" LDE_HUB_IMAGE=img LDE_WUI_UID=1000 LDE_COMPOSE_PROJECT=p \
      LDE_WUI_PORT=3999 LDE_WUI_IMAGE=img LDE_SMOKE_TENANT=t LDE_HUB_PORT=1 \
      LDE_WUI_READY_TIMEOUT="$1"
    # shellcheck disable=SC1091
    source "$PROJ_ROOT/src/bash/run/wui-up.func.sh"
    do_wui_up
  ) 2>/dev/null
  rc=$?
  echo "$rc $(wc -l <"$work/curls") $(grep -c '^FATAL GET ' "$work/log" 2>/dev/null)"
  rm -rf "$work"
}
read -r rc curls fatal < <(wui_ready_tries abc)
[[ "$rc" != 0 && "$curls" == 0 && "$fatal" == 1 ]] \
  && pass "wui-up: LDE_WUI_READY_TIMEOUT=abc -> 0 tries, FATAL GET" \
  || fail "wui-up: timeout abc: want rc!=0 / 0 curls / 1 FATAL, got $rc / $curls / $fatal"
read -r rc curls fatal < <(wui_ready_tries 3)
[[ "$rc" != 0 && "$curls" == 3 && "$fatal" == 1 ]] \
  && pass "wui-up: LDE_WUI_READY_TIMEOUT=3 -> exactly 3 tries, FATAL GET" \
  || fail "wui-up: timeout 3: want rc!=0 / 3 curls / 1 FATAL, got $rc / $curls / $fatal"

# _lde_cnf_wui_image picks the image: the caller's value, else cnf, else the
# host's Node major, else 20. $1 = caller's value, $2 = cnf's, $3 = what the
# stub node prints (empty: it prints nothing and fails).
wui_image() {
  local bin
  bin=$(mktemp -d)
  if [[ -n "$3" ]]; then
    printf '#!/bin/sh\necho %s\n' "$3" >"$bin/node"
  else
    printf '#!/bin/sh\nexit 1\n' >"$bin/node"
  fi
  chmod +x "$bin/node"
  (
    set -u
    # shellcheck disable=SC1091
    source "$PROJ_ROOT/lib/bash/funcs/lde-cnf.func.sh"
    _lde_get() { echo "$CNF_IMAGE"; }
    PATH="$bin:$PATH" CNF_IMAGE="$2" LDE_WUI_IMAGE="$1"
    _lde_cnf_wui_image
    echo "$LDE_WUI_IMAGE"
  )
  rm -rf "$bin"
}
check_wui_image() {
  local got
  got=$(wui_image "$2" "$3" "$4")
  [[ "$got" == "$5" ]] && pass "lde wui image: $1 -> $5" || fail "lde wui image: $1: want $5, got $got"
}
check_wui_image "the caller's value wins" caller-img cnf-img 99 caller-img
check_wui_image "cnf wins over node" "" cnf-img 99 cnf-img
check_wui_image "no cnf: the host's Node major" "" "" 99 node:99-bookworm-slim
check_wui_image "no cnf, node fails: 20" "" "" "" node:20-bookworm-slim

# _wui_prepare helper and one-copy delegation across wui-{dev,build,test} (r09-02)
WUI_T=$(mktemp -d)
trap 'rm -rf "$WUI_T"' EXIT
wui_prep_run() {
  local app="$1" bin_rc="${2:-0}"
  APP_PATH="$app" WUI_BIN_RC="$bin_rc" bash -c '
    set -uo pipefail
    do_require_bin() { echo "REQ:$*"; return "$WUI_BIN_RC"; }
    do_log() { echo "$*"; }
    pnpm() { echo "PNPM:$PWD:$*"; }
    WUI_DIR=""
    . "$1/src/bash/run/wui-dev.func.sh"
    _wui_prepare || exit $?
    echo "DIR:$WUI_DIR"' _ "$PROJ_ROOT" 2>&1
}
out="$(wui_prep_run "$WUI_T/missing-app" 0)"; rc=$?
[[ "$rc" = 1 && "$out" == *"FATAL missing $WUI_T/missing-app/csi-spl-wui"* ]] \
  && pass "wui-prepare: refuses missing csi-spl-wui dir" || fail "wui-prepare missing ($rc: $out)"
mkdir -p "$WUI_T/no-nm/csi-spl-wui"
out="$(wui_prep_run "$WUI_T/no-nm" 0)"; rc=$?
[[ "$rc" = 0 && "$out" == *"INFO pnpm install in $WUI_T/no-nm/csi-spl-wui"* && "$out" == *"PNPM:$WUI_T/no-nm/csi-spl-wui:install"* && "$out" == *"DIR:$WUI_T/no-nm/csi-spl-wui"* ]] \
  && pass "wui-prepare: installs when node_modules is absent and sets WUI_DIR" || fail "wui-prepare no-nm ($rc: $out)"
mkdir -p "$WUI_T/has-nm/csi-spl-wui/node_modules"
out="$(wui_prep_run "$WUI_T/has-nm" 0)"; rc=$?
[[ "$rc" = 0 && "$out" != *"PNPM:"* && "$out" == *"DIR:$WUI_T/has-nm/csi-spl-wui"* ]] \
  && pass "wui-prepare: skips pnpm install when node_modules exists" || fail "wui-prepare has-nm ($rc: $out)"
out="$(wui_prep_run "$WUI_T/has-nm" 1)"; rc=$?
[[ "$rc" = 1 && "$out" == *"REQ:pnpm"* && "$out" != *"DIR:"* ]] \
  && pass "wui-prepare: fails fast when pnpm is missing" || fail "wui-prepare no-pnpm ($rc: $out)"

wui_host="$PROJ_ROOT/src/bash/run/wui-dev.func.sh"
[[ "$(grep -c '&& pnpm install )' "$wui_host")" -eq 1 ]] && grep -q '^_wui_prepare()' "$wui_host" \
  && pass "one copy: wui-dev.func.sh hosts _wui_prepare" || fail "one copy: wui-dev host"
for wf in wui-build.func.sh wui-test.func.sh; do
  wfp="$PROJ_ROOT/src/bash/run/$wf"
  own="$(grep -nE 'pnpm install|FATAL missing' "$wfp" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  [[ -z "$own" ]] && grep -q '_wui_prepare ' "$wfp" \
    && pass "one copy: $wf delegates WUI preamble to _wui_prepare" \
    || fail "one copy $wf: own=[$own]"
done

mkdir -p "$WUI_T/st-dev/csi-spl-wui" "$WUI_T/st-build/csi-spl-wui" "$WUI_T/st-test/csi-spl-wui/node_modules"
out="$(APP_PATH="$WUI_T/st-dev" bash -c '
  set -uo pipefail
  do_lde_cnf() { LDE_HUB_PORT=8080; LDE_WUI_PORT=3123; }
  do_require_bin() { :; }; do_log() { echo "$*"; }
  pnpm() { echo "PNPM:$PWD:$*"; }
  . "$1/src/bash/run/wui-dev.func.sh" && do_wui_dev' _ "$PROJ_ROOT" 2>&1)"; rc=$?
[[ "$rc" = 0 && "$out" == *"PNPM:$WUI_T/st-dev/csi-spl-wui:install"* && "$out" == *"PNPM:$WUI_T/st-dev/csi-spl-wui:dev --host 0.0.0.0 --port 3123"* ]] \
  && pass "standalone: do_wui_dev installs and starts dev server" || fail "standalone wui-dev ($rc: $out)"
out="$(APP_PATH="$WUI_T/st-dev" bash -c '
  set -uo pipefail
  do_lde_cnf() { return 1; }
  do_require_bin() { echo "REQ:$*"; }; do_log() { echo "$*"; }
  pnpm() { echo "PNPM:$PWD:$*"; }
  . "$1/src/bash/run/wui-dev.func.sh" && do_wui_dev' _ "$PROJ_ROOT" 2>&1)"; rc=$?
[[ "$rc" = 1 && "$out" != *"REQ:pnpm"* && "$out" != *"PNPM:"* ]] \
  && pass "standalone: do_wui_dev runs do_lde_cnf before _wui_prepare" || fail "standalone wui-dev order ($rc: $out)"
out="$(APP_PATH="$WUI_T/st-build" bash -c '
  set -uo pipefail
  do_require_bin() { :; }; do_log() { echo "$*"; }
  pnpm() { echo "PNPM:$PWD:$*"; [[ "$1" == generate ]] && mkdir -p .output/public || true; }
  . "$1/src/bash/run/wui-build.func.sh" && do_wui_build' _ "$PROJ_ROOT" 2>&1)"; rc=$?
[[ "$rc" = 0 && "$out" == *"PNPM:$WUI_T/st-build/csi-spl-wui:install"* && "$out" == *"PNPM:$WUI_T/st-build/csi-spl-wui:generate"* && "$out" == *"INFO generated $WUI_T/st-build/csi-spl-wui/.output/public"* ]] \
  && pass "standalone: do_wui_build installs, generates, and logs output dir" || fail "standalone wui-build ($rc: $out)"
out="$(APP_PATH="$WUI_T/st-test" bash -c '
  set -uo pipefail
  do_require_bin() { :; }; do_log() { echo "$*"; }
  pnpm() { echo "PNPM:$PWD:$*"; }
  . "$1/src/bash/run/wui-test.func.sh" && do_wui_test' _ "$PROJ_ROOT" 2>&1)"; rc=$?
[[ "$rc" = 0 && "$out" != *":install"* && "$out" == *"PNPM:$WUI_T/st-test/csi-spl-wui:test:unit"* && "$out" == *"PNPM:$WUI_T/st-test/csi-spl-wui:typecheck"* ]] \
  && pass "standalone: do_wui_test skips install and runs test:unit + typecheck" || fail "standalone wui-test ($rc: $out)"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
