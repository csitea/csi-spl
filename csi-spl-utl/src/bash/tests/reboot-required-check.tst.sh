#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for rel-02: kernel reboot & library restart advisory (SPL-2221)
# Tests do_os_reboot_required_check against a stub needrestart, a temp flag
# file and a temp boot dir; the live box is never read or changed.
#   1. Nothing pending (KSTA=1, no flag, no SVC) -> exits 0, no note
#   2. Flag + pkgs, DRY_RUN=1 in window -> exits 1, PLAN, no note, no stamp
#   3. Flag + pkgs, DRY_RUN=0 in window -> exits 1, note with pkgs, stamp
#   4. Same state again -> exits 1, no second note
#   5. New state (services on old libraries) -> exits 1, note lists services
#   6. Outside the window -> exits 1, no note, no stamp
#   7. Cleared state, DRY_RUN=0 -> exits 0, stamp removed
#   8. KSTA=3 alone -> exits 1, note names running and expected kernel
#   9. No needrestart, older running kernel than /boot -> exits 1, source boot-dir
#  10. No needrestart, running kernel is the newest -> exits 0
#  11. Failed send -> exits 1, no stamp
#  12. Never runs needrestart without -b -k -l (list only)
#  13. Through the csi-spl-utl ./run harness -> exits 0 under 2 s
#------------------------------------------------------------------------------
set -uo pipefail

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
UTL_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC_SH="$UTL_ROOT/src/bash/run/reboot-required-check.func.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

BIN_DIR="$T/bin"
mkdir -p "$BIN_DIR" "$T/state" "$T/run" "$T/boot"
NR_OUT="$T/needrestart.out"
NR_ARGS="$T/needrestart.args"
SEND_LOG="$T/spool-send.log"
STAMP_FILE="$T/state/reboot-required.stamp"
FLAG_FILE="$T/run/reboot-required"

