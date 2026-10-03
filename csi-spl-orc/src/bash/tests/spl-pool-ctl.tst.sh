#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_pool_ctl (spec 071 section 4), the one start/stop/status
#          action of a box's runtimes, against STUB runtimes: the desk
#          sidecars, the lease loop, the peer poll loops and `pool serve` are
#          `sleep` processes under the argv0, pid file and lock the real ones
#          use, so the action's real status reads (spl_desk_alive,
#          spl_lease_running, spl_peer_running) and the real lease and peer
#          stops run against them.
#   1. before start every runtime row reads stopped (the CONTROL of 2)
#   2. start (DRY_RUN=0) then status: every row running
#   3. stop then status: every row stopped (CONTROL: 2 read running)
#   4. stop twice is a no-op: no stop call, exit 0. CONTROL: the first stop
#      made the calls
#   5. a binary without `pool serve` (with or without do_spl_pool_serve) reads "not built yet (spec 070 L3)" and
#      start does not fail. CONTROL: a binary with it, and do_spl_pool_serve
#      landed, run it and read running
#   6. an interactive pane is never killed: a `spool pool serve` running IN a
#      tmux pane, named by serve.pid, is refused and lives; an agent pane
#      lives through every stop. CONTROL: the same process outside a pane is
#      stopped
#   7. DRY_RUN defaults to 1: start makes no call. CONTROL: 2 made them
#   8. ENV=dev never stops the box rows of the prd box env. CONTROL: 3 stopped
#      them with ENV = box env
#   9. ensure while paused touches nothing; with only the lease pause it
#      starts the rest and keeps the lease down. CONTROL: ensure unpaused starts
#  10. each `# csi-spl:<tag>` crontab line is a cron:<tag> row
# No real crontab, no real tmux, no cloud call.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
cleanup() {
  local p
  while read -r p; do kill -- "-$p" 2>/dev/null; kill "$p" 2>/dev/null; done <"$T/pids" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT
: >"$T/pids"

mkdir -p "$T/stub" "$T/root/dispatch" "$T/root/peer" "$T/state/dev/bin"
for d in t1/box-desk acme/box-desk; do mkdir -p "$T/state/dev/desk/$d/spool/.hub"; done
printf 'LEASE_FLEET=main\nLEASE_ENV=dev\nLEASE_TENANT=t1\n' >"$T/root/dispatch/lease.conf"
printf 'c-201 claude\nc-202 grok\n' >"$T/root/peer/seats"
: >"$T/panes"
printf '1 2 * * * /bin/true # csi-spl:desk-reconcile\n' >"$T/crontab"

cat >"$T/stub/tmux" <<'EOF'
#!/bin/sh
case "$*" in *list-panes*) cat "$STUB_PANES" ;; esac
exit 0
EOF
cat >"$T/stub/crontab" <<'EOF'
#!/bin/sh
[ "$1" = -l ] && cat "$STUB_CRONTAB"
exit 0
EOF
# the spool binary of the state dir: `pool serve` only once $T/built exists
cat >"$T/state/dev/bin/spool" <<'EOF'
#!/bin/sh
if [ "$1" = pool ] && [ ! -e "$STUB_BUILT" ]; then echo 'unknown command "pool"'; exit 2; fi
exit 0
EOF
chmod +x "$T/stub/"* "$T/state/dev/bin/spool"

