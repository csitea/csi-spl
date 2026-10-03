#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_dispatch_tick, the dispatchers' upkeep on every desk cron
#          tick (2026-10-01: two channels created after the morning's
#          subscribe reached nobody until it was re-run by hand). The hub DB is
#          fixture files the stub add runner appends to (as the hub would), the
#          check a stub printing its table, the note sender a stub.
#   1. no lease.conf: nothing runs, nothing is printed
#   2. a new channel: the next tick subscribes every OD seat to it
#   3. no change: the next tick calls no runner, prints nothing, writes nothing
#   4. a dead subscription: logged once per agent, never sent
#   5. a new check GAP on prd: logged and ONE note to the lease holder; the
#      same gap with another value is not new; still open after
#      DISPATCH_GAP_ESCALATE s: the orchestrator told once; a gone gap is
#      logged as cleared; on dev the same gap is logged and never sent
#   6. a failing subscribe fails the tick and prints its output
#   7. desk-reconcile-cron.sh logs only the tick's DISPATCH lines, a failing
#      tick makes the tick exit 1, DESK_DISPATCH=0 skips it
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

P="$T/proc" S="$T/spool" SUBS="$T/subs"
mkdir -p "$P" "$S/dispatch" "$SUBS" "$T/state/desk/w1/box-desk"
touch "$T/state/desk/w1/box-desk/pinned"
mkdir -p "$P/101"; echo claude >"$P/101/comm"; printf 'HOME=/x\0SPOOL_AGENT_ID=CLE-8\0' >"$P/101/environ"
printf 'chan|lobby\nros|box-desk|c-001\nros|box-desk|CLE-002\nros|box-desk|CLE-003\nsub|lobby|box-desk|c-001|invite\nsub|lobby|box-desk|CLE-002|invite\nsub|lobby|box-desk|CLE-003|invite\n' >"$SUBS/w1.txt"
printf '| what | value | verdict |\n|---|---|---|\n| CLE-002 process | pid 7, SPOOL_AGENT_ID=CLE-002 | ok |\n' >"$T/check"

tick() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$T/repo" SPL_STATE_DIR="$T/state" LEASE_PROC_ROOT="$P" \
    DISPATCH_SUBS_DIR="$SUBS" SPOOL_ROOT="$S" ENV=prd CALLS="$T/calls" CHECK="$T/check" \
    DISPATCH_TICK_SEND="$T/send.sh" SENT="$T/sent" SPOOL_BIN=/bin/true "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/src/bash/run/spl-dispatch-*.func.sh; do source "$f"; done
    _spl_channel_agent_add_op_run() {
      echo "add $*" >>"$CALLS"
      [[ "${FAIL_ADD:-}" == "$2" ]] && return 1
      local a; for a in $4; do echo "sub|$2|$3|$a|invite" >>"$DISPATCH_SUBS_DIR/$1.txt"; done
    }
    _spl_channel_agent_remove_op_run() { echo "remove $*" >>"$CALLS"; }
    do_spl_dispatch_check() { cat "$CHECK"; grep -q "| GAP" "$CHECK" && return 1; return 0; }
    do_spl_dispatch_tick' >"$T/o" 2>&1
}
printf '#!/usr/bin/env bash\necho "send $*" >>"$SENT"\nwhile [ $# -gt 0 ]; do [ "$1" = --body-file ] && cat "$2" >>"$SENT"; shift; done\n' >"$T/send.sh"
chmod +x "$T/send.sh"

# --- 1. no opt-in ---------------------------------------------------------------------------
echo 'chan|newc' >>"$SUBS/w1.txt"
: >"$T/calls"
tick; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" && ! -s "$T/o" && ! -e "$S/dispatch/gaps.prd.state" ]] &&
  pass "1. without lease.conf the tick does nothing and prints nothing" || fail "1. rc=$rc $(cat "$T/calls" "$T/o")"

