#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-1290 - a dev/prd do_spl_tenant_create pins box-wui under the new
#          tenant (prd 2026-10-01, CLE-77876: seven workspaces had no pin, so
#          their people's posts reached no agent). spl_tenant_create_pin_wui
#          with do_spl_cloud_pin_box_wui stubbed:
#   1. the pin gets TENANT_ID, DRY_RUN=0, FORCE=0 and a 0600 TENANT_FILE
#      holding the tenant and its root key; the file is gone afterwards
#   2. a failing pin fails the helper (the create then exits 4); the file is
#      still removed
#   3. TENANT_PIN_WUI=0 skips the pin
#   4. the create chains the helper before the host step, exit 4 on failure
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
F="$PROJ_ROOT/src/bash/run/spl-tenant-create.func.sh"

helper() {
  mkdir -p "$T/d"
  env PROJ_PATH="$PROJ_ROOT" F="$F" REC="$T/rec" D="$T/d" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$F"
    do_spl_cloud_pin_box_wui() {
      { echo "tenant=$TENANT_ID dry=$DRY_RUN force=$FORCE mode=$(stat -c %a "$TENANT_FILE")"; cat "$TENANT_FILE"; } >"$REC"
      [[ "${PIN_FAIL:-0}" == 0 ]]
    }
    spl_tenant_create_pin_wui acme https://acme.example.org PUBKEY PRIVKEY "$D"' >"$T/o" 2>&1
}

rm -f "$T/rec"; helper; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'tenant=acme dry=0 force=0 mode=600' "$T/rec" &&
  grep -q '"tenant":"acme"' "$T/rec" && grep -q '"root_private_key":"PRIVKEY"' "$T/rec" && [[ ! -e "$T/d/tenant.json" ]] &&
  grep -q 'OK box-wui pinned under acme' "$T/o" &&
  pass "1. the pin gets the tenant and a 0600 root-key file, removed afterwards" || fail "1. rc=$rc $(cat "$T/rec" "$T/o" 2>&1)"

helper PIN_FAIL=1; rc=$?
[[ $rc -ne 0 && ! -e "$T/d/tenant.json" ]] && pass "2. a failing pin fails; the key file is still removed" || fail "2. rc=$rc"

rm -f "$T/rec"; helper TENANT_PIN_WUI=0; rc=$?
[[ $rc -eq 0 && ! -e "$T/rec" ]] && grep -q 'TENANT_PIN_WUI=0' "$T/o" && pass "3. TENANT_PIN_WUI=0 skips the pin" || fail "3. rc=$rc"

body="$(sed -n '/^do_spl_tenant_create() {/,/^}/p' "$F")"
pin_at="$(grep -n 'spl_tenant_create_pin_wui' <<<"$body" | head -1 | cut -d: -f1)"
host_at="$(grep -n 'spl_tenant_create_host' <<<"$body" | head -1 | cut -d: -f1)"
[[ -n "$pin_at" && -n "$host_at" && "$pin_at" -lt "$host_at" ]] && grep -q 'return 4' <<<"$body" &&
  pass "4. the create pins before the host step and exits 4 when the pin fails" || fail "4. pin=$pin_at host=$host_at"

(( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
