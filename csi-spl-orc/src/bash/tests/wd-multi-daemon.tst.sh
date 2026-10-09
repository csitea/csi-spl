#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the 3 watchdog instances of spec 102 10.4.1 (T023a) in a sandbox:
#          do_spl_watchdog with WD_INST 1..3, spl_wd_inst_start, the judge
#          lock <id>.judge.lock and the per-instance scratch. Nothing real is
#          touched: ps, tmux, spool-send.sh, the restart and ./run are stubs,
#          the situation scripts are stubs that log who evaluated, then sleep.
#   1. three instances at once, started by spl_wd_inst_start (WD_INST_START=
#      "1 2 3"): each detached (its own session), each holding its own
#      run.<inst>.lock with its pid in run.<inst>.pid, its own tick.<inst>/,
#      ctx.<inst>/, last.tick.<inst> and heartbeat.<inst>.json; instance 1
#      also holds the 093 keeper's run.lock; a second start starts nothing;
#      a dead instance is the only one started again; a second loop of a
#      running instance and a 093 loop beside instance 1 start nothing
#   2. one tick period, 3 instances: every agent is judged exactly once
#   3. 2 instances on the same stuck agent: exactly 1 evaluates and acts,
#      1 restart launched, ONE line in <id>/lifetime/restarts (the counter
#      that replaced <id>.takeovers in T008); the restart finds the T003 id
#      lock free and does not inherit the judge lock; S6 re-poke: ONE C-c
#   4. control: the judge lock removed (WD_JUDGE_LOCK=0): both evaluate and
#      the double action is caught (2 C-c, 2 S9 notes)
#   5. inside-lock dedup: a restart in flight in rotate.log -> the next judge
#      skips the id; s9.reported: the same pane is not reported again within
#      300 s (control: a changed pane is); input.log: a poke recorded 30 s
#      ago -> no poke (control: 120 s ago -> one poke)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
command -v setsid >/dev/null || { echo "FAIL: setsid is required"; exit 1; }
T0=1800000000   # 2027-01-15T08:00:00Z
iso() { date -u -d "@$1" +%FT%TZ; }
S="$T/spool"; D="$S/dispatch"; W="$D/wd"
mkdir -p "$T/bin" "$T/sit" "$T/tmux" "$D" "$S/peer"
printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\nSPOOL_BOX_TAG=box1\nSPOOL_DESK_BOX=box1\n' "$(id -un)" "$(id -un)" > "$S/box.env"

# ---- stubs -------------------------------------------------------------------
printf '#!/usr/bin/env bash\ncat "%s/ps"\n' "$T" > "$T/bin/ps"
# tmux: panes in "$T/tmux/panes"; send-keys logged, then KEY_SLEEP s (a slow act)
cat > "$T/bin/tmux" <<'EOF'
#!/usr/bin/env bash
cmd="$1"; shift; tgt="" a=""
while [ $# -gt 0 ]; do case "$1" in -t) tgt="$2"; shift 2 ;; -F) shift 2 ;; -a|-p|-e) shift ;; *) a="$1"; shift ;; esac; done
case "$cmd" in
  list-panes) cat "$T/tmux/panes" ;;
  capture-pane) cat "$T/tmux/screen.$tgt" 2>/dev/null || exit 1 ;;
  send-keys) echo "keys $tgt $a" >> "$T/tmux/log"; sleep "${KEY_SLEEP:-0}" ;;