# --- 2. a new channel ------------------------------------------------------------------------
printf 'LEASE_MASTER=CLE-002\nLEASE_FAILOVER=CLE-003\nLEASE_ORCH=c-001\n' >"$S/dispatch/lease.conf"
tick; rc=$?
[[ $rc -eq 0 && "$(cat "$T/calls")" == 'add w1 newc box-desk c-001 CLE-002 CLE-003 1' ]] &&
  grep -qx 'DISPATCH subscribe add w1 #newc c-001 CLE-002 CLE-003 (box-desk)' "$T/o" &&
  pass "2. a new channel: the next tick subscribes every OD seat, the orchestrator too, and says so" || fail "2. rc=$rc calls=$(cat "$T/calls") $(cat "$T/o")"

# --- 3. no change ----------------------------------------------------------------------------
: >"$T/calls"; touch "$T/mark"; sleep 1
tick; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" && ! -s "$T/o" ]] && [[ -z "$(find "$S/dispatch" -newer "$T/mark")" ]] &&
  pass "3. no change: no runner, no line, no write" || fail "3. rc=$rc calls=$(cat "$T/calls") $(cat "$T/o") new=$(find "$S/dispatch" -newer "$T/mark")"

# --- 4. a dead subscription ------------------------------------------------------------------
printf 'sub|lobby|box-desk|CLE-9|invite\nsub|lobby|box-desk|CLE-10|invite\nsub|newc|box-desk|CLE-8|invite\n' >>"$SUBS/w1.txt"
tick; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'DISPATCH gap DEAD w1 #lobby CLE-9' "$T/o" && grep -qx 'DISPATCH gap DEAD w1 #lobby CLE-10' "$T/o" &&
  ! grep -q 'CLE-8' "$T/o" && [[ ! -s "$T/sent" ]] &&
  pass "4. a dead subscription: one line per agent, a live one not, nothing sent" || fail "4. rc=$rc $(cat "$T/o") sent=$(cat "$T/sent" 2>&1)"
tick
[[ ! -s "$T/o" ]] && pass "4. the same dead subscriptions are not logged again" || fail "4. again: $(cat "$T/o")"

# --- 5. a check GAP --------------------------------------------------------------------------
echo '| CLE-003 process | none with SPOOL_AGENT_ID=CLE-003 | GAP not running |' >>"$T/check"
echo '| CLE-002 unread | 25 | GAP over 20 |' >>"$T/check"
tick; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'DISPATCH gap GAP CLE-003 process: GAP not running (none with SPOOL_AGENT_ID=CLE-003)' "$T/o" &&
  grep -qx 'DISPATCH gap GAP CLE-002 unread: GAP over 20 (25)' "$T/o" && grep -qx 'DISPATCH told CLE-002' "$T/o" &&
  pass "5. a new check GAP is logged and the lease holder told" || fail "5. rc=$rc $(cat "$T/o")"
[[ "$(grep -c '^send ' "$T/sent")" == 1 ]] && grep -q -- '--from c-001 --to CLE-002 --kind note --task dispatch-gaps' "$T/sent" &&
  grep -qx -- '- CLE-003 process: GAP not running (none with SPOOL_AGENT_ID=CLE-003)' "$T/sent" && ! grep -q 'DEAD' "$T/sent" &&
  pass "5. ONE note, the new GAP rows only" || fail "5. sent: $(cat "$T/sent")"
sed -i 's/| 25 |/| 31 |/' "$T/check"
tick
[[ ! -s "$T/o" && "$(grep -c '^send ' "$T/sent")" == 1 ]] && pass "5. the same gap with another value is not new" || fail "5. value: $(cat "$T/o")"
echo "CLE-003 $(date +%s)" >"$S/dispatch/lease"
tick DISPATCH_NOW=$(( $(date +%s) + 3700 ))
grep -q '^DISPATCH still open after 3600s: GAP CLE-003 process' "$T/o" && grep -qx 'DISPATCH told c-001' "$T/o" &&
  [[ "$(grep -c -- '--to c-001 ' "$T/sent")" == 1 ]] && pass "5. still open after an hour: the orchestrator told" || fail "5. escalate: $(cat "$T/o")"
