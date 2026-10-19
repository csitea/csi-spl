#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-2562, do_spl_role_failover_drill: a live drill of the role
#          vendor failover (SPL-2544). A sandbox: a fake /proc
#          (LEASE_PROC_ROOT), tmux, kill and ./run are stubs, nothing real is
#          killed. do_spl_role_failover is a stub that first runs a stub
#          watchdog tick: the REAL spl_wd_gate decides whether it restarts the
#          ended seat (as S3 would), then the stub switches the seat only when
#          no process carries it (the real step 2: "can act again").
#   1. dry run: the plan, nothing stopped, no hold
#   2. refused inside an hourly rotation (rotate.orch.lock held)
#   3. refused for a seat that is not lease.conf's holder; and for a holder
#      with no live process
#   4. the order: hold, stop (TERM of the seat's own pid), failover; the
#      switch printed with the new holder; the hold released
#   5. the hold is released on failure (the failover exits mid-run)
#      and a hold that stood before is put back as it was
#   6. nothing switched: the hold released, then the seat restarted by
#      do_spl_agent_restart CAUSE=S3
#   7. RED CONTROL: the same run without the hold: the stub watchdog restarts
#      the seat before the failover runs, the failover skips, and the test
#      sees it
#   8. dispatch: LEASE_MASTER's seat is drilled
#   9. the caller IS the seat: a stub caller in its own process group whose
#      pid is the seat pid runs the drill (not detached yet); the stop kills
#      that whole group (the pane closing), and the detached drill still runs
#      the failover and writes its log. RED CONTROL: the same run with no
#      detach dies with the caller before the failover
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
case "$(readlink -f "$T")" in /var/spool-hub|/var/spool-hub/*) echo "FAIL: refusing to run inside the live spool root ($T)"; exit 1 ;; esac
S="$T/spool"; D="$S/dispatch"
mkdir -p "$T/bin" "$T/proc" "$T/tmux" "$D"
TCK="$(getconf CLK_TCK)"; UP=100000
echo "$UP.00 0.00" >"$T/proc/uptime"
printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\n' "$(id -un)" "$(id -un)" >"$S/box.env"
CONF=$'LEASE_MASTER=c-002\nLEASE_FAILOVER=c-003\nLEASE_ORCH=c-001\nLEASE_FLEET=main\nLEASE_ENV=prd\nLEASE_TENANT=t1'

# proc <pid> <id> [comm]: a fake agent process carrying SPOOL_AGENT_ID=<id>
cat >"$T/bin/proc" <<'EOF'
#!/usr/bin/env bash
d="$T/proc/$1"; mkdir -p "$d"; echo "${3:-claude}" >"$d/comm"
printf 'SPOOL_AGENT_ID=%s\0' "$2" >"$d/environ"
echo "$1 (${3:-claude}) S 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 $(( (UP - 7200) * TCK ))" >"$d/stat"
printf 'Uid:\t%s\t%s\n' "$(id -u)" "$(id -u)" >"$d/status"
EOF
cat >"$T/bin/tmux" <<'EOF'
#!/usr/bin/env bash
P="$T/tmux/panes"; cmd="$1"; shift; tgt=""
while [ $# -gt 0 ]; do case "$1" in -t) tgt="$2"; shift 2 ;; -F) shift 2 ;; *) shift ;; esac; done
echo "$cmd $tgt" >>"$T/tmux/log"
case "$cmd" in
  list-panes) awk -F'\t' '{print $2" "$1}' "$P" 2>/dev/null ;;
  capture-pane) printf '────\n❯ \n────\n' ;;
  *) : ;;
esac
EOF
# kill: logged with whether a watchdog hold stood at that moment
cat >"$T/bin/kill" <<'EOF'
#!/usr/bin/env bash
echo "kill $*" >>"$T/kill.log"
h=n; ls "$T/wd/"*.heldout >/dev/null 2>&1 && h=y
echo "stop $2 held=$h" >>"$T/order.log"
rm -rf "${T:?}/proc/$2"
# the stub caller of case 9: its whole process group goes, as a closed pane's
c="$(cat "$T/caller.pid" 2>/dev/null)"
[ -n "$c" ] && [ "$2" = "$c" ] && command kill -HUP -- "-$c" 2>/dev/null
exit 0
EOF
# ./run: do_spl_agent_restart records its env and whether a hold still stood,
# then starts the seat again (pid 301)
cat >"$T/bin/run" <<'EOF'
#!/usr/bin/env bash
echo "run $* ID=${ID:-} CAUSE=${CAUSE:-} DRY_RUN=${DRY_RUN:-}" >>"$T/run.log"
[ "$2" = do_spl_role_failover_drill ] && exec "$T/bin/act"
[ "$2" = do_spl_agent_restart ] || exit 0
echo "restart $ID held=$([ -e "$T/wd/$ID.heldout" ] && echo y || echo n)" >>"$T/order.log"
"$T/bin/proc" 301 "$ID"
EOF
# the action under ./run's set -E + ERR trap; the failover and the watchdog
# tick are stubs (see the header)
cat >"$T/bin/act" <<'EOF'
#!/usr/bin/env bash
set -E
trap 'echo "ERRTRAP: $BASH_COMMAND (line $LINENO)"; exit 99' ERR
sleep() { :; }
do_log() { echo "$*"; }
do_require_bin() { return 0; }
source "$PROJ_PATH/src/bash/run/spl-role-failover-drill.func.sh"
source "$PROJ_PATH/src/bash/run/spl-watchdog.func.sh"
# a watchdog tick on the role seat: S3 restarts a dead seat unless its gate holds
wd_tick() {
  local id="$1" why
  [[ -n "$(spl_lease_agent_pid "$id")" ]] && return 0
  mkdir -p "$T/ctx"
  why="$(WD_DIR="$WD_STATE_DIR" DRY_RUN=0 WD_BOX_BUSY="" spl_wd_gate "$id" "$(date +%s)" "$T/ctx")"
  if [[ -n "$why" ]]; then echo "watchdog $id held: $why" >>"$T/order.log"; return 0; fi
  echo "watchdog restart $id" >>"$T/order.log"; "$T/bin/proc" 201 "$id"
}
do_spl_role_failover() {
  local key=LEASE_ORCH rid new
  [[ "$ROLE_FAILOVER_ROLE" == dispatch ]] && key=LEASE_MASTER
  wd_tick "$ROLE_FAILOVER_SEAT"
  echo "failover $ROLE_FAILOVER_ROLE seat=$ROLE_FAILOVER_SEAT DRY_RUN=$DRY_RUN" >>"$T/order.log"
  rid="$(date -u +%Y%m%dT%H%MZ)-failover-$ROLE_FAILOVER_ROLE"
  if [[ "${FAIL_DIE:-0}" == 1 ]]; then echo "the failover dies"; exit 99; fi
  if [[ -n "$(spl_lease_agent_pid "$ROLE_FAILOVER_SEAT")" ]]; then
    echo "$(date -u +%FT%TZ) $rid SWITCH SKIP $ROLE_FAILOVER_SEAT can act again: nothing to switch" >>"$ROTATE_LOG"; return 0
  fi
  if [[ "${NO_SWITCH:-0}" == 1 ]]; then
    echo "$(date -u +%FT%TZ) $rid SWITCH SKIP no vendor is left" >>"$ROTATE_LOG"; return 0
  fi
  new="g-${ROLE_FAILOVER_SEAT#*-}"
  sed -i "s/^$key=.*/$key=$new/" "$LEASE_CONF"
  "$T/bin/proc" 3001 "$new" grok
  echo "$(date -u +%FT%TZ) $rid SWITCH OK $new (grok, pid 3001) runs the $ROLE_FAILOVER_ROLE seat; lease.conf $key=$new" >>"$ROTATE_LOG"
}
# the red control's run: the same drill with no hold written
if [[ "${ACT_NO_HOLD:-0}" == 1 ]]; then spl_rfd_hold() { RFD_HELD=""; }; fi
# the red control of case 9: the drill goes on in the caller's process group
if [[ "${ACT_NO_DETACH:-0}" == 1 ]]; then spl_rfd_detach() { return 1; }; fi
do_spl_role_failover_drill || exit $?
EOF
chmod +x "$T/bin/"*

