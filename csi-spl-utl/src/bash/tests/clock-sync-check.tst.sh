#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for rel-09: clock synchronization loss & NTP drift (SPL-2659)
# Tests do_os_clock_sync_check against a stub timedatectl, a stub chronyc and
# temp state dirs; the live clock is never read or changed.
#   1. Synchronized, offset -34us -> OK, exit 0, offset and poll reported, no note
#   2. First NTPSynchronized=no -> UNSYNCED, exit 1, since-stamp written, no note
#   3. Unsynced 29 min -> still UNSYNCED, no note
#   4. Unsynced 31 min, DRY_RUN=1 -> LOST, PLAN, no note, no alert stamp
#   5. Unsynced 31 min, DRY_RUN=0 -> LOST note to the orchestrator, alert stamp
#   6. Same state again -> throttled, no second note
#   7. Same state after the throttle -> a second note
#   8. Synchronized again, DRY_RUN=0 -> OK, both stamps removed
#   9. Synchronized, offset +1.5s -> DRIFT note
#  10. Offset "-1min 2.5s" -> DRIFT, offset_us=-62500000
#  11. Offset 999ms -> OK (the limit is |offset| > 1 s)
#  12. No timesync-status (chrony box) -> chronyc tracking read, source chrony
#  13. No NTPSynchronized answer -> ERROR, exit 1, alert planned
#  14. A failed send -> no alert stamp, so the next run retries
#  15. timedatectl / chronyc are only ever read (show, timesync-status, tracking)
#  16. Through the csi-spl-utl ./run harness -> exits 0; the probe < 100 ms
#------------------------------------------------------------------------------
set -uo pipefail

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
UTL_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC_SH="$UTL_ROOT/src/bash/run/clock-sync-check.func.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

BIN_DIR="$T/bin"
mkdir -p "$BIN_DIR" "$T/state"
TDC_STATUS="$T/timesync-status.out"
CHR_OUT="$T/chronyc.out"
ARGS_LOG="$T/args.log"
SEND_LOG="$T/send.log"
STATE_DIR="$T/state"
SINCE="$STATE_DIR/unsynced-since"
STAMP="$STATE_DIR/last-alert.stamp"

cat >"$BIN_DIR/timedatectl" <<'EOF'
#!/bin/bash
echo "timedatectl $*" >>"$ARGS_LOG"
case "$1" in
  show) [[ -n "$TDC_SYNC" ]] && printf 'NTPSynchronized=%s\nNTP=%s\n' "$TDC_SYNC" "$TDC_NTP"; exit 0 ;;
  timesync-status) [[ -f "$TDC_STATUS" ]] || exit 1; cat "$TDC_STATUS" ;;
  *) exit 3 ;;
