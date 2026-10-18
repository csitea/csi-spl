#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the orchestrator outcome check (SPL-1717), spl_wd_orch_outcome, in
#          a sandbox spool root. spool-send.sh is a stub that logs. The clock
#          is the real one; the evidence files get their mtimes and journal
#          times relative to it.
#   1. an ask waits 3 h, the role wrote no brief, sent no task and closed no
#      ask for 2 h -> ONE blocker to the dispatch lease holder on task
#      wd-orch-outcome, naming the ask (the control that fires)
#   2. the next check inside WD_ORCH_OUTCOME_EVERY does nothing; the one
#      after logs "still none" and sends no second blocker
#   3. a new lane brief (c001tnk-<slug>.md) clears the episode; once it ages
#      out of the window, the alert fires again (re-armed)
#   4. each outcome alone keeps it quiet: a g001-*.md brief in a second brief
#      dir, a kind=task message in g-001's outbox, a "done" by c-001@box1 in
#      the journal; a dispatcher's brief (c002-*), a note in the outbox and a
#      done by c-002 do not count
#   5. nothing waits (no ask, or the only ask is younger than the window, or
#      it is done) -> no alert
#   6. WD_ORCH_OUTCOME_HOURS=1 alerts on a 90 min old ask; 0 = off
#   7. the orch role held on another box, or no lease.orch -> this box
#      checks nothing and prints nothing
#   8. DRY_RUN=1 -> the DRY line, nothing sent, not marked alerted
#   9. spl_wd_tick calls it once per tick
#  10. a-/g-/m-/q-001 symlinked to c-001 (sat 2026-10-18): each real outbox
#      is read once, round_tasks counts 2 tasks as 2 (old code: 10), and jq
#      runs only on the 3 files of 43 that can be a task, plus one for the
#      ask book (old code: 216 jq runs; on sat 17-23 s of the 20 s pre-flight
#      tick, SPL-2510); a truncated file that mentions "task" counts nothing
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
RUN_DIR="$PROJ_ROOT/src/bash/run"
NOW=$(date +%s)
mkdir -p "$T/bin"
export T
printf '#!/usr/bin/env bash\necho "send $*" >> "$T/sent"\n' > "$T/bin/send"
chmod +x "$T/bin/send"

# wd NOW [VAR=v]...: one check in a fresh shell over the sandbox state
wd() {
  local now="$1"; shift
  ( set +u
    do_log() { echo "$*"; }
    # shellcheck source=../run/spl-watchdog.func.sh
    source "$RUN_DIR/spl-watchdog.func.sh"
    export SPOOL_ROOT="$T/spool" LEASE_DIR="$T/spool/dispatch" WD_DIR="$T/wd" WD_LOG="$T/wd.log"
    export WD_SEND="$T/bin/send" WD_FROM=c-001 WD_BOX=box1 DRY_RUN=0
    export WD_ORCH_BRIEF_DIRS="$T/spool/dispatch/briefs $T/parent/briefs" WD_ORCH_OUTCOME_EVERY=300
    for kv in "$@"; do export "${kv?}"; done
    spl_wd_orch_outcome "$now" )
}
reset() {
  rm -rf "$T/wd" "$T/spool" "$T/parent" "$T/sent" "$T/wd.log"
  mkdir -p "$T/wd" "$T/spool/dispatch/briefs" "$T/spool/asks" "$T/parent/briefs" "$T/spool/c-001/outbox" "$T/spool/g-001/outbox"
  echo "c-001@box1 $NOW" > "$T/spool/dispatch/lease.orch"
  echo "c-002@box2 $NOW" > "$T/spool/dispatch/lease"
  : > "$T/spool/asks/journal.log"
}
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
# ask ID AGE_S [STATE]: an ask to the orchestrator created AGE_S ago
ask() {
  jq -n -c --arg id "$1" --arg c "$(iso $(( NOW - $2 )))" --arg s "${3:-open}" \
    '{ask_id:$id, role:"orch", kind:"task", from:"c-050", to:"c-001", state:$s, created_at:$c}' > "$T/spool/asks/$1.json"
}
# file PATH AGE_S [BODY]
file() { printf '%s\n' "${3:-x}" > "$1"; touch -d "@$(( NOW - $2 ))" "$1"; }
journal() { echo "$(iso $(( NOW - $1 ))) $2 aaaa0000-0000-0000-0000-000000000000 $3 done" >> "$T/spool/asks/journal.log"; }
n() { if [[ -f "$T/$1" ]]; then grep -c -- "$2" "$T/$1"; else echo 0; fi; }
A1=a1a1a1a1-0000-4000-8000-000000000001

