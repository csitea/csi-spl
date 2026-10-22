#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for rel-11: cron dead-man's snitch & heartbeat age monitor (SPL-2665)
# Tests do_cron_heartbeat_snitch and its beat wrapper against a fixture
# crontab, temp beat/log dirs, a stub pidfile and a stub spool-send; the live
# crontab and cron daemon are never read or changed.
#   1. Every beat fresh -> exits 0, all OK, no note
#   2. Period from schedule (13 schedules, incl. ranges, steps, lists, dow 7, @)
#   3. 1 min job: beat 360 s old is OK, 361 s is SILENT (60 s + 300 s grace)
#   4. Stale beat, DRY_RUN=1 -> exits 1, PLAN with schedule + last beat, no note
#   5. Stale beat, DRY_RUN=0 -> exits 1, one note to orchestrator, stamp
#   6. Same silent set again -> no second note
#   7. Cleared, DRY_RUN=0 -> exits 0, stamp removed
#   8. No beat: fresh log LOG-OK, old log LOG-STALE, none NO-DATA; exits 0
#   9. @reboot is BOOT; commented and untagged lines are skipped
#  10. Cron daemon down (pidfile names no cron) -> exits 1, note says down
#  11. Failed send -> exits 1, no stamp
#  12. CRON_HB_PERIOD_OVERRIDES sets a gated line's period
#  13. --wrap runs the command, keeps its rc, writes the beat; the check reads it
#  14. --beat writes a beat; a bad call is a usage error (exit 2)
#  15. Default source runs only `crontab -l` (never writes a crontab)
#  16. 43-line crontab checked under CHS_TEST_MAX_MS of CPU time (default 250;
#      target 100). CPU, not wall: a loaded box stretches wall time 4x (sat
#      load ~42: 421 ms) while the work done stays the same.
#  17. Through the csi-spl-utl ./run harness -> exits 0
#------------------------------------------------------------------------------
set -uo pipefail

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
UTL_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC_SH="$UTL_ROOT/src/bash/run/cron-heartbeat-snitch.func.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

BIN_DIR="$T/bin"
mkdir -p "$BIN_DIR" "$T/state/heartbeat" "$T/log" "$T/proc/4242"
SEND_LOG="$T/spool-send.log"
STAMP_FILE="$T/state/cron-heartbeat-snitch.stamp"
HB="$T/state/heartbeat"
TAB="$T/crontab"
NOW=1800000000

cat > "$BIN_DIR/spool-send.sh" << 'SEND_EOF'
#!/bin/bash
echo "CALL spool-send: $*" >> "$SEND_LOG"
SEND_EOF
printf '#!/bin/bash\nexit 1\n' > "$BIN_DIR/failing-send.sh"
cat > "$BIN_DIR/crontab" << 'CT_EOF'
#!/bin/bash
echo "$*" >> "$CT_ARGS"
cat "$CT_TAB"
CT_EOF
chmod +x "$BIN_DIR"/*
echo 4242 > "$T/crond.pid"
echo cron > "$T/proc/4242/comm"

export SEND_LOG
export CRON_HB_CRONTAB_FILE="$TAB"
export CRON_HB_STATE_DIR="$T/state"
export CRON_HB_STAMP_FILE="$STAMP_FILE"
export CRON_HB_ALERT_SEND_BIN="$BIN_DIR/spool-send.sh"
export CRON_HB_PIDFILE="$T/crond.pid"
export CRON_HB_PROC_DIR="$T/proc"
export CRON_HB_NOW=$NOW
export DEV_BOX="PC"
unset SPOOL_AGENT_ID CRON_HB_ALERT_FROM CRON_HB_DIR CRON_HB_PERIOD_OVERRIDES SPL_STATE_DIR

# beat <tag> <age_s> [rc]: a beat file aged <age_s> before NOW
beat() {
  printf 'ts=%s rc=%s\n' "$((NOW - $2))" "${3:-0}" > "$HB/${1//\//_}"
  touch -d "@$((NOW - $2))" "$HB/${1//\//_}"
}

cat > "$TAB" << EOF
SHELL=/bin/bash
# a comment
* * * * * /bin/bash '/x/gc-cron.sh' >> '$T/log/gc.log' 2>&1 # csi-spl:box-cron:gc
*/5 * * * * cd /x && ./run -a do_a >> $T/log/a.out 2>&1 # csi-spl:five
0 5 * * * /x/daily.sh >> $T/log/daily.out 2>&1 # csi-spl:daily
@reboot sleep 5; /x/boot.sh >> $T/log/boot.out 2>&1 # csi-spl:boot
#* * * * * /x/disabled.sh # csi-spl:disabled
* * * * * /x/untagged.sh >> $T/log/u.out 2>&1
EOF