tick DISPATCH_NOW=$(( $(date +%s) + 7400 ))
[[ ! -s "$T/o" && "$(grep -c '^send ' "$T/sent")" == 2 ]] && pass "5. escalated once only" || fail "5. escalate twice: $(cat "$T/o")"
echo '| lease watch loop | not running | GAP LEASE_CMD=ensure do_spl_dispatch_lease |' >>"$T/check"
tick
grep -q -- '--to CLE-003 ' "$T/sent" && pass "5. a new gap goes to the CURRENT lease holder" || fail "5. holder: $(grep '^send' "$T/sent")"
n="$(grep -c '^send ' "$T/sent")"
echo '| CLE-002 desks | 1/2, missing: w2 | GAP seat it |' >>"$T/check"
tick ENV=dev
grep -q '^DISPATCH gap GAP CLE-002 desks: GAP seat it' "$T/o" && [[ "$(grep -c '^send ' "$T/sent")" == "$n" ]] &&
  pass "5. dev: logged, never sent" || fail "5. dev: $(cat "$T/o")"
sed -i '/CLE-002 desks/d' "$T/check"
sed -i '/CLE-003 process/d' "$T/check"
tick
grep -qx 'DISPATCH cleared GAP CLE-003 process: GAP not running' "$T/o" && [[ "$(grep -c '^send ' "$T/sent")" == "$n" ]] &&
  pass "5. a gone gap is logged as cleared, nothing sent" || fail "5. cleared: $(cat "$T/o")"

# --- 5b. an unseated OD seat (owner 2026-10-03: every OD in every channel) ---------------------
cp "$SUBS/w1.txt" "$T/w1.keep"; grep -v '^ros|box-desk|c-001$' "$T/w1.keep" >"$SUBS/w1.txt"
tick ENV=dev
grep -qx 'DISPATCH gap GAP w1 OD seats: unseated, seat them with do_spl_desk_up (c-001@box-desk)' "$T/o" &&
  pass "5b. an OD seat the workspace does not seat is a GAP item" || fail "5b. unseated: $(cat "$T/o")"
cp "$T/w1.keep" "$SUBS/w1.txt"; tick ENV=dev
grep -q '^DISPATCH cleared GAP w1 OD seats' "$T/o" && pass "5b. seated again: cleared" || fail "5b. cleared: $(cat "$T/o")"

# --- 5c. SILENT while the fleet lease is held on another box (c-001, sat 2026-10-03) ----------
mkdir -p "$T/state/desk/w1/box-desk/spool/CLE-002/inbox"
cp "$SUBS/w1.txt" "$T/w1.keep"; echo 'hum|6|0' >>"$SUBS/w1.txt"
echo "CLE-002@box-desk $(date +%s)" >"$S/dispatch/lease"; tick ENV=dev
grep -q '^DISPATCH gap GAP w1 inbound: the workspace receives nothing' "$T/o" &&
  pass "5c. lease held on this box: a silent desk is a GAP (the control)" || fail "5c. control: $(cat "$T/o")"
echo "CLE-002@other-box $(date +%s)" >"$S/dispatch/lease"; tick ENV=dev
grep -q '^DISPATCH cleared GAP w1 inbound' "$T/o" && ! grep -q '^DISPATCH gap GAP w1 inbound' "$T/o" &&
  pass "5c. lease held on another box: the silent desk here is no GAP" || fail "5c. remote: $(cat "$T/o")"
cp "$T/w1.keep" "$SUBS/w1.txt"; echo "CLE-003 $(date +%s)" >"$S/dispatch/lease"; tick ENV=dev

# --- 6. failing subscribe ------------------------------------------------------------------
echo 'chan|other' >>"$SUBS/w1.txt"
tick FAIL_ADD=other; rc=$?
[[ $rc -eq 1 ]] && grep -q '^DISPATCH subscribe FAILED (prd)' "$T/o" && grep -q '^DISPATCH   .*subscription change(s) failed' "$T/o" &&
  pass "6. a failing subscribe fails the tick and shows why" || fail "6. rc=$rc $(cat "$T/o")"

