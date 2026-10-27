#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: adding a seat never restarts the box's live hub-run sidecar
#          (SPL-3713, lessons-learnt row 7). Seating agents one by one
#          restarted the box link each time, so the WUI showed the box offline
#          while it worked. Measured on prd sat 2026-10-26..27: every one of
#          the 432 restarts in the desk reconcile log was the "spool binary
#          rebuilt" branch (SPL-952), none a SPOOL_POKE mismatch - and a seat
#          call rebuilds that binary itself (spl_host_spool) whenever its tree
#          is newer, so the same call then found its own sidecar stale.
#   1. RED: a live sidecar, its binary rebuilt, a NEW agent seated: the same
#      pid serves on (hub-run picks the new inbox up on its own rescan)
#   2. CONTROL: the same rebuild with a RE-seat of an agent already on the
#      box still restarts it on the new binary (SPL-952 kept: the reconcile
#      tick re-seats every agent, so the box catches up within one tick)
#   3. a restart stays where a flag is read at exec: a new seat asking for
#      another DESK_BOX_POKE restarts it, and says why
#   4. CONTROL: no rebuild, a new seat: the same pid
# A sandbox desk under $T: the real spl_desk_sidecar and spl_desk_detach, a
# fake spool binary (a copy of bash running ./hub-run), no hub, no tmux.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

D="$T/state/prd/desk/t1/box-desk"
PIDF="$D/spool/.hub/hub-run.pid"
mkfifo "$T/hold.fifo"
# The fake sidecar: `<fake spool> hub-run` is bash running this script, so
# /proc/<pid>/exe is the fake binary and the cmdline carries " hub-run". It
# blocks on a read of a fifo (no child) and exits on SIGTERM.
printf 'read -r -t 120 _ <>"%s"\n' "$T/hold.fifo" >"$T/hub-run"
cp "$(command -v bash)" "$T/fake-spool"; chmod +x "$T/fake-spool"

# up <env assignments...>: one do_spl_desk_up on the sandbox desk. REBUILD=1
# makes the stubbed spl_host_spool replace the binary file, as a build does.
up() {
  ( cd "$T" && env -u AGENT_ID -u SPOOL_AGENT_ID -u MCP_BOT_AGENT_ID -u TMUX_PANE -u CLE_TMUX_PANE \
      PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/prd" SPL_CNF=/dev/null \
      SPL_ORG_APP="$(basename "$PROJ_ROOT" | sed 's/-orc$//')" FAKE="$T/fake-spool" \
      ENV=prd TENANT_ID=t1 DESK_BOX=box-desk DESK_NOTIFY_CMD=off DESK_WAIT_SECS=0 DRY_RUN=0 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_box_ws_guard() { return 0; }
    do_spl_desk_cnf() { SPL_HUB_URL=https://hub.example.com SPL_WUI_URL=https://example.com; return 0; }
    spl_desk_up_caller_ok() { return 0; }
    spl_host_spool() {
      SPL_SPOOL="$FAKE"
      [[ "${REBUILD:-0}" == 1 ]] && { rm -f "$FAKE"; cp "$(command -v bash)" "$FAKE"; chmod +x "$FAKE"; }
      return 0
    }
    spl_desk_cap_check() { return 0; }
    spl_desk_pin() { echo pub; }
    spl_desk_keep_ids() { :; }
    spl_desk_wait_roster() { return 0; }
    spl_desk_show_pane() { :; }
    do_spl_desk_up' 2>&1 )
}
pid_now() { cat "$PIDF" 2>/dev/null; }
alive() { kill -0 "$1" 2>/dev/null; }
# live_on_binary <pid>: 0 once the pid runs the fake binary (not yet "(deleted)")
live_on_binary() {
  for _ in $(seq 50); do
    [[ "$(readlink "/proc/$1/exe" 2>/dev/null)" == "$T/fake-spool" ]] && return 0
    sleep 0.1
  done
  return 1
}
cleanup_sidecar() { local p; p="$(pid_now)"; [[ -n "$p" ]] && kill "$p" 2>/dev/null; }
trap 'cleanup_sidecar; rm -rf "$T"' EXIT

# --- setup: the first seat starts the sidecar -------------------------------------
out=$(up DESK_AGENT=c-101); rc=$?
p0="$(pid_now)"
[[ $rc -eq 0 && "$out" == *"started the hub-run sidecar of box-desk"* && -n "$p0" ]] && live_on_binary "$p0" &&
  pass "CONTROL the first seat starts the sandbox sidecar (pid $p0)" || fail "first seat (rc=$rc): $out"

# --- 4. CONTROL: no rebuild, a new seat keeps the pid ------------------------------
out=$(up DESK_AGENT=c-102); rc=$?
[[ $rc -eq 0 && "$(pid_now)" == "$p0" && "$out" == *"is already live"* ]] && alive "$p0" &&
  pass "CONTROL no rebuild: seating c-102 keeps the live sidecar (pid $p0)" || fail "no rebuild, new seat (rc=$rc): $out"

# --- 1. RED: the binary rebuilt, a NEW seat: the same pid serves on ----------------
out=$(up DESK_AGENT=c-103 REBUILD=1); rc=$?
[[ "$(readlink "/proc/$p0/exe" 2>/dev/null)" == *" (deleted)" || "$(pid_now)" != "$p0" ]] &&
  pass "CONTROL the rebuild replaced the binary under the live sidecar" || fail "the rebuild did not make the sidecar stale"
[[ $rc -eq 0 && "$(pid_now)" == "$p0" ]] && alive "$p0" &&
  pass "a new seat after a rebuild keeps the live sidecar (pid $p0): the box link stays up" ||
  fail "seating c-103 after a rebuild restarted the sidecar ($p0 -> $(pid_now), rc=$rc): $out"
[[ "$out" == *"left for the next re-seat"* ]] &&
  pass "…and it says the stale sidecar is left for the next re-seat" || fail "no 'left for the next re-seat' line: $out"

# --- 2. CONTROL: a re-seat after the rebuild restarts it (SPL-952) -----------------
out=$(up DESK_AGENT=c-101); rc=$?
p1="$(pid_now)"
[[ $rc -eq 0 && -n "$p1" && "$p1" != "$p0" && "$out" == *"rebuilt since it started; restarting it"* ]] && ! alive "$p0" &&
  live_on_binary "$p1" &&
  pass "CONTROL re-seating c-101 restarts the stale sidecar on the new binary ($p0 -> $p1)" || fail "re-seat after rebuild (rc=$rc): $out"

# --- 3. a flag read at exec: another DESK_BOX_POKE restarts, and says why ----------
out=$(up DESK_AGENT=c-104 DESK_BOX_POKE=0); rc=$?
p2="$(pid_now)"
[[ $rc -eq 0 && -n "$p2" && "$p2" != "$p1" && "$out" == *"SPOOL_POKE=1 but this call asks for 0; restarting it, because that flag is only read at exec"* ]] &&
  pass "a new seat asking for DESK_BOX_POKE=0 restarts it, naming the exec-time flag ($p1 -> $p2)" ||
  fail "box poke change (rc=$rc): $out"

exit $(( fails > 0 ))