run_check() {
  local dry="$1"
  (
    # shellcheck source=/dev/null
    source "$FUNC_SH"
    DRY_RUN="$dry" do_cron_heartbeat_snitch
  )
}

fresh_all() { beat box-cron:gc 30; beat five 200; beat daily 3600; }

# 1. Every beat fresh
fresh_all
rm -f "$SEND_LOG" "$STAMP_FILE"
out=$(run_check 0 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"lines=4 ok=3 silent=0"* && "$out" == *"daemon=up"* && ! -f "$SEND_LOG" ]]; then
  pass "1. every beat fresh exits 0, 3 OK + 1 BOOT, no note"
else
  fail "1. every beat fresh (rc=$rc, out=$out)"
fi

# 2. Period from schedule
(
  # shellcheck source=/dev/null
  source "$FUNC_SH"
  declare -A _CHS_PCACHE=()
  bad=""
  while IFS='|' read -r sched want; do
    read -r a b c d e <<< "$sched"
    _chs_period "$a" "$b" "$c" "$d" "$e"
    [[ "$_CHS_PERIOD" == "$want" ]] || bad+=" [$sched]=$_CHS_PERIOD!=$want"
  done << 'P_EOF'
* * * * *|60
*/5 * * * *|300
1-59/5 * * * *|300
7-59/15 * * * *|900
7,37 * * * *|1800
23 * * * *|3600
0 5 * * *|86400
*/15 8-19 * * *|44100
0 17 * * 5|604800
23 4 * * 0|604800
30 9 * * 1,3|432000
0 9 * * 0,7|604800
0 0 1 * *|2678400
P_EOF
  [[ -z "$bad" ]] && echo OK || echo "BAD$bad"
) > "$T/p.out" 2>&1
if [[ "$(cat "$T/p.out")" == "OK" ]]; then
  pass "2. 13 schedules give the longest gap between runs (steps, ranges, lists, dow 0/7, dom)"
else
  fail "2. periods: $(cat "$T/p.out")"
fi

# 3. Grace boundary for a 1 min job
beat box-cron:gc 360
out=$(run_check 1 2>&1); rc=$?
beat box-cron:gc 361
out2=$(run_check 1 2>&1); rc2=$?
if [[ $rc -eq 0 && "$out" == *"OK        box-cron:gc"* && $rc2 -eq 1 && "$out2" == *"SILENT    box-cron:gc"* \
   && "$out2" == *"period=60s grace=300s source=hb age=361s"* ]]; then
  pass "3. 1 min job: 360 s OK, 361 s SILENT (60 s period + 300 s grace)"
else
  fail "3. grace boundary (rc=$rc rc2=$rc2, out2=$out2)"
fi

# 4. Stale beat, DRY_RUN=1
rm -f "$SEND_LOG" "$STAMP_FILE"
beat box-cron:gc 900
out=$(run_check 1 2>&1); rc=$?
if [[ $rc -eq 1 && "$out" == *"PLAN note to orchestrator"* \
   && "$out" == *'box-cron:gc: schedule "* * * * *", last beat 15m ago'* \
   && ! -f "$SEND_LOG" && ! -f "$STAMP_FILE" ]]; then
  pass "4. stale beat in DRY_RUN=1 exits 1, plans a note naming schedule and last beat, sends nothing"
else
  fail "4. stale DRY_RUN=1 (rc=$rc, out=$out)"
fi

# 5. Stale beat, DRY_RUN=0
out=$(run_check 0 2>&1); rc=$?
if [[ $rc -eq 1 && -f "$STAMP_FILE" ]] \
   && grep -q -- "--from cron-heartbeat-snitch@PC --to orchestrator --kind note --task cron-heartbeat-snitch" "$SEND_LOG" \
   && grep -q "Silent jobs: 1" "$SEND_LOG" && grep -q "restarts nothing" "$SEND_LOG"; then
  pass "5. stale beat in DRY_RUN=0 sends one note and writes the stamp"
