#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the box beat and the fence of spec 102 10.2 (T017), in a sandbox:
#          spl_wd_fence (the tick's one call) and spl_wd_takeover's gate.
#          The hub is a stub that answers the beat with an ack, or is silent
#          (hangs past WD_BEAT_TIMEOUT); the wip push, kill, spool-send.sh
#          and the restart are stubs that log. The clock is the NOW of each
#          tick, 30 s apart.
#   1. hub answering: 11 ticks over 5 min -> never fenced, nothing TERMed
#   2. a 1 min gap (silent ticks 90 s after the last ack) -> not fenced
#   3. hub silent for 2 min -> fenced: <wd>/fenced, every lane's wip pushed
#      and then TERMed, the seat untouched, ONE note to the orchestrator; a
#      takeover is refused and the restart is never started; the next tick
#      sends no second note and TERMs nothing again
#   4. the hub answers again -> unfenced, the takeover runs (the control of
#      the gate); WD_BEAT=0 (no hub) -> never fenced however old the ack
#   5. DRY_RUN=1 fences but pushes, TERMs and sends nothing
#   6. an m- lane is TERMed only through its vibe: a row that points at a
#      node (spl_wd_agents' fallback) gets its wip push and NO kill, logged
#      "no agent process to TERM"; a row on the vibe pid is TERMed; a c-
#      lane on a bare node (no agent CLI below it) is not TERMed either
#      (fences of 2026-10-11, m-834/m-874; sat 2026-10-15, c-973)
#   7. the TERM reaches the agent CLI: a row on a wrapper with the CLI as its
#      child TERMs the CLI (real processes, real kill); a CLI that ignores
#      TERM is logged "still alive after TERM" (PC box 2026-10-16: 7 of 8
#      TERMed agents ran on); a kill refused (EPERM: the agent runs as
#      another user) goes through the owner hop
#   8. a wip push that failed while fenced is retried once at UNFENCED, for
#      that lane only; a lane whose push succeeded is not pushed again
#   9. SPL-2257: a box back from a 7 min suspend (its tick saw the gap and
#      wrote resume) is not fenced for WD_FENCE_RESUME_GRACE (180 s) while it
#      re-beats: the hub acks within the grace -> never fenced, one "RESUME
#      detected" line; the hub still silent after the grace -> fenced as
#      today; a box that did not sleep is fenced as in 3 (no regression).
#      RED control: WD_FENCE_RESUME_GRACE=0 (the code before) fences on the
#      first tick after the wake (the PC box 2026-10-16 20:01:16Z, 11 lanes TERMed)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
RUN_DIR="$PROJ_ROOT/src/bash/run"
T0=1800000000   # 2027-01-15T08:00:00Z
mkdir -p "$T/bin"
export T

# ---- stubs -------------------------------------------------------------------
# the hub: "$T/hub" says ok (an ack) or silent (no answer before the timeout)
cat > "$T/bin/hub" <<'STUB'
#!/usr/bin/env bash
echo "beat $*" >> "$T/beats"
if [ "$(cat "$T/hub")" = ok ]; then echo '{"ok":true,"box":"box1","beat_at":"2027-01-15T08:00:00Z","box_down_min":2}'; else sleep 5; fi
STUB
printf '#!/usr/bin/env bash\necho "wip $ID" >> "$T/acts"\n' > "$T/bin/wip"
printf '#!/usr/bin/env bash\necho "kill $*" >> "$T/acts"\n' > "$T/bin/kill"
printf '#!/usr/bin/env bash\necho "send $*" >> "$T/sent"\n' > "$T/bin/send"
printf '#!/usr/bin/env bash\necho "restart $ID $CAUSE" >> "$T/restarts"\n' > "$T/bin/restart"
chmod +x "$T/bin/"*

# one seat (c-001) and two lanes, as spl_wd_agents lists them: id pid pane
mkdir -p "$T/tick"
printf 'c-001\t101\t%%1\nc-050\t150\t%%2\nc-051\t151\t%%3\n' > "$T/tick/agents"
printf '101 1 500 claude\n150 1 500 claude\n151 1 500 claude\n' > "$T/tick/ps"

