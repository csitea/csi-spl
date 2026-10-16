#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for rel-01: systemd service failure & crash detector (SPL-2210)
# Tests do_os_systemd_unit_check against stubs on PATH; live box is untouched.
#   1. Healthy system (state=running, 0 failed units) -> exits 0, no alert
#   2. Failed unit in DRY_RUN=1 (default) -> exits 1, PLAN note, no note sent, no stamp
#   3. Failed unit in DRY_RUN=0 -> exits 1, structured alert sent, crash logs, stamp created
#   4. Throttling by stamp file -> exits 1, note suppressed when within throttle duration
#   5. Alert unthrottled on timeout -> exits 1, note sent when stamp is expired
#   6. Alert unthrottled on new failure -> exits 1, note sent when new failed unit added
#   7. Explicit ignore list (cnf/systemd-unit-ignore.tsv) -> exits 0, 0 false alerts
#   8. Mixed units (some ignored, some failed) -> exits 1, alerts only on unignored unit
#   9. System recovery in DRY_RUN=0 -> exits 0, clears existing stamp file
#  10. Bullet glyph parsing in systemctl output -> parsed correctly
#  11. Invocation via csi-spl-utl ./run harness -> works end-to-end
#  12. Failed send does not write stamp file -> exits 1, logs failure, no stamp written
#  13. Sender identity respects SPOOL_AGENT_ID when provided -> exits 1, uses SPOOL_AGENT_ID
#------------------------------------------------------------------------------
set -uo pipefail

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
UTL_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC_SH="$UTL_ROOT/src/bash/run/systemd-unit-health.func.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

BIN_DIR="$T/bin"
STATE_DIR="$T/state"
CNF_DIR="$T/cnf"
LOG_DIR="$T/log"
mkdir -p "$BIN_DIR" "$STATE_DIR" "$CNF_DIR" "$LOG_DIR"

STAMP_FILE="$STATE_DIR/systemd-unit-alert.stamp"
IGNORE_FILE="$CNF_DIR/systemd-unit-ignore.tsv"
SEND_LOG="$T/spool-send.log"

# Stub binaries
SYS_RUNNING_FILE="$T/sys_running.out"
SYS_RUNNING_RC="$T/sys_running.rc"
SYS_FAILED_FILE="$T/sys_failed.out"
SYS_FAILED_RC="$T/sys_failed.rc"
JOURNAL_LOGS_FILE="$T/journal.out"

cat > "$BIN_DIR/systemctl" << 'S_EOF'
#!/bin/bash
if [[ "$*" == *"is-system-running"* ]]; then
  cat "${SYS_RUNNING_FILE:-/dev/null}" 2>/dev/null || echo "running"
  exit "$(cat "${SYS_RUNNING_RC:-/dev/null}" 2>/dev/null || echo 0)"
elif [[ "$*" == *"--failed"* ]]; then
  cat "${SYS_FAILED_FILE:-/dev/null}" 2>/dev/null || true
  exit "$(cat "${SYS_FAILED_RC:-/dev/null}" 2>/dev/null || echo 0)"
fi
echo "systemctl stub called with $*"
exit 0
S_EOF
chmod +x "$BIN_DIR/systemctl"

cat > "$BIN_DIR/journalctl" << 'J_EOF'
#!/bin/bash
unit=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "-u" && $((i+1)) -lt ${#args[@]} ]]; then
    unit="${args[$((i+1))]}"
    break
  fi
done
if [[ -n "$unit" && -f "$T/journal-$unit.out" ]]; then
  cat "$T/journal-$unit.out"
elif [[ -f "${JOURNAL_LOGS_FILE:-/dev/null}" ]]; then
  cat "${JOURNAL_LOGS_FILE:-/dev/null}"
else
  echo "(journalctl default stub for $unit)"
fi
exit 0
J_EOF
chmod +x "$BIN_DIR/journalctl"

cat > "$BIN_DIR/spool-send.sh" << 'SEND_EOF'
#!/bin/bash
echo "CALL spool-send: $*" >> "${SEND_LOG:-/dev/null}"
exit 0
SEND_EOF
chmod +x "$BIN_DIR/spool-send.sh"

export PATH="$BIN_DIR:$PATH"
export SYS_RUNNING_FILE SYS_RUNNING_RC SYS_FAILED_FILE SYS_FAILED_RC JOURNAL_LOGS_FILE SEND_LOG T
export SYSTEMD_UNIT_STATE_DIR="$STATE_DIR"
export SYSTEMD_UNIT_STAMP_FILE="$STAMP_FILE"
export SYSTEMD_UNIT_IGNORE_FILE="$IGNORE_FILE"
export SYSTEMD_UNIT_ALERT_SEND_BIN="$BIN_DIR/spool-send.sh"
export SYSTEMCTL_BIN="$BIN_DIR/systemctl"
export JOURNALCTL_BIN="$BIN_DIR/journalctl"
export PROJ_PATH="$UTL_ROOT"
export DEV_BOX="PC"
unset SPOOL_AGENT_ID SYSTEMD_UNIT_ALERT_FROM

# Helper to execute check
run_check() {
  local dry="${1:-1}"
  (
    # shellcheck source=/dev/null
    source "$FUNC_SH"
    DRY_RUN="$dry" do_os_systemd_unit_check
  )
}

# -----------------------------------------------------------------------------
# Case 1: Healthy system
# -----------------------------------------------------------------------------
echo "running" > "$SYS_RUNNING_FILE"
echo 0 > "$SYS_RUNNING_RC"
: > "$SYS_FAILED_FILE"
echo 0 > "$SYS_FAILED_RC"
: > "$IGNORE_FILE"
rm -f "$STAMP_FILE" "$SEND_LOG"

out=$(run_check 1 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"systemd units healthy: state=running, failed=0"* && ! -f "$STAMP_FILE" ]]; then
  pass "1. Healthy system exits 0 with healthy log and no stamp"