esac
EOF
cat >"$BIN_DIR/chronyc" <<'EOF'
#!/bin/bash
echo "chronyc $*" >>"$ARGS_LOG"
[[ "$1" == tracking && -f "$CHR_OUT" ]] || exit 1
cat "$CHR_OUT"
EOF
cat >"$BIN_DIR/send.sh" <<'EOF'
#!/bin/bash
echo "SEND $*" >>"$SEND_LOG"
EOF
printf '#!/bin/bash\nexit 1\n' >"$BIN_DIR/failing-send.sh"
chmod +x "$BIN_DIR"/*

export TDC_STATUS CHR_OUT ARGS_LOG SEND_LOG
export TDC_SYNC=yes TDC_NTP=yes
export CLOCK_SYNC_TIMEDATECTL_BIN="$BIN_DIR/timedatectl"
export CLOCK_SYNC_CHRONYC_BIN="$BIN_DIR/chronyc"
export CLOCK_SYNC_STATE_DIR="$STATE_DIR"
export CLOCK_SYNC_SEND_CMD="$BIN_DIR/send.sh"
unset SPOOL_AGENT_ID CLOCK_SYNC_ALERT_FROM CLOCK_SYNC_NOW CLOCK_SYNC_THROTTLE_S

NOW=2000000000

status_offset() {
  printf '       Server: 169.254.169.254 (169.254.169.254)\nPoll interval: 34min 8s (min: 32s; max 34min 8s)\n         Leap: normal\n       Offset: %s\n        Delay: 195us\n' "$1" >"$TDC_STATUS"
}

run_check() {
  local dry="$1" now="${2:-$NOW}"
  (
    # shellcheck source=/dev/null
    source "$FUNC_SH"
    DRY_RUN="$dry" CLOCK_SYNC_NOW="$now" do_os_clock_sync_check
  )
}

reset() { rm -f "$SINCE" "$STAMP" "$SEND_LOG" "$CHR_OUT"; TDC_SYNC=yes; status_offset "$1"; }

# 1. Synchronized
reset -34us
out=$(run_check 0 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"clock-sync OK synced=yes"* && "$out" == *"offset_us=-34 "* &&
  "$out" == *"poll=34min 8s "* && "$out" == *"source=timesyncd"* && ! -f "$SEND_LOG" ]]; then
  pass "1. synchronized: OK with offset -34 us and poll 34min 8s, no note"
else
  fail "1. synchronized (rc=$rc, out=$out)"
fi

# 2. First unsynced run
reset -34us; TDC_SYNC=no
out=$(run_check 0 2>&1); rc=$?
if [[ $rc -eq 1 && "$out" == *"clock-sync UNSYNCED"* && "$(cat "$SINCE" 2>/dev/null)" == "$NOW" && ! -f "$SEND_LOG" ]]; then
  pass "2. first NTPSynchronized=no: UNSYNCED, since-stamp $NOW, no note"
else
  fail "2. first unsynced (rc=$rc, since=$(cat "$SINCE" 2>/dev/null), out=$out)"
fi

# 3. 29 min later
out=$(run_check 0 $((NOW + 29 * 60)) 2>&1); rc=$?
if [[ $rc -eq 1 && "$out" == *"clock-sync UNSYNCED"* && "$out" == *"unsynced_s=1740 "* && ! -f "$SEND_LOG" ]]; then
  pass "3. unsynced 29 min: still UNSYNCED, no note"
else
  fail "3. unsynced 29 min (rc=$rc, out=$out)"
fi

# 4. 31 min later, dry run
out=$(run_check 1 $((NOW + 31 * 60)) 2>&1); rc=$?
if [[ $rc -eq 1 && "$out" == *"clock-sync LOST"* && "$out" == *"PLAN note to orchestrator"* && ! -f "$SEND_LOG" && ! -f "$STAMP" ]]; then
  pass "4. unsynced 31 min, DRY_RUN=1: LOST planned, nothing sent, no alert stamp"
else
  fail "4. LOST dry run (rc=$rc, out=$out)"
fi

# 5. 31 min later, real run
out=$(run_check 0 $((NOW + 31 * 60)) 2>&1); rc=$?
if [[ $rc -eq 1 && "$(grep -c '^SEND' "$SEND_LOG" 2>/dev/null)" == 1 &&
  "$(cat "$SEND_LOG")" == *"--to orchestrator --kind note --task clock-sync --no-poke"* &&
  "$(cat "$SEND_LOG")" == *"clock-sync LOST on "*"NTPSynchronized=no for 31 min"* && -f "$STAMP" ]]; then
  pass "5. unsynced 31 min, DRY_RUN=0: one LOST note to the orchestrator, alert stamp"
else
  fail "5. LOST real run (rc=$rc, send=$(cat "$SEND_LOG" 2>/dev/null), out=$out)"
fi

# 6. Same state inside the throttle
out=$(run_check 0 $((NOW + 40 * 60)) 2>&1); rc=$?
if [[ $rc -eq 1 && "$(grep -c '^SEND' "$SEND_LOG")" == 1 && "$out" == *"throttled"* ]]; then
  pass "6. same LOST state 9 min later: throttled, no second note"
else
  fail "6. throttle (rc=$rc, sends=$(grep -c '^SEND' "$SEND_LOG"), out=$out)"
fi

# 7. Same state after the throttle (3600 s)
out=$(run_check 0 $((NOW + 92 * 60)) 2>&1); rc=$?
if [[ $rc -eq 1 && "$(grep -c '^SEND' "$SEND_LOG")" == 2 ]]; then
  pass "7. same LOST state after the throttle: a second note"
else
  fail "7. after throttle (rc=$rc, sends=$(grep -c '^SEND' "$SEND_LOG"), out=$out)"
fi

# 8. Synchronized again
TDC_SYNC=yes
out=$(run_check 0 $((NOW + 95 * 60)) 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"clock-sync OK"* && ! -f "$SINCE" && ! -f "$STAMP" ]]; then
  pass "8. synchronized again: OK, since-stamp and alert stamp removed"
else
  fail "8. recovery (rc=$rc, since=$([[ -f $SINCE ]] && echo y), stamp=$([[ -f $STAMP ]] && echo y), out=$out)"
fi

# 9. Drift +1.5s
reset +1.5s
out=$(run_check 0 2>&1); rc=$?
if [[ $rc -eq 1 && "$out" == *"clock-sync DRIFT"* && "$out" == *"offset_us=1500000 "* &&
  "$(cat "$SEND_LOG" 2>/dev/null)" == *"clock-sync DRIFT on "*"|offset| +1.5s > 1000 ms"* ]]; then
  pass "9. offset +1.5s: DRIFT note"
else
  fail "9. drift (rc=$rc, send=$(cat "$SEND_LOG" 2>/dev/null), out=$out)"
fi

# 10. Drift in a compound timespan
reset "-1min 2.5s"
out=$(run_check 1 2>&1); rc=$?
if [[ $rc -eq 1 && "$out" == *"clock-sync DRIFT"* && "$out" == *"offset_us=-62500000 "* ]]; then
  pass "10. offset -1min 2.5s: DRIFT, offset_us=-62500000"
else
  fail "10. compound timespan (rc=$rc, out=$out)"
fi

# 11. 999ms is inside the limit
reset 999ms
out=$(run_check 0 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"clock-sync OK"* && "$out" == *"offset_us=999000 "* && ! -f "$SEND_LOG" ]]; then
  pass "11. offset 999ms: OK (alert only above 1 s)"
else
  fail "11. 999ms (rc=$rc, out=$out)"
fi

# 12. chrony box: no timesync-status
reset -34us; rm -f "$TDC_STATUS"
printf 'Reference ID    : A9FEA9FE (metadata.google.internal)\nStratum         : 3\nSystem time     : 0.000012345 seconds slow of NTP time\nLast offset     : +0.000001 seconds\nUpdate interval : 64.2 seconds\n' >"$CHR_OUT"
out=$(run_check 0 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"clock-sync OK"* && "$out" == *"offset_us=-12 "* && "$out" == *"source=chrony"* &&
  "$out" == *"poll=64.2s "* && "$out" == *"server=metadata.google.internal "* ]]; then
  pass "12. chrony box: chronyc tracking read, offset -12 us, poll 64.2s"
else
  fail "12. chrony (rc=$rc, out=$out)"
fi

# 13. No answer at all
reset -34us; TDC_SYNC=""; rm -f "$TDC_STATUS"
out=$(run_check 1 2>&1); rc=$?
if [[ $rc -eq 1 && "$out" == *"clock-sync ERROR"* && "$out" == *"PLAN note"* && "$out" == *"source=none"* ]]; then
  pass "13. no NTPSynchronized answer: ERROR, alert planned"
else
  fail "13. error (rc=$rc, out=$out)"
fi

# 14. Failed send
reset +2s
out=$(CLOCK_SYNC_SEND_CMD="$BIN_DIR/failing-send.sh" run_check 0 2>&1); rc=$?
if [[ $rc -eq 1 && "$out" == *"note to orchestrator failed"* && ! -f "$STAMP" ]]; then
  pass "14. a failed send writes no alert stamp, so the next run retries"
else
  fail "14. failed send (rc=$rc, out=$out)"
fi

# 15. Read-only calls only
bad=$(grep -vE '^(timedatectl show -p NTPSynchronized -p NTP|timedatectl timesync-status|chronyc tracking)$' "$ARGS_LOG")
if [[ -s "$ARGS_LOG" && -z "$bad" ]]; then
  pass "15. $(wc -l <"$ARGS_LOG") stub calls, all read-only (show, timesync-status, tracking)"
else
  fail "15. unexpected calls: ${bad//$'\n'/|}"
fi

# 16. Through ./run
reset -34us
out=$(cd "$UTL_ROOT" && DRY_RUN=1 ./run -a do_os_clock_sync_check 2>&1); rc=$?
ms=$(sed -n 's/.*clock-sync OK .* ms=\([0-9]*\).*/\1/p' <<<"$out" | tail -n 1)
if [[ $rc -eq 0 && -n "$ms" ]] && ((ms < 100)); then
  pass "16. ./run -a do_os_clock_sync_check exits 0, probe ${ms} ms (< 100)"
else
  fail "16. ./run harness (rc=$rc, ms=${ms:-?}, out=$out)"
fi

echo "=========================================="
echo "clock-sync-check: $fails failure(s)"
echo "=========================================="
[[ "$fails" -eq 0 ]]