esac
EOF
cat > "$T/bin/send" <<'EOF'
#!/usr/bin/env bash
echo "send $*" >> "$T/sent"; sleep "${SEND_SLEEP:-0}"
EOF
# the restart: logs, the ONE counter, whether the T003 id lock is free and
# whether it carries a judge lock fd; a rotate.log line in flight
cat > "$T/bin/takeover" <<'EOF'
#!/usr/bin/env bash
echo "takeover $ID $REASON" >> "$T/takeovers"
mkdir -p "$SPOOL_ROOT/$ID/lifetime"; echo "$LEASE_NOW $CAUSE" >> "$SPOOL_ROOT/$ID/lifetime/restarts"
if flock -n "$SPOOL_ROOT/$ID/lifetime/restart.lock" true; then echo free; else echo held; fi >> "$T/idlock"
n=0; for f in /proc/$$/fd/*; do case "$(readlink "$f")" in *judge.lock*) n=$((n + 1)) ;; esac; done; echo "$n" >> "$T/judgefd"
echo "$(date -u -d "@$LEASE_NOW" +%FT%TZ) 20270115T0800Z-wd-$ID SPAWN OK started" >> "$SPOOL_ROOT/dispatch/rotate.log"
echo "$ID" >> "$T/takeover.done"
EOF
# every situation script: --norm/--scrub copy the pane; else, when
# "$T/hit.<id>.<sN>" exists, log "<sN> <id> <instance>" to $T/evals, sleep
# SIT_SLEEP s (an evaluation that takes time) and print the file
cat > "$T/sit/s1.sh" <<'EOF'
#!/usr/bin/env bash
n="$(basename "$0" .sh)"
case "${1:-}" in --norm|--scrub) cat; exit 0 ;; esac
f="$T/hit.$1.$n"; [ -f "$f" ] || exit 0
echo "$n $1 ${WD_INST:-0}" >> "$T/evals"
sleep "${SIT_SLEEP:-0}"
cat "$f"
EOF
for s in s3 s6 s9; do cp "$T/sit/s1.sh" "$T/sit/$s.sh"; done
# ./run: the watchdog action, as spl_lease_detach starts it
cat > "$T/bin/run" <<'EOF'
#!/usr/bin/env bash
do_log() { echo "$*"; }
source "$PROJ_PATH/src/bash/run/spl-watchdog.func.sh"
"$2"
EOF
chmod +x "$T/bin/"* "$T/sit/"*
export T

# agent <id> <pane> <pid>: a window, a live claude process 1 h old, a pane
agent() {
  local id="$1" pane="$2" pid="$3" sh=$(( ${2#%} + 5000 ))
  mkdir -p "$S/$id/inbox" "$T/proc/$pid"
  printf '%s\t%s\t$1\t%s@box1 a lane\tsh\n' "$pane" "$sh" "$id" >> "$T/tmux/panes"
  printf '%s 1 3600 sh\n%s %s 3600 claude\n' "$sh" "$pid" "$sh" >> "$T/ps"
  printf 'SPOOL_AGENT_ID=%s\0' "$id" > "$T/proc/$pid/environ"
  printf 'working on the brief\n' > "$T/tmux/screen.$pane"
}
reset_box() {
  rm -rf "$D" "$S"/c-* "$T/proc" "$T"/hit.* "$T/evals" "$T/sent" "$T/takeovers" "$T/idlock" "$T/judgefd" "$T/takeover.done" "$T/tmux/log"
  mkdir -p "$D" "$T/proc"; : > "$T/ps"; : > "$T/tmux/panes"
}
wd_env=(PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" LEASE_PROC_ROOT="$T/proc"
  WD_PS_CMD="$T/bin/ps" ROTATE_TMUX="$T/bin/tmux" WD_SEND="$T/bin/send" WD_TAKEOVER_CMD="$T/bin/takeover"
  WD_SITUATIONS="$T/sit" LEASE_TRANSCRIPT_CMD=true)
# wd <inst>: one tick of instance <inst> ("" = the 093 loop) under ./run's set -E + ERR trap
wd() {
  env "${wd_env[@]}" WD_INST="$1" LEASE_NOW="${NOW:-$T0}" WD_TICKS=1 WD_TICK=30 DRY_RUN=0 bash -c '
    set -E; trap "echo ERR-TRAP: \$BASH_COMMAND; exit 9" ERR
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-watchdog.func.sh"
    do_spl_watchdog' 2>&1
}
# both <inst> <inst>: two instances on one tick, at once; output in $T/out.<inst>
both() {
  wd "$1" > "$T/out.$1" & local a=$!
  wd "$2" > "$T/out.$2" & local b=$!
  wait "$a" "$b"
}
# settle [N]: wait (up to 30 s) until N detached restarts (default 1) have
# made their last write. One still running when the next case resets the box
# lands in the new rotate.log and that judge skips the id (gate 10 run
# 37969307772: '4 S9:  /' after the S9 control's two restarts)
settle() { local n="${1:-1}"; for _ in $(seq 1 300); do (( $(grep -c . "$T/takeover.done" 2>/dev/null || true) >= n )) && return; sleep 0.1; done; }
held() { [[ -f "$1" ]] && ! flock -n "$1" true; }
cnt() { local n; n="$(grep -c -- "$1" "$2" 2>/dev/null)"; echo "${n:-0}"; }

# ---- 1. three instances at once, by spl_wd_inst_start ---------------------------
reset_box; agent c-940 %1 4040
stop_all() {
  local i p
  for i in 1 2 3; do
    p="$(cat "$W/run.$i.pid" 2>/dev/null || true)"
    [[ "$p" =~ ^[0-9]+$ ]] && { kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null; }
  done
  for _ in $(seq 1 50); do held "$W/run.1.lock" || held "$W/run.2.lock" || held "$W/run.3.lock" || return 0; sleep 0.1; done
}
trap 'stop_all; rm -rf "$T"' EXIT
start() { env "${wd_env[@]}" WD_RUN="$T/bin/run" WD_TICK=2 WD_INST_START="$1" bash -c '
  do_log() { echo "$*"; }
  source "$PROJ_PATH/src/bash/run/spl-watchdog.func.sh"
  do_spl_watchdog' 2>&1; }
out="$(start "1 2 3")"
ok=1; for i in 1 2 3; do held "$W/run.$i.lock" || ok=0; done
(( ok )) && pass "1 WD_INST_START=\"1 2 3\": three instances hold run.1.lock, run.2.lock and run.3.lock at once" ||
  fail "1 three locks: $out / $(ls "$W")"
p1="$(cat "$W/run.1.pid" 2>/dev/null)"; p2="$(cat "$W/run.2.pid" 2>/dev/null)"; p3="$(cat "$W/run.3.pid" 2>/dev/null)"
[[ -n "$p1" && -n "$p2" && -n "$p3" && "$p1" != "$p2" && "$p2" != "$p3" && "$p1" != "$p3" ]] && kill -0 "$p1" "$p2" "$p3" 2>/dev/null &&
  pass "1 three live pids in run.<inst>.pid" || fail "1 pids: '$p1' '$p2' '$p3'"
sids="$(for p in "$p1" "$p2" "$p3"; do ps -o sid= -p "$p" | tr -d ' '; done | tr '\n' ' ')"
[[ "$sids" == "$p1 $p2 $p3 " ]] && pass "1 each instance runs detached in its own session (setsid)" || fail "1 sessions: '$sids' for '$p1 $p2 $p3'"
for _ in $(seq 1 60); do [[ -s "$W/heartbeat.1.json" && -s "$W/heartbeat.2.json" && -s "$W/heartbeat.3.json" ]] && break; sleep 0.1; done
ok=1; for i in 1 2 3; do
  jq -e --argjson i "$i" --argjson p "$(cat "$W/run.$i.pid")" '.instance == $i and .pid == $p and .status == "ok" and (.tick_seq >= 1) and (.git_sha | length > 0)' \
    "$W/heartbeat.$i.json" >/dev/null 2>&1 || ok=0
done
(( ok )) && pass "1 heartbeat.<inst>.json per instance names its instance and pid" || fail "1 heartbeats: $(cat "$W"/heartbeat.*.json 2>/dev/null)"
for _ in $(seq 1 60); do [[ -d "$W/tick.1" && -d "$W/tick.2" && -d "$W/tick.3" && -s "$W/last.tick.3" ]] && break; sleep 0.1; done
ok=1; for i in 1 2 3; do [[ -d "$W/tick.$i" && -d "$W/ctx.$i" && -s "$W/last.tick.$i" ]] || ok=0; done
[[ $ok == 1 && ! -e "$W/tick" && ! -e "$W/ctx" ]] && pass "1 isolated scratch: tick.<inst>/, ctx.<inst>/, last.tick.<inst> per instance, no shared tick/ or ctx/" ||
  fail "1 scratch: $(ls "$W" | tr '\n' ' ')"
held "$W/run.lock" && [[ "$(cat "$W/run.pid")" == "$p1" ]] && pass "1 instance 1 also holds the 093 keeper's run.lock + run.pid (do_spl_wd_ensure sees a loop)" ||
  fail "1 keeper lock: run.pid=$(cat "$W/run.pid" 2>/dev/null) p1=$p1"
out="$(start "1 2 3")"
[[ "$(cat "$W/run.1.pid") $(cat "$W/run.2.pid") $(cat "$W/run.3.pid")" == "$p1 $p2 $p3" && "$(grep -c 'runs (pid' <<<"$out")" == 3 ]] &&
  pass "1 a second start starts nothing: all three run" || fail "1 second start: $out"
out="$(env "${wd_env[@]}" WD_INST=2 WD_TICKS=1 WD_TICK=1 bash -c 'do_log() { echo "$*"; }; source "$PROJ_PATH/src/bash/run/spl-watchdog.func.sh"; do_spl_watchdog' 2>&1)"
grep -q 'instance 2 already runs' <<<"$out" && pass "1 a second loop of instance 2 starts nothing" || fail "1 second loop: $out"
out="$(env "${wd_env[@]}" WD_TICKS=1 WD_TICK=1 bash -c 'do_log() { echo "$*"; }; source "$PROJ_PATH/src/bash/run/spl-watchdog.func.sh"; do_spl_watchdog' 2>&1)"
grep -q 'instance 1 runs on this box' <<<"$out" && pass "1 a 093 loop (no WD_INST) beside instance 1 starts nothing" || fail "1 093 loop: $out"
kill -- "-$p2" 2>/dev/null; for _ in $(seq 1 50); do held "$W/run.2.lock" || break; sleep 0.1; done
out="$(start "1 2 3")"
n2="$(cat "$W/run.2.pid")"
[[ "$n2" != "$p2" ]] && kill -0 "$n2" 2>/dev/null && [[ "$(cat "$W/run.1.pid") $(cat "$W/run.3.pid")" == "$p1 $p3" ]] && grep -q 'instance 2 started' <<<"$out" &&
  pass "1 a dead instance 2 is started again; 1 and 3 are left alone" || fail "1 restart of 2: $out"
held "$W/run.2.start.lock" && fail "1 the start lock is still held after the start" || pass "1 the start lock is released after the start"
stop_all

# ---- 2. one tick period, three instances: every agent judged exactly once ------
reset_box; agent c-941 %1 4041; agent c-942 %2 4042; agent c-943 %3 4043
for i in 1 2 3; do wd "$i" > "$T/out.$i" & done; wait
lines="$(cat "$T/out.1" "$T/out.2" "$T/out.3" | grep -E '^c-94[123] ')"
[[ "$(grep -c '^c-941 OK' <<<"$lines") $(grep -c '^c-942 OK' <<<"$lines") $(grep -c '^c-943 OK' <<<"$lines")" == "1 1 1" ]] &&
  pass "2 three instances, one tick period: each agent judged exactly once" || fail "2 judged: $lines"
grep -q ERR-TRAP "$T/out.1" "$T/out.2" "$T/out.3" && fail "2 the ERR trap fired: $(cat "$T"/out.*)" || pass "2 the ticks run clean under set -E + ERR trap"
[[ "$(cut -d' ' -f1 "$W/c-941.judged")" == "$T0" ]] && pass "2 <id>.judged holds the tick epoch and the instance" || fail "2 judged file: $(cat "$W/c-941.judged" 2>/dev/null)"
ls "$W"/c-94[123].judge.lock >/dev/null 2>&1 && pass "2 a judge lock file per agent (never removed)" || fail "2 judge locks: $(ls "$W")"

# ---- 3. two instances, one stuck agent: one judge, one action ------------------
reset_box; agent c-950 %1 4050
echo "HIT S1 age=999 prog=0 inbox=1" > "$T/hit.c-950.s1"
SIT_SLEEP=2 both 1 2; settle
[[ "$(cnt 'c-950' "$T/evals")" == 1 ]] && pass "3 exactly 1 instance evaluates the stuck agent (judge lock)" || fail "3 evaluations: $(cat "$T/evals")"
[[ "$(cnt 'takeover c-950 S1' "$T/takeovers")" == 1 ]] && pass "3 exactly 1 restart launched" || fail "3 takeovers: $(cat "$T/takeovers" 2>/dev/null)"
[[ "$(grep -c . "$S/c-950/lifetime/restarts" 2>/dev/null)" == 1 ]] && pass "3 the ONE counter <id>/lifetime/restarts = 1" || fail "3 restarts: $(cat "$S/c-950/lifetime/restarts" 2>/dev/null)"
[[ "$(cat "$T/idlock" 2>/dev/null)" == free ]] && pass "3 the restart finds the T003 id lock free: the watchdog does not hold it" || fail "3 id lock: $(cat "$T/idlock" 2>/dev/null)"
[[ "$(cat "$T/judgefd" 2>/dev/null)" == 0 ]] && pass "3 the detached restart does not inherit the judge lock" || fail "3 judge fd in the restart: $(cat "$T/judgefd" 2>/dev/null)"
grep -q 'c-950 HIT S1' "$T/out.1" "$T/out.2" && [[ "$(cat "$T/out.1" "$T/out.2" | grep -c '^c-950 ')" == 1 ]] &&
  pass "3 one verdict line for the agent, from the instance that judged it" || fail "3 lines: $(cat "$T/out.1" "$T/out.2")"
reset_box; agent c-951 %1 4051
echo "HIT S6 poke=1 age=200" > "$T/hit.c-951.s6"
SIT_SLEEP=1 KEY_SLEEP=2 both 1 2
[[ "$(cnt 'keys %1 C-c' "$T/tmux/log")" == 1 && "$(cnt 'poke-only' "$T/sent")" == 1 ]] &&
  pass "3 S6 re-poke on a stuck agent: exactly ONE C-c and one ring" || fail "3 S6: $(cat "$T/tmux/log" 2>/dev/null) / $(cat "$T/sent" 2>/dev/null)"

# ---- 4. control: the judge lock removed (seam) -> the double action is caught ----
reset_box; agent c-951 %1 4051
echo "HIT S6 poke=1 age=200" > "$T/hit.c-951.s6"
WD_JUDGE_LOCK=0 SIT_SLEEP=1 KEY_SLEEP=2 both 1 2
[[ "$(cnt 'c-951' "$T/evals")" == 2 && "$(cnt 'keys %1 C-c' "$T/tmux/log")" == 2 ]] &&
  pass "4 control: no judge lock -> both instances evaluate and the C-c is sent twice (caught)" ||
  fail "4 control did not double: $(cat "$T/evals" 2>/dev/null) / $(cat "$T/tmux/log" 2>/dev/null)"
reset_box; agent c-952 %1 4052
echo "HIT S9 stuck=1 poke_age=400" > "$T/hit.c-952.s9"
WD_JUDGE_LOCK=0 SIT_SLEEP=1 SEND_SLEEP=2 both 1 2; settle 2
[[ "$(cnt 'WATCHDOG (102 S9): c-952' "$T/sent")" == 2 ]] && pass "4 control: no judge lock -> the S9 note goes twice (caught)" ||
  fail "4 S9 control: $(cat "$T/sent" 2>/dev/null)"
reset_box; agent c-952 %1 4052
echo "HIT S9 stuck=1 poke_age=400" > "$T/hit.c-952.s9"
SIT_SLEEP=1 SEND_SLEEP=2 both 1 2; settle
[[ "$(cnt 'WATCHDOG (102 S9): c-952' "$T/sent")" == 1 && "$(cnt 'takeover c-952 S9' "$T/takeovers")" == 1 ]] &&
  pass "4 with the judge lock: ONE S9 note, ONE restart" || fail "4 S9: $(cat "$T/sent" 2>/dev/null) / $(cat "$T/takeovers" 2>/dev/null)"

# ---- 5. inside-lock dedup ----------------------------------------------------------
# rotate.log: the restart in flight (its SPAWN line) -> the next judge skips the id
out="$(NOW=$((T0 + 30)) wd 3)"
grep -q '^c-952 SKIP rotation: .*-wd-c-952 SPAWN' <<<"$out" && [[ "$(cnt 'takeover' "$T/takeovers")" == 1 ]] &&
  pass "5 a restart in flight in rotate.log: the next judge (instance 3) skips the id" || fail "5 rotate.log: $out"
# s9.reported: the same pane within 300 s is not reported again
[[ "$(cut -d' ' -f1 "$S/c-952/lifetime/s9.reported" 2>/dev/null)" == "$T0" ]] && pass "5 s9.reported written with the report" || fail "5 s9.reported: $(cat "$S/c-952/lifetime/s9.reported" 2>/dev/null)"
rm -f "$W"/c-952.ep.* "$D/rotate.log"
out="$(NOW=$((T0 + 60)) wd 1)"
settle 2
[[ "$(cnt 'WATCHDOG (102 S9): c-952' "$T/sent")" == 1 ]] && grep -q 'reported 60s ago' <<<"$out" &&
  pass "5 a new S9 episode on the same pane 60 s later: not reported again" || fail "5 s9 dedup: $out / $(cat "$T/sent")"
rm -f "$W"/c-952.ep.* "$D/rotate.log"; printf 'another screen\n' > "$T/tmux/screen.%1"
out="$(NOW=$((T0 + 90)) wd 2)"
settle 3
[[ "$(cnt 'WATCHDOG (102 S9): c-952' "$T/sent")" == 2 ]] && pass "5 control: a changed pane is reported" || fail "5 s9 control: $out / $(cat "$T/sent")"
# input.log: a poke recorded 30 s ago -> no poke now; control: 120 s ago -> one poke
reset_box; agent c-953 %1 4053
echo "POKE m1.json age=200" > "$T/hit.c-953.s9"; echo '{}' > "$S/c-953/inbox/m1.json"
mkdir -p "$S/c-953/lifetime"; echo "$(iso $((T0 - 30))) task" > "$S/c-953/lifetime/input.log"
out="$(wd 1)"
[[ "$(cnt 'poke-only' "$T/sent")" == 0 ]] && grep -q 'a poke was recorded 30s ago' <<<"$out" &&
  pass "5 input.log: a poke recorded 30 s ago -> no poke" || fail "5 input.log: $out / $(cat "$T/sent" 2>/dev/null)"
echo "$(iso $((T0 - 120))) task" > "$S/c-953/lifetime/input.log"
out="$(NOW=$((T0 + 30)) wd 2)"
[[ "$(cnt 'poke-only --from c-001 --to c-953' "$T/sent")" == 1 ]] && pass "5 control: the last poke 150 s ago -> ONE poke" || fail "5 input.log control: $out / $(cat "$T/sent" 2>/dev/null)"

echo
if (( fails )); then echo "wd-multi-daemon: $fails FAILED"; exit 1; fi
echo "wd-multi-daemon: all passed"
