#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a desk-reconcile pause holds moves, never the re-seat of a desk
# whose sidecar died with the box (SPL-4772). On sat 2026-11-01 the box
# rebooted at 02:39:12Z under a fresh desk-move pause; every tick logged "no
# seat step", 11 of 12 prd sidecars stayed dead and box-restart pass 2 said
# only "rc 1".
#   1. desk-reconcile-cron.sh (./run a stub that records its calls):
#      (a) a fresh pause runs do_spl_desk_reseat_dead and no seat step;
#      (c) no pause keeps today's path (up_all, up_tenants, up_boxes, no
#      reseat); DESK_PAUSE_RESEAT=0 turns the paused re-seat off
#   2. do_spl_desk_reseat_dead (do_spl_desk_up a stub):
#      (a) a dead sidecar whose pid file predates the boot is re-seated as
#      the current user, with no root key and no join token;
#      (b) a live sidecar gets no action; a sidecar that died after the boot,
#      a desk that is not pinned, a rebox-retired desk and a desk owned by
#      another user than the caller get none either
#   3. (d) box-restart's after-check names the dead desk (env, tenant, box,
#      user) in its log, its record and its final line; none dead: OK
# RESEAT_ORC=<orc tree> runs it against another tree (the red control on
# trunk's code). Stubs and a temp spool root only; no real desk.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
PROJ_ROOT="${RESEAT_ORC:-$PROJ_ROOT}"
ME="$(id -un)"

# --- 1. the cron tick ------------------------------------------------------------------
O="$T/co/csi-spl-orc"
mkdir -p "$O/src/bash/scripts" "$T/spool"
cp "$PROJ_ROOT/src/bash/scripts/desk-reconcile-cron.sh" "$O/src/bash/scripts/"
printf '#!/bin/sh\necho "run $*" >>"%s/calls"\nexit 0\n' "$T" >"$O/run"
chmod +x "$O/run"
tick() {
  : >"$T/calls"
  env SPOOL_ROOT="$T/spool" DESK_CRON_TOOLS=true DESK_CRON_STATE_DIR="$T/cstate" HOME="$T" \
    DESK_TRUNK_CHECK=0 DESK_LEASE=0 DESK_SETTINGS_CHECK=0 ENV=prd "$@" \
    bash "$O/src/bash/scripts/desk-reconcile-cron.sh" >"$T/o" 2>&1
}
echo "do_spl_desk_move hold" >"$T/spool/.desk-reconcile.prd.pause"
tick; rc=$?
[[ $rc -eq 0 ]] && grep -q 'do_spl_desk_reseat_dead' "$T/calls" && ! grep -q 'do_spl_desk_up_all\|do_spl_desk_up_tenants\|do_spl_desk_up_boxes' "$T/calls" &&
  pass "1a. a fresh pause runs do_spl_desk_reseat_dead and no seat step" || fail "1a. rc=$rc calls: $(tr '\n' ';' <"$T/calls")"
tick DESK_PAUSE_RESEAT=0
! grep -q 'do_spl_desk_reseat_dead' "$T/calls" && pass "1a. DESK_PAUSE_RESEAT=0 turns the paused re-seat off" || fail "1a. off switch: $(tr '\n' ';' <"$T/calls")"
rm -f "$T/spool/.desk-reconcile.prd.pause"
tick; rc=$?
[[ $rc -eq 0 ]] && grep -q 'do_spl_desk_up_all' "$T/calls" && grep -q 'do_spl_desk_up_tenants' "$T/calls" &&
  grep -q 'do_spl_desk_up_boxes' "$T/calls" && ! grep -q 'do_spl_desk_reseat_dead' "$T/calls" &&
  pass "1c. no pause keeps today's path: up_all, up_tenants, up_boxes, no re-seat step" || fail "1c. rc=$rc calls: $(tr '\n' ';' <"$T/calls")"

# --- 2. do_spl_desk_reseat_dead -----------------------------------------------------------
S="$T/state/dev" D="$T/state/dev/desk/t1/box-desk"
NOW="$(date +%s)"
mkdir -p "$D/spool/c-010/inbox" "$D/spool/.hub"
echo pubkey >"$D/pinned"
( exit 0 ) & dead_pid=$!; wait "$dead_pid"
# desk <pid> <pid file age vs the boot: before|after>
desk() { echo "$1" >"$D/spool/.hub/hub-run.pid"; [[ "$2" == before ]] && touch -d "@$((NOW - 600))" "$D/spool/.hub/hub-run.pid"; }
STUB='do_spl_desk_up() { echo "CALL up $TENANT_ID $DESK_BOX $DESK_AGENT rkj=[${ROOT_KEY_JSON:-}] join=[${SPOOL_JOIN_TOKEN:-}] as=$(id -un)"; }'
reseat() { SNIPPET="$STUB; do_spl_desk_reseat_dead" in_orc SPL_STATE_DIR="$S" SPOOL_BOX_USER="$ME" DESK_BOOT_TIME="$((NOW - 300))" \
  ROOT_KEY_JSON=/nonexistent/root.json DRY_RUN=0 "$@" 2>&1; }
