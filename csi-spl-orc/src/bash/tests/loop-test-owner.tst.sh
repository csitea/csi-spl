#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a loop a test starts ends with that test (SPL-4566). On sat on
#          2026-10-30, 3 watchdog loops (wd-self-update.tst.sh) and 1 lease
#          watch loop (dispatch-lease.tst.sh) ran for 5 days with ppid 1:
#          their test had been killed, so its EXIT trap, the only stop, never
#          ran. test-lib.inc.sh now exports SPL_TEST_OWNER (the test shell's
#          pid and start time) and both loops end once that process is gone.
#   1. spl_test_owner_gone: unset -> not gone (a live loop is never touched);
#      a live owner -> not gone; a dead pid -> gone; a live pid whose start
#      time differs (a reused pid) -> gone; garbage -> gone
#   2. the lease loop (spl_lease_loop, LEASE_CMD=watch) ends within 6 s of
#      its owner's death; CONTROL: with its owner alive it still runs
#   3. the watchdog loop (do_spl_watchdog) the same, with its control
#  Each loop is bounded (LEASE_TICKS / WD_TICKS, 1 s ticks), so on the code
#  before the fix (the red) the loop still ends on its own and leaks nothing.
#  The owner is a sleep this test starts and kills: its own child pid.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
S="$T/spool"; D="$S/dispatch"
mkdir -p "$D" "$T/bin" "$T/proc" "$T/tmux"
printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\nSPOOL_BOX_TAG=box1\nSPOOL_DESK_BOX=box1\n' "$(id -un)" "$(id -un)" > "$S/box.env"

# owner_of <pid>: the SPL_TEST_OWNER value for <pid>, as test-lib.inc.sh writes it
owner_of() { echo "$1:$(awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/$1/stat")"; }
gone() {
  env SPL_TEST_OWNER="$1" PROJ_PATH="$PROJ_ROOT" bash -c '
    source "$PROJ_PATH/src/bash/features/spawn-agents/lib/spool-env.inc.sh"
    if spl_test_owner_gone; then echo gone; else echo alive; fi' 2>&1
}

# ---- 1. units -------------------------------------------------------------------
sleep 300 & O=$!
own="$(owner_of "$O")"
dead_pid=$(( $(cat /proc/sys/kernel/pid_max) - 1 ))
[[ "$(gone '')" == alive ]] && pass "1 no SPL_TEST_OWNER: not gone" || fail "1 unset: $(gone '')"
[[ "$(gone "$own")" == alive ]] && pass "1 a live owner: not gone" || fail "1 live: $(gone "$own")"
[[ "$(gone "$dead_pid:1")" == gone ]] && pass "1 a dead pid: gone" || fail "1 dead: $(gone "$dead_pid:1")"
[[ "$(gone "$O:1")" == gone ]] && pass "1 a live pid with another start time (reused): gone" || fail "1 reused: $(gone "$O:1")"
[[ "$(gone "x")" == gone ]] && pass "1 a garbled value: gone" || fail "1 garbled: $(gone x)"
kill "$O" 2>/dev/null; wait "$O" 2>/dev/null

# ends_with_owner <label> <lock> <cmd...>: start the loop under a fresh owner,
# wait until it holds <lock>; CONTROL: 2 s later, owner alive, it still holds
# it; then kill the owner: the loop must free the lock within 6 s.
held() { [[ -f "$1" ]] && ! flock -n "$1" true; }
wait_held() { local i; for (( i = 0; i < 100; i++ )); do held "$1" && return 0; sleep 0.1; done; return 1; }
wait_free() { local i; for (( i = 0; i < $2 * 10; i++ )); do held "$1" || return 0; sleep 0.1; done; return 1; }
ends_with_owner() {
  local label="$1" lock="$2" o lp; shift 2
  sleep 300 & o=$!
  SPL_TEST_OWNER="$(owner_of "$o")" "$@" >"$T/$label.out" 2>&1 & lp=$!
  if ! wait_held "$lock"; then
    fail "$label: the loop never started: $(tail -5 "$T/$label.out")"
  else
    sleep 2
    if held "$lock"; then pass "$label CONTROL: with its owner alive the loop still runs"
    else fail "$label CONTROL: the loop ended with its owner alive: $(tail -5 "$T/$label.out")"; fi
    kill "$o"; wait "$o" 2>/dev/null
    if wait_free "$lock" 6; then pass "$label: the loop ended within 6 s of its owner's death"
    else fail "$label: the loop outlived its owner by 6 s: $(tail -3 "$T/$label.out")"; fi
  fi
  kill "$o" 2>/dev/null; wait "$o" "$lp" 2>/dev/null
}

# ---- 2. the lease loop ----------------------------------------------------------------
lease() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" LEASE_PROC_ROOT="$T/proc" LEASE_SEND=true LEASE_PANE_CMD=true \
    LEASE_MASTER=M-1 LEASE_FAILOVER=F-1 LEASE_ORCH=O-1 LEASE_ALLOW_STALE=1 LEASE_PERIOD=1 LEASE_TICKS=30 "$@" bash -c '
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    spl_lease_init || exit 1
    do_spl_dispatch_lease'
}
ends_with_owner "2 lease watch" "$D/watch.run" lease LEASE_CMD=watch

# ---- 3. the watchdog loop -------------------------------------------------------------
: > "$T/ps"; : > "$T/tmux/panes"
printf '#!/usr/bin/env bash\ncat "%s/ps"\n' "$T" > "$T/bin/ps"
printf '#!/usr/bin/env bash\n[ "$1" = list-panes ] && cat "%s/tmux/panes"\nexit 0\n' "$T" > "$T/bin/tmux"
chmod +x "$T/bin/"*
wd() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" LEASE_PROC_ROOT="$T/proc" \
    WD_PS_CMD="$T/bin/ps" ROTATE_TMUX="$T/bin/tmux" WD_SEND=true WD_TAKEOVER_CMD=true \
    LEASE_TRANSCRIPT_CMD=true WD_TICK=1 WD_TICKS=30 "$@" bash -c '
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-watchdog.func.sh"
    do_spl_watchdog'
}
ends_with_owner "3 watchdog" "$D/wd/run.lock" wd

echo "$( (( fails == 0 )) && echo PASSED || echo "FAILED ($fails)" ): loop-test-owner"
(( fails == 0 ))
