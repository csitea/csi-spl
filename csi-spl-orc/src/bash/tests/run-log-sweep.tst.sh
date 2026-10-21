#!/usr/bin/env bash
# run-log-sweep.tst.sh - the box sweep's runlogs step (SPL-2649) on a temp
# $HOME with aged ./run logs:
#   0. box-disk-sweep accepts step runlogs and dry-runs it (on origin/master
#      the same command exits 2: unknown step 'runlogs' - the red)
#   1. the dry run (default) plans the two aged 1 MB logs, removes nothing
#   2. DRY_RUN=0 removes ONLY the aged *.log under <proj>/, oldest first, and
#      reports the 2 MB; keeps a recent log, a log a process holds open, a
#      non-.log file, a log one dir deeper and a symlink's target
#   3. the sweep passes the retention by level: 72 h normal, 24 h low, 6 h crit;
#      under DRY_RUN=0 the step runs live by default (SPL-2804, after the
#      orchestrator's first live run 2026-10-21T21:54Z); the off switch
#      BOX_SWEEP_RUNLOG_APPLY=0 keeps it a plan
#   4. a bad age is refused (exit 2)
#   5. the INSTALLED cron row's env (do_box_disk_sweep_install_cron, fake
#      crontab) through the REAL sweep and run-log-sweep.sh: an aged planted
#      log is removed, a log a process holds open is kept; RED CONTROL: the
#      same row with BOX_SWEEP_RUNLOG_APPLY=0 (the old hold) removes nothing

set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

RS="$PROJ_ROOT/src/bash/scripts/run-log-sweep.sh"
SW="$PROJ_ROOT/src/bash/scripts/box-disk-sweep.sh"

