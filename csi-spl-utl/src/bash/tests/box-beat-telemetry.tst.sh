#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for rel-12: box beat and watchdog fence telemetry (SPL-2669)
# Tests do_box_beat_telemetry_check against a temp watchdog dir (beat.ack,
# beat.down_min, fenced), a temp state dir and a stub sender; the box's real
# watchdog files are never read or written.
#   1. Beat cycles of 15 s, ack age 10 s -> OK, exit 0, step_s=15, no note
#   2. Ack age 75 s, DRY_RUN=1 -> NEAR, WARN, near_today=1, nothing recorded
#   3. Ack age 75 s, DRY_RUN=0 -> NEAR, near event recorded, no note while silent
#   4. Same silence, age 90 s -> still one near-fence (counted once)
#   5. Same silence, age 130 s -> FENCE, fenced_today=1, wd=fenced read
#   6. Ack again, DRY_RUN=0 -> RECONNECT, ONE note, silence 130..148 s, counts
#   7. Next run, ack age 5 s -> OK, no second note
#   8. Silence seen once, ack came between runs -> RECONNECT, note 60..72 s
#   9. Reconnect, DRY_RUN=1 -> PLAN line, no note, no state change
#  10. A failed send keeps pending-note; the next (OK) run sends it once
#  11. beat.down_min 5 -> fence_s=300, near_s=150: age 100 s is OK
#  12. BOX_BEAT_NEAR_S=30 -> age 45 s is NEAR
#  13. No beat.ack -> NOBEAT, exit 0; garbage beat.ack -> ERROR, exit 1
#  14. A near-fence of yesterday (UTC) is not counted today
#  15. The watchdog dir is only read: its files are unchanged byte for byte
#  16. A bad BOX_BEAT_NEAR_S -> exit 2
#  17. Through the csi-spl-utl ./run harness -> exits 0; the probe < 500 ms
#------------------------------------------------------------------------------
set -uo pipefail

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
UTL_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC_SH="$UTL_ROOT/src/bash/run/box-beat-telemetry.func.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