# wd FN ARGS: one call in a fresh shell over the sandbox state (files only,
# as three instances share it)
wd() {
  ( set +u
    do_log() { echo "$*"; }
    # shellcheck source=../run/spl-watchdog.func.sh
    source "$RUN_DIR/spl-watchdog.func.sh"
    export SPOOL_ROOT="$T/spool" WD_DIR="$T/wd" WD_LOG="$T/wd.log" WD_SEND="$T/bin/send" WD_FROM=c-001 WD_BOX=box1
    export WD_BEAT_CMD="$T/bin/hub" WD_BEAT_TIMEOUT=1 WD_WIP_CMD="$T/bin/wip" WD_KILL_CMD="$T/bin/kill"
    export WD_FENCE_TERM_WAIT="${WD_FENCE_TERM_WAIT:-0}"
    export WD_TAKEOVER_CMD="$T/bin/restart" RESTART_MAX_PER_HOUR=3 WD_TICK_SEQ=1
    "$@" )
}
reset() { rm -rf "$T/wd" "$T/spool" "$T/acts" "$T/sent" "$T/restarts" "$T/beats" "$T/wd.log"; mkdir -p "$T/wd" "$T/spool"; }
# ticks FROM TO MODE: one fence call per 30 s from T0+FROM to T0+TO with the hub in MODE
ticks() {
  local s; echo "$3" > "$T/hub"
  for (( s = $1; s <= $2; s += 30 )); do DRY_RUN="${DRY:-0}" wd spl_wd_fence $(( T0 + s )) "$T/tick"; done
}
n() { if [[ -f "$T/$1" ]]; then grep -c -- "$2" "$T/$1"; else echo 0; fi; }

# ---- 1. the hub answering: never fenced --------------------------------------
reset
ticks 0 300 ok
[[ ! -e "$T/wd/fenced" && "$(n acts .)" == 0 && "$(n beats 'put --pid')" == 11 ]] &&
  pass "1. hub answering: 11 beats in 5 min, never fenced, nothing TERMed" ||
  fail "1. hub answering: fenced=$([[ -e "$T/wd/fenced" ]] && echo yes || echo no) acts=$(n acts .) beats=$(n beats 'put --pid')"
[[ "$(cat "$T/wd/beat.ack")" == $(( T0 + 300 )) && "$(cat "$T/wd/beat.down_min")" == 2 ]] &&
  pass "1. the ack and the hub's box_down_min are kept" || fail "1. beat.ack=$(cat "$T/wd/beat.ack") down_min=$(cat "$T/wd/beat.down_min" 2>/dev/null)"

# ---- 2. a 1 min gap: not fenced ----------------------------------------------
ticks 330 390 silent
ticks 420 420 ok
[[ ! -e "$T/wd/fenced" && "$(n acts .)" == 0 && "$(n sent .)" == 0 ]] &&
  pass "2. a 90 s gap with no ack -> not fenced" || fail "2. a gap fenced the box: $(cat "$T/acts" "$T/sent" 2>/dev/null)"
grep -q "BEAT: no ack" "$T/wd.log" && pass "2. the missed acks are logged" || fail "2. no BEAT line in wd.log"

# ---- 3. the hub silent for 2 min: fenced --------------------------------------
reset
ticks 0 0 ok
ticks 30 90 silent
[[ ! -e "$T/wd/fenced" ]] && pass "3. 90 s without an ack: not yet fenced" || fail "3. fenced before box_down_min"
ticks 120 120 silent
[[ -e "$T/wd/fenced" ]] && pass "3. 120 s without an ack: fenced" || fail "3. not fenced after box_down_min"
grep -qx "kill -TERM 150" "$T/acts" && grep -qx "kill -TERM 151" "$T/acts" &&
  pass "3. both lanes TERMed" || fail "3. lanes not TERMed: $(cat "$T/acts" 2>/dev/null)"
for l in 50 51; do
  w="$(grep -nx "wip c-0$l" "$T/acts" | cut -d: -f1)"; k="$(grep -nx "kill -TERM 1$l" "$T/acts" | cut -d: -f1)"
  [[ -n "$w" && -n "$k" ]] && (( w < k )) && pass "3. c-0$l: wip push before TERM" || fail "3. c-0$l: wip line '$w', kill line '$k'"