H="$T/box-user" R="$T/box-user/var/log" OUT="$T/outside"
mkdir -p "$R/csi-spl-orc/deeper" "$R/csi-spl-iac" "$OUT"
mk() { head -c "${2:-10}" /dev/zero >"$1"; }
mk "$R/csi-spl-orc/run.sh.20261010_000000.out.log" 1048576
mk "$R/csi-spl-iac/run.sh.20261011_000000.err.log" 1048576
mk "$R/csi-spl-orc/run.sh.20261012_000000.out.log"
mk "$R/csi-spl-orc/run.sh.20261013_000000.err.log"
mk "$R/csi-spl-orc/notes.txt"
mk "$R/csi-spl-orc/deeper/x.log"
mk "$OUT/precious.log"; ln -s "$OUT/precious.log" "$R/csi-spl-orc/link.log"
touch -h -d '5 days ago' "$R"/csi-spl-orc/* "$R"/csi-spl-iac/* "$R/csi-spl-orc/deeper/x.log" "$OUT/precious.log"
touch -d '4 days ago' "$R/csi-spl-iac/run.sh.20261011_000000.err.log"
touch -d '1 hour ago' "$R/csi-spl-orc/run.sh.20261012_000000.out.log"
OPEN="$R/csi-spl-orc/run.sh.20261013_000000.err.log"
sleep 600 3>>"$OPEN" & hold_pid=$!
for _ in $(seq 300); do [ "$(readlink "/proc/$hold_pid/fd/3")" = "$OPEN" ] && break; sleep 0.1; done

out="$(DRY_RUN=1 BOX_SWEEP_STEPS=runlogs BOX_SWEEP_LOCK="$T/s.lock" BOX_SWEEP_MOUNTS="$T" BOX_SWEEP_NOTE=0 BOX_SWEEP_FREE_PCT=50 HOME="$H" bash "$SW" 2>&1)"
rc=$?
[ "$rc" = 0 ] && grep -q 'DONE run-log sweep removed=2 (2 MB) kept_open=1 planned' <<<"$out" \
  && pass "0. the sweep dry-runs step runlogs (red on origin/master: unknown step)" || fail "0. sweep runlogs (rc $rc: $out)"

n0="$(find "$T" | wc -l)"
out="$(HOME="$H" bash "$RS" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q 'removed=2 (2 MB) kept_open=1 planned' <<<"$out" && [ "$(find "$T" | wc -l)" = "$n0" ] \
  && pass "1. the dry run (default) plans the two aged logs and removes nothing" || fail "1. dry run (rc $rc: $out)"

out="$(HOME="$H" DRY_RUN=0 bash "$RS" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q 'DONE run-log sweep removed=2 (2 MB) kept_open=1$' <<<"$out" \
  && [ ! -e "$R/csi-spl-orc/run.sh.20261010_000000.out.log" ] && [ ! -e "$R/csi-spl-iac/run.sh.20261011_000000.err.log" ] \
  && pass "2. DRY_RUN=0 removes the aged run logs and reports 2 MB" || fail "2. live run (rc $rc: $out)"
grep -q "KEEP open $OPEN\$" <<<"$out" && [ -f "$OPEN" ] && pass "2. a log a process holds open is kept" || fail "2. open ($out)"
[ -f "$R/csi-spl-orc/run.sh.20261012_000000.out.log" ] && pass "2. a recent log is kept" || fail "2. recent removed"
[ -f "$R/csi-spl-orc/notes.txt" ] && [ -f "$R/csi-spl-orc/deeper/x.log" ] && [ -L "$R/csi-spl-orc/link.log" ] && [ -f "$OUT/precious.log" ] \
  && pass "2. a non-.log file, a deeper log, a symlink and its target are untouched" || fail "2. other shapes touched"
kill "$hold_pid" 2>/dev/null; wait "$hold_pid" 2>/dev/null

F="$T/fake" L="$T/steps.log"; mkdir -p "$F"
printf '#!/bin/sh\necho "run-log-sweep DRY_RUN=$DRY_RUN AGE=$RUN_LOG_SWEEP_AGE_H" >>%q\n' "$L" >"$F/run-log-sweep.sh"
for c in "50 72" "10 24" "3 6"; do
  read -r f a <<<"$c"; : >"$L"
  DRY_RUN=0 BOX_SWEEP_RUNLOG_APPLY=1 BOX_SWEEP_STEPS=runlogs BOX_SWEEP_SCRIPTS="$F" BOX_SWEEP_LOCK="$T/s.lock" BOX_SWEEP_MOUNTS="$T" BOX_SWEEP_NOTE=0 \
    BOX_SWEEP_FREE_PCT="$f" bash "$SW" >/dev/null 2>&1
  [ "$(cat "$L")" = "run-log-sweep DRY_RUN=0 AGE=$a" ] && pass "3. free $f%: runlogs keeps $a h" || fail "3. free $f% ($(cat "$L"))"
done

: >"$L"; DRY_RUN=0 BOX_SWEEP_STEPS=runlogs BOX_SWEEP_SCRIPTS="$F" BOX_SWEEP_LOCK="$T/s.lock" BOX_SWEEP_MOUNTS="$T" BOX_SWEEP_NOTE=0 \
  BOX_SWEEP_FREE_PCT=10 bash "$SW" >/dev/null 2>&1
[ "$(cat "$L")" = "run-log-sweep DRY_RUN=0 AGE=24" ] && pass "3. DRY_RUN=0 without BOX_SWEEP_RUNLOG_APPLY runs live (default 1)" || fail "3. default ($(cat "$L"))"
: >"$L"; DRY_RUN=0 BOX_SWEEP_RUNLOG_APPLY=0 BOX_SWEEP_STEPS=runlogs BOX_SWEEP_SCRIPTS="$F" BOX_SWEEP_LOCK="$T/s.lock" BOX_SWEEP_MOUNTS="$T" BOX_SWEEP_NOTE=0 \
  BOX_SWEEP_FREE_PCT=10 bash "$SW" >/dev/null 2>&1
[ "$(cat "$L")" = "run-log-sweep DRY_RUN=1 AGE=24" ] && pass "3. the off switch BOX_SWEEP_RUNLOG_APPLY=0 only plans" || fail "3. off switch ($(cat "$L"))"

out="$(RUN_LOG_SWEEP_AGE_H=0 HOME="$H" bash "$RS" 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -q 'FAIL RUN_LOG_SWEEP_AGE_H' <<<"$out" && pass "4. a zero age is refused" || fail "4. age 0 (rc $rc: $out)"

# 5. the installed row's env, end to end
CT="$T/crontab"; : >"$CT"
printf '#!/bin/sh\nif [ "$1" = -l ]; then cat %q; else cp "$1" %q; fi\n' "$CT" "$CT" >"$T/fake-crontab"; chmod +x "$T/fake-crontab"
row_env() {
  : >"$CT"
  SNIPPET='do_box_disk_sweep_install_cron' in_orc DRY_RUN=0 BOX_SWEEP_CRONTAB="$T/fake-crontab" BOX_SWEEP_CRON_LOG_DIR="$T/cronlog" \
    BOX_SWEEP_ALLOW_WORKTREE=1 "$@" >/dev/null 2>&1
  grep ' # csi-spl:box-disk-sweep$' "$CT" | sed -E 's/^([^ ]+ ){5}//; s/ bash .*//'
}
plant5() {
  H5="$T/h5-$1"; R5="$H5/var/log/csi-spl-orc"; mkdir -p "$R5"
  mk "$R5/run.sh.20261001_000000.out.log"; mk "$R5/run.sh.20261002_000000.err.log"
  touch -d '5 days ago' "$R5"/*.log
}
sweep5() { env $1 BOX_SWEEP_STEPS=runlogs BOX_SWEEP_MOUNTS="$T" BOX_SWEEP_NOTE=0 BOX_SWEEP_FREE_PCT=50 HOME="$H5" bash "$SW" 2>&1; }
env_on="$(row_env)"
grep -q '^DRY_RUN=0 BOX_SWEEP_RUNLOG_APPLY=1 BOX_SWEEP_GATE=1 BOX_SWEEP_LOCK=' <<<"$env_on" \
  && pass "5. the installed row carries DRY_RUN=0 BOX_SWEEP_RUNLOG_APPLY=1" || fail "5. row env ($env_on)"
plant5 on; OPEN5="$R5/run.sh.20261002_000000.err.log"
sleep 600 3>>"$OPEN5" & hold5=$!
for _ in $(seq 300); do [ "$(readlink "/proc/$hold5/fd/3")" = "$OPEN5" ] && break; sleep 0.1; done
out="$(sweep5 "$env_on")"
[ ! -e "$R5/run.sh.20261001_000000.out.log" ] && grep -q 'DONE run-log sweep removed=1 .* kept_open=1$' <<<"$out" \
  && pass "5. with the row's env the runlogs step removes the aged log (dry_run=0)" || fail "5. live row ($out)"
[ -f "$OPEN5" ] && grep -q "KEEP open $OPEN5\$" <<<"$out" && pass "5. ...and keeps the log a process holds open" || fail "5. open log ($out)"
kill "$hold5" 2>/dev/null; wait "$hold5" 2>/dev/null
env_off="$(row_env BOX_SWEEP_CRON_RUNLOG_APPLY=0)"
rm -f "$T/cronlog/box-disk-sweep.lock.last-normal"; plant5 off; out="$(sweep5 "$env_off")"
grep -q 'BOX_SWEEP_RUNLOG_APPLY=0' <<<"$env_off" && [ "$(ls "$R5" | wc -l)" = 2 ] && grep -q 'removed=2 .*planned' <<<"$out" \
  && pass "5. RED CONTROL: the row with BOX_SWEEP_RUNLOG_APPLY=0 only plans, removes nothing" || fail "5. control ($env_off: $out)"

echo "run-log-sweep: ${fails} failure(s)"
[ "$fails" -eq 0 ]
