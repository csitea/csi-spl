#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_wd_ensure and do_spl_wd_ensure_install_cron (spec 093 T007).
#   1. a dead watchdog is started on the next run; only do_spl_watchdog, and
#      the loop is handed DRY_RUN=0 with WD_TICKS cleared
#   2. a second run while that loop holds the lock starts nothing
#   3. after the loop dies, the next run starts it again
#   4. no seats file, and a seats file, both start exactly one watchdog
#   5. a missing runner is refused and starts nothing
#   6. crontab fixture: dry run writes nothing; install writes ONE
#      `* * * * *` line tagged `# csi-spl:wd-ensure` and keeps every other
#      line; a re-install changes no byte; check and remove
#   7. spec 068 8.1 on the fixture before and after (0 failing), and a
#      control whose script is outside any checkout (the check DOES fire)
#   8. foreign lines that fail a whole-crontab 8.1 do not block the install;
#      a wd-ensure line outside any checkout is still not written; a worktree
#      source is refused. WD_ENSURE_WATCH_DRY=1 is copied onto the cron line.
# No real crontab, tmux or live spool is touched.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/spool" "$T/log"

# the action, as ./run runs it: set -E, pipefail, an ERR trap that ends the run
cat > "$T/bin/act" << EOF
#!/usr/bin/env bash
set -Euo pipefail
trap 'echo "ERRTRAP: \$BASH_COMMAND (line \$LINENO)"; exit 99' ERR
do_log() { echo "\$*"; }
do_require_bin() { return 0; }
source "$PROJ_ROOT/src/bash/run/spl-wd-ensure.func.sh"
source "$PROJ_ROOT/src/bash/run/spl-wd-ensure-install-cron.func.sh"
"\$@" || exit \$?
EOF
chmod +x "$T/bin/act"

D="$T/spool/dispatch/wd"
CALLS="$T/calls"
cat > "$T/bin/wd" << EOF
#!/usr/bin/env bash
echo "DRY_RUN=\${DRY_RUN-} WD_TICKS=\${WD_TICKS-unset} \$*" >> "$CALLS"
mkdir -p "$D"
exec 7>>"$D/run.lock"
flock 7
echo \$\$ > "$D/run.pid"
# same pid keeps fd 7: a forked sleep would inherit the lock after the parent dies
exec python3 -c "import time; time.sleep(120)"
EOF
chmod +x "$T/bin/wd"

cat > "$T/bin/crontab" << 'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi
cp "$1" "$FAKE_CRONTAB"
EOF
chmod +x "$T/bin/crontab"

export SPOOL_TEST=1 SPOOL_ROOT="$T/spool" PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" \
  PATH="$T/bin:$PATH" WD_RUN="$T/bin/wd" DRY_RUN=1 WD_TICKS=3
unset WD_ENSURE_WATCH_DRY SPOOL_BOX_ENV SPOOL_DESK_BOX

run_act() { "$T/bin/act" "$@"; }
wait_held() {
  local n=0
  while (( n < 50 )); do
    [[ -s "$D/run.pid" ]] && ! flock -n "$D/run.lock" true && return 0
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}
stop_loop() {
  local pid n=0
  pid="$(cat "$D/run.pid" 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]]; then kill "$pid" 2>/dev/null || true; fi
  [[ -e "$D/run.lock" ]] || return 0
  while (( n < 50 )); do
    if flock -n "$D/run.lock" true; then return 0; fi
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}

# --- 1-5. the keeper ----------------------------------------------------------
: > "$CALLS"
out="$(run_act do_spl_wd_ensure)"; rc=$?
wait_held || true
[[ $rc -eq 0 && "$out" == *"no seats"* && "$out" == *"watchdog started"* && "$(cat "$CALLS")" == "DRY_RUN=0 WD_TICKS= -a do_spl_watchdog" ]] &&
  pass "1. no seats: one start of do_spl_watchdog, DRY_RUN=0, WD_TICKS cleared (parent had DRY_RUN=1 WD_TICKS=3)" ||
  fail "1. start rc=$rc out=$out calls=$(cat "$CALLS" 2>&1)"