# ---- 1. the control: no outcome for 2 h while an ask waits 3 h --------------
reset; ask "$A1" 10800
file "$T/spool/dispatch/briefs/c001tnk-old.md" 9000
wd "$NOW"
[[ "$(n sent .)" == 1 && "$(n sent '--to c-002@box2 --kind blocker --task wd-orch-outcome')" == 1 && "$(n sent 'a1a1a1a1')" == 1 && -e "$T/wd/orch-outcome.alerted" ]] &&
  pass "1. no outcome 2 h, an ask waits 3 h: ONE blocker to the dispatch holder naming the ask" ||
  fail "1. sent=$(cat "$T/sent" 2>/dev/null) log=$(tail -n 2 "$T/wd.log" 2>/dev/null)"

# ---- 2. rate limit, then once per episode ------------------------------------
wd $(( NOW + 60 ))
[[ "$(n sent .)" == 1 && "$(n wd.log ORCH-OUTCOME)" == 1 ]] && pass "2. a check inside WD_ORCH_OUTCOME_EVERY does nothing" ||
  fail "2. rate: sent=$(n sent .) lines=$(n wd.log ORCH-OUTCOME)"
wd $(( NOW + 301 ))
[[ "$(n sent .)" == 1 && "$(n wd.log 'still none')" == 1 ]] && pass "2. the next check logs 'still none', no second blocker" ||
  fail "2. once: sent=$(n sent .) still=$(n wd.log 'still none')"

# ---- 3. a brief clears it; aged out, it fires again --------------------------
file "$T/spool/dispatch/briefs/c001tnk-new.md" 0
wd $(( NOW + 602 ))
[[ "$(n sent .)" == 1 && "$(n wd.log 'ORCH-OUTCOME cleared')" == 1 && ! -e "$T/wd/orch-outcome.alerted" ]] &&
  pass "3. a new lane brief clears the episode" || fail "3. clear: sent=$(n sent .) log=$(tail -n 2 "$T/wd.log")"
wd $(( NOW + 7300 ))
[[ "$(n sent .)" == 2 ]] && pass "3. the brief aged out of the window: the alert fires again" || fail "3. re-arm: sent=$(n sent .)"

# ---- 4. each outcome alone keeps it quiet; others' work does not count -------
quiet() {  # LABEL: one check over the current sandbox -> no blocker
  wd "$NOW"
  if [[ "$(n sent .)" == 0 && "$(n wd.log 'ORCH-OUTCOME ok')" == 1 ]]; then pass "4. $1: no alert"; else fail "4. $1: sent=$(n sent .) log=$(tail -n 1 "$T/wd.log")"; fi
}
loud() {  # LABEL: one check -> the blocker
  wd "$NOW"
  if [[ "$(n sent .)" == 1 ]]; then pass "4. $1: still alerts"; else fail "4. $1: sent=$(n sent .) log=$(tail -n 1 "$T/wd.log")"; fi
}
reset; ask "$A1" 10800; file "$T/parent/briefs/g001-lane.md" 3600; quiet "a g001 brief in the second brief dir"
reset; ask "$A1" 10800; file "$T/spool/g-001/outbox/m1.json" 600 '{"kind":"task","from":"g-001"}'; quiet "a kind=task (round brief) in g-001's outbox"
reset; ask "$A1" 10800; journal 1800 "done" c-001@box1; quiet "an ask closed (done) by c-001@box1"
reset; ask "$A1" 10800; journal 1800 decline g-001; quiet "an ask declined by g-001"
reset; ask "$A1" 10800; file "$T/spool/dispatch/briefs/c002-lane.md" 600; loud "a dispatcher's brief (c002-*)"
reset; ask "$A1" 10800; file "$T/spool/c-001/outbox/m2.json" 600 '{"kind":"note","from":"c-001"}'; loud "a note in c-001's outbox"
reset; ask "$A1" 10800; journal 1800 "done" c-002@box2; loud "an ask closed by c-002"
reset; ask "$A1" 10800; journal 9000 "done" c-001@box1; loud "an ask closed before the window"

# ---- 5. nothing waits --------------------------------------------------------
reset; wd "$NOW"
[[ "$(n sent .)" == 0 ]] && pass "5. no ask: no alert" || fail "5. no ask: sent=$(n sent .)"
reset; ask "$A1" 3600; wd "$NOW"
[[ "$(n sent .)" == 0 ]] && pass "5. the only ask is 1 h old (window 2 h): no alert" || fail "5. young ask: sent=$(n sent .)"
reset; ask "$A1" 10800 "done"; wd "$NOW"
[[ "$(n sent .)" == 0 ]] && pass "5. the only ask is done: no alert" || fail "5. done ask: sent=$(n sent .)"
reset; ask "$A1" 10800 acked; wd "$NOW"
[[ "$(n sent .)" == 1 ]] && pass "5. an acked ask still waits: alert" || fail "5. acked ask: sent=$(n sent .)"

