#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_workspace_seat_alarm (spec 158 row B, SPL-3504) over planted
#          rows and a fake spool sender. No hub, no DB, no spool binary.
#   1. dry run: the report lists the 0-seat workspace, the test one (e2e) is
#      left out; a PLAN line; nothing sent or written
#   2. a 0-seat workspace with member posts: ONE blocker to the orchestrator
#      (LEASE_ORCH) on task seat-alarm naming it
#   3. RED CONTROL: the same workspace seated (no row) sends nothing
#   4. unchanged: not re-alarmed; after SEAT_ALARM_REALERT: alarmed again
#   5. a failed send keeps the alarm for the next run (exit 1, no state)
#   6. fleet mode: the lease held on another machine sends nothing
#   7. bad input is refused
#   8. the sweep's cron script runs the alarm before the sweep
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

S="$T/spool"
mkdir -p "$S/dispatch"
printf 'LEASE_MASTER=c-002\nLEASE_ORCH=c-001\nLEASE_TENANT=t1\n' >"$S/dispatch/lease.conf"
cat >"$T/send.sh" <<'EOF'
#!/usr/bin/env bash
to="" kind="" task="" body=""
while [ $# -gt 0 ]; do case "$1" in --to) to="$2"; shift 2 ;; --kind) kind="$2"; shift 2 ;; --task) task="$2"; shift 2 ;; --body-file) body="$2"; shift 2 ;; *) shift ;; esac; done
[ -e "$SEND_LOG.fail" ] && exit 11
{ echo "TO $to $kind $task"; cat "$body"; echo "END"; } >>"$SEND_LOG"
EOF
chmod +x "$T/send.sh"
printf 'ws-new\t3\t1793005020\ne2e\t5\t1793005020\n' >"$T/rows.red"
: >"$T/rows.green"

alarm() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" ENV=prd SEND_LOG="$T/sent" SEAT_ALARM_SEND="$T/send.sh" \
    HOME="$T/home" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-workspace-seat-alarm.func.sh"
    do_spl_workspace_seat_alarm'
}
sent() { grep -c '^TO c-001 blocker seat-alarm$' "$T/sent" 2>/dev/null || echo 0; }

# --- 1. dry run ----------------------------------------------------------------------
alarm SEAT_ALARM_ROWS_FILE="$T/rows.red" >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q '^| ws-new | 3 | 2026-10-26T08:57:00Z |$' "$T/o" && ! grep -q '^| e2e ' "$T/o" &&
  grep -q '^PLAN blocker to c-001: ws-new' "$T/o" && [[ ! -e "$T/sent" && ! -e "$S/dispatch/seat-alarm.state" ]] &&
  pass "1. dry run: ws-new reported, e2e left out, nothing sent or written" || fail "1. dry: rc=$rc $(cat "$T/o")"

# --- 2. a 0-seat workspace alarms the orchestrator ----------------------------------------
alarm DRY_RUN=0 SEAT_ALARM_ROWS_FILE="$T/rows.red" >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(sent)" == 1 ]] && grep -q '^| ws-new | 3 |' "$T/sent" && ! grep -q '^| e2e ' "$T/sent" &&
  grep -q 'NO agent is seated' "$T/sent" && grep -q $'^ws-new\t' "$S/dispatch/seat-alarm.state" &&
  pass "2. member posts + 0 seats: one blocker to c-001 on task seat-alarm" || fail "2. alarm: rc=$rc sent=$(sent) $(cat "$T/o")"

# --- 3. RED CONTROL: seated -> silent ---------------------------------------------------
rm -f "$T/sent" "$S/dispatch/seat-alarm.state"
alarm DRY_RUN=0 SEAT_ALARM_ROWS_FILE="$T/rows.green" >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && ! -e "$T/sent" ]] && grep -q '^none$' "$T/o" &&
  pass "3. control: the same workspace with a seat (no row) sends nothing" || fail "3. control: rc=$rc $(cat "$T/o")"

# --- 4. dedup and re-alert ----------------------------------------------------------------
alarm DRY_RUN=0 SEAT_ALARM_ROWS_FILE="$T/rows.red" >/dev/null 2>&1
alarm DRY_RUN=0 SEAT_ALARM_ROWS_FILE="$T/rows.red" >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(sent)" == 1 ]] && pass "4. an unchanged 0-seat workspace is not re-alarmed" || fail "4. dedup: sent=$(sent)"
alarm DRY_RUN=0 SEAT_ALARM_ROWS_FILE="$T/rows.red" SEAT_ALARM_NOW=$(( $(date +%s) + 3600 )) >/dev/null 2>&1
[[ "$(sent)" == 2 ]] && pass "4. after SEAT_ALARM_REALERT it is alarmed again" || fail "4. realert: sent=$(sent) $(cat "$S/dispatch/seat-alarm.state")"

# --- 5. a failed send keeps the alarm -------------------------------------------------------
rm -f "$T/sent" "$S/dispatch/seat-alarm.state"; touch "$T/sent.fail"
alarm DRY_RUN=0 SEAT_ALARM_ROWS_FILE="$T/rows.red" >"$T/o" 2>&1; rc=$?
rm -f "$T/sent.fail"
[[ $rc -ne 0 && ! -e "$S/dispatch/seat-alarm.state" ]] && grep -q 'repeats on the next run' "$T/o" &&
  pass "5. a failed send: exit 1, no memory, the alarm repeats" || fail "5. fail: rc=$rc $(cat "$T/o")"

# --- 6. fleet mode: the lease is held on another machine -------------------------------------
printf 'c-002@far %s\n' "$(date +%s)" >"$S/dispatch/lease"
alarm DRY_RUN=0 SEAT_ALARM_ROWS_FILE="$T/rows.red" LEASE_MACHINE=here >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && ! -e "$T/sent" ]] && grep -q 'sends nothing' "$T/o" &&
  pass "6. the lease held on another machine: this one sends nothing" || fail "6. fleet: rc=$rc $(cat "$T/o")"
rm -f "$S/dispatch/lease"

# --- 7. bad input ----------------------------------------------------------------------------
for bad in ENV=qa SEAT_ALARM_DAYS=0 SEAT_ALARM_REALERT=x DRY_RUN=2; do
  alarm SEAT_ALARM_ROWS_FILE="$T/rows.red" "$bad" >"$T/o" 2>&1 && fail "7. $bad accepted" || pass "7. $bad refused"
done

# --- 8. the cron script runs the alarm --------------------------------------------------------
grep -q 'do_spl_workspace_seat_alarm' "$PROJ_ROOT/src/bash/scripts/unanswered-sweep-cron.sh" &&
  pass "8. unanswered-sweep-cron.sh runs the seat alarm" || fail "8. the cron script does not run the seat alarm"

echo
(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