desk "$dead_pid" before
out="$(reseat)"; rc=$?
[[ $rc -eq 0 && "$out" == *"CALL up t1 box-desk c-010 rkj=[] join=[] as=$ME"* && "$out" == *"re-seated dead desk box-desk of t1 (dev) as $ME"* ]] &&
  pass "2a. pause + a sidecar dead since the boot: re-seated as the current user, no root key, no join token" || fail "2a. rc=$rc: $out"
bash -c 'exec -a "spool hub-run" sleep 120' & live_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'hub-run' "/proc/$live_pid/cmdline" 2>/dev/null && break; sleep 0.1; done
desk "$live_pid" before
out="$(reseat)"; rc=$?
[[ $rc -eq 0 && "$out" != *"CALL up"* && "$out" == *"OK 0 dead desk(s) in dev, 0 re-seated"* ]] &&
  pass "2b. pause + a live sidecar: no action" || fail "2b. rc=$rc: $out"
kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
desk "$dead_pid" after
out="$(reseat)"
[[ "$out" != *"CALL up"* && "$out" == *"died after the boot"* ]] && pass "2b. a sidecar that died after the boot: no action while paused" || fail "2b. after boot: $out"
desk "$dead_pid" before; mv "$D/pinned" "$D/pinned.x"
out="$(reseat)"
[[ "$out" != *"CALL up"* && "$out" == *"is not pinned: no re-seat while paused"* ]] && pass "2b. a desk that is not pinned: no re-seat (no keygen)" || fail "2b. unpinned: $out"
mv "$D/pinned.x" "$D/pinned"; mkdir -p "$D/rebox-retired"
out="$(reseat)"
[[ "$out" != *"CALL up"* ]] && pass "2b. a rebox-retired desk: no action" || fail "2b. rebox-retired: $out"
rmdir "$D/rebox-retired"
out="$(SNIPPET="$STUB; id() { [[ \"\$*\" == -un ]] && echo other-user || command id \"\$@\"; }; do_spl_desk_reseat_dead" in_orc SPL_STATE_DIR="$S" \
  SPOOL_BOX_USER="$ME" DESK_BOOT_TIME="$((NOW - 300))" DRY_RUN=0 2>&1)"
[[ "$out" != *"CALL up"* && "$out" == *"belongs to $ME: re-seated by $ME's tick, not as other-user"* ]] &&
  pass "2b. a desk owned by another user than the caller: no re-seat, left to its owner's tick" || fail "2b. other owner: $out"
out="$(reseat DRY_RUN=1)"
[[ "$out" != *"CALL up"* && "$out" == *"DRY_RUN would: re-seat dead desk box-desk of t1 (dev) as $ME"* ]] &&
  pass "2. the dry run names the re-seat and makes none" || fail "2. dry run: $out"

# --- 3. (d) box-restart's after-check names the dead desk ---------------------------------
PEND="$T/pending"; printf 'utc\t20261101T023021Z\n' >"$PEND"
after() { SNIPPET="spl_brx_after_dead_desks $PEND; echo rc=\$?; spl_brx_dead_desk_names $PEND" \
  in_orc SPL_STATE_DIR="$S" SPOOL_BOX_USER="$ME" BOX_RESTART_DESK_ENVS=dev 2>&1; }
out="$(after)"
[[ "$out" == *"ERROR dead desk after the restart: env=dev tenant=t1 box=box-desk user=$ME"* && "$out" == *"rc=1"* &&
   "$out" == *" - dead desks: dev/t1/box-desk ($ME)"* ]] && grep -qP "^dead_desk\tdev\tt1\tbox-desk\t$ME$" "$PEND" &&
  pass "3d. the after-check names the dead desk: env, tenant, box, user (log, record, final line)" || fail "3d. $out | $(cat "$PEND")"
bash -c 'exec -a "spool hub-run" sleep 120' & live_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'hub-run' "/proc/$live_pid/cmdline" 2>/dev/null && break; sleep 0.1; done
desk "$live_pid" before; printf 'utc\tx\n' >"$PEND"
out="$(after)"
kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
[[ "$out" == *"OK no dead desk sidecar in dev"* && "$out" == *"rc=0"* && "$out" != *"dead desks:"* ]] &&
  pass "3d. CONTROL every sidecar live: OK, rc 0, no name" || fail "3d. control: $out"

echo "desk-reseat-dead: ${fails} failure(s)"
[ "$fails" -eq 0 ]