# ---- 6. configurable N -------------------------------------------------------
reset; ask "$A1" 5400; wd "$NOW" WD_ORCH_OUTCOME_HOURS=1
[[ "$(n sent .)" == 1 && "$(n sent 'for 1 h')" == 1 ]] && pass "6. WD_ORCH_OUTCOME_HOURS=1: a 90 min ask alerts" || fail "6. hours=1: sent=$(cat "$T/sent" 2>/dev/null)"
reset; ask "$A1" 10800; wd "$NOW" WD_ORCH_OUTCOME_HOURS=0
[[ "$(n sent .)" == 0 && ! -s "$T/wd.log" ]] && pass "6. WD_ORCH_OUTCOME_HOURS=0: off" || fail "6. off: sent=$(n sent .)"

# ---- 7. the orch role on another box -----------------------------------------
reset; ask "$A1" 10800; echo "c-001@box9 $NOW" > "$T/spool/dispatch/lease.orch"; wd "$NOW"
[[ "$(n sent .)" == 0 && ! -s "$T/wd.log" ]] && pass "7. orch held on box9: box1 checks nothing" || fail "7. other box: sent=$(n sent .)"

reset; ask "$A1" 10800; rm -f "$T/spool/dispatch/lease.orch"; err="$(wd "$NOW" 2>&1 >/dev/null)"
[[ "$(n sent .)" == 0 && -z "$err" ]] && pass "7. no lease.orch: nothing checked, nothing on stderr" || fail "7. no lease.orch: sent=$(n sent .) stderr=$err"

# ---- 8. DRY_RUN=1 ------------------------------------------------------------
reset; ask "$A1" 10800; wd "$NOW" DRY_RUN=1
[[ "$(n sent .)" == 0 && "$(n wd.log ORCH-OUTCOME-DRY)" == 1 && ! -e "$T/wd/orch-outcome.alerted" ]] &&
  pass "8. DRY_RUN=1: the DRY line, nothing sent" || fail "8. dry: sent=$(n sent .) log=$(cat "$T/wd.log")"

# ---- 9. wired into the tick --------------------------------------------------
c="$( ( set +u; do_log() { :; }; source "$RUN_DIR/spl-watchdog.func.sh"; declare -f spl_wd_tick ) | grep -c 'spl_wd_orch_outcome "\$now"')"
[[ "$c" == 1 ]] && pass "9. spl_wd_tick calls spl_wd_orch_outcome once" || fail "9. calls in spl_wd_tick: $c"

# ---- 10. symlinked seats: each outbox once, jq only on candidates ----------
reset; ask "$A1" 10800
rm -rf "$T/spool/g-001"
for s in a g m q; do ln -s c-001 "$T/spool/$s-001"; done
for i in $(seq 1 40); do file "$T/spool/c-001/outbox/n$i.json" 600 '{"kind":"note","from":"c-001","body":"ok"}'; done
file "$T/spool/c-001/outbox/t1.json" 600 '{"kind":"task","from":"c-001"}'
file "$T/spool/c-001/outbox/t2.json" 600 '{"body":"x","kind":"task","from":"c-001"}'
file "$T/spool/c-001/outbox/cut.json" 600 '{"kind":"task","fr'
mkdir -p "$T/jqbin"
printf '#!/usr/bin/env bash\necho x >> "$T/jq.calls"\nexec %q "$@"\n' "$(command -v jq)" > "$T/jqbin/jq"
chmod +x "$T/jqbin/jq"; : > "$T/jq.calls"
wd "$NOW" PATH="$T/jqbin:$PATH"
calls="$(grep -c . "$T/jq.calls")"
[[ "$(n sent .)" == 0 && "$(n wd.log 'round_tasks=2 ')" == 1 ]] &&
  pass "10. 5 seat links to one outbox: round_tasks=2, the truncated file counts nothing" ||
  fail "10. count: $(tail -n 1 "$T/wd.log")"
(( calls <= 4 )) && pass "10. jq runs on the 3 task candidates + the ask book only ($calls calls; one per file x 5 links was 216)" ||
  fail "10. jq calls: $calls"

if (( fails )); then echo "wd-orch-outcome: $fails FAILED"; exit 1; fi
echo "wd-orch-outcome: all passed"