export T UP TCK PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPL_STATE_DIR="$T/state" SPOOL_BOX_ENV="$S/box.env" SPOOL_TEST=1 SPOOL_DESK_BOX=box-desk \
  LEASE_PROC_ROOT="$T/proc" WD_STATE_DIR="$T/wd" \
  ROTATE_TMUX="$T/bin/tmux" ROTATE_KILL="$T/bin/kill" ROTATE_RUN="$T/bin/run" ROTATE_SEND=/bin/true \
  ROTATE_POLL=1 ROTATE_TERM_WAIT=1 ROLE_FAILOVER_EXIT_WAIT=1 RFD_DETACHED=1

world() {
  rm -rf "${T:?}/proc/"[0-9]* "${T:?}/tmux/"* "${T:?}/"*.log "${T:?}/wd" "${T:?}/ctx" "${T:?}/caller.pid" "${D:?}"/* "${S:?}"/[acgmq]-0*
  echo "$CONF" >"$D/lease.conf"
  local id
  for id in c-001 c-002 c-003; do mkdir -p "$S/$id/inbox" "$S/$id/outbox" "$S/$id/lifetime"; done
  "$T/bin/proc" 101 c-001; "$T/bin/proc" 102 c-002; "$T/bin/proc" 103 c-003
  printf '%%101\t101\n%%102\t102\n%%103\t103\n' >"$T/tmux/panes"
}
act() { env "$@" "$T/bin/act"; }
key() { sed -n "s/^$1=//p" "$D/lease.conf"; }
order() { tr '\n' '|' <"$T/order.log" 2>/dev/null; }

# --- 1. dry run --------------------------------------------------------------------------
world
act ROLE_FAILOVER_ROLE=orch >"$T/o" 2>&1; rc=$?
[[ $rc == 0 && ! -e "$T/kill.log" && ! -e "$T/order.log" && ! -e "$T/wd/c-001.heldout" && -d "$T/proc/101" && ! -s "$D/rotate.log" ]] &&
  grep -q 'DRILL PLAN orch holder c-001 (pid 101, pane %101): hold .*c-001.heldout' "$T/o" &&
  pass "1. dry run: the plan printed, nothing stopped, no hold, nothing in rotate.log" || fail "1. rc=$rc $(cat "$T/o") $(order)"

# --- 2. inside an hourly rotation ------------------------------------------------------------
world
( flock -n 9 && act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 >"$T/o" 2>&1; echo $? >"$T/rc" ) 9>>"$D/rotate.orch.lock"
[[ "$(cat "$T/rc")" != 0 && ! -e "$T/kill.log" && -d "$T/proc/101" && ! -e "$T/wd/c-001.heldout" ]] &&
  grep -q 'DRILL REFUSED an hourly rotation holds rotate.orch.lock' "$T/o" &&
  pass "2. refused inside an hourly rotation: nothing held or stopped" || fail "2. $(cat "$T/rc") $(cat "$T/o")"

# --- 3. not the holder; no live process ------------------------------------------------------
world
act ROLE_FAILOVER_ROLE=orch ROLE_FAILOVER_SEAT=c-003 DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc != 0 && ! -e "$T/kill.log" && -d "$T/proc/103" && ! -e "$T/order.log" ]] &&
  grep -q 'DRILL REFUSED c-003 is not the orch holder: lease.conf has LEASE_ORCH=c-001' "$T/o" &&
  pass "3. a seat that is not lease.conf's holder is refused, nothing stopped" || fail "3. rc=$rc $(cat "$T/o")"
world; rm -rf "${T:?}/proc/101"
act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc != 0 && ! -e "$T/order.log" && ! -e "$T/wd/c-001.heldout" ]] && grep -q 'DRILL REFUSED c-001 has no live process on this box' "$T/o" &&
  pass "3. a holder with no live process is refused (nothing to drill)" || fail "3b. rc=$rc $(cat "$T/o")"

# --- 4. the order: hold, stop, failover, switched ------------------------------------------------
world
act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc == 0 && "$(order)" == "stop 101 held=y|watchdog c-001 held: held out after "*" takeovers in an hour|failover orch seat=c-001 DRY_RUN=0|" ]] &&
  pass "4. the order: the seat's own pid 101 stopped under the hold, the watchdog held off, then the failover with ROLE_FAILOVER_SEAT=c-001" || fail "4. rc=$rc order=$(order) $(cat "$T/o")"
grep -q '^kill -TERM 101$' "$T/kill.log" && [[ "$(wc -l <"$T/kill.log")" == 1 && -d "$T/proc/102" && -d "$T/proc/103" ]] &&
  pass "4. only the seat's own pid got a signal (TERM 101), the other seats untouched" || fail "4. kill: $(cat "$T/kill.log")"
[[ "$(key LEASE_ORCH)" == g-001 && ! -e "$T/wd/c-001.heldout" ]] && grep -q -- '-failover-orch SWITCH OK g-001' "$T/o" &&
  grep -q 'DRILL RESULT OK PROVED: lease.conf LEASE_ORCH=g-001 (was c-001); .*g-001 has live pid 3001; the old c-001 pid 101 gone: yes' "$T/o" &&
  grep -q 'DRILL RESULT NOTE NOT PROVED: that g-001 works the orch role' "$T/o" && grep -q -- '-drill-orch DRILL STOP OK pid 101' "$D/rotate.log" &&
  ! grep -q 'do_spl_agent_restart' "$T/run.log" 2>/dev/null &&
  pass "4. the failover's lines and the new holder printed, the hold released, no restore" || fail "4. result: $(cat "$T/o") $(ls "$T/wd" 2>&1)"
[[ ! -e "$D/rotate.orch.state" ]] && pass "4. the drill writes no rotate.orch.state (it is no rotation)" || fail "4. state: $(cat "$D/rotate.orch.state")"

# --- 5. the hold is released on failure; a prior hold put back ------------------------------------
world
act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 FAIL_DIE=1 >"$T/o" 2>&1; rc=$?
[[ $rc == 99 && ! -e "$T/wd/c-001.heldout" ]] && grep -q '^the failover dies' "$T/o" && grep -q 'DRILL HOLD OK .*c-001.heldout released' "$T/o" &&
  pass "5. the failover exits mid-run: the hold is released all the same (EXIT trap)" || fail "5. rc=$rc held=$(ls "$T/wd" 2>&1) $(cat "$T/o")"
world; mkdir -p "$T/wd"; echo 1234567 >"$T/wd/c-001.heldout"
act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc == 0 && "$(cat "$T/wd/c-001.heldout")" == 1234567 && "$(order)" == "stop 101 held=y|"* ]] &&
  pass "5. a hold that stood before the drill is put back as it was" || fail "5b. rc=$rc $(cat "$T/wd/c-001.heldout" 2>&1) $(order)"

# --- 6. nothing switched: release, then restore ------------------------------------------------------
world
act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 NO_SWITCH=1 >"$T/o" 2>&1; rc=$?
[[ $rc != 0 && "$(key LEASE_ORCH)" == c-001 && "$(order)" == *"|failover orch seat=c-001 DRY_RUN=0|restart c-001 held=n|" && -d "$T/proc/301" ]] &&
  grep -q '^run -a do_spl_agent_restart ID=c-001 CAUSE=S3 DRY_RUN=0$' "$T/run.log" && grep -q 'DRILL RESULT FAIL lease.conf LEASE_ORCH=c-001: nothing switched' "$T/o" &&
  pass "6. nothing switched: the hold released first, then c-001 restarted (do_spl_agent_restart CAUSE=S3), the drill reports FAIL" ||
  fail "6. rc=$rc order=$(order) $(cat "$T/run.log" 2>&1) $(cat "$T/o")"

# --- 7. RED CONTROL: no hold -> the watchdog wins the race -------------------------------------------
world
act ROLE_FAILOVER_ROLE=orch DRY_RUN=0 ACT_NO_HOLD=1 >"$T/o" 2>&1; rc=$?
[[ "$(order)" == "stop 101 held=n|watchdog restart c-001|failover orch seat=c-001 DRY_RUN=0|" && "$(key LEASE_ORCH)" == c-001 && -d "$T/proc/201" ]] &&
  grep -q 'SWITCH SKIP c-001 can act again: nothing to switch' "$T/o" && grep -q 'DRILL RESULT FAIL .*c-001 runs again' "$T/o" &&
  pass "7. RED CONTROL: without the hold the watchdog restarts c-001 first, the failover skips, and the drill sees it" ||
  fail "7. control: rc=$rc order=$(order) $(cat "$T/o")"

# --- 8. dispatch ----------------------------------------------------------------------------------
world
act ROLE_FAILOVER_ROLE=dispatch DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc == 0 && "$(key LEASE_MASTER)" == g-002 && "$(key LEASE_ORCH)" == c-001 && -d "$T/proc/101" && ! -d "$T/proc/102" ]] &&
  grep -q '^kill -TERM 102$' "$T/kill.log" && grep -q 'failover dispatch seat=c-002' "$T/order.log" &&
  pass "8. dispatch: LEASE_MASTER's seat c-002 drilled, the orch seat untouched" || fail "8. rc=$rc $(cat "$T/o")"

# --- 9. the caller is the seat ---------------------------------------------------------------------
# caller <log> [env...]: a process group of its own (setsid) whose pid carries
# c-001 in the fake /proc, the pane's pid; it runs the drill, then lives on as
# a session would, until the stop kills its group
cat >"$T/bin/caller" <<'EOF'
#!/usr/bin/env bash
echo $$ >"$T/caller.pid"
rm -rf "${T:?}/proc/101"; "$T/bin/proc" $$ c-001
printf '%%%s\t%s\n' $$ $$ >>"$T/tmux/panes"
log="$1"; shift
env RFD_DETACHED=0 "$@" "$T/bin/act" >"$log" 2>&1
echo "caller after act" >>"$log"
command sleep 30
EOF
chmod +x "$T/bin/caller"
waitfor() { local _; for _ in $(seq 1 100); do grep -qh "$1" "$D/role-failover/"*.drill.log 2>/dev/null && return 0; command sleep 0.1; done; return 1; }
world
setsid "$T/bin/caller" "$T/o" ROLE_FAILOVER_ROLE=orch DRY_RUN=0 & cpid=$!
waitfor 'DRILL RESULT NOTE'; DL="$(ls "$D/role-failover/"*.drill.log 2>/dev/null | sed -n 1p)"
{ wait "$cpid"; } 2>/dev/null
cp="$(cat "$T/caller.pid")"
[[ -n "$DL" && "$(key LEASE_ORCH)" == g-001 ]] && grep -q "DRILL DETACH OK the drill of c-001 runs detached" "$T/o" &&
  grep -q "^stop $cp held=y" "$T/order.log" && grep -q 'failover orch seat=c-001 DRY_RUN=0' "$T/order.log" &&
  grep -q 'DRILL RESULT OK PROVED: lease.conf LEASE_ORCH=g-001' "$DL" && grep -q 'DRILL RESULT NOTE NOT PROVED: that g-001 works the orch role' "$DL" &&
  ! kill -0 "$cp" 2>/dev/null &&
  pass "9. the caller IS the seat (pid $cp): its group killed by the stop, the detached drill still ran the failover (log $DL)" ||
  fail "9. conf=$(key LEASE_ORCH) order=$(order) caller: $(cat "$T/o") log: $(cat "$DL" 2>&1)"
[[ -z "$(ls "$T/wd/" 2>/dev/null)" ]] && pass "9. the detached run released its hold" || fail "9. hold: $(ls "$T/wd")"
world
setsid "$T/bin/caller" "$T/o" ROLE_FAILOVER_ROLE=orch DRY_RUN=0 ACT_NO_DETACH=1 & cpid=$!
{ wait "$cpid"; } 2>/dev/null
cp="$(cat "$T/caller.pid")"
[[ "$(key LEASE_ORCH)" == c-001 ]] && grep -q "^stop $cp held=y" "$T/order.log" && ! grep -q '^failover' "$T/order.log" && ! grep -q 'caller after act' "$T/o" &&
  pass "9. RED CONTROL: not detached, the drill dies with the caller's group before the failover" ||
  fail "9. control: conf=$(key LEASE_ORCH) order=$(order) $(cat "$T/o")"

echo "fails=$fails"
(( fails == 0 ))