done
[[ "$(n acts c-001)" == 0 && "$(n acts ' 101')" == 0 ]] && pass "3. the seat is untouched" || fail "3. the seat was touched: $(cat "$T/acts")"
[[ "$(n sent 'FENCED')" == 1 ]] && grep -q -- "--to orchestrator --kind note" "$T/sent" &&
  pass "3. ONE note to the orchestrator" || fail "3. notes: $(cat "$T/sent" 2>/dev/null)"
out="$(LEASE_NOW=$(( T0 + 130 )) wd spl_wd_takeover c-050 S3 "dead")"; rc=$?
[[ "$rc" != 0 && "$out" == fenced:* && ! -s "$T/restarts" ]] &&
  pass "3. a fenced box starts nothing: takeover refused ($out)" || fail "3. takeover while fenced: rc=$rc out=$out restarts=$(cat "$T/restarts" 2>/dev/null)"
ticks 150 150 silent
[[ "$(n sent 'FENCED')" == 1 && "$(n acts 'kill')" == 2 && "$(n acts 'wip')" == 2 ]] &&
  pass "3. the next fenced tick: no second note, nothing TERMed twice" || fail "3. repeated: sent=$(n sent FENCED) kills=$(n acts kill) wips=$(n acts wip)"

# ---- 4. the hub back: unfenced; no hub: never fenced ---------------------------
ticks 180 180 ok
[[ ! -e "$T/wd/fenced" ]] && grep -q UNFENCED "$T/wd.log" && pass "4. the next ack lifts the fence" || fail "4. still fenced after an ack"
out="$(LEASE_NOW=$(( T0 + 190 )) wd spl_wd_takeover c-050 S3 "dead")"
for _ in $(seq 50); do [[ -s "$T/restarts" ]] && break; sleep 0.1; done   # the restart starts detached
grep -q "restart c-050 S3" "$T/restarts" 2>/dev/null && pass "4. control: unfenced, the takeover runs" || fail "4. control: no takeover after the fence lifted ($out)"
reset
echo $(( T0 - 3600 )) > "$T/wd/beat.ack"
echo silent > "$T/hub"
WD_BEAT=0 DRY_RUN=0 wd spl_wd_fence "$T0" "$T/tick"
[[ ! -e "$T/wd/fenced" && "$(n acts .)" == 0 && "$(n beats .)" == 0 ]] &&
  pass "4. WD_BEAT=0 (no hub): no beat, never fenced" || fail "4. WD_BEAT=0 fenced or beat"

# ---- 5. a dry run fences and acts on nothing -----------------------------------
reset
ticks 0 0 ok
DRY=1 ticks 30 120 silent
[[ -e "$T/wd/fenced" && "$(n acts .)" == 0 && "$(n sent .)" == 0 ]] && grep -q "FENCE-DRY c-050" "$T/wd.log" &&
  pass "5. DRY_RUN=1: fenced, nothing pushed, TERMed or sent" || fail "5. dry run acted: $(cat "$T/acts" "$T/sent" 2>/dev/null)"

# ---- 6. an m- lane: TERM its vibe, never a node ---------------------------------
reset
mkdir -p "$T/tick6"
printf 'm-060\t160\t%%4\nm-061\t161\t%%5\nc-062\t162\t%%6\n' > "$T/tick6/agents"
printf '160 1 500 node\n161 1 500 vibe\n162 1 500 node\n' > "$T/tick6/ps"
echo ok > "$T/hub"; DRY_RUN=0 wd spl_wd_fence "$T0" "$T/tick6"
echo silent > "$T/hub"; DRY_RUN=0 wd spl_wd_fence $(( T0 + 120 )) "$T/tick6"
[[ "$(n acts 'kill -TERM 160')" == 0 ]] && grep -qx "wip m-060" "$T/acts" &&
  pass "6. m- lane on a node pid: wip pushed, NO kill" || fail "6. m-060 node pid: $(cat "$T/acts" 2>/dev/null)"
grep -q "FENCE m-060: .*no agent process to TERM" "$T/wd.log" &&
  pass "6. m- lane with no vibe: logged 'no agent process to TERM'" || fail "6. no skip line for m-060: $(grep m-060 "$T/wd.log")"
