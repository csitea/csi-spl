#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_responder_sweep (SPL-1265 / epic SPL-1238) — the reboot-proof
#          cron driver. It runs the responder pass for EVERY tenant with a
#          box-rsp desk seated on this box, skips the unseated, and is a no-op
#          (exit 0) when no desk is seated. do_spl_responder_run is stubbed.
#   1. two tenants seated (box-rsp/spool present) + one desk-only tenant ->
#      do_spl_responder_run is called for the two seated, not the desk-only one
#   2. no box-rsp seated anywhere -> OK, no call, exit 0
#   3-5. SPL-5586, on the lease holder with the sidecar down:
#      3. dev, desk NEVER pinned (no <desk>/pinned) -> rc 0, one "not set up
#         in dev: skipped" line, no seat, no run
#      4. dev, pinned desk whose seat fails -> rc 1 (a real failure stays red)
#      5. prd, desk never pinned -> rc 1, "is not pinned" FAIL (prd stays loud)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# sweep_with <state-dir> runs do_spl_responder_sweep with the cloud cnf pointed
# at <state-dir> and do_spl_responder_run stubbed to log the tenant it handled.
sweep_with() {
  # SPOOL_ROOT: no dispatch lease, so the live box's lease cannot gate it (specs/064 L2)
  env PROJ_PATH="$PROJ_ROOT" STATE="$1" RUN_LOG="$T/run.log" ENV=dev SPOOL_ROOT="$T/spool" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_STATE_DIR="$STATE"; export SPL_STATE_DIR; return 0; }
    do_spl_responder_run() { echo "run TENANT_ID=$TENANT_ID DESK_BOX=$DESK_BOX" >>"$RUN_LOG"; return 0; }
    do_spl_responder_sweep'
}

# --- 1. two seated RSP tenants + one desk-only tenant ------------------------------
mkdir -p "$T/a/desk/t1/box-rsp/spool" \
         "$T/a/desk/csitea/box-rsp/spool" \
         "$T/a/desk/ws-a/box-desk/spool"
: >"$T/run.log"
sweep_with "$T/a/desk/.." >"$T/o" 2>&1 || true   # STATE is the state dir (parent of desk/)
: >"$T/run.log"
sweep_with "$T/a" >"$T/o" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q "TENANT_ID=t1 " "$T/run.log" && grep -q "TENANT_ID=csitea " "$T/run.log" \
   && ! grep -q "TENANT_ID=ws-a " "$T/run.log" && [ "$(grep -c '^run ' "$T/run.log")" = "2" ]; then
  pass "sweeps the two seated RSP tenants only (not the desk-only tenant)"
else
  fail "seated sweep wrong: rc=$rc log=[$(tr '\n' ';' <"$T/run.log")] out=$(cat "$T/o")"
fi

# --- 2. nothing seated -------------------------------------------------------------
mkdir -p "$T/empty"
: >"$T/run.log"
sweep_with "$T/empty" >"$T/o" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$T/run.log" ]; then
  pass "no RSP desk seated -> no-op, exit 0"
else
  fail "empty sweep misbehaved: rc=$rc log=[$(cat "$T/run.log")] out=$(cat "$T/o")"
fi

# holder_sweep <env> <state dir> [seat rc]: the REAL sweep (DRY_RUN=0) as the
# dispatch lease holder (this machine = sat), the sidecar down, desk_up stubbed
# (returns <seat rc>, default 0; its output is discarded), do_spl_responder_run stubbed (RAN).
holder_sweep() {
  rm -rf "$T/hspool"; mkdir -p "$T/hspool/dispatch"
  printf '%s\n' "c-002@sat 1790000000" >"$T/hspool/dispatch/lease"
  env -u LEASE_MACHINE -u DESK_BOX PROJ_PATH="$PROJ_ROOT" STATE="$2" ENV="$1" SPOOL_ROOT="$T/hspool" \
    SPOOL_TEST=1 SPOOL_DESK_BOX=sat LEASE_NOW=1790000000 DRY_RUN=0 SEAT_RC="${3:-0}" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_STATE_DIR="$STATE"; export SPL_STATE_DIR; return 0; }
    do_spl_responder_run() { echo "RAN $TENANT_ID"; }
    spl_desk_alive() { return 1; }
    do_spl_desk_up() { echo "SEAT $TENANT_ID $DESK_BOX"; return "$SEAT_RC"; }
    do_spl_responder_sweep'
}

# --- 3. dev, never pinned: skipped, the sweep stays green --------------------------
mkdir -p "$T/u/desk/t1/box-rsp/spool"
holder_sweep dev "$T/u" >"$T/o" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q "^OK box-rsp of t1 is not set up in dev: skipped; pin it with do_spl_desk_pin to enable" "$T/o" \
   && ! grep -qE "^(SEAT|RAN|FAIL)" "$T/o" && grep -q "0/1 tenant(s) handled, 1 not set up, 0 failed" "$T/o"; then
  pass "dev holder, RSP desk never pinned -> rc 0, one skip line, no seat, no run"
else
  fail "dev unpinned desk: rc=$rc out=$(cat "$T/o")"
fi

# --- 4. dev, pinned, the seat fails: still a red -----------------------------------
mkdir -p "$T/p/desk/t1/box-rsp/spool"; echo pubkey >"$T/p/desk/t1/box-rsp/pinned"
holder_sweep dev "$T/p" 1 >"$T/o" 2>&1
rc=$?
if [ "$rc" -eq 1 ] && grep -q "^FAIL seating .* on box-rsp of t1" "$T/o" \
   && ! grep -q "^RAN" "$T/o"; then
  pass "dev holder, pinned desk whose seat fails -> rc 1"
else
  fail "dev pinned seat failure: rc=$rc out=$(cat "$T/o")"
fi

# --- 5. prd, never pinned: stays a loud FAIL ---------------------------------------
holder_sweep prd "$T/u" >"$T/o" 2>&1
rc=$?
if [ "$rc" -eq 1 ] && grep -q "^FAIL box-rsp of t1 is not pinned: pin it first (do_spl_desk_pin)" "$T/o" \
   && ! grep -q "is not set up in" "$T/o" && ! grep -qE "^(SEAT|RAN)" "$T/o"; then
  pass "prd holder, RSP desk never pinned -> rc 1, FAIL (prd keeps failing loudly)"
else
  fail "prd unpinned desk: rc=$rc out=$(cat "$T/o")"
fi

echo "----"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
