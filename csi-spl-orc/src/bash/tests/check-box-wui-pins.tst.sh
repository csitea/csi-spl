#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_check_box_wui_pins (SPL-1290; prd 2026-10-01: csitea had no
#          box-wui pin, so every browser post there was stored unsigned and
#          reached no agent). The hub DB is a rows file (PINS_ROWS_FILE), the
#          hub's key BOX_WUI_PUBKEY.
#   1. a workspace pinned to the hub's key is ok, also with old unsigned posts
#   2. no pin, a revoked pin and a foreign key are each a GAP naming the fix
#   3. any GAP exits 1; all pinned exits 0
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

HUB="7ginIASzAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
OTHER="OTHERkeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
cat >"$T/rows" <<EOF
good|$HUB||0
healed|$HUB||128
nopin|||12
revoked|$HUB|revoked|0
foreign|$OTHER||3
EOF
printf 'good|%s||0\n' "$HUB" >"$T/ok"

run() {
  env PROJ_PATH="$PROJ_ROOT" ENV=prd BOX_WUI_PUBKEY="$HUB" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-check-box-wui-pins.func.sh"
    do_spl_check_box_wui_pins' >"$T/o" 2>&1
}

run PINS_ROWS_FILE="$T/rows"; rc=$?
grep -qE '^\| good \| 7ginIASz\.\.\. \| 0 \| ok \|$' "$T/o" &&
  grep -qE '^\| healed \| .* \| 128 \| ok \(the unsigned posts predate the pin\) \|$' "$T/o" &&
  pass "1. pinned to the hub's key is ok, old unsigned posts noted" || fail "1. $(cat "$T/o")"
grep -qE '^\| nopin \| none \| 12 \| GAP no pin: do_spl_cloud_pin_box_wui \|$' "$T/o" &&
  grep -qE '^\| revoked \| .* revoked \| 0 \| GAP revoked' "$T/o" &&
  grep -qE '^\| foreign \| OTHERkey\.\.\. \| 3 \| GAP not the hub.s key' "$T/o" &&
  pass "2. no pin / revoked / foreign key are GAPs naming the fix" || fail "2. $(cat "$T/o")"
[[ $rc -eq 1 ]] && grep -q '5 workspace(s), 3 gap(s)' "$T/o" &&
  pass "3. a GAP exits 1 with the count" || fail "3. rc=$rc $(tail -2 "$T/o")"
run PINS_ROWS_FILE="$T/ok"; rc=$?
[[ $rc -eq 0 ]] && grep -q '1 workspace(s), 0 gap(s)' "$T/o" &&
  pass "3. all pinned exits 0" || fail "3. ok rc=$rc $(cat "$T/o")"
run PINS_ROWS_FILE="$T/missing"; rc=$?
[[ $rc -eq 1 ]] && pass "3. a missing rows file fails" || fail "3. missing rc=$rc"

(( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