grep -qx "kill -TERM 161" "$T/acts" && pass "6. m- lane on its vibe pid: TERMed" || fail "6. m-061 vibe not TERMed: $(cat "$T/acts" 2>/dev/null)"
[[ "$(n acts 'kill -TERM 162')" == 0 ]] && grep -qx "wip c-062" "$T/acts" &&
  pass "6. c- lane on a bare node pid: wip pushed, NO kill" || fail "6. c-062 node pid: $(cat "$T/acts" 2>/dev/null)"

# ---- 7. the TERM reaches the agent CLI (real processes) ------------------------
# fence7 TICKDIR: an acked tick, then a fenced one over the real ps and kill
fence7_tick() { unset WD_KILL_CMD; spl_wd_ps > "$2/ps"; spl_wd_fence "$1" "$2"; }
fence7() {
  echo ok > "$T/hub"; DRY_RUN=0 wd fence7_tick "$T0" "$1"
  echo silent > "$T/hub"; DRY_RUN=0 wd fence7_tick $(( T0 + 120 )) "$1"
}
reset
mkdir -p "$T/tick7" "$T/cli"
cp "$(command -v sleep)" "$T/cli/claude"
bash -c '"$1" 300; :' _ "$T/cli/claude" 2>/dev/null & wrap=$!
for _ in $(seq 50); do cli="$(ps -o pid= --ppid "$wrap" | tr -d ' ')"; [[ -n "$cli" ]] && break; sleep 0.1; done
printf 'c-070\t%s\t%%7\n' "$wrap" > "$T/tick7/agents"
WD_FENCE_TERM_WAIT=3 fence7 "$T/tick7"
if ps -o pid= -p "$cli" >/dev/null; then
  fail "7. wrapper row: the CLI $cli under wrapper $wrap still runs after the fence ($(grep 'FENCE c-070' "$T/wd.log"))"
else pass "7. wrapper row: the CLI under it is TERMed"; fi
grep -q "FENCE c-070: wip push rc=0, TERM pid $cli\$" "$T/wd.log" &&
  pass "7. the log names the CLI pid" || fail "7. log: $(grep 'FENCE c-070' "$T/wd.log")"
kill -KILL "$wrap" "$cli" 2>/dev/null; wait "$wrap" 2>/dev/null
reset
printf '#!/bin/bash\ntrap "" TERM\nwhile :; do sleep 0.2; done\n' > "$T/cli/agy"; chmod +x "$T/cli/agy"
"$T/cli/agy" & ign=$!
for _ in $(seq 50); do [[ "$(ps -o comm= -p "$ign")" == agy ]] && break; sleep 0.1; done
printf 'a-071\t%s\t%%8\n' "$ign" > "$T/tick7/agents"
WD_FENCE_TERM_WAIT=1 fence7 "$T/tick7"
grep -q "FENCE a-071: pid $ign still alive after TERM" "$T/wd.log" &&
  pass "7. a CLI that ignores TERM: logged 'still alive after TERM'" || fail "7. no still-alive line: $(grep 'a-071' "$T/wd.log")"
kill -KILL "$ign" 2>/dev/null; wait "$ign" 2>/dev/null
printf '#!/usr/bin/env bash\necho "hop $*" >> "$T/acts"\n' > "$T/bin/hop"; chmod +x "$T/bin/hop"
# kill refuses as for another user's pid; the hop is a stub that logs
fence7_eperm() {
  unset WD_KILL_CMD; kill() { return 1; }
  # shellcheck source=../features/spawn-agents/lib/proc-owner.inc.sh
  source "$PROJ_ROOT/src/bash/features/spawn-agents/lib/proc-owner.inc.sh"
  SPOOL_OWNER_HOP=force SPOOL_OWNER_HOP_CMD="$T/bin/hop" spl_wd_fence_kill 4711
}
reset; wd fence7_eperm
grep -qx "hop test kill -TERM 4711" "$T/acts" &&
  pass "7. a refused kill (EPERM) goes through the owner hop" || fail "7. no owner hop: $(cat "$T/acts" 2>/dev/null)"

