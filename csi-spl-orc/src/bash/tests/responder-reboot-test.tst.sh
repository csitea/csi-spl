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
#   4-9. do_spl_responder_sweep keeps the RSP sidecar on the lease holder only
#      (specs/064 L2): standby downs its own and sends nothing; holder seats a
#      down one and answers; an unreachable/stale lease changes nothing; a lease
#      flip moves the sidecar in one tick; one-machine mode is unchanged
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

# sweep_test <lease line or ''> [state dir] runs the REAL
# do_spl_responder_sweep (DRY_RUN=0) with do_spl_responder_run stubbed (RAN
# <tenant>), this machine = box sat, now = 1790000000, the lease file under
# $T/spool. The sidecar is a pid file holding ALIVE: do_spl_desk_up writes it
# (SEAT), do_spl_desk_down removes it (DOWN).
sweep_test() {
  rm -rf "$T/spool"; mkdir -p "$T/spool/dispatch"
  [ -n "$1" ] && printf '%s\n' "$1" >"$T/spool/dispatch/lease"
  env -u LEASE_MACHINE -u DESK_BOX PROJ_PATH="$PROJ_ROOT" STATE="${2:-$T/state}" ENV=prd SPOOL_ROOT="$T/spool" \
    SPOOL_TEST=1 SPOOL_DESK_BOX="${SPOOL_DESK_BOX:-sat}" LEASE_NOW=1790000000 DRY_RUN=0 bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_STATE_DIR="$STATE"; export SPL_STATE_DIR; return 0; }
    do_spl_responder_run() { echo "RAN $TENANT_ID"; }
    spl_desk_alive() { [ "$(cat "$1" 2>/dev/null)" = ALIVE ]; }
    do_spl_desk_up() { echo ALIVE >"$SPL_STATE_DIR/desk/$TENANT_ID/$DESK_BOX/spool/.hub/hub-run.pid"; echo "SEAT $TENANT_ID $DESK_BOX $DESK_AGENT" >&2; }
    do_spl_desk_down() { rm -f "$SPL_STATE_DIR/desk/$TENANT_ID/$DESK_BOX/spool/.hub/hub-run.pid"; echo "DOWN $TENANT_ID $DESK_BOX" >&2; }
    do_spl_responder_sweep'
}
PIDF="$T/state/desk/t1/box-rsp/spool/.hub/hub-run.pid"
echo pubkey >"$T/state/desk/t1/box-rsp/pinned"

# --- 4. standby: its live sidecar is taken down, nothing is sent -------------------
echo ALIVE >"$PIDF"
if sweep_test "c-002@other-box 1790000000" >"$T/o" 2>&1 && ! grep -q "^RAN" "$T/o" \
   && grep -q "^DOWN t1 box-rsp" "$T/o" && [ ! -e "$PIDF" ] \
   && grep -q "INFO the fleet's dispatch lease is held by c-002@other-box: this machine's responder sends nothing" "$T/o"; then
  pass "standby -> its sidecar is taken down, nothing sent, one INFO line"
else
  fail "standby path wrong: $(cat "$T/o")"
fi

# --- 5. holder: a down sidecar is seated, then the desk is answered ----------------
if sweep_test "c-002@sat 1790000000" >"$T/o" 2>&1 && grep -q "^SEAT t1 box-rsp RSP-01" "$T/o" \
   && grep -q "^RAN t1" "$T/o" && [ "$(cat "$PIDF" 2>/dev/null)" = ALIVE ]; then
  pass "holder -> its down sidecar is seated, then answered"
else
  fail "the holder did not seat + answer: $(cat "$T/o")"
fi

# --- 6. the holder never touches a live sidecar ------------------------------------
if sweep_test "c-002@sat 1790000000" >"$T/o" 2>&1 && ! grep -qE "^(SEAT|DOWN)" "$T/o" && grep -q "^RAN t1" "$T/o"; then
  pass "holder with a live sidecar -> no seat, no down, answered"
else
  fail "the holder touched a live sidecar: $(cat "$T/o")"
fi

# --- 7. lease read failure (unreachable, stale): no change, WARN, still answered ---
ok=1
for l in "none@unreachable 1790000000" "c-002@other-box 1789990000"; do
  echo ALIVE >"$PIDF"
  if sweep_test "$l" >"$T/o" 2>&1 && ! grep -qE "^(SEAT|DOWN)" "$T/o" && grep -q "^WARN the dispatch lease reads" "$T/o" \
     && grep -q "^RAN t1" "$T/o" && [ "$(cat "$PIDF")" = ALIVE ]; then :; else ok=0; fail "lease '$l' changed the sidecar: $(cat "$T/o")"; fi
  rm -f "$PIDF"
  if sweep_test "$l" >"$T/o" 2>&1 && ! grep -qE "^(SEAT|DOWN)" "$T/o"; then :; else ok=0; fail "lease '$l' seated a down sidecar: $(cat "$T/o")"; fi
done
(( ok )) && pass "unreachable or stale lease -> WARN, no sidecar seated or taken down"

# --- 8. a lease flip moves the sidecar within one tick -----------------------------
mkdir -p "$T/pc/desk/t1/box-rsp/spool/.hub" "$T/sat/desk/t1/sat-rsp/spool/.hub"
echo pubkey >"$T/pc/desk/t1/box-rsp/pinned"; echo pubkey >"$T/sat/desk/t1/sat-rsp/pinned"
echo ALIVE >"$T/pc/desk/t1/box-rsp/spool/.hub/hub-run.pid"
printf 'SPOOL_RSP_BOX=sat-rsp\n' >"$T/sat.env"
# after the flip to sat: the PC (box pc) is standby, sat is the holder
SPOOL_DESK_BOX=pc sweep_test "c-002@sat 1790000000" "$T/pc" >"$T/o1" 2>&1
SPOOL_BOX_ENV="$T/sat.env" sweep_test "c-002@sat 1790000000" "$T/sat" >"$T/o2" 2>&1
if [ ! -e "$T/pc/desk/t1/box-rsp/spool/.hub/hub-run.pid" ] && grep -q "^SEAT t1 sat-rsp RSP-01" "$T/o2" \
   && [ "$(cat "$T/sat/desk/t1/sat-rsp/spool/.hub/hub-run.pid")" = ALIVE ] && ! grep -q "^RAN" "$T/o1" && grep -q "^RAN t1" "$T/o2"; then
  pass "lease flip -> one tick: the old holder downs box-rsp, the new one seats sat-rsp (SPOOL_RSP_BOX)"
else
  fail "lease flip did not move the sidecar: $(cat "$T/o1" "$T/o2")"
fi

# --- 9. one machine, no fleet mirror (bare id / no lease): answered as before ------
echo ALIVE >"$PIDF"
if sweep_test "c-002 1790000000" >"$T/o" 2>&1 && grep -q "^RAN t1" "$T/o" && ! grep -qE "^(SEAT|DOWN)" "$T/o" \
   && sweep_test "" >"$T/o" 2>&1 && grep -q "^RAN t1" "$T/o"; then
  pass "a bare-id lease or no lease -> answered (one-machine mode unchanged)"
else
  fail "one-machine mode changed: $(cat "$T/o")"
fi

echo "----"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
