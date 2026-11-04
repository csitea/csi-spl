#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: an every-minute box cron line never stacks (SPL-4495). On
# 2026-10-31 a slow box stacked 111 runner CPU budget runs, 75 seat alarms, 25
# box stats and 13 lane rotations (load 467 on 16 cores). Every frequent line
# the installers write now runs its job behind cron-no-stack.sh on its own lock.
#   1. a line do_install_box_crons writes, run twice by /bin/sh as cron does,
#      over a fake slow job: the second start exits at once, rc 0, one SKIP
#      line in the line's log; the first runs to its end; one job ran
#   2. red control: the same line with the wrapper cut out runs two jobs at
#      once
#   3. the wrapper passes the job's exit code through; a usage error is rc 2
#   4. a daemon the job leaves behind holds no lock: the next start runs
#   5. a re-install keeps the lock (the installer writes it, not a hand edit)
#   6. the SKIP line names the holder's job, not the new start's
#   7. a holder older than CRON_NO_STACK_MAX_S is stuck: STUCK line, rc 3,
#      one spool note per stuck holder; red control: a young holder sends none
#   8. with no sender set, as on a real cron line, the note goes from the
#      box's orchestrator seat (LEASE_ORCH), an id spool-send.sh's own check
#      (spool_valid_id) takes; no LEASE_ORCH -> one WARN, no note
#   9. a job that runs long by design declares its own max (SPL-4768): the
#      wrapper names its lock to the job (CRON_NO_STACK_LOCK); the file
#      follower's max is run_s + 600 of the shipped cnf, larger than run_s;
#      red control: a holder aged between 1800 s and run_s with no max of its
#      own is STUCK (every start on one box, 2475 lines by 2026-11-04); with the
#      declared max it is a SKIP; past run_s + margin it is STUCK again;
#      a max test(1) cannot compare (20 digits) is STUCK at the default; the
#      declare refuses a max that is not 1..6 digits; a run_s of 0900 is 900
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

W="$PROJ_ROOT/src/bash/scripts/cron-no-stack.sh"
bash -n "$W" || { echo "FAIL: bash -n $W"; exit 1; }
O="$T/orc"
mkdir -p "$O/cnf/box-crons" "$O/src/bash/scripts" "$T/state"
cp "$W" "$O/src/bash/scripts/"
# the fake slow job: one "start" line, 3 s of work, one "end" line
cat >"$O/src/bash/scripts/slow-job-cron.sh" <<EOF
#!/bin/sh
echo "start \$\$" >>"$T/jobs"
sleep 3
echo "end \$\$" >>"$T/jobs"
EOF
chmod +x "$O/src/bash/scripts/slow-job-cron.sh"
echo 'slow-job | * * * * * | src/bash/scripts/slow-job-cron.sh | slow-job/cron.log |' >"$O/cnf/box-crons/box-crons.manifest"
: >"$T/crontab"
printf '#!/bin/sh\nif [ "$1" = -l ]; then cat %q; else cp "$1" %q; fi\n' "$T/crontab" "$T/crontab" >"$T/fake-crontab"; chmod +x "$T/fake-crontab"
inst() { SNIPPET="PROJ_PATH=$O; do_install_box_crons" in_orc BOX_CRONS_CRONTAB="$T/fake-crontab" BOX_CRONS_STATE_DIR="$T/state" DRY_RUN=0 2>&1; }

out="$(inst)" || { echo "FAIL: install ($out)"; exit 1; }
line="$(grep ' # csi-spl:box-cron:slow-job$' "$T/crontab")"
cmd="$(cut -d' ' -f6- <<<"$line")"
log="$T/state/slow-job/cron.log"
lock="$T/state/slow-job/slow-job.cron.lock"
[[ "$cmd" == "$O/src/bash/scripts/cron-no-stack.sh $lock /bin/bash "* ]] &&
  pass "0. the installed line runs its job behind cron-no-stack.sh on its own lock" || fail "0. line shape: $line"