# --- 6b. a silent workspace (CLE-77876) -------------------------------------------------------
sed -i '/^chan|other$/d' "$SUBS/w1.txt"
mkdir -p "$T/state/desk/w1/box-desk/spool/CLE-002/inbox"
echo 'hum|4|4' >>"$SUBS/w1.txt"
n="$(grep -c '^send ' "$T/sent")"
tick; rc=$?
[[ $rc -eq 0 ]] && grep -qx "DISPATCH gap GAP w1 inbound: the workspace receives nothing (4 human posts in 120 min, 0 inbound files on the dispatchers' desk)" "$T/o" &&
  grep -qx 'DISPATCH gap GAP w1 unsigned posts: no agent got them: no box-wui pin, see do_spl_check_box_wui_pins (4 of 4 human posts in 120 min stored unsigned)' "$T/o" &&
  [[ "$(grep -c '^send ' "$T/sent")" == $((n + 1)) ]] && grep -q -- '- w1 inbound: the workspace receives nothing' "$T/sent" &&
  pass "6b. people post, the desk receives nothing: a GAP to the lease holder" || fail "6b. rc=$rc $(cat "$T/o")"
sed -i 's/^hum|4|4$/hum|9|9/' "$SUBS/w1.txt"
tick
[[ ! -s "$T/o" ]] && pass "6b. the same silence with other counts is not new" || fail "6b. again: $(cat "$T/o")"
touch "$T/state/desk/w1/box-desk/spool/CLE-002/inbox/new.json"
sed -i 's/^hum|9|9$/hum|9|0/' "$SUBS/w1.txt"
tick
grep -q '^DISPATCH cleared GAP w1 inbound' "$T/o" && grep -q '^DISPATCH cleared GAP w1 unsigned posts' "$T/o" &&
  pass "6b. a delivered file clears it" || fail "6b. cleared: $(cat "$T/o")"

# --- 7. the cron script -----------------------------------------------------------------------
ORC_NAME="$(basename "$PROJ_ROOT")" O="$T/co/$ORC_NAME"
mkdir -p "$O/src/bash/scripts"
cp "$PROJ_ROOT/src/bash/scripts/desk-reconcile-cron.sh" "$O/src/bash/scripts/"
printf '#!/bin/sh\necho "run $*" >>"%s/runs"\n[ "$2" = do_spl_dispatch_tick ] || exit 0\necho "INFO START noise"\necho "DISPATCH subscribe add w1 #x CLE-002 CLE-003"\nexit "${TICK_RC:-0}"\n' "$T" >"$O/run"
chmod +x "$O/run"
cron() {
  env DESK_CRON_TOOLS=true DESK_TRUNK_CHECK=0 DESK_LEASE=0 DESK_WELCOME=0 DESK_RESPONDER=0 DESK_ALL_TENANTS=0 "$@" \
    bash "$O/src/bash/scripts/desk-reconcile-cron.sh" >"$T/o" 2>&1
}
cron; rc=$?
[[ $rc -eq 0 ]] && grep -q 'INFO DISPATCH subscribe add w1 #x CLE-002 CLE-003$' "$T/o" && ! grep -q noise "$T/o" &&
  pass "7. the cron logs only the tick's DISPATCH lines" || fail "7. rc=$rc $(cat "$T/o")"
cron TICK_RC=1; rc=$?
[[ $rc -eq 1 ]] && grep -q 'WARN do_spl_dispatch_tick exit 1' "$T/o" && pass "7. a failing tick fails the cron tick" || fail "7. rc=$rc $(cat "$T/o")"
: >"$T/runs"
cron DESK_DISPATCH=0
! grep -q do_spl_dispatch_tick "$T/runs" && pass "7. DESK_DISPATCH=0 skips it" || fail "7. off: $(cat "$T/runs")"

echo "dispatch-tick: $fails failure(s)"
[[ $fails -eq 0 ]]
