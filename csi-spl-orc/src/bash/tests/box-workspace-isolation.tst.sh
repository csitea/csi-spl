#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 108 3.5 and test 4(d) - one box = one workspace. Every check
#          is a pair with its control; n counts the pairs of each part. All
#          of it runs on a fake base under $T, never the live spool root.
#   1. (n=4) a box claimed by workspace wsa REFUSES wsb in do_spl_desk_up
#      (dry run and DRY_RUN=0: no state written, no external call),
#      do_spl_desk_pin and the operator-only do_spl_desk_up_tenants.
#      CONTROL: wsa's desk-up and pin dry runs pass, with the state dir
#      inside the workspace; an unclaimed (operator) box seats wsb as before
#   2. (n=1) do_spl_box_workspace_setup refuses a second workspace on a
#      claimed box (exit 3). CONTROL: the claimed workspace's dry run passes
#   3. (n=2, needs passwordless sudo + useradd: SKIP otherwise) setup for
#      real, two boxes (two bases) with throwaway users: workspace B's OS user
#      gets EACCES on workspace A's spool root, listing and message.
#      CONTROL: A's own user reads both. And desk-up on box A as a user that
#      is not A's refuses. CONTROL: the guard passes on a dir the caller owns
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
skip() { echo "SKIP: $1"; }

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux
W="$T/ws"
mkdir -p "$W/wsa"
printf 'wsa\n' >"$W/claim"

# --- 1. desk-up / pin / up-tenants on a claimed box --------------------------------
: >"$T/calls.log"
SNIPPET=do_spl_desk_up in_orc SPL_WS_BASE="$W" SPL_STATE_DIR= TENANT_ID=wsa DESK_AGENT=c-101 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q "state $W/wsa/state/dev" "$T/o" &&
  pass "CONTROL desk-up of the box's own workspace passes, state inside $W/wsa" || fail "own desk-up rc=$rc: $(cat "$T/o")"
for dry in 1 0; do
  SNIPPET=do_spl_desk_up in_orc SPL_WS_BASE="$W" SPL_STATE_DIR= TENANT_ID=wsb DESK_AGENT=c-101 DRY_RUN=$dry \
    ROOT_KEY_JSON=/nonexistent.json >"$T/o" 2>&1; rc=$?
  [[ $rc -ne 0 ]] && grep -q "belongs to workspace 'wsa'" "$T/o" &&
    pass "desk-up DRY_RUN=$dry refuses a second workspace on the box" || fail "desk-up DRY_RUN=$dry wsb rc=$rc: $(cat "$T/o")"
done
[[ ! -e "$W/wsb" && ! -e "$T/state/dev/desk/wsb" && ! -s "$T/calls.log" ]] &&
  pass "the refusal wrote no state and made no external call" || fail "refusal side effects: $(ls "$W" "$T/state/dev/desk" 2>&1; cat "$T/calls.log")"

SNIPPET=do_spl_desk_pin in_orc SPL_WS_BASE="$W" SPL_STATE_DIR= TENANT_ID=wsa >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && pass "CONTROL desk-pin of the box's own workspace passes" || fail "own pin rc=$rc: $(cat "$T/o")"
SNIPPET=do_spl_desk_pin in_orc SPL_WS_BASE="$W" SPL_STATE_DIR= TENANT_ID=wsb >"$T/o" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q "belongs to workspace 'wsa'" "$T/o" &&
  pass "desk-pin refuses a second workspace on the box" || fail "pin wsb rc=$rc: $(cat "$T/o")"

SNIPPET=do_spl_desk_up in_orc TENANT_ID=wsb DESK_AGENT=c-101 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && pass "CONTROL an unclaimed (operator) box seats any workspace as before" || fail "operator box rc=$rc: $(cat "$T/o")"
SNIPPET=do_spl_desk_up_tenants in_orc SPL_WS_BASE="$W" >"$T/o" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'operator boxes only' "$T/o" &&
  pass "the multi-workspace desk refuses a workspace box" || fail "up-tenants on a claimed box rc=$rc: $(cat "$T/o")"

