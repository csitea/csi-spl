#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_responder_reboot_test (SPL-1265 / epic SPL-1238, step 5) —
#          the read-only reboot-recovery assertion. crontab, spl_desk_alive,
#          do_spl_responder_sweep and the cloud cnf are stubbed, so the checks
#          are exercised against a staged box tree, not the live box.
#   1. cron installed + script executable + runs the sweep, one LIVE desk,
#      sweep clean -> exit 0 (reboot-proof)
#   2. a seated desk whose sidecar is DEAD -> FAIL 3/4, non-zero
#   3. no desk-reconcile cron line -> FAIL 1/4, non-zero
#   4-6. do_spl_responder_sweep is holder-gated (specs/064 L2): the lease held
#      on ANOTHER machine -> one INFO line, no responder run; held here, or a
#      one-machine bare id -> the seated desk is answered
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# an executable "reconcile script" that mentions the sweep step
mkdir -p "$T/bin"
printf '#!/bin/sh\n# runs do_spl_responder_sweep\n' >"$T/bin/desk-reconcile-cron.sh"
chmod +x "$T/bin/desk-reconcile-cron.sh"

# reboot_test <crontab-output> <alive:0|1> runs the action with:
#  - crontab -l -> $1
#  - spl_desk_alive -> success iff $2=1
#  - one seated desk at state/desk/t1/box-desk + the responder box-rsp
reboot_test() {
  env PROJ_PATH="$PROJ_ROOT" CRONTXT="$1" ALIVE="$2" STATE="$T/state" ENV=prd bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_STATE_DIR="$STATE"; SPL_ORG_APP="csi-spl"; export SPL_STATE_DIR SPL_ORG_APP; return 0; }
    crontab() { printf "%s\n" "$CRONTXT"; }
    spl_desk_alive() { [ "$ALIVE" = 1 ]; }
    do_spl_responder_sweep() { return 0; }
    do_spl_responder_reboot_test'
}

mkdir -p "$T/state/desk/t1/box-desk/spool/.hub" "$T/state/desk/t1/box-rsp/spool/.hub"
: >"$T/state/desk/t1/box-desk/spool/.hub/hub-run.pid"
: >"$T/state/desk/t1/box-rsp/spool/.hub/hub-run.pid"
GOODCRON="2-59/5 * * * * $T/bin/desk-reconcile-cron.sh >> /var/log/x 2>&1 # csi-spl:desk-reconcile-prd"

# --- 1. healthy -------------------------------------------------------------------
if reboot_test "$GOODCRON" 1 >"$T/o" 2>&1; then
  grep -q "1/4 reboot driver" "$T/o" && grep -q "2/4 the reconcile runs the responder sweep" "$T/o" \
    && grep -q "reboot-proof" "$T/o" && pass "healthy box -> exit 0, reboot-proof" \
    || fail "healthy path missing a check: $(cat "$T/o")"
else
  fail "healthy box returned non-zero: $(cat "$T/o")"
fi

# --- 2. a dead seated sidecar -----------------------------------------------------
if reboot_test "$GOODCRON" 0 >"$T/o" 2>&1; then
  fail "a dead sidecar should fail the reboot test: $(cat "$T/o")"
else
  grep -q "3/4 a seated desk did not come back" "$T/o" && pass "a dead seated sidecar -> FAIL, non-zero" \
    || fail "dead-sidecar path wrong: $(cat "$T/o")"
fi

# --- 3. no reconcile cron ---------------------------------------------------------
if reboot_test "" 1 >"$T/o" 2>&1; then
  fail "no reconcile cron should fail the reboot test: $(cat "$T/o")"
else
  grep -q "no 'csi-spl:desk-reconcile' crontab line" "$T/o" && pass "no reconcile cron -> FAIL, non-zero" \
    || fail "no-cron path wrong: $(cat "$T/o")"
fi

# sweep_test <lease line or ''> runs the REAL do_spl_responder_sweep with
# do_spl_responder_run stubbed (prints RAN <tenant>), this machine = box sat,
# the staged t1/box-rsp desk above and the dispatch lease file under $T/spool.
sweep_test() {
  rm -rf "$T/spool"; mkdir -p "$T/spool/dispatch"
  [ -n "$1" ] && printf '%s\n' "$1" >"$T/spool/dispatch/lease"
  env -u LEASE_MACHINE PROJ_PATH="$PROJ_ROOT" STATE="$T/state" ENV=prd SPOOL_ROOT="$T/spool" \
    SPOOL_TEST=1 SPOOL_DESK_BOX=sat bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_STATE_DIR="$STATE"; export SPL_STATE_DIR; return 0; }
    do_spl_responder_run() { echo "RAN $TENANT_ID"; }
    do_spl_responder_sweep'
}

# --- 4. the lease is held on another machine: this one sends nothing ---------------
if sweep_test "c-002@other-box 1790000000" >"$T/o" 2>&1; then
  if grep -q "^RAN" "$T/o"; then
    fail "a standby machine answered: $(cat "$T/o")"
  else
    grep -q "INFO the fleet's dispatch lease is held by c-002@other-box: this machine's responder sends nothing" "$T/o" \
      && pass "lease on another machine -> standby sends nothing, one INFO line" \
      || fail "standby path missing its INFO line: $(cat "$T/o")"
  fi
else
  fail "standby sweep returned non-zero: $(cat "$T/o")"
fi

# --- 5. the lease is held on THIS machine: the seated desk is answered -------------
if sweep_test "c-002@sat 1790000000" >"$T/o" 2>&1 && grep -q "^RAN t1" "$T/o"; then
  pass "lease held here -> the t1 box-rsp desk is answered"
else
  fail "the holder did not answer: $(cat "$T/o")"
fi

# --- 6. one machine, no fleet mirror (bare id / no lease): answered as before ------
if sweep_test "c-002 1790000000" >"$T/o" 2>&1 && grep -q "^RAN t1" "$T/o" \
   && sweep_test "" >"$T/o" 2>&1 && grep -q "^RAN t1" "$T/o"; then
  pass "a bare-id lease or no lease -> answered (one-machine mode unchanged)"
else
  fail "one-machine mode changed: $(cat "$T/o")"
fi

echo "----"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