# The stub actions: started runtimes are sleeps under the real argv0 / pid
# file / lock; the lease and peer STOPS are the real ones.
cat >"$T/stubs.sh" <<'EOF'
stub_bg() {
  if [[ -n "${3:-}" ]]; then
    setsid flock "$3" bash -c "exec -a '$1' sleep 300" </dev/null >/dev/null 2>&1 &
    echo $! >"$2"; echo $! >>"$T_PIDS"
    local i; for ((i = 0; i < 50; i++)); do flock -n "$3" true || break; sleep 0.1; done
  else
    bash -c "exec -a '$1' sleep 300" </dev/null >/dev/null 2>&1 &
    echo $! >"$2"; echo $! >>"$T_PIDS"
  fi
}
do_spl_desk_up_all() {
  echo "desk_up_all ENV=$ENV TENANT_ID=$TENANT_ID DESK_MUTE=${DESK_MUTE:-}" >>"$STUB_LOG"
  local d; for d in "$SPL_STATE_DIR"/desk/*/*; do
    spl_desk_alive "$d/spool/.hub/hub-run.pid" || stub_bg "spool hub-run" "$d/spool/.hub/hub-run.pid"
  done
}
do_spl_desk_up_tenants() { echo "desk_up_tenants skip=$DESK_SKIP_TENANTS" >>"$STUB_LOG"; }
do_spl_desk_up_boxes() { echo "desk_up_boxes" >>"$STUB_LOG"; }
do_spl_desk_down() {
  echo "desk_down $TENANT_ID/$DESK_BOX all=$DESK_ALL" >>"$STUB_LOG"
  local f="$SPL_STATE_DIR/desk/$TENANT_ID/$DESK_BOX/spool/.hub/hub-run.pid"
  kill "$(cat "$f")" 2>/dev/null; rm -f "$f"
}
eval "orig_$(declare -f do_spl_dispatch_lease)"
do_spl_dispatch_lease() {
  echo "lease $LEASE_CMD" >>"$STUB_LOG"
  if [[ "$LEASE_CMD" == ensure ]]; then
    spl_lease_init; spl_lease_running fleet || stub_bg lease-fleet "$LEASE_DIR/fleet.pid" "$LEASE_DIR/fleet.run"
  else orig_do_spl_dispatch_lease; fi
}
do_spl_peer_ensure() {
  echo "peer_ensure" >>"$STUB_LOG"
  spl_peer_init ro; local id
  while read -r id _; do
    mkdir -p "$PEER_DIR/$id"
    spl_peer_running "$id" || stub_bg peer-poll "$PEER_DIR/$id/poll.pid" "$PEER_DIR/$id/poll.run"
  done < <(spl_peer_seats)
}
if [[ -e "$STUB_BUILT" || -n "${STUB_POOL_FN:-}" ]]; then
  do_spl_pool_serve() {
    echo "pool_serve ENV=$ENV" >>"$STUB_LOG"; mkdir -p "$SPOOL_ROOT/pool"
    pool_ctl_serve_alive || stub_bg "spool pool serve" "$SPOOL_ROOT/pool/serve.pid"
  }
fi
EOF

ctl() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" SPOOL_ROOT="$T/root" \
    STUB_LOG="$T/calls.log" STUB_PANES="$T/panes" STUB_CRONTAB="$T/crontab" STUB_BUILT="$T/built" \
    T_PIDS="$T/pids" SPOOL_TEST=1 PATH="$T/stub:$PATH" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    source "'"$T"'/stubs.sh"
    do_spl_pool_ctl' 2>&1
}
calls() { wc -l <"$T/calls.log" 2>/dev/null || echo 0; }
: >"$T/calls.log"
rows() { grep -E '^(desk:|lease |peer:|pool-serve )' <<<"$1"; }

# ---- 1. before start ---------------------------------------------------------
out="$(ctl POOL_CMD=status)"
if [[ "$(rows "$out" | grep -c ' stopped ')" == 5 && -z "$(rows "$out" | grep ' running ')" ]]; then
  pass "1 before start: desk x2, lease, peer x2 read stopped"
else fail "1 before start should read 5 stopped rows: $out"; fi

# ---- 7. DRY_RUN defaults to 1 -----------------------------------------------
out="$(ctl POOL_CMD=start)"
if [[ "$(calls)" == 0 && "$out" == *"PLAN desk:"* && "$out" == *"PLAN lease:"* ]]; then
  pass "7 start without DRY_RUN plans and calls nothing"
else fail "7 a default start made calls ($(calls)) or planned nothing: $out"; fi

# ---- 2. start then status ----------------------------------------------------
ctl POOL_CMD=start DRY_RUN=0 >"$T/start.out"; rc=$?
started="$(calls)"
st_up="$(ctl POOL_CMD=status)"
if [[ "$rc" == 0 && "$(rows "$st_up" | grep -c ' running ')" == 5 && -z "$(rows "$st_up" | grep ' stopped ')" ]]; then
  pass "2 start then status: all 5 runtime rows running"
else fail "2 start (rc $rc) then status should be all running: $(cat "$T/start.out") // $st_up"; fi
if (( started > 0 )); then pass "7 CONTROL: DRY_RUN=0 made the calls ($started)"
else fail "7 CONTROL: DRY_RUN=0 made no call - check 7 proves nothing"; fi
grep -q 'desk_up_all ENV=dev TENANT_ID=t1' "$T/calls.log" &&
  grep -q 'desk_up_tenants skip=t1' "$T/calls.log" && grep -q '^lease ensure' "$T/calls.log" &&
  grep -q '^peer_ensure' "$T/calls.log" &&
  pass "2 start went through the existing actions (desk up all/tenants, lease ensure, peer ensure)" ||
  fail "2 start skipped an existing action: $(cat "$T/calls.log")"

# ---- 5. pool serve not built -------------------------------------------------
if grep -q '^pool-serve  *missing  *not built yet (spec 070 L3)' <<<"$st_up" && grep -q 'SKIP pool-serve: not built yet' "$T/start.out"; then
  pass "5 no 'pool serve' in the binary: missing, not built yet (spec 070 L3); start still exit 0"
else fail "5 an unbuilt pool serve should read 'not built yet': $st_up"; fi

# the action landed but the binary lacks the subcommand: still not built
: >"$T/calls.log"
out="$(ctl STUB_POOL_FN=1 POOL_CMD=start DRY_RUN=0)"
st="$(ctl STUB_POOL_FN=1 POOL_CMD=status)"
if grep -q '^pool-serve  *missing  *not built yet (spec 070 L3)$' <<<"$st" && ! grep -q '^pool_serve' "$T/calls.log"; then
  pass "5 do_spl_pool_serve landed, binary without 'pool serve': not built yet, never run"
else fail "5 a binary without 'pool serve' was run or read built: $out // $st"; fi

# ---- 10. cron rows -----------------------------------------------------------
grep -q '^cron:desk-reconcile  *running  *installed' <<<"$st_up" &&
  pass "10 the tagged crontab line is a cron row" || fail "10 no cron:desk-reconcile row: $st_up"

# ---- 6 (setup). an agent pane that must outlive every stop ------------------
bash -c "exec -a claude sleep 300" </dev/null >/dev/null 2>&1 & agent=$!; echo "$agent" >>"$T/pids"
echo "$agent" >>"$T/panes"

# ---- 3. stop then status -----------------------------------------------------
: >"$T/calls.log"
ctl POOL_CMD=stop DRY_RUN=0 >"$T/stop.out"; rc=$?
first_stop="$(calls)"
out="$(ctl POOL_CMD=status)"
if [[ "$rc" == 0 && "$(rows "$out" | grep -c ' stopped ')" == 5 && -z "$(rows "$out" | grep ' running ')" ]]; then
  pass "3 stop then status: all 5 runtime rows stopped"
else fail "3 stop (rc $rc) then status should be all stopped: $(cat "$T/stop.out") // $out"; fi
[[ "$(rows "$st_up" | grep -c ' running ')" == 5 ]] && pass "3 CONTROL: the same rows read running before the stop" ||
  fail "3 CONTROL: the rows never read running - check 3 proves nothing"
[[ -e "$T/root/.desk-reconcile.dev.pause" ]] && pass "3 stop wrote the reconcile pause marker" ||
  fail "3 stop wrote no pause marker: the reconcile would re-seat the desks"
[[ -e "$T/root/dispatch/lease.pause" ]] && pass "3 stop (box env) wrote the lease pause: the reconcile will not re-take the lease (spec 071 4.4)" ||
  fail "3 stop wrote no lease pause: the next reconcile tick re-takes the lease"

# ---- 4. stop twice -----------------------------------------------------------
: >"$T/calls.log"
out="$(ctl POOL_CMD=stop DRY_RUN=0)"; rc=$?
if [[ "$rc" == 0 && "$(calls)" == 0 ]]; then pass "4 the second stop is a no-op (no call, exit 0)"
else fail "4 the second stop made $(calls) call(s) or exit $rc: $out"; fi
(( first_stop >= 3 )) && pass "4 CONTROL: the first stop made $first_stop calls (desk down x2, lease stop)" ||
  fail "4 CONTROL: the first stop made only $first_stop call(s) - check 4 proves nothing"

# ---- 9. ensure while paused --------------------------------------------------
: >"$T/calls.log"
out="$(ctl POOL_CMD=ensure DRY_RUN=0)"
if [[ "$(calls)" == 0 && "$out" == *"is paused by"* ]]; then pass "9 ensure while paused touches nothing"
else fail "9 ensure while paused made $(calls) call(s): $out"; fi
rm -f "$T/root/.desk-reconcile.dev.pause"
out="$(ctl POOL_CMD=ensure DRY_RUN=0)"
st="$(ctl POOL_CMD=status)"
if grep -q '^lease  *stopped' <<<"$st" && [[ "$(grep -c '^peer:c-20[12]  *running' <<<"$st")" == 2 ]] && grep -q 'SKIP lease: paused by' <<<"$out"; then
  pass "9 ensure with only the lease paused starts the rest and keeps the lease down"
else fail "9 ensure re-took a paused lease: $out // $st"; fi
rm -f "$T/root/dispatch/lease.pause"
out="$(ctl POOL_CMD=ensure DRY_RUN=0)"
if (( $(calls) > 0 )) && [[ "$(rows "$(ctl POOL_CMD=status)" | grep -c ' running ')" == 5 ]]; then
  pass "9 CONTROL: ensure unpaused starts every row"
else fail "9 CONTROL: ensure unpaused did not start the rows: $out"; fi

# ---- 8. ENV=dev never stops the prd box rows --------------------------------
sed -i 's/^LEASE_ENV=dev$/LEASE_ENV=prd/' "$T/root/dispatch/lease.conf"
out="$(ctl POOL_CMD=stop DRY_RUN=0)"
st="$(ctl POOL_CMD=status)"
if grep -q '^lease  *running' <<<"$st" && [[ "$(grep -c '^peer:c-20[12]  *running' <<<"$st")" == 2 ]] && grep -q 'SKIP lease, peer' <<<"$out"; then
  pass "8 ENV=dev stop with box env prd: the lease and peer loops keep running"
else fail "8 ENV=dev stop touched the prd box rows: $out // $st"; fi
[[ ! -e "$T/root/dispatch/lease.pause" ]] && pass "8 ... and wrote no lease pause" || fail "8 ENV=dev stop paused the prd lease"
grep -q '^desk:t1/box-desk  *stopped' <<<"$st" && pass "8 ... and the dev desks did stop" || fail "8 the dev desks did not stop: $st"
sed -i 's/^LEASE_ENV=prd$/LEASE_ENV=dev/' "$T/root/dispatch/lease.conf"
ctl POOL_CMD=stop DRY_RUN=0 >/dev/null

# ---- 5 CONTROL. a built pool serve --------------------------------------------
touch "$T/built"
: >"$T/calls.log"
out="$(ctl POOL_CMD=start DRY_RUN=0)"
[[ ! -e "$T/root/dispatch/lease.pause" && ! -e "$T/root/.desk-reconcile.dev.pause" ]] && pass "start lifts both pause markers" ||
  fail "start left a pause marker: $(ls -a "$T/root" "$T/root/dispatch")"
st="$(ctl POOL_CMD=status)"
if grep -q '^pool_serve ENV=dev' "$T/calls.log" && grep -q '^pool-serve  *running' <<<"$st" && ! grep -q 'not built' <<<"$st"; then
  pass "5 CONTROL: a binary with 'pool serve' runs do_spl_pool_serve and reads running"
else fail "5 CONTROL: a built pool serve was not run: $out // $st"; fi

# ---- 6. the pane guard -------------------------------------------------------
out="$(ctl POOL_CMD=stop DRY_RUN=0)"
st="$(ctl POOL_CMD=status)"
grep -q '^pool-serve  *stopped' <<<"$st" && pass "6 CONTROL: a pool serve outside any pane is stopped" ||
  fail "6 CONTROL: the pool serve outside a pane was not stopped: $out // $st"
bash -c "exec -a 'spool pool serve' sleep 300" </dev/null >/dev/null 2>&1 & inpane=$!
echo "$inpane" >>"$T/pids"; echo "$inpane" >>"$T/panes"; echo "$inpane" >"$T/root/pool/serve.pid"
rm -f "$T/root/.desk-reconcile.dev.pause"
out="$(ctl POOL_CMD=stop DRY_RUN=0)"
if kill -0 "$inpane" 2>/dev/null && [[ "$out" == *"REFUSE pool-serve: pid $inpane runs in a tmux pane"* ]]; then
  pass "6 a 'spool pool serve' running in a tmux pane is refused and lives"
else fail "6 the in-pane pool serve was killed or not refused: $out"; fi
kill -0 "$agent" 2>/dev/null && pass "6 the agent pane process outlived every stop" ||
  fail "6 the agent pane process was killed"

echo "spl-pool-ctl: $fails failure(s)"
[[ $fails -eq 0 ]]
