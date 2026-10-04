#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_box_update with stub steps (do_spl_spool_refresh,
# do_spl_box_deploy), a scripted deploy-lag verdict and a gh stub, on a
# throwaway checkout with a local bare origin. Every check has a control.
#   1. at trunk, nothing lags: refresh + deploy run (DRY_RUN passed, deploy
#      in update mode: keep installed lines, add none, start no desk), no gh
#   2. a lagging hub, gate green: 20 is dispatched once (environment=all);
#      the dry run only plans it
#   3. a red gate on trunk: nothing dispatched, the newest green sha named
#   4. a run in flight: skipped; the last run failed: not dispatched, rc 1
#   5. master moved since the fetch: not dispatched
#   6. fetch: a checkout behind trunk is fast-forwarded (DRY_RUN=0 only);
#      one not on master is refused
#   7. a failing step: the later steps still run, and the run exits non-zero
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

g() { git -c user.name=t -c user.email=t@example.com "$@"; }
git init -q --bare -b master "$T/origin.git"
git clone -q "$T/origin.git" "$T/app" 2>/dev/null
g -C "$T/app" commit -q --allow-empty -m one && g -C "$T/app" push -q origin HEAD:master
git clone -q "$T/origin.git" "$T/up" 2>/dev/null
advance() { g -C "$T/up" pull -q --ff-only origin master; g -C "$T/up" commit -q --allow-empty -m "$1"; g -C "$T/up" push -q origin HEAD:master; }

cat >"$T/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >>"$STUB_LOG"
a="$*"
case "$a" in
  "auth status"*) exit 0 ;;
  *"workflow run"*) exit 0 ;;
  *"--workflow 10_ci-quality.yml --commit"*) echo "${STUB_GATE:-success}" ;;
  *"--workflow 10_ci-quality.yml --branch master --status success"*) echo "${STUB_GREEN:-abc123green}" ;;
  *"--json status "*) echo "${STUB_INFLIGHT:-0}" ;;
  *"--json conclusion "*) echo "${STUB_LAST:-success}" ;;
  *) echo "gh stub: unscripted: $a" >&2; exit 9 ;;
esac
EOF
chmod +x "$T/gh"

STUBS='
do_spl_spool_refresh() { echo "refresh DRY_RUN=$DRY_RUN" >>"$STUB_LOG"; [[ -z "${STUB_REFRESH_FAIL:-}" ]]; }
do_spl_box_deploy() { echo "deploy $BOX_DEPLOY_CMD DRY_RUN=$DRY_RUN missing=${BOX_DEPLOY_MISSING:-} pool=${BOX_DEPLOY_POOL:-}" >>"$STUB_LOG"; }
'
# LAG: "<env> <comp> <verdict>" lines the lag stub prints for every env
upd() {
  : >"$T/calls.log"
  SNIPPET="$STUBS do_spl_box_update" in_orc APP_PATH="$T/app" USER=tester BOX_UPDATE_REEXEC=0 BOX_UPDATE_GH="$T/gh" \
    BOX_UPDATE_REPO=o/n GH_TOKEN=x BOX_UPDATE_LAG_CMD='printf "%s hub %s x\n%s wui %s y\n" "$ENV" "${LAG_HUB:-current}" "$ENV" "${LAG_WUI:-current}"' \
    "$@" 2>&1
}
dispatched() { grep -c '^gh workflow run' "$T/calls.log"; }

# 1. nothing lags
out="$(upd)"; rc=$?
[ "$rc" -eq 0 ] && grep -q '^refresh DRY_RUN=1$' "$T/calls.log" && grep -q '^deploy install DRY_RUN=1 missing=skip pool=status$' "$T/calls.log" \
  && ! grep -q '^gh ' "$T/calls.log" && grep -q 'OK lag: nothing lags trunk' <<<"$out" \
  && pass "1. at trunk, nothing lags: refresh + deploy (dry), gh never called" || fail "1. ($rc: $out; $(cat "$T/calls.log"))"
out="$(upd DRY_RUN=0)"
grep -q '^refresh DRY_RUN=0$' "$T/calls.log" && grep -q '^deploy install DRY_RUN=0 missing=skip pool=status$' "$T/calls.log" \
  && pass "1. control: DRY_RUN=0 reaches both steps" || fail "1. control ($(cat "$T/calls.log"))"