else
  fail "1. Healthy system failed (rc=$rc, out=$out)"
fi

# -----------------------------------------------------------------------------
# Case 2: Failed unit in DRY_RUN=1 (default)
# -----------------------------------------------------------------------------
echo "degraded" > "$SYS_RUNNING_FILE"
echo 1 > "$SYS_RUNNING_RC"
cat > "$SYS_FAILED_FILE" << 'CASE2_EOF'
docker.service loaded failed failed Docker Application Container Engine
CASE2_EOF
cat > "$T/journal-docker.service.out" << 'CASE2_EOF'
Oct 16 12:00:01 host dockerd[123]: panic: fatal error
Oct 16 12:00:02 host systemd[1]: docker.service: Main process exited, code=exited, status=2/INVALIDARGUMENT
Oct 16 12:00:02 host systemd[1]: docker.service: Failed with result 'exit-code'.
Oct 16 12:00:03 host systemd[1]: Failed to start Docker Application Container Engine.
Oct 16 12:00:04 host systemd[1]: docker.service: Scheduled restart job, restart counter is at 5.
CASE2_EOF
rm -f "$STAMP_FILE" "$SEND_LOG"

out=$(run_check 1 2>&1); rc=$?
if [[ $rc -eq 1 ]] && grep -q "PLAN note to orchestrator:" <<< "$out" \
   && grep -q "docker.service" <<< "$out" \
   && grep -q "panic: fatal error" <<< "$out" \
   && [[ ! -f "$STAMP_FILE" ]] && [[ ! -f "$SEND_LOG" ]]; then
  pass "2. Failed unit in DRY_RUN=1 exits 1, prints PLAN with crash logs, sends no note, writes no stamp"
else
  fail "2. Failed unit in DRY_RUN=1 failed (rc=$rc, out=$out)"
fi

# -----------------------------------------------------------------------------
# Case 3: Failed unit in DRY_RUN=0
# -----------------------------------------------------------------------------
rm -f "$STAMP_FILE" "$SEND_LOG"
out=$(run_check 0 2>&1); rc=$?
if [[ $rc -eq 1 ]] && [[ -f "$STAMP_FILE" ]] && [[ -f "$SEND_LOG" ]] \
   && grep -q "CALL spool-send:.*--from systemd-unit-health@" "$SEND_LOG" \
   && grep -q "CALL spool-send:.*--to orchestrator.*--kind note" "$SEND_LOG" \
   && grep -q "panic: fatal error" "$SEND_LOG" \
   && grep -q "^UNITS=docker.service" "$STAMP_FILE"; then
  pass "3. Failed unit in DRY_RUN=0 exits 1, sends structured spool note with default sender, writes stamp file"
else
  fail "3. Failed unit in DRY_RUN=0 failed (rc=$rc, stamp_exists=$(test -f "$STAMP_FILE" && echo 1 || echo 0))"
fi

# -----------------------------------------------------------------------------
# Case 4: Throttling by stamp file
# -----------------------------------------------------------------------------
: > "$SEND_LOG"
out=$(run_check 0 2>&1); rc=$?
if [[ $rc -eq 1 ]] && [[ ! -s "$SEND_LOG" ]] \
   && grep -q "alert throttled by" <<< "$out"; then
  pass "4. Throttling suppresses duplicate spool note while unit is still failed"
