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

# wd FN ARGS: one call in a fresh shell over the sandbox state (files only,
# as three instances share it)
wd() {
  ( set +u
    do_log() { echo "$*"; }
    # shellcheck source=../run/spl-watchdog.func.sh
    source "$RUN_DIR/spl-watchdog.func.sh"
    export SPOOL_ROOT="$T/spool" WD_DIR="$T/wd" WD_LOG="$T/wd.log" WD_SEND="$T/bin/send" WD_FROM=c-001 WD_BOX=box1
    export WD_BEAT_CMD="$T/bin/hub" WD_BEAT_TIMEOUT=1 WD_WIP_CMD="$T/bin/wip" WD_KILL_CMD="$T/bin/kill"
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

if (( fails )); then echo "wd-fence: $fails FAILED"; exit 1; fi
echo "wd-fence: all passed"