out="$(run_act do_spl_wd_ensure)"; rc=$?
[[ $rc -eq 0 && "$out" == *"watchdog running"* && "$(wc -l < "$CALLS")" -eq 1 ]] &&
  pass "2. loop alive: the next run starts nothing" ||
  fail "2. alive rc=$rc out=$out calls=$(cat "$CALLS" 2>&1)"

stop_loop || fail "3. the loop did not release the lock"
out="$(run_act do_spl_wd_ensure)"; rc=$?
wait_held || true
[[ $rc -eq 0 && "$out" == *"watchdog started"* && "$(wc -l < "$CALLS")" -eq 2 && "$(sed -n 2p "$CALLS")" == "DRY_RUN=0 WD_TICKS= -a do_spl_watchdog" ]] &&
  pass "3. dead loop: the next run starts it again, still only the watchdog" ||
  fail "3. restart rc=$rc out=$out calls=$(cat "$CALLS" 2>&1)"

stop_loop || true
mkdir -p "$T/spool/peer"
printf 'c-001 claude\nc-002 claude\ng-003 grok\n' > "$T/spool/peer/seats"
out="$(run_act do_spl_wd_ensure)"; rc=$?
wait_held || true
[[ $rc -eq 0 && "$out" != *"no seats"* && "$out" == *"watchdog started"* && "$(wc -l < "$CALLS")" -eq 3 && "$(grep -c 'do_spl_peer_' "$CALLS")" -eq 0 ]] &&
  pass "4. three seats: still one watchdog, no poll loop" ||
  fail "4. seats rc=$rc out=$out calls=$(cat "$CALLS" 2>&1)"

stop_loop || true
out="$(WD_RUN="$T/bin/missing" run_act do_spl_wd_ensure)"; rc=$?
[[ $rc -eq 1 && "$out" == *"missing or not executable"* && "$(wc -l < "$CALLS")" -eq 3 ]] &&
  pass "5. a missing runner is refused and starts nothing" ||
  fail "5. missing rc=$rc out=$out calls=$(wc -l < "$CALLS")"

# --- 6-8. the cron ------------------------------------------------------------
SH="$T/shared"
mkdir -p "$SH/csi-spl-orc/src/bash/scripts"
git init -q "$SH"
printf '#!/bin/sh\n' > "$SH/csi-spl-orc/src/bash/scripts/keep.sh"
printf '#!/bin/sh\n' > "$SH/csi-spl-orc/run"
chmod +x "$SH/csi-spl-orc/src/bash/scripts/keep.sh" "$SH/csi-spl-orc/run"
cat > "$T/crontab.before" << EOF
# keep me
* * * * * $SH/csi-spl-orc/src/bash/scripts/keep.sh >> $T/log/keep.out 2>&1 # csi-spl:keep
EOF
cp "$T/crontab.before" "$T/crontab"
export FAKE_CRONTAB="$T/crontab" DESK_CRON_SRC="$SH" WD_CRON_LOG_DIR="$T/log/wd" SPL_ORG_APP=csi-spl
unset DRY_RUN WD_CRON_ACTION CRON_REMOVE
want="* * * * * PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin $SH/csi-spl-orc/run -a do_spl_wd_ensure >> $T/log/wd/ensure.out 2>&1 # csi-spl:wd-ensure"

out="$(run_act do_spl_wd_ensure_install_cron)"; rc=$?
grep -F -q "+$want" <<<"$out" && has_want=1 || has_want=0
[[ $rc -eq 0 && "$out" == *"DRY_RUN nothing was touched"* && "$has_want" == 1 && "$out" == *"OK 8.1 1 command line(s), 0 failing"* ]] &&
  cmp -s "$T/crontab" "$T/crontab.before" &&
  pass "6. dry run: the every-minute line and 8.1, nothing written" ||
  fail "6. dry rc=$rc has_want=$has_want out=$out"

