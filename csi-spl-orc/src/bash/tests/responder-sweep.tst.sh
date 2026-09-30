#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_responder_sweep (SPL-1265 / epic SPL-1238) — the reboot-proof
#          cron driver. It runs the responder pass for EVERY tenant with a
#          box-rsp desk seated on this box, skips the unseated, and is a no-op
#          (exit 0) when no desk is seated. do_spl_responder_run is stubbed.
#   1. two tenants seated (box-rsp/spool present) + one desk-only tenant ->
#      do_spl_responder_run is called for the two seated, not the desk-only one
#   2. no box-rsp seated anywhere -> OK, no call, exit 0
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
  env PROJ_PATH="$PROJ_ROOT" STATE="$1" RUN_LOG="$T/run.log" ENV=dev bash -c '
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
         "$T/a/desk/leiden/box-desk/spool"
: >"$T/run.log"
sweep_with "$T/a/desk/.." >"$T/o" 2>&1 || true   # STATE is the state dir (parent of desk/)
: >"$T/run.log"
sweep_with "$T/a" >"$T/o" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q "TENANT_ID=t1 " "$T/run.log" && grep -q "TENANT_ID=csitea " "$T/run.log" \
   && ! grep -q "TENANT_ID=leiden " "$T/run.log" && [ "$(grep -c '^run ' "$T/run.log")" = "2" ]; then
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

echo "----"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