# ---- 8. a failed wip push is retried once at UNFENCED --------------------------
reset
printf '#!/usr/bin/env bash\necho "wip $ID" >> "$T/acts"\n[ "$ID" != c-050 ] || [ -e "$T/net" ]\n' > "$T/bin/wipnet"
chmod +x "$T/bin/wipnet"; rm -f "$T/net"
fence8_tick() { WD_WIP_CMD="$T/bin/wipnet"; spl_wd_fence "$@"; }
ticks8() { local s; echo "$3" > "$T/hub"; for (( s = $1; s <= $2; s += 30 )); do DRY_RUN=0 wd fence8_tick $(( T0 + s )) "$T/tick"; done; }
ticks8 0 0 ok
ticks8 30 120 silent
[[ "$(n acts 'wip c-050')" == 1 && "$(n acts 'wip c-051')" == 1 ]] && grep -q "FENCE c-050: wip push rc=1" "$T/wd.log" &&
  pass "8. fenced: c-050's wip push failed, c-051's passed" || fail "8. fenced pushes: $(cat "$T/acts" 2>/dev/null)"
touch "$T/net"
ticks8 150 150 ok
[[ "$(n acts 'wip c-050')" == 2 ]] && grep -q "UNFENCED c-050: wip push retried, rc=0" "$T/wd.log" &&
  pass "8. UNFENCED: c-050's failed push retried once, rc logged" || fail "8. no retry for c-050: $(cat "$T/acts" 2>/dev/null) | $(grep UNFENCED "$T/wd.log")"
[[ "$(n acts 'wip c-051')" == 1 ]] && pass "8. UNFENCED: c-051 (pushed) is not pushed again" || fail "8. c-051 pushed $(n acts 'wip c-051') times"
ticks8 180 180 ok
[[ "$(n acts 'wip c-050')" == 2 ]] && ! ls "$T/wd"/fence.wipfail.* >/dev/null 2>&1 &&
  pass "8. the retry runs once: no state left, no second retry" || fail "8. after: wips=$(n acts 'wip c-050') files=$(cd "$T/wd" && echo fence.wipfail.*)"

# ---- 9. a resume from a suspend: re-beat first, fence only after the grace ------
# sleep9 GRACE: the last ack at T0, the box asleep T0+30..T0+450, its first
# tick awake at T0+454 writes resume (as spl_wd_tick does on a tick gap)
sleep9() {
  reset; ticks 0 0 ok
  echo $(( T0 + 454 )) > "$T/wd/resume"; echo 424 > "$T/wd/resume.gap"
  export WD_FENCE_RESUME_GRACE="$1"
}
sleep9 180
ticks 454 574 silent
[[ ! -e "$T/wd/fenced" && "$(n acts .)" == 0 && "$(n sent .)" == 0 ]] &&
  pass "9. woke 424 s after the last ack, hub silent 120 s of the 180 s grace: not fenced" ||
  fail "9. fenced inside the resume grace: $(cat "$T/acts" "$T/sent" 2>/dev/null)"
[[ "$(n wd.log 'RESUME detected (slept 424s), fence held for 180s')" == 1 ]] &&
  pass "9. one 'RESUME detected (slept 424s), fence held for 180s' line" || fail "9. resume lines: $(grep RESUME "$T/wd.log")"
ticks 604 604 ok
ticks 634 664 ok
[[ ! -e "$T/wd/fenced" && "$(n acts .)" == 0 ]] && pass "9. the hub acks inside the grace: never fenced, nothing TERMed" ||
  fail "9. acked inside the grace yet fenced: $(cat "$T/acts" 2>/dev/null)"
sleep9 180
ticks 454 634 silent
[[ -e "$T/wd/fenced" ]] && grep -qx "kill -TERM 150" "$T/acts" &&
  pass "9. the hub still silent after the grace: fenced as today" || fail "9. not fenced after the grace: $(cat "$T/acts" 2>/dev/null)"
sleep9 0
ticks 454 454 silent
[[ -e "$T/wd/fenced" ]] && grep -qx "kill -TERM 150" "$T/acts" &&
  pass "9. RED control: grace 0 (the code before) fences the first tick after the wake" ||
  fail "9. RED control: grace 0 did not fence at the wake: $(cat "$T/acts" 2>/dev/null)"
sleep9 180; rm -f "$T/wd/resume"
ticks 30 120 silent
[[ -e "$T/wd/fenced" ]] && pass "9. no resume: hub silent 120 s -> fenced as in 3" || fail "9. no resume yet not fenced"
unset WD_FENCE_RESUME_GRACE

if (( fails )); then echo "wd-fence: $fails FAILED"; exit 1; fi
echo "wd-fence: all passed"