# 2. lagging hub, gate green
out="$(upd DRY_RUN=0 LAG_HUB=lagging)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(dispatched)" = 1 ] && grep -q '^gh workflow run 20_hub-build-deploy.yml --repo o/n --ref master -f environment=all$' "$T/calls.log" \
  && pass "2. a lagging hub (both envs) dispatches 20 once, environment=all" || fail "2. ($rc: $out; $(cat "$T/calls.log"))"
out="$(upd LAG_HUB=lagging)"
[ "$(dispatched)" = 0 ] && grep -q '^PLAN hub: gh workflow run 20_hub-build-deploy.yml' <<<"$out" \
  && pass "2. control: the dry run plans it and dispatches nothing" || fail "2. control ($out)"
out="$(upd DRY_RUN=0 LAG_WUI=lagging)"
grep -q '^gh workflow run 30_wui-build-deploy.yml' "$T/calls.log" && [ "$(dispatched)" = 1 ] \
  && pass "2. a lagging WUI dispatches 30, not 20" || fail "2. wui ($out; $(cat "$T/calls.log"))"

# 3. red gate
out="$(upd DRY_RUN=0 LAG_HUB=lagging STUB_GATE=failure STUB_GREEN=feedbeef)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(dispatched)" = 0 ] && grep -q "SKIP hub lags, but the CI gate on trunk .* is 'failure'; the newest green trunk sha is feedbeef" <<<"$out" \
  && pass "3. a red gate on trunk: nothing dispatched, the newest green sha named" || fail "3. ($rc: $out)"

# 4. in flight / broken
out="$(upd DRY_RUN=0 LAG_HUB=lagging STUB_INFLIGHT=1)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(dispatched)" = 0 ] && grep -q 'SKIP hub lags, but a 20_hub-build-deploy.yml run is in flight' <<<"$out" \
  && pass "4. a run in flight: not dispatched" || fail "4. inflight ($rc: $out)"
out="$(upd DRY_RUN=0 LAG_HUB=lagging STUB_LAST=failure)"; rc=$?
[ "$rc" -ne 0 ] && [ "$(dispatched)" = 0 ] && grep -q "the last 20_hub-build-deploy.yml run concluded 'failure'" <<<"$out" \
  && pass "4. the last run failed: not dispatched, the run exits non-zero" || fail "4. broken ($rc: $out)"

# 5. master moved since the fetch (fetch skipped: origin/master stays old)
advance two
out="$(upd DRY_RUN=0 LAG_HUB=lagging BOX_UPDATE_FETCHED=1)"
[ "$(dispatched)" = 0 ] && grep -q 'SKIP hub: master moved to' <<<"$out" \
  && pass "5. master moved since the fetch: not dispatched" || fail "5. ($out)"

# 6. fetch
old="$(git -C "$T/app" rev-parse HEAD)"; new="$(git -C "$T/origin.git" rev-parse master)"
out="$(upd)"
[ "$(git -C "$T/app" rev-parse HEAD)" = "$old" ] && grep -q '^PLAN fetch: git merge --ff-only origin/master' <<<"$out" \
  && pass "6. the dry run fetches but does not move the checkout" || fail "6. dry ($out)"
out="$(upd DRY_RUN=0)"
[ "$(git -C "$T/app" rev-parse HEAD)" = "$new" ] && grep -q '^DO fetch: .* fast-forwarded' <<<"$out" \
  && pass "6. DRY_RUN=0 fast-forwards a checkout behind trunk" || fail "6. ff ($out)"
advance three
g -C "$T/app" checkout -q -b side
out="$(upd DRY_RUN=0)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "is on 'side', not master" <<<"$out" && ! grep -q '^refresh' "$T/calls.log" \
  && pass "6. a checkout not on master is refused before any step" || fail "6. side ($rc: $out)"
g -C "$T/app" checkout -q master; upd DRY_RUN=0 >/dev/null

# 7. a failing step
out="$(upd DRY_RUN=0 STUB_REFRESH_FAIL=1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q '^deploy install DRY_RUN=0 ' "$T/calls.log" && grep -q 'FAIL step refresh' <<<"$out" && grep -q 'OK lag' <<<"$out" \
  && pass "7. a failing refresh: deploy and lag still run, the run exits non-zero" || fail "7. ($rc: $out)"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