out="$(WD_CRON_ACTION=check run_act do_spl_wd_ensure_install_cron)"; rc=$?
[[ $rc -eq 1 && "$out" == *"NOT installed"* ]] &&
  pass "6. check before install: FAIL, exit 1" ||
  fail "6. check none rc=$rc out=$out"

out="$(DRY_RUN=0 run_act do_spl_wd_ensure_install_cron)"; rc=$?
[[ $rc -eq 0 && "$(grep -c 'csi-spl:wd-ensure$' "$T/crontab")" -eq 1 && "$(grep -F -x -c "$want" "$T/crontab")" -eq 1 && -d "$T/log/wd" ]] &&
  [[ "$(head -2 "$T/crontab")" == "$(cat "$T/crontab.before")" ]] &&
  pass "6. install: ONE every-minute line, tagged csi-spl:wd-ensure, other lines kept" ||
  fail "6. install rc=$rc out=$out crontab=$(cat "$T/crontab")"

cp "$T/crontab" "$T/crontab.1"
DRY_RUN=0 run_act do_spl_wd_ensure_install_cron >/dev/null
cmp -s "$T/crontab" "$T/crontab.1" &&
  pass "6. a re-install changes no byte" ||
  fail "6. reinstall: $(diff "$T/crontab.1" "$T/crontab" || true)"

out="$(WD_CRON_ACTION=check run_act do_spl_wd_ensure_install_cron)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK wd-ensure is installed"* ]] &&
  pass "6. check after install: OK" ||
  fail "6. check rc=$rc out=$out"

out="$(DRY_RUN=0 CRON_REMOVE=1 run_act do_spl_wd_ensure_install_cron)"; rc=$?
cmp -s "$T/crontab" "$T/crontab.before" && [[ $rc -eq 0 ]] &&
  pass "6. CRON_REMOVE=1 takes only its own line" ||
  fail "6. remove rc=$rc crontab=$(cat "$T/crontab")"

want_obs="* * * * * PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin WD_ENSURE_WATCH_DRY=1 $SH/csi-spl-orc/run -a do_spl_wd_ensure >> $T/log/wd/ensure.out 2>&1 # csi-spl:wd-ensure"
out="$(WD_ENSURE_WATCH_DRY=1 run_act do_spl_wd_ensure_install_cron)"; rc=$?
grep -F -q "+$want_obs" <<<"$out" && has_obs=1 || has_obs=0
[[ $rc -eq 0 && "$has_obs" == 1 ]] && cmp -s "$T/crontab" "$T/crontab.before" &&
  pass "6. observe-only: the cron line carries WD_ENSURE_WATCH_DRY=1" ||
  fail "6. observe rc=$rc has_obs=$has_obs out=$out"

out="$(WD_ENSURE_WATCH_DRY=2 run_act do_spl_wd_ensure_install_cron)"; rc=$?
[[ $rc -eq 1 && "$out" == *"WD_ENSURE_WATCH_DRY must be 0 or 1"* ]] &&
  cmp -s "$T/crontab" "$T/crontab.before" &&
  pass "6. WD_ENSURE_WATCH_DRY=2 is refused" ||
  fail "6. bad-dry rc=$rc out=$out"

# 8.1 before / after, and the failing control
c81() { ( do_log() { :; }; source "$PROJ_ROOT/src/bash/run/spl-peer-crons.func.sh"; SPL_ORG_APP=csi-spl; spl_peer_cron_8_1 "$1" ); }
c81 "$T/crontab.before" > "$T/o81b"; rb=$?
c81 "$T/crontab.1" > "$T/o81a"; ra=$?
[[ $rb -eq 0 && $ra -eq 0 ]] && grep -qx 'OK 8.1 1 command line(s), 0 failing' "$T/o81b" && grep -qx 'OK 8.1 2 command line(s), 0 failing' "$T/o81a" &&
  pass "7. acceptance 8.1: before n=1 and after n=2, 0 failing" ||
  fail "7. 8.1 before rc=$rb $(cat "$T/o81b") / after rc=$ra $(cat "$T/o81a")"