BIN_DIR="$T/bin"
WD="$T/wd"
STATE_DIR="$T/state"
SEND_LOG="$T/send.log"
mkdir -p "$BIN_DIR" "$WD"
cat >"$BIN_DIR/send.sh" <<'EOF'
#!/bin/bash
echo "SEND $*" >>"$SEND_LOG"
EOF
printf '#!/bin/bash\nexit 1\n' >"$BIN_DIR/failing-send.sh"
chmod +x "$BIN_DIR"/*

export SEND_LOG
export BOX_BEAT_WD_DIR="$WD"
export BOX_BEAT_STATE_DIR="$STATE_DIR"
export BOX_BEAT_SEND_CMD="$BIN_DIR/send.sh"
unset SPOOL_AGENT_ID BOX_BEAT_ALERT_FROM BOX_BEAT_NOW BOX_BEAT_NEAR_S BOX_BEAT_DOWN_MIN WD_BOX_DOWN_MIN WD_STATE_DIR

# 2033-05-18T03:33:20Z: well inside one UTC day
NOW=2000000000

ack() { echo "$1" >"$WD/beat.ack"; }
reset() { rm -rf "$STATE_DIR" "$SEND_LOG" "$WD"; mkdir -p "$WD"; echo 2 >"$WD/beat.down_min"; }
sends() { [[ -f "$SEND_LOG" ]] && wc -l <"$SEND_LOG" || echo 0; }

run_check() {
  local dry="$1" now="$2"
  (
    # shellcheck source=/dev/null
    source "$FUNC_SH"
    DRY_RUN="$dry" BOX_BEAT_NOW="$now" do_box_beat_telemetry_check
  )
}

# 1. Normal beat cycles
reset
ack $((NOW - 25)); run_check 0 $((NOW - 20)) >/dev/null
ack $((NOW - 10)); out=$(run_check 0 "$NOW" 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"box-beat OK ack_age_s=10 "* && "$out" == *"step_s=15 "* && "$out" == *"near_s=60 fence_s=120"* && "$out" == *"near_today=0 fenced_today=0"* && $(sends) -eq 0 ]]; then
  pass "1. 15 s beat cycles, ack age 10 s: OK, exit 0, step_s=15, no note"
else
  fail "1. normal (rc=$rc, out=$out)"
fi

# 2. Simulated 75 s ack age, dry run
reset; ack $((NOW - 75))
out=$(run_check 1 "$NOW" 2>&1); rc=$?
if [[ $rc -eq 1 && "$out" == *"box-beat NEAR ack_age_s=75 "* && "$out" == *"near_today=1 "* && "$out" == *"WARN box-beat NEAR: no beat ack for 75s"* && ! -e "$STATE_DIR" && $(sends) -eq 0 ]]; then
  pass "2. ack age 75 s, DRY_RUN=1: NEAR, WARN, near_today=1, nothing recorded"
else
  fail "2. near dry (rc=$rc, out=$out)"
fi

# 3. Same, recorded
out=$(run_check 0 "$NOW" 2>&1); rc=$?
if [[ $rc -eq 1 && "$out" == *"near_today=1 "* && $(grep -c " near $((NOW - 75)) 75$" "$STATE_DIR/events.tsv") -eq 1 && $(sends) -eq 0 && ! -e "$STATE_DIR/pending-note" ]]; then
  pass "3. ack age 75 s, DRY_RUN=0: near event recorded, no note while silent"
else
  fail "3. near recorded (rc=$rc, out=$out)"
fi

# 4. Same silence, older
out=$(run_check 0 $((NOW + 15)) 2>&1); rc=$?
if [[ $rc -eq 1 && "$out" == *"box-beat NEAR ack_age_s=90 "* && "$out" == *"near_today=1 "* && $(grep -c ' near ' "$STATE_DIR/events.tsv") -eq 1 ]]; then
  pass "4. the same silence at 90 s is still one near-fence"
else
  fail "4. counted once (rc=$rc, out=$out)"
fi

# 5. Past the fence
touch "$WD/fenced"
out=$(run_check 0 $((NOW + 55)) 2>&1); rc=$?
if [[ $rc -eq 1 && "$out" == *"box-beat FENCE ack_age_s=130 "* && "$out" == *"wd=fenced"* && "$out" == *"near_today=1 fenced_today=1"* ]]; then
  pass "5. age 130 s: FENCE, fenced_today=1, the watchdog's fenced marker read"
else
  fail "5. fence (rc=$rc, out=$out)"
fi

# 6. Reconnect
rm -f "$WD/fenced"; ack $((NOW + 73))
out=$(run_check 0 $((NOW + 75)) 2>&1); rc=$?
sent=$(cat "$SEND_LOG" 2>/dev/null)
if [[ $rc -eq 1 && "$out" == *"box-beat RECONNECT ack_age_s=2 "* && "$out" == *"note sent to orchestrator"* && $(sends) -eq 1 &&
  "$sent" == *"--to orchestrator --kind note --task box-beat --no-poke"* && "$sent" == *"after a FENCE silence: no beat ack for 130..148 s"* &&
  "$sent" == *"Near-fences today (UTC): 1, fences: 1."* && ! -e "$STATE_DIR/pending-note" ]]; then
  pass "6. ack again: RECONNECT, ONE note, silence 130..148 s, today's counts"
else
  fail "6. reconnect (rc=$rc, out=$out, sent=$sent)"
fi

# 7. Back to normal
ack $((NOW + 90))
out=$(run_check 0 $((NOW + 95)) 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"box-beat OK ack_age_s=5 "* && "$out" == *"step_s=17 "* && $(sends) -eq 1 ]]; then
  pass "7. next run OK, no second note"
else
  fail "7. after reconnect (rc=$rc, out=$out)"
fi

# 8. Silence seen once, the ack came between runs
reset; ack $((NOW - 60))
run_check 0 "$NOW" >/dev/null
ack $((NOW + 12))
out=$(run_check 0 $((NOW + 30)) 2>&1); rc=$?
sent=$(cat "$SEND_LOG" 2>/dev/null)
if [[ $rc -eq 1 && "$out" == *"box-beat RECONNECT ack_age_s=18 "* && $(sends) -eq 1 && "$sent" == *"after a NEAR silence: no beat ack for 60..72 s"* ]]; then
  pass "8. silence seen at exactly 60 s, ack between runs: RECONNECT, note 60..72 s"
else
  fail "8. reconnect between runs (rc=$rc, out=$out, sent=$sent)"
fi

# 9. Reconnect in a dry run
reset; ack $((NOW - 80))
run_check 0 "$NOW" >/dev/null
before=$(cat "$STATE_DIR/state")
ack $((NOW + 5))
out=$(run_check 1 $((NOW + 10)) 2>&1); rc=$?
if [[ $rc -eq 1 && "$out" == *"box-beat RECONNECT"* && "$out" == *"PLAN note to orchestrator on task box-beat: box-beat RECONNECT on"* &&
  $(sends) -eq 0 && "$(cat "$STATE_DIR/state")" == "$before" && ! -e "$STATE_DIR/pending-note" ]]; then
  pass "9. reconnect with DRY_RUN=1: PLAN line, no note, state unchanged"
else
  fail "9. dry reconnect (rc=$rc, out=$out)"
fi

# 10. A failed send is retried once by the next run
out=$(BOX_BEAT_SEND_CMD="$BIN_DIR/failing-send.sh" run_check 0 $((NOW + 10)) 2>&1); rc=$?
kept=0; [[ -s "$STATE_DIR/pending-note" ]] && kept=1
ack $((NOW + 25))
out2=$(run_check 0 $((NOW + 30)) 2>&1); rc2=$?
out3=$(run_check 0 $((NOW + 31)) 2>&1)
if [[ $rc -eq 1 && "$out" == *"note to orchestrator failed; kept in"* && $kept -eq 1 && $rc2 -eq 0 &&
  "$out2" == *"box-beat OK"* && "$out2" == *"note sent to orchestrator"* && "$out3" != *"note sent"* && $(sends) -eq 1 ]]; then
  pass "10. a failed send keeps pending-note; the next OK run sends it, once"
else
  fail "10. retry (rc=$rc, rc2=$rc2, out=$out, out2=$out2, sends=$(sends))"
fi

# 11. The hub's box_down_min
reset; echo 5 >"$WD/beat.down_min"; ack $((NOW - 100))
out=$(run_check 1 "$NOW" 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"box-beat OK ack_age_s=100 "* && "$out" == *"near_s=150 fence_s=300"* ]]; then
  pass "11. beat.down_min 5: fence_s=300, near_s=150, age 100 s is OK"
else
  fail "11. down_min (rc=$rc, out=$out)"
fi

# 12. A near threshold override
reset; ack $((NOW - 45))
out=$(BOX_BEAT_NEAR_S=30 run_check 1 "$NOW" 2>&1); rc=$?
if [[ $rc -eq 1 && "$out" == *"box-beat NEAR ack_age_s=45 "* && "$out" == *"near_s=30 fence_s=120"* ]]; then
  pass "12. BOX_BEAT_NEAR_S=30: age 45 s is NEAR"
else
  fail "12. near override (rc=$rc, out=$out)"
fi

# 13. No beat, a bad beat
reset; rm -f "$WD/beat.ack"
out=$(run_check 0 "$NOW" 2>&1); rc=$?
echo "not-a-number" >"$WD/beat.ack"
out2=$(run_check 0 "$NOW" 2>&1); rc2=$?
if [[ $rc -eq 0 && "$out" == *"box-beat NOBEAT"* && $rc2 -eq 1 && "$out2" == *"box-beat ERROR"* && ! -e "$STATE_DIR" ]]; then
  pass "13. no beat.ack: NOBEAT exit 0; a non-epoch beat.ack: ERROR exit 1"
else
  fail "13. nobeat/error (rc=$rc, rc2=$rc2, out=$out, out2=$out2)"
fi

# 14. Yesterday's near-fence
reset; mkdir -p "$STATE_DIR"
echo "$((NOW - 86400)) near $((NOW - 86475)) 75" >"$STATE_DIR/events.tsv"
ack $((NOW - 5))
out=$(run_check 1 "$NOW" 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"near_today=0 fenced_today=0"* ]]; then
  pass "14. a near-fence of yesterday (UTC) is not counted today"
else
  fail "14. day window (rc=$rc, out=$out)"
fi

# 15. The watchdog dir is only read
reset; ack $((NOW - 80)); touch "$WD/held"
sum_before=$(cd "$WD" && find . -type f -exec md5sum {} + | sort)
run_check 0 "$NOW" >/dev/null; ack_now=$(cat "$WD/beat.ack")
run_check 0 $((NOW + 60)) >/dev/null
sum_after=$(cd "$WD" && find . -type f -exec md5sum {} + | sort)
out=$(run_check 1 $((NOW + 61)) 2>&1)
if [[ "$sum_before" == "$sum_after" && "$ack_now" == "$((NOW - 80))" && "$out" == *"wd=held"* ]]; then
  pass "15. the watchdog's files are unchanged after DRY_RUN=0 runs (held read)"
else
  fail "15. watchdog dir changed or held not read (out=$out)"
fi

# 16. Usage error
out=$(BOX_BEAT_NEAR_S=abc run_check 1 "$NOW" 2>&1); rc=$?
if [[ $rc -eq 2 && "$out" == *"FATAL BOX_BEAT_NEAR_S"* ]]; then
  pass "16. a bad BOX_BEAT_NEAR_S exits 2"
else
  fail "16. usage (rc=$rc, out=$out)"
fi

# 17. Through ./run
# The bound is an answer, not a speed record: 50 ms is the bound that failed
# tmux-health-guard on a loaded hosted runner (wf 10 40244469102, 87b1eb023:
# the first probe 11 ms, the next five >= 53 ms); 24 busy loops on 16 CPUs
# gave p50 59, p99 120 ms (n=100), idle p99 17 ms. Same 500 ms here.
reset; ack "$(date +%s)"
out=$(cd "$UTL_ROOT" && DRY_RUN=1 ./run -a do_box_beat_telemetry_check 2>&1); rc=$?
ms=$(sed -n 's/.*box-beat OK .* ms=\([0-9]*\).*/\1/p' <<<"$out" | tail -n 1)
if [[ $rc -eq 0 && -n "$ms" ]] && ((ms < 500)); then
  pass "17. ./run -a do_box_beat_telemetry_check exits 0, probe ${ms} ms (< 500)"
else
  fail "17. ./run harness (rc=$rc, ms=${ms:-?}, out=$out)"
fi

echo "=========================================="
echo "box-beat-telemetry: $fails failure(s)"
echo "=========================================="
[[ "$fails" -eq 0 ]]