else
  fail "5. stale DRY_RUN=0 (rc=$rc, out=$out)"
fi

# 6. Same set again
: > "$SEND_LOG"
out=$(run_check 0 2>&1); rc=$?
if [[ $rc -eq 1 && ! -s "$SEND_LOG" && "$out" == *"alert already sent"* ]]; then
  pass "6. the same silent set is not alerted twice"
else
  fail "6. same set (rc=$rc, out=$out)"
fi

# 7. Cleared
fresh_all
out=$(run_check 0 2>&1); rc=$?
if [[ $rc -eq 0 && ! -f "$STAMP_FILE" ]]; then
  pass "7. a cleared set exits 0 and removes the stamp"
else
  fail "7. cleared (rc=$rc, out=$out)"
fi

# 8. No beat: log fallback, never alerted
rm -f "$HB"/* "$SEND_LOG"
beat box-cron:gc 10
touch -d "@$((NOW - 100))" "$T/log/a.out"
touch -d "@$((NOW - 200000))" "$T/log/daily.out"
out=$(run_check 0 2>&1); rc=$?
mv "$T/log/a.out" "$T/log/a.gone"
out2=$(run_check 0 2>&1)
mv "$T/log/a.gone" "$T/log/a.out"
if [[ $rc -eq 0 && "$out" == *"LOG-OK    five"*"source=log age=100s"* && "$out" == *"LOG-STALE daily"* \
   && "$out" == *"log_ok=1 log_stale=1"* && "$out2" == *"NO-DATA   five"* && ! -f "$SEND_LOG" ]]; then
  pass "8. without a beat: fresh log LOG-OK, old log LOG-STALE, none NO-DATA; exits 0, no note"
else
  fail "8. log fallback (rc=$rc, out=$out, out2=$out2)"
fi

# 9. @reboot, comments, untagged
if [[ "$out" == *"BOOT      boot"* && "$out" != *"disabled"* && "$out" != *"untagged"* && "$out" == *"lines=4 "* ]]; then
  pass "9. @reboot is BOOT; the commented and the untagged line are skipped"
else
  fail "9. line selection (out=$out)"
fi

# 10. Cron daemon down
fresh_all
rm -f "$SEND_LOG" "$STAMP_FILE"
echo bash > "$T/proc/4242/comm"
out=$(run_check 0 2>&1); rc=$?
echo cron > "$T/proc/4242/comm"
out2=$(CRON_HB_PIDFILE="$T/missing.pid" CRON_HB_PGREP_BIN=false run_check 1 2>&1); rc2=$?
if [[ $rc -eq 1 && "$out" == *"daemon=down"* ]] && grep -q "Cron daemon: down" "$SEND_LOG" \
   && [[ $rc2 -eq 1 && "$out2" == *"daemon=down"* ]]; then
  pass "10. a pidfile naming no cron (or no pidfile and no process) is daemon=down, exits 1, alerted"
else
  fail "10. daemon down (rc=$rc rc2=$rc2, out=$out)"
fi

# 11. Failed send
rm -f "$STAMP_FILE"
beat five 5000
out=$(CRON_HB_ALERT_SEND_BIN="$BIN_DIR/failing-send.sh" run_check 0 2>&1); rc=$?
if [[ $rc -eq 1 && ! -f "$STAMP_FILE" && "$out" == *"failed to send spool note"* ]]; then
  pass "11. a failed send logs it and writes no stamp, so the next run retries"
else
  fail "11. failed send (rc=$rc, out=$out)"
fi

# 12. Period override
out=$(CRON_HB_PERIOD_OVERRIDES="five=604800 other=1" run_check 1 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"OK        five"*"period=604800s"* ]]; then
  pass "12. CRON_HB_PERIOD_OVERRIDES gives a self-gated line its real period"
else
  fail "12. override (rc=$rc, out=$out)"
fi

# 13. --wrap keeps the rc and writes the beat
rm -f "$HB/five"
bash "$FUNC_SH" --wrap five -- bash -c 'echo job-ran; exit 3' > "$T/wrap.out" 2>&1; wrc=$?
out=$(CRON_HB_NOW="$(date +%s)" run_check 1 2>&1)
if [[ $wrc -eq 3 && "$(cat "$T/wrap.out")" == "job-ran" ]] && grep -q 'rc=3' "$HB/five" \
   && [[ "$out" == *"OK        five"*"source=hb"*"rc=3"* ]]; then
  pass "13. --wrap runs the job, exits with its rc 3, writes the beat; the check reads rc=3"
else
  fail "13. --wrap (wrc=$wrc, beat=$(cat "$HB/five" 2>&1), out=$out)"
fi

# 14. --beat and usage errors
CRON_HB_DIR="$T/hb2" bash "$FUNC_SH" --beat box-cron:x 0; brc=$?
bash "$FUNC_SH" --wrap five > /dev/null 2>&1; urc=$?
bash "$FUNC_SH" > /dev/null 2>&1; urc2=$?
if [[ $brc -eq 0 && -f "$T/hb2/box-cron:x" && $urc -eq 2 && $urc2 -eq 2 ]]; then
  pass "14. --beat writes <dir>/<tag>; --wrap without a command and no mode exit 2"
else
  fail "14. --beat/usage (brc=$brc urc=$urc urc2=$urc2)"
fi

# 15. Default source: crontab -l only
export CT_ARGS="$T/crontab.args" CT_TAB="$TAB"
fresh_all
out=$(PATH="$BIN_DIR:$PATH" CRON_HB_CRONTAB_FILE="" run_check 1 2>&1); rc=$?
if [[ $rc -eq 0 && "$(sort -u "$CT_ARGS")" == "-l" && "$out" == *"lines=4 "* ]]; then
  pass "15. without CRON_HB_CRONTAB_FILE it runs only 'crontab -l' (read-only)"
else
  fail "15. crontab -l (rc=$rc, args=$(cat "$CT_ARGS" 2>&1), out=$out)"
fi

# 16. A 43-line crontab under the time bound
max_ms="${CHS_TEST_MAX_MS:-250}"
big="$T/crontab.big"
scheds=('* * * * *' '*/5 * * * *' '1-59/5 * * * *' '7-59/15 * * * *' '23 * * * *' '0 5 * * *' '7,37 * * * *' '*/10 * * * *' '0 17 * * 5')
: > "$big"
for i in $(seq 1 43); do
  s="${scheds[$((i % ${#scheds[@]}))]}"
  printf "%s cd /x && git fetch -q origin master; ENV=prd /x/job-%s.sh >> %s/log/job-%s.out 2>&1 # csi-spl:job-%s\n" "$s" "$i" "$T" "$i" "$i" >> "$big"
  (( i % 2 )) && beat "job-$i" 30
  (( i % 3 )) && touch -d "@$((NOW - 30))" "$T/log/job-$i.out"