else
  fail "4. Throttling failed (rc=$rc, out=$out, send_lines=$(wc -l < "$SEND_LOG" 2>/dev/null || echo 0))"
fi

# -----------------------------------------------------------------------------
# Case 5: Alert unthrottled on timeout
# -----------------------------------------------------------------------------
: > "$SEND_LOG"
# Set stamp file mtime to 2500 seconds ago (older than throttle 1800s)
past_time=$(( $(date +%s) - 2500 ))
touch -d "@$past_time" "$STAMP_FILE"
out=$(run_check 0 2>&1); rc=$?
if [[ $rc -eq 1 ]] && [[ -s "$SEND_LOG" ]] \
   && grep -q "CALL spool-send:" "$SEND_LOG"; then
  pass "5. Alert fires again once throttle duration has expired"
else
  fail "5. Alert unthrottled on timeout failed (rc=$rc, out=$out)"
fi

# -----------------------------------------------------------------------------
# Case 6: Alert unthrottled when NEW unit fails
# -----------------------------------------------------------------------------
# Current stamp file only has docker.service. Now cron.service also fails.
cat > "$SYS_FAILED_FILE" << 'CASE6_EOF'
docker.service loaded failed failed Docker Application Container Engine
cron.service   loaded failed failed Regular background program processing daemon
CASE6_EOF
cat > "$T/journal-cron.service.out" << 'CASE6_EOF'
Oct 16 12:05:01 host cron[567]: (CRON) STARTUP (fork ok)
Oct 16 12:05:02 host cron[567]: (CRON) DEATH (can't lock /var/run/crond.pid)
CASE6_EOF
: > "$SEND_LOG"
# Set stamp file timestamp to fresh (0 seconds ago)
touch "$STAMP_FILE"
out=$(run_check 0 2>&1); rc=$?
if [[ $rc -eq 1 ]] && [[ -s "$SEND_LOG" ]] \
   && grep -q "cron.service" "$SEND_LOG" \
   && grep -q "^UNITS=docker.service cron.service" "$STAMP_FILE"; then
  pass "6. Alert fires immediately when new failed unit is detected, even within throttle window"
else
  fail "6. Alert unthrottled on new failure failed (rc=$rc, out=$out)"
fi

# -----------------------------------------------------------------------------
# Case 7: Explicit ignore list (cnf/systemd-unit-ignore.tsv)
# -----------------------------------------------------------------------------
cat > "$SYS_FAILED_FILE" << 'CASE7_EOF'
docker.service loaded failed failed Docker Application Container Engine
CASE7_EOF
cat > "$IGNORE_FILE" << 'CASE7_EOF'
# Ignored units
docker.service	known test failure
CASE7_EOF
rm -f "$STAMP_FILE" "$SEND_LOG"
out=$(run_check 0 2>&1); rc=$?
if [[ $rc -eq 0 ]] && [[ ! -f "$SEND_LOG" ]] \
   && grep -q "systemd units healthy" <<< "$out"; then
  pass "7. Ignored unit in cnf/systemd-unit-ignore.tsv emits 0 false alerts and exits 0"
else
  fail "7. Ignore list failed (rc=$rc, out=$out)"
fi

# -----------------------------------------------------------------------------
# Case 8: Mixed units (some ignored, some failed)
# -----------------------------------------------------------------------------
cat > "$SYS_FAILED_FILE" << 'CASE8_EOF'
docker.service loaded failed failed Docker Application Container Engine
cron.service   loaded failed failed Regular background program processing daemon
CASE8_EOF
cat > "$IGNORE_FILE" << 'CASE8_EOF'
docker.service
CASE8_EOF
cat > "$T/journal-cron.service.out" << 'CASE8_EOF'
Oct 16 12:05:01 host cron[567]: (CRON) STARTUP (fork ok)
Oct 16 12:05:02 host cron[567]: (CRON) DEATH (can't lock /var/run/crond.pid)
CASE8_EOF
rm -f "$STAMP_FILE" "$SEND_LOG"
out=$(run_check 0 2>&1); rc=$?
if [[ $rc -eq 1 ]] && [[ -s "$SEND_LOG" ]] \
   && grep -q "cron.service" "$SEND_LOG" \
   && ! grep -q "docker.service" "$SEND_LOG"; then
  pass "8. Mixed units alert only on unignored failed unit"
else
  fail "8. Mixed units failed (rc=$rc, out=$out)"
fi

# -----------------------------------------------------------------------------
# Case 9: System recovery clears stamp file
# -----------------------------------------------------------------------------
touch "$STAMP_FILE"
: > "$SYS_FAILED_FILE"
echo "running" > "$SYS_RUNNING_FILE"
echo 0 > "$SYS_RUNNING_RC"
: > "$IGNORE_FILE"
out=$(run_check 0 2>&1); rc=$?
if [[ $rc -eq 0 ]] && [[ ! -f "$STAMP_FILE" ]]; then
  pass "9. Healthy system in DRY_RUN=0 clears existing stamp file"
else
  fail "9. System recovery stamp cleanup failed (rc=$rc, stamp_exists=$(test -f "$STAMP_FILE" && echo 1 || echo 0))"
fi

# -----------------------------------------------------------------------------
# Case 10: Bullet glyph parsing in systemctl output
# -----------------------------------------------------------------------------
echo "degraded" > "$SYS_RUNNING_FILE"
echo 1 > "$SYS_RUNNING_RC"
cat > "$SYS_FAILED_FILE" << 'CASE10_EOF'
● custom-daemon.service loaded failed failed Custom Internal Daemon
CASE10_EOF
rm -f "$STAMP_FILE" "$SEND_LOG"
out=$(run_check 1 2>&1); rc=$?
if [[ $rc -eq 1 ]] && grep -q "custom-daemon.service" <<< "$out"; then
  pass "10. Bullet glyph '●' in systemctl output parsed cleanly"
else
  fail "10. Bullet glyph parsing failed (rc=$rc, out=$out)"
fi

# -----------------------------------------------------------------------------
# Case 11: Invocation via csi-spl-utl ./run harness
# -----------------------------------------------------------------------------
echo "running" > "$SYS_RUNNING_FILE"
echo 0 > "$SYS_RUNNING_RC"
: > "$SYS_FAILED_FILE"
out=$(cd "$UTL_ROOT" && DRY_RUN=1 ./run -a do_os_systemd_unit_check 2>&1); rc=$?
if [[ $rc -eq 0 ]] && grep -q "systemd units healthy" <<< "$out"; then
  pass "11. Invocation via csi-spl-utl ./run -a do_os_systemd_unit_check succeeds"
else
  fail "11. Invocation via ./run failed (rc=$rc, out=$out)"
fi

# -----------------------------------------------------------------------------
# Case 12: Failed send does not write stamp file
# -----------------------------------------------------------------------------
echo "degraded" > "$SYS_RUNNING_FILE"
echo 1 > "$SYS_RUNNING_RC"
cat > "$SYS_FAILED_FILE" << 'CASE12_EOF'
docker.service loaded failed failed Docker Application Container Engine
CASE12_EOF
cat > "$BIN_DIR/failing-send.sh" << 'FAIL_SEND_EOF'
#!/bin/bash
exit 1
FAIL_SEND_EOF
chmod +x "$BIN_DIR/failing-send.sh"
rm -f "$STAMP_FILE" "$SEND_LOG"

out=$(SYSTEMD_UNIT_ALERT_SEND_BIN="$BIN_DIR/failing-send.sh" run_check 0 2>&1); rc=$?
if [[ $rc -eq 1 ]] && [[ ! -f "$STAMP_FILE" ]] && grep -q "failed to send spool note" <<< "$out"; then
  pass "12. Failed send logs failure and does not write stamp file"
else
  fail "12. Failed send stamp prevention failed (rc=$rc, stamp_exists=$(test -f "$STAMP_FILE" && echo 1 || echo 0))"
fi

# -----------------------------------------------------------------------------
# Case 13: Sender identity respects SPOOL_AGENT_ID when provided
# -----------------------------------------------------------------------------
echo "degraded" > "$SYS_RUNNING_FILE"
echo 1 > "$SYS_RUNNING_RC"
cat > "$SYS_FAILED_FILE" << 'CASE13_EOF'
docker.service loaded failed failed Docker Application Container Engine
CASE13_EOF
rm -f "$STAMP_FILE" "$SEND_LOG"
out=$(SPOOL_AGENT_ID="a-999" run_check 0 2>&1); rc=$?
if [[ $rc -eq 1 ]] && grep -q "CALL spool-send:.*--from a-999" "$SEND_LOG"; then
  pass "13. Sender identity respects SPOOL_AGENT_ID when present"
else
  fail "13. SPOOL_AGENT_ID sender override failed (rc=$rc, out=$out)"
fi

echo "=========================================="
echo "systemd-unit-health: $fails failure(s)"
echo "=========================================="
[[ "$fails" -eq 0 ]]
