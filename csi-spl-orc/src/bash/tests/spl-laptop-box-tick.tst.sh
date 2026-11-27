#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the laptop box's working day (SPL-6680, spec 037 "Laptop box"):
#          do_spl_laptop_box_tick, her controls (laptop-box-ctl.sh) and her
#          pop-up (laptop-box-ask.sh). A mktemp spool root; the clock, the
#          lane list, the box join, the lane handover and notify-send are stubs.
#   1. in her hours: takes lanes; a box.leave marker is cleared by the join
#   2. in her hours at the cap (4 lanes): box.leave written, no join
#   3. after her hours, 0 lanes: box.leave, idle, no question
#   4. after her hours, 2 lanes: the question (ask-pending names them,
#      asked-at), no move; the next tick within 15 min waits
#   5. the pop-up: Continue -> answer file; the tick: continue-until +1 h,
#      no move; still within the hour: waits; Stop -> the lanes move at once
#   6. 15 min unanswered -> every lane handed over to the move box, one
#      moves.log line each, the question cleared
#   7. a failed handover: exit 1, FAILED line, move-now kept for a retry
#   8. her controls: stop (today out of hours, move-now), off/start, continue,
#      status; remove: refused without root, refused with lanes, else the
#      plan (timers off, units gone, the agents' user deleted)
#   9. a closed pop-up writes no answer
#  10. not a laptop box (no laptop-box.env) -> exit 3
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
export IN_ORC_RUN="spl-laptop-box-tick"
FB="$PROJ_ROOT/src/bash/features/laptop-box"
SR="$T/spool"; D="$SR/dispatch/laptop-box"; mkdir -p "$D"
printf '%s\n' "LAPTOP_HOURS=Mon-Fri 09:00-17:00" LAPTOP_AGENT_MAX=4 LAPTOP_BOX_TAG=lap-a LAPTOP_AGENT_USER=agt-u LAPTOP_MOVE_BOX=home LAPTOP_MEMBER=mem >"$SR/dispatch/laptop-box.env"
mkdir -p "$T/stub"
printf '#!/usr/bin/env bash\ncat "%s/lanes.in" 2>/dev/null\n' "$T" >"$T/stub/lanes"
printf '#!/usr/bin/env bash\necho join >>"%s/join.log"; rm -f "%s/dispatch/box.leave"\n' "$T" "$SR" >"$T/stub/join"
printf '#!/usr/bin/env bash\necho "handover $FROM $TO_BOX $DRY_RUN" >>"%s/handover.log"; [ ! -e "%s/handover.fail" ]\n' "$T" "$T" >"$T/stub/handover"
chmod +x "$T/stub/"*
FRI10=$(date -d '2026-11-27 10:00' +%s); FRI18=$(date -d '2026-11-27 18:00' +%s)
tick() {  # <epoch>
  SNIPPET=do_spl_laptop_box_tick in_orc SPOOL_ROOT="$SR" LAPTOP_NOW="$1" LAPTOP_LANES_CMD="$T/stub/lanes" \
    LAPTOP_JOIN_CMD="$T/stub/join" LAPTOP_HANDOVER_CMD="$T/stub/handover" >"$T/o" 2>&1
}
ctl() { SPOOL_ROOT="$SR" LAPTOP_NOW="${NOW:-$FRI18}" bash "$FB/laptop-box-ctl.sh" "$@"; }
reset() { rm -f "$D"/* "$SR/dispatch/box.leave" "$T"/*.log "$T/lanes.in" "$T/handover.fail"; }
lanes() { printf '%s\n' "$@" >"$T/lanes.in"; }

# 1
reset; lanes c-101; echo x >"$SR/dispatch/box.leave"; tick "$FRI10"; rc=$?
[[ $rc -eq 0 && ! -e "$SR/dispatch/box.leave" && -s "$T/join.log" ]] && grep -q "TICK in-hours lanes=1 cap=4: takes lanes" "$T/o" \
  && pass "1 in hours: takes lanes, leave marker cleared" || { fail "1 in hours rc=$rc"; cat "$T/o"; }
# 2
reset; lanes c-101 c-102 c-103 c-104; tick "$FRI10"
[[ -e "$SR/dispatch/box.leave" && ! -e "$T/join.log" ]] && grep -q "full, no new lanes" "$T/o" && pass "2 at the cap: no new lanes" || { fail "2 cap"; cat "$T/o"; }
# 3
reset; tick "$FRI18"
[[ -e "$SR/dispatch/box.leave" && ! -e "$D/ask-pending" ]] && grep -q "TICK out lanes=0: idle" "$T/o" && pass "3 after hours, idle: no question" || { fail "3 idle"; cat "$T/o"; }
# 4
reset; lanes c-101 c-102; tick "$FRI18"
if grep -q "asked her" "$T/o" && grep -q "c-102" "$D/ask-pending" && [[ "$(cat "$D/asked-at")" == "$FRI18" && ! -e "$T/handover.log" ]]; then
  tick $((FRI18 + 600)); grep -q "waiting for her answer" "$T/o" && [[ ! -e "$T/handover.log" ]] && pass "4 the question, then waits" || fail "4 waits: $(cat "$T/o")"
else fail "4 the question: $(cat "$T/o")"; fi
# 5
printf '#!/usr/bin/env bash\necho "$NOTIFY_PICK"\n' >"$T/stub/notify"; chmod +x "$T/stub/notify"
NOTIFY_PICK=continue SPOOL_ROOT="$SR" LAPTOP_NOTIFY="$T/stub/notify" LAPTOP_NOW=$((FRI18 + 60)) bash "$FB/laptop-box-ask.sh"
tick $((FRI18 + 120)); a=$?
tick $((FRI18 + 1800)); b="$(cat "$T/o")"
if [[ $a -eq 0 && ! -e "$T/handover.log" && "$(cat "$D/continue-until")" == $((FRI18 + 120 + 3600)) ]] && grep -q "she continues until" <<<"$b"; then
  echo x >"$D/ask-pending"; NOTIFY_PICK=stop SPOOL_ROOT="$SR" LAPTOP_NOTIFY="$T/stub/notify" bash "$FB/laptop-box-ask.sh"
  tick $((FRI18 + 1900))
  [[ "$(grep -c '^handover .* home 0$' "$T/handover.log")" == 2 ]] && pass "5 Continue keeps 1 h, Stop moves at once" || fail "5 stop: $(cat "$T/o")"
else fail "5 continue: a=$a $b"; fi
# 6
reset; lanes c-101 c-102; tick "$FRI18"; tick $((FRI18 + 900))
if [[ "$(grep -c '^handover' "$T/handover.log")" == 2 ]] && [[ "$(grep -c ' moved c-10[12] -> home' "$D/moves.log")" == 2 ]] \
  && [[ ! -e "$D/ask-pending" && ! -e "$D/asked-at" ]] && grep -q "lanes moved to home" "$T/o"; then pass "6 15 min unanswered: both lanes moved"
else fail "6 move"; cat "$T/o" "$D/moves.log"; fi
# 7
reset; lanes c-101; touch "$T/handover.fail"; ctl stop >/dev/null; tick "$FRI18"; rc=$?
[[ $rc -eq 1 && -e "$D/move-now" ]] && grep -q "FAILED c-101 -> home" "$D/moves.log" && pass "7 failed handover: retried next tick" || { fail "7 rc=$rc"; cat "$T/o"; }
# 8
reset; NOW=$FRI10 ctl stop >/dev/null; lanes c-101; tick "$FRI10"
grep -q "lanes moved to home" "$T/o" && [[ -e "$SR/dispatch/box.leave" ]] && pass "8 stop: out of hours today, lanes move" || { fail "8 stop"; cat "$T/o"; }
reset; ctl off >/dev/null; tick "$FRI10"; o1="$(cat "$T/o")"; ctl start >/dev/null; lanes c-101; tick "$FRI10"
grep -q "TICK out" <<<"$o1" && grep -q "takes lanes" "$T/o" && pass "8 off, then start" || fail "8 off/start: $o1 / $(cat "$T/o")"
reset; NOW=$FRI18 ctl continue >/dev/null; lanes c-101; tick $((FRI18 + 60))
grep -q "she continues" "$T/o" && pass "8 continue from the command line" || fail "8 continue: $(cat "$T/o")"
s="$(ctl status)"; grep -q "hours:  Mon-Fri 09:00-17:00" <<<"$s" && grep -q "agents: 1 running" <<<"$s" && pass "8 status" || fail "8 status: $s"
LAPTOP_EUID=1000 ctl remove >/dev/null 2>&1; r1=$?
LAPTOP_EUID=0 ctl remove >/dev/null 2>&1; r2=$?
: >"$D/lanes"; LAPTOP_EUID=0 LAPTOP_ROOT_SH=echo ctl remove >"$T/rm.out" 2>&1; r3=$?
[[ $r1 -eq 3 && $r2 -eq 3 && $r3 -eq 0 ]] && grep -q "userdel -r 'agt-u'" "$T/rm.out" && grep -q "systemctl disable --now spl-laptop-box-tick.timer" "$T/rm.out" \
  && pass "8 remove: needs root, refused with lanes, else the plan" || { fail "8 remove r=$r1/$r2/$r3"; cat "$T/rm.out"; }
ctl bogus >/dev/null 2>&1; [[ $? -eq 2 ]] && pass "8 unknown control: exit 2" || fail "8 unknown control"
# 9
reset; echo q >"$D/ask-pending"; NOTIFY_PICK="" SPOOL_ROOT="$SR" LAPTOP_NOTIFY="$T/stub/notify" bash "$FB/laptop-box-ask.sh"
[[ ! -e "$D/answer" ]] && pass "9 a closed pop-up writes no answer" || fail "9 closed pop-up"
# 10
mv "$SR/dispatch/laptop-box.env" "$T/env.bak"; tick "$FRI10"; rc=$?; mv "$T/env.bak" "$SR/dispatch/laptop-box.env"
[[ $rc -eq 3 ]] && pass "10 not a laptop box: exit 3" || fail "10 rc=$rc"

echo "=== spl-laptop-box-tick: $fails failure(s) ==="
(( fails == 0 ))