# --- 2. setup refuses a second workspace -------------------------------------------
SNIPPET=do_spl_box_workspace_setup in_orc SPL_WS_BASE="$W" TENANT_ID=wsa >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q 'DRY_RUN' "$T/o" && pass "CONTROL setup dry run of the claimed workspace passes" ||
  fail "setup wsa rc=$rc: $(cat "$T/o")"
SNIPPET=do_spl_box_workspace_setup in_orc SPL_WS_BASE="$W" TENANT_ID=wsb >"$T/o" 2>&1; rc=$?
[[ $rc -eq 3 ]] && pass "setup refuses a second workspace on the box (exit 3)" || fail "setup wsb rc=$rc: $(cat "$T/o")"

# --- 3. real users: EACCES across workspaces -----------------------------------------
P="spl-t$$-"
UA="${P}wsa" UB="${P}wsb"
cleanup_users() { sudo -n userdel "$UA" 2>/dev/null; sudo -n userdel "$UB" 2>/dev/null; sudo -n rm -rf "$R" 2>/dev/null; }
if sudo -n sh -c "command -v useradd" >/dev/null 2>&1; then
  # a TMPDIR under a closed home would hide both trees from both users
  R=$(mktemp -d /tmp/box-ws-iso.XXXXXX); chmod 711 "$R"
  trap 'cleanup_users; rm -rf "$T"' EXIT
  ok=1
  for pair in "$R/boxA wsa" "$R/boxB wsb"; do
    read -r base t <<<"$pair"
    SNIPPET=do_spl_box_workspace_setup in_orc SPL_WS_BASE="$base" SPL_WS_USER_PREFIX="$P" TENANT_ID="$t" DRY_RUN=0 \
      >"$T/s.$t" 2>&1 || { ok=0; fail "setup $t: $(tail -3 "$T/s.$t")"; }
  done
  if (( ok )); then
    pass "setup made $UA and $UB, each with its own 0700 workspace dir"
    sudo -n -u "$UA" sh -c "printf '{\"v\":1}' >'$R/boxA/wsa/spool/m.json'" || fail "A cannot write its own spool root"
    sudo -n -u "$UA" ls "$R/boxA/wsa/spool" >/dev/null 2>&1 && sudo -n -u "$UA" cat "$R/boxA/wsa/spool/m.json" >/dev/null 2>&1 &&
      pass "CONTROL workspace A's user reads its own spool root" || fail "A cannot read its own spool root"
    out=$(sudo -n -u "$UB" ls "$R/boxA/wsa/spool" 2>&1); rc=$?
    [[ $rc -ne 0 && "$out" == *"Permission denied"* ]] && pass "workspace B's user gets EACCES listing A's spool root" ||
      fail "B listed A's spool root rc=$rc: $out"
    out=$(sudo -n -u "$UB" cat "$R/boxA/wsa/spool/m.json" 2>&1); rc=$?
    [[ $rc -ne 0 && "$out" == *"Permission denied"* ]] && pass "workspace B's user gets EACCES reading A's message" ||
      fail "B read A's message rc=$rc: $out"
    SNIPPET=do_spl_desk_up in_orc SPL_WS_BASE="$R/boxA" SPL_STATE_DIR= TENANT_ID=wsa DESK_AGENT=c-101 >"$T/o" 2>&1; rc=$?
    [[ $rc -ne 0 ]] && grep -q "its own OS user '$UA'" "$T/o" &&
      pass "desk-up on box A as a user that is not $UA refuses" || fail "desk-up as $(id -un) rc=$rc: $(cat "$T/o")"
    [[ "$(cat "$R/boxA/claim")" == wsa && "$(stat -c '%a %U' "$R/boxA/claim")" == "644 root" ]] &&
      pass "the claim is root-owned 0644 and names wsa" || fail "claim $(stat -c '%a %U' "$R/boxA/claim")"
  fi
else
  skip "part 3 needs passwordless sudo and useradd"
fi

echo "=== $( ((fails)) && echo "$fails FAILED" || echo "all passed") ==="
exit $((fails > 0))
