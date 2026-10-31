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
[[ "$(grep -c ' SKIP an earlier run of bash still holds ' "$log")" -eq 1 ]] &&
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

echo
if [ "$fails" -eq 0 ]; then echo "cron-no-stack: all passed"; exit 0; fi
echo "cron-no-stack: $fails FAILED"; exit 1