done
# user+sys of the check and its children; wall elapsed_ms is only reported
TIMEFORMAT='%3U %3S'
{ time { out=$(CRON_HB_CRONTAB_FILE="$big" run_check 1 2>&1); rc=$?; }; } 2> "$T/cpu16"
unset TIMEFORMAT
cpu_ms=$(awk 'NF == 2 { printf "%d", ($1 + $2) * 1000 }' "$T/cpu16")
ms=$(sed -n 's/.*elapsed_ms=\([0-9]*\).*/\1/p' <<< "$out")
if [[ $rc -eq 0 && "$out" == *"lines=43 "* && -n "$cpu_ms" && "$cpu_ms" -lt "$max_ms" ]]; then
  pass "16. 43 tagged lines checked in ${cpu_ms} ms CPU (< ${max_ms}; target 100; wall ${ms} ms)"
else
  fail "16. 43 lines (rc=$rc, cpu_ms=$cpu_ms, wall ms=$ms, time=$(cat "$T/cpu16"), out=$(tail -n 2 <<< "$out"))"
fi

# 17. Through ./run
fresh_all
out=$(cd "$UTL_ROOT" && DRY_RUN=1 ./run -a do_cron_heartbeat_snitch 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"cron-heartbeat-snitch: lines=4 ok=3"* ]]; then
  pass "17. ./run -a do_cron_heartbeat_snitch exits 0"
else
  fail "17. ./run harness (rc=$rc, out=$out)"
fi

echo "=========================================="
echo "cron-heartbeat-snitch: $fails failure(s)"
echo "=========================================="
[[ "$fails" -eq 0 ]]