# wait_jobs <n>: until $T/jobs has n "start" lines (5 s at most)
wait_jobs() {
  local n=0
  while [ "$n" -lt 50 ]; do
    [ "$(grep -c '^start' "$T/jobs" 2>/dev/null)" -ge "$1" ] && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

# 1. the line started twice
: >"$T/jobs"
sh -c "$cmd" & first=$!
wait_jobs 1 || fail "1. the first start never ran its job"
t0=$(date +%s%N)
sh -c "$cmd"; rc=$?
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
running="$(grep -c '^start' "$T/jobs")"
wait "$first"; frc=$?
[[ $rc -eq 0 && $ms -lt 2000 ]] && pass "1. the second start exits at once, rc 0 (${ms} ms)" || fail "1. second start rc=$rc after ${ms} ms"
[[ "$(grep -c ' SKIP an earlier run of bash (pid [0-9]*) still holds ' "$log")" -eq 1 ]] &&
  pass "1. ...with one SKIP line in the line's log" || fail "1. SKIP lines: $(cat "$log")"
[[ $frc -eq 0 && "$running" -eq 1 && "$(grep -c '^start' "$T/jobs")" -eq 1 && "$(grep -c '^end' "$T/jobs")" -eq 1 ]] &&
  pass "1. the first run finished, one job ran" || fail "1. first rc=$frc, jobs: $(cat "$T/jobs")"

# 2. red control: the line without the wrapper
bare="${cmd/"$O/src/bash/scripts/cron-no-stack.sh $lock "/}"
: >"$T/jobs"
if [[ "$bare" == "$cmd" ]]; then
  fail "2. red control: could not cut the wrapper out of the line"
else
  sh -c "$bare" & a=$!
  sh -c "$bare" & b=$!
  wait_jobs 2; both="$(grep -c '^start' "$T/jobs")"
  ended="$(grep -c '^end' "$T/jobs")"
  wait "$a" "$b"
  [[ "$both" -eq 2 && "$ended" -eq 0 ]] && pass "2. red control: without the lock two jobs run at once" ||
    fail "2. red control: started=$both ended=$ended"
fi

# 3. exit codes
"$W" "$T/rc.lock" sh -c 'exit 7'; rc=$?
[[ $rc -eq 7 ]] && pass "3. the job's exit code passes through" || fail "3. rc=$rc, want 7"
out="$("$W" "$T/rc.lock" 2>&1)"; rc=$?
out2="$("$W" relative.lock true 2>&1)"; rc2=$?
[[ $rc -eq 2 && $rc2 -eq 2 && "$out" == *usage* && "$out2" == *'absolute path'* ]] &&
  pass "3. no command or a relative lock: rc 2" || fail "3. usage rc=$rc/$rc2: $out / $out2"

# 4. a daemon left behind holds no lock
"$W" "$T/d.lock" sh -c "sleep 20 >/dev/null 2>&1 & echo \$! >'$T/daemon.pid'"
out="$("$W" "$T/d.lock" echo ran 2>&1)"; rc=$?
[[ -s "$T/daemon.pid" ]] && kill "$(cat "$T/daemon.pid")" 2>/dev/null
[[ $rc -eq 0 && "$out" == ran ]] && pass "4. a daemon the job left behind does not hold the lock" || fail "4. rc=$rc out=$out"

# 5. a re-install keeps the line, lock and all
out="$(inst)"; rc=$?
[[ $rc -eq 0 && "$(grep -cxF "$line" "$T/crontab")" -eq 1 && "$(grep -c 'csi-spl:box-cron:' "$T/crontab")" -eq 1 ]] &&
  pass "5. a re-install keeps the locked line" || fail "5. reinstall rc=$rc: $(cat "$T/crontab")"
# hold_lock <lock> <age s> <job> [<hold s>]: a fake holder of <lock>, started
# <age> s ago, for <hold s> (default 5); its pid in $holder
hold_lock() {
  ( exec 9>>"$1"; flock 9
    printf 'pid=%s start=%s job=%s\n' "$BASHPID" "$(( $(date +%s) - $2 ))" "$3" >"$1"
    : >"$1.held"; sleep "${4:-5}" ) & holder=$!
  local n=0; while [ ! -e "$1.held" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
}
printf '#!/bin/sh\necho "$*" >>%q\n' "$T/alerts" >"$T/fake-send"
: >"$T/alerts"
export CRON_NO_STACK_ALERT_SEND_BIN="$T/fake-send"
# the sender and the spool root are the test's own: the host's SPOOL_AGENT_ID or
# live lease.conf must not decide a verdict (CI has neither: wf 10 red on 5b0ead29a)
export SPOOL_ROOT="$T/spool" CRON_NO_STACK_ALERT_FROM=c-001

# 6. the SKIP line names the holder
hold_lock "$T/h.lock" 5 sleep
out="$("$W" "$T/h.lock" true 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"SKIP an earlier run of sleep (pid $holder) still holds"* && ! -s "$T/alerts" ]] &&
  pass "6. a young holder: SKIP names its job and pid, rc 0, no alert" || fail "6. rc=$rc out=$out alerts=$(cat "$T/alerts")"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

# 7. a stuck holder
hold_lock "$T/s.lock" 4000 git
out="$(CRON_NO_STACK_MAX_S=1800 "$W" "$T/s.lock" true 2>&1)"; rc=$?
out2="$(CRON_NO_STACK_MAX_S=1800 "$W" "$T/s.lock" true 2>&1)"; rc2=$?
[[ $rc -eq 3 && "$out" == *"STUCK git held 400"?" s by pid $holder"*"(max 1800 s)"* ]] &&
  pass "7. a holder past CRON_NO_STACK_MAX_S: STUCK line naming job, age and pid, rc 3" || fail "7. rc=$rc out=$out"
[[ $rc2 -eq 3 && "$(grep -c -- '--kind note --task cron-no-stack --body STUCK git' "$T/alerts")" -eq 1 ]] &&
  pass "7. ...one spool note for that holder, not one per start" || fail "7. rc2=$rc2 alerts: $(cat "$T/alerts")"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
out="$("$W" "$T/s.lock" echo ran 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == ran && ! -e "$T/s.lock.stuck" ]] &&
  pass "7. once the holder is gone the next start runs and clears the stuck mark" || fail "7. after: rc=$rc out=$out"
# 8. the default sender, as a real cron line has it: no CRON_NO_STACK_ALERT_FROM
# and no SPOOL_AGENT_ID. The fake send runs spool-send.sh's own id check on
# --from and refuses as spool-send.sh does (rc 2).
SPL_ENV="$PROJ_ROOT/src/bash/features/spawn-agents/lib/spool-env.inc.sh"
cat >"$T/check-send" <<EOF
#!/usr/bin/env bash
source '$SPL_ENV' >/dev/null 2>&1
while [ \$# -gt 0 ]; do [ "\$1" = --from ] && from="\$2"; shift; done
spool_valid_id "\$from" 2>>'$T/refused' || exit 2
echo "from=\$from" >>'$T/sent'
EOF
mkdir -p "$T/spool/dispatch"; echo 'LEASE_ORCH=c-001' >"$T/spool/dispatch/lease.conf"
: >"$T/sent"; : >"$T/refused"
hold_lock "$T/f.lock" 4000 git
out="$(env -u SPOOL_AGENT_ID -u CRON_NO_STACK_ALERT_FROM CRON_NO_STACK_ALERT_SEND_BIN="$T/check-send" "$W" "$T/f.lock" true 2>&1)"; rc=$?
[[ $rc -eq 3 && "$(cat "$T/sent")" == from=c-001 && ! -s "$T/refused" && -e "$T/f.lock.stuck" && "$out" == *"stuck alert sent"* ]] &&
  pass "8. no sender set: the note goes from LEASE_ORCH (c-001), spool_valid_id takes it" ||
  fail "8. rc=$rc sent=$(cat "$T/sent") refused=$(cat "$T/refused") out=$out"
rm -f "$T/spool/dispatch/lease.conf" "$T/f.lock.stuck"; : >"$T/sent"
out="$(env -u SPOOL_AGENT_ID -u CRON_NO_STACK_ALERT_FROM CRON_NO_STACK_ALERT_SEND_BIN="$T/check-send" "$W" "$T/f.lock" true 2>&1)"; rc=$?
[[ $rc -eq 3 && ! -s "$T/sent" && "$out" == *"WARN no agent id to send the stuck alert from"* ]] &&
  pass "8. no LEASE_ORCH either: one WARN naming the gap, no note" || fail "8. no orch: rc=$rc sent=$(cat "$T/sent") out=$out"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

# 9. the file follower's own max. fs_declare <lock>: what its cron job does
# under the wrapper: the follower's env from the shipped cnf, then
# spl_file_stream_stuck_max on CRON_NO_STACK_LOCK; [VAR=value ...] the env it
# runs with. raw_declare <lock> <s>: spl_cron_no_stack_declare_max <s> itself
FS_FUNC="$PROJ_ROOT/src/bash/run/spl-file-stream-follow.func.sh"
CNF="$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml"
raw_declare() {
  CRON_NO_STACK_LOCK="$1" bash -c 'source "$1" >/dev/null 2>&1; spl_cron_no_stack_declare_max "$2"' _ "$FS_FUNC" "$2" 2>/dev/null
}
fs_declare() {
  env -u FILE_STREAMS_RUN_S -u FILE_STREAMS_STUCK_MARGIN_S "${@:2}" CRON_NO_STACK_LOCK="$1" bash -c '
    source "$1" >/dev/null 2>&1; envs=(); spl_file_stream_env "$2" >/dev/null 2>&1 && spl_file_stream_stuck_max' _ "$FS_FUNC" "$CNF"
}
run_s="$(yq -r '.env.box.file_streams.run_s' "$CNF")"
out="$("$W" "$T/n.lock" sh -c 'printf %s "$CRON_NO_STACK_LOCK"' 2>&1)"
[[ "$out" == "$T/n.lock" ]] && pass "9. the wrapper names its lock to the job (CRON_NO_STACK_LOCK)" || fail "9. CRON_NO_STACK_LOCK=$out"
unset CRON_NO_STACK_MAX_S; : >"$T/alerts"
hold_lock "$T/fs.lock" 2500 bash 10
out="$("$W" "$T/fs.lock" true 2>&1)"; rc=$?
[[ $rc -eq 3 && "$out" == *"STUCK bash held 250"?" s by pid $holder"*"(max 1800 s)"* ]] &&
  pass "9. red control: a 2500 s holder with no max of its own is STUCK (max 1800 s)" || fail "9. red control: rc=$rc out=$out"
rm -f "$T/fs.lock.stuck"; : >"$T/alerts"
fs_declare "$T/fs.lock"; drc=$?
max="$(sed -n 's/.* max=\([0-9]*\)$/\1/p' "$T/fs.lock")"
[[ $drc -eq 0 && "$run_s" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ && "$max" -gt "$run_s" && "$max" -eq $(( run_s + 600 )) ]] &&
  pass "9. the file follower declares max $max s, larger than its run_s $run_s (shipped cnf)" || fail "9. declare rc=$drc max='$max' run_s='$run_s': $(cat "$T/fs.lock")"
out="$("$W" "$T/fs.lock" true 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"SKIP an earlier run of bash (pid $holder)"* && ! -s "$T/alerts" ]] &&
  pass "9. the same 2500 s holder under its declared max: SKIP, rc 0, no alert" || fail "9. declared: rc=$rc out=$out alerts=$(cat "$T/alerts")"
fs_declare "$T/fs.lock"
[[ "$(grep -o ' max=' "$T/fs.lock" | wc -l)" -eq 1 && "$(wc -l <"$T/fs.lock")" -eq 1 ]] &&
  pass "9. a second declare keeps one max= on one record line" || fail "9. record: $(cat "$T/fs.lock")"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
hold_lock "$T/fh.lock" $(( run_s + 600 + 300 )) bash 10
fs_declare "$T/fh.lock"
out="$("$W" "$T/fh.lock" true 2>&1)"; rc=$?
[[ $rc -eq 3 && "$out" == *"STUCK bash held"*"(max $(( run_s + 600 )) s)"* && -s "$T/alerts" ]] &&
  pass "9. a holder past run_s + margin is still STUCK, one note" || fail "9. hang: rc=$rc out=$out"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
printf 'not a holder record\n' >"$T/hand.lock"
fs_declare "$T/hand.lock"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/hand.lock")" == "not a holder record" ]] &&
  pass "9. a lock with no holder record is left as it is" || fail "9. no record: rc=$rc $(cat "$T/hand.lock")"
: >"$T/alerts"
hold_lock "$T/big.lock" 2500 bash 10
rec="$(cat "$T/big.lock")"; printf '%s max=99999999999999999999\n' "$rec" >"$T/big.lock"
out="$("$W" "$T/big.lock" true 2>&1)"; rc=$?
[[ $rc -eq 3 && "$out" == *"STUCK bash held"*"(max 1800 s)"* && "$out" != *"integer expression"* && -s "$T/alerts" ]] &&
  pass "9. a 20-digit max in the record is STUCK at the default 1800 s, one note" || fail "9. 20-digit max: rc=$rc out=$out"
rec="$(cat "$T/big.lock")"
raw_declare "$T/big.lock" 99999999999999999999; rc=$?
[[ $rc -eq 1 && "$(cat "$T/big.lock")" == "$rec" ]] &&
  pass "9. the declare refuses a 20-digit max, rc 1, the record unchanged" || fail "9. 20-digit declare: rc=$rc $(cat "$T/big.lock")"
raw_declare "$T/big.lock" abc; rc=$?
[[ $rc -eq 1 && "$(cat "$T/big.lock")" == "$rec" ]] &&
  pass "9. the declare refuses a non-numeric max, rc 1, the record unchanged" || fail "9. abc declare: rc=$rc $(cat "$T/big.lock")"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
hold_lock "$T/oct.lock" 60 bash 10
fs_declare "$T/oct.lock" FILE_STREAMS_RUN_S=0900; rc=$?
max="$(sed -n 's/.* max=\([0-9]*\)$/\1/p' "$T/oct.lock")"
[[ $rc -eq 0 && "$max" == 1500 ]] &&
  pass "9. FILE_STREAMS_RUN_S=0900 declares max 1500 (decimal, not octal)" || fail "9. 0900: rc=$rc $(cat "$T/oct.lock")"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

echo
if [ "$fails" -eq 0 ]; then echo "cron-no-stack: all passed"; exit 0; fi
echo "cron-no-stack: $fails FAILED"; exit 1