mkdir -p "$T/adhoc"
printf '#!/bin/sh\n' > "$T/adhoc/loop.sh"
chmod +x "$T/adhoc/loop.sh"
{ cat "$T/crontab.1"; echo "*/5 * * * * $T/adhoc/loop.sh >> /dev/null 2>&1"; echo "0 1 * * * tmux new -d"; } > "$T/crontab.bad"
c81 "$T/crontab.bad" > "$T/o"; rc=$?
[[ $rc -eq 1 ]] && grep -q "^FAIL 8.1 line 4: $T/adhoc/loop.sh is in no csi-spl checkout" "$T/o" &&
  grep -q '^FAIL 8.1 line 5: no script path' "$T/o" &&
  grep -qx 'FAIL 8.1 4 command line(s), 2 failing' "$T/o" &&
  pass "7. control: a script outside any checkout, and a line with no script, each named" ||
  fail "7. control rc=$rc: $(cat "$T/o")"

{ cat "$T/crontab.before"
  echo "*/5 * * * * $T/adhoc/loop.sh >> /dev/null 2>&1"
  echo "0 1 * * * tmux new -d"
  echo "* * * * * /var/tmp/no-such-checkout/box-update.lock >> /dev/null 2>&1 # csi-spl:box-update"
} > "$T/crontab.foreign"
cp "$T/crontab.foreign" "$T/crontab"
out="$(DRY_RUN=0 run_act do_spl_wd_ensure_install_cron)"; rc=$?
[[ $rc -eq 0 && "$(grep -F -x -c "$want" "$T/crontab")" -eq 1   && "$(grep -c 'csi-spl:box-update$' "$T/crontab")" -eq 1   && "$(grep -c 'tmux new -d' "$T/crontab")" -eq 1   && "$(grep -F -c "$T/adhoc/loop.sh" "$T/crontab")" -eq 1 ]] &&
  pass "8. foreign lines stay, and they do not block the install" ||
  fail "8. foreign rc=$rc out=$out crontab=$(cat "$T/crontab")"

OUT="$T/outside"
mkdir -p "$OUT/csi-spl-orc"
printf '#!/bin/sh\n' > "$OUT/csi-spl-orc/run"
chmod +x "$OUT/csi-spl-orc/run"
cp "$T/crontab.before" "$T/crontab"
out="$(DESK_CRON_SRC="$OUT" DRY_RUN=0 run_act do_spl_wd_ensure_install_cron)"; rc=$?
cmp -s "$T/crontab" "$T/crontab.before" && [[ $rc -eq 1 && "$out" == *"fails spec 068 8.1"* ]] &&
  pass "8. a wd-ensure line outside any checkout is not written" ||
  fail "8. own-bad rc=$rc out=$out"

cp "$T/crontab.before" "$T/crontab"
WT="$T/csi-spl-wt/g-999"
mkdir -p "$WT/csi-spl-orc"
printf '#!/bin/sh\n' > "$WT/csi-spl-orc/run"
chmod +x "$WT/csi-spl-orc/run"
out="$(DESK_CRON_SRC="$WT" DRY_RUN=0 run_act do_spl_wd_ensure_install_cron)"; rc=$?
[[ $rc -eq 1 && "$out" == *"agent worktree"* ]] && cmp -s "$T/crontab" "$T/crontab.before" &&
  pass "8. a worktree source is refused, nothing written" ||
  fail "8. worktree rc=$rc out=$out"

echo "=== fails=$fails"
[[ "$fails" -eq 0 ]]