cat > "$BIN_DIR/needrestart" << 'NR_EOF'
#!/bin/bash
echo "$*" >> "$NR_ARGS"
cat "$NR_OUT"
NR_EOF
cat > "$BIN_DIR/spool-send.sh" << 'SEND_EOF'
#!/bin/bash
echo "CALL spool-send: $*" >> "$SEND_LOG"
SEND_EOF
printf '#!/bin/bash\nexit 1\n' > "$BIN_DIR/failing-send.sh"
chmod +x "$BIN_DIR"/*

export NR_OUT NR_ARGS SEND_LOG
export NEEDRESTART_BIN="$BIN_DIR/needrestart"
export REBOOT_REQUIRED_FILE="$FLAG_FILE"
export REBOOT_CHECK_STAMP_FILE="$STAMP_FILE"
export REBOOT_CHECK_ALERT_SEND_BIN="$BIN_DIR/spool-send.sh"
export REBOOT_CHECK_BOOT_DIR="$T/boot"
export REBOOT_CHECK_HOUR=04
export DEV_BOX="PC"
unset SPOOL_AGENT_ID REBOOT_CHECK_ALERT_FROM REBOOT_CHECK_WINDOW_HOURS

nr_current() {
  printf 'NEEDRESTART-VER: 3.11\nNEEDRESTART-KCUR: 6.12.1\nNEEDRESTART-KEXP: 6.12.1\nNEEDRESTART-KSTA: 1\n' > "$NR_OUT"
}

run_check() {
  local dry="$1"
  (
    # shellcheck source=/dev/null
    source "$FUNC_SH"
    DRY_RUN="$dry" do_os_reboot_required_check
  )
}

# 1. Nothing pending
nr_current
rm -f "$FLAG_FILE" "$STAMP_FILE" "$SEND_LOG"
out=$(run_check 0 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"no reboot pending"* && ! -f "$SEND_LOG" ]]; then
  pass "1. nothing pending exits 0 and sends no note"
else
  fail "1. nothing pending (rc=$rc, out=$out)"
fi

# 2. Flag + pkgs, DRY_RUN=1
echo '*** System restart required ***' > "$FLAG_FILE"
printf 'linux-image-6.12.2-amd64\nlinux-image-6.12.2-amd64\n' > "$FLAG_FILE.pkgs"
out=$(run_check 1 2>&1); rc=$?
if [[ $rc -eq 1 && "$out" == *"PLAN note to orchestrator"* && "$out" == *"pkgs: linux-image-6.12.2-amd64)"* \
   && ! -f "$SEND_LOG" && ! -f "$STAMP_FILE" ]]; then
  pass "2. flag in DRY_RUN=1 exits 1, prints the plan with deduplicated pkgs, sends nothing"
else
  fail "2. flag in DRY_RUN=1 (rc=$rc, out=$out)"
fi

# 3. Flag + pkgs, DRY_RUN=0
out=$(run_check 0 2>&1); rc=$?
if [[ $rc -eq 1 && -f "$STAMP_FILE" ]] \
   && grep -q -- "--from reboot-required-check@PC --to orchestrator --kind note --task reboot-required-check" "$SEND_LOG" \
   && grep -q "linux-image-6.12.2-amd64" "$SEND_LOG" \
   && grep -q "never reboots" "$SEND_LOG"; then
  pass "3. flag in DRY_RUN=0 sends one advisory note and writes the stamp"
else
  fail "3. flag in DRY_RUN=0 (rc=$rc, out=$out)"
fi

# 4. Same state again
: > "$SEND_LOG"
out=$(run_check 0 2>&1); rc=$?
if [[ $rc -eq 1 && ! -s "$SEND_LOG" && "$out" == *"advice already sent"* ]]; then
  pass "4. the same pending state is not advised twice"
else
  fail "4. same state (rc=$rc, out=$out)"
fi

# 5. New state: services on outdated libraries
printf 'NEEDRESTART-SVC: cron.service\nNEEDRESTART-SVC: ssh.service\n' >> "$NR_OUT"
out=$(run_check 0 2>&1); rc=$?
if [[ $rc -eq 1 ]] && grep -q "cron.service" "$SEND_LOG" && grep -q "ssh.service" "$SEND_LOG" \
   && grep -q "outdated libraries: 2" "$SEND_LOG"; then
  pass "5. a new pending state (2 services) is advised again"
else
  fail "5. new state (rc=$rc, out=$out)"
fi

# 6. Outside the window
rm -f "$STAMP_FILE" "$SEND_LOG"
out=$(REBOOT_CHECK_HOUR=13 run_check 0 2>&1); rc=$?
if [[ $rc -eq 1 && ! -f "$SEND_LOG" && ! -f "$STAMP_FILE" && "$out" == *"outside the advisory window"* ]]; then
  pass "6. outside the 04 window: reported, no note"
else
  fail "6. outside window (rc=$rc, out=$out)"
fi

# 7. Cleared state removes the stamp
touch "$STAMP_FILE"
rm -f "$FLAG_FILE" "$FLAG_FILE.pkgs"
nr_current
out=$(run_check 0 2>&1); rc=$?
if [[ $rc -eq 0 && ! -f "$STAMP_FILE" ]]; then
  pass "7. a cleared state exits 0 and removes the stamp"
else
  fail "7. cleared state (rc=$rc, out=$out)"
fi

# 8. KSTA=3 alone
printf 'NEEDRESTART-KCUR: 6.12.1\nNEEDRESTART-KEXP: 6.12.2\nNEEDRESTART-KSTA: 3\n' > "$NR_OUT"
rm -f "$SEND_LOG"
out=$(run_check 0 2>&1); rc=$?
if [[ $rc -eq 1 ]] && grep -q "running 6.12.1, expected 6.12.2 (KSTA=3, source needrestart)" "$SEND_LOG"; then
  pass "8. a pending kernel upgrade (KSTA=3) alone is advised"
else
  fail "8. KSTA=3 (rc=$rc, out=$out)"
fi

# 9. No needrestart, older running kernel
touch "$T/boot/vmlinuz-6.12.9-amd64" "$T/boot/vmlinuz-6.12.10-amd64"
rm -f "$STAMP_FILE" "$SEND_LOG"
out=$(NEEDRESTART_BIN="$T/missing" REBOOT_CHECK_UNAME_R=6.12.9-amd64 run_check 1 2>&1); rc=$?
if [[ $rc -eq 1 && "$out" == *"needrestart unavailable"* \
   && "$out" == *"running 6.12.9-amd64, expected 6.12.10-amd64 (KSTA=3, source boot-dir)"* ]]; then
  pass "9. without needrestart an older running kernel than /boot is reported (version sort)"
else
  fail "9. boot-dir fallback pending (rc=$rc, out=$out)"
fi

# 10. No needrestart, running kernel is the newest
out=$(NEEDRESTART_BIN="$T/missing" REBOOT_CHECK_UNAME_R=6.12.10-amd64 run_check 1 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"source=boot-dir"* ]]; then
  pass "10. without needrestart the newest running kernel exits 0"
else
  fail "10. boot-dir fallback current (rc=$rc, out=$out)"
fi

# 11. Failed send writes no stamp
echo 'x' > "$FLAG_FILE"
rm -f "$STAMP_FILE"
out=$(REBOOT_CHECK_ALERT_SEND_BIN="$BIN_DIR/failing-send.sh" run_check 0 2>&1); rc=$?
if [[ $rc -eq 1 && ! -f "$STAMP_FILE" && "$out" == *"failed to send spool note"* ]]; then
  pass "11. a failed send logs it and writes no stamp, so the next run retries"
else
  fail "11. failed send (rc=$rc, out=$out)"
fi

# 12. needrestart is only ever called in list mode
if [[ -s "$NR_ARGS" ]] && ! grep -qvx -- "-b -k -l" "$NR_ARGS"; then
  pass "12. needrestart ran $(wc -l < "$NR_ARGS") time(s), always as -b -k -l (list only)"
else
  fail "12. needrestart args: $(sort -u "$NR_ARGS" | tr '\n' '|')"
fi

# 13. Through ./run, under 2 s
rm -f "$FLAG_FILE"
nr_current
start=$(date +%s%N)
out=$(cd "$UTL_ROOT" && DRY_RUN=1 ./run -a do_os_reboot_required_check 2>&1); rc=$?
ms=$(( ($(date +%s%N) - start) / 1000000 ))
if [[ $rc -eq 0 && "$out" == *"no reboot pending"* && $ms -lt 2000 ]]; then
  pass "13. ./run -a do_os_reboot_required_check exits 0 in ${ms} ms (< 2000)"
else
  fail "13. ./run harness (rc=$rc, ms=$ms, out=$out)"
fi

echo "=========================================="
echo "reboot-required-check: $fails failure(s)"
echo "=========================================="
[[ "$fails" -eq 0 ]]
