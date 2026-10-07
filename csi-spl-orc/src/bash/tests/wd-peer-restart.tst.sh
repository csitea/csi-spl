#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: watchdog peer supervision and the crontab starter of spec 102
#          10.4.1, 10.4.2 and 15.6 (T023b) in a sandbox. Nothing real is
#          touched: ps (the agent list), tmux, spool-send.sh, crontab and
#          ./run are stubs; a "peer" is either a real detached loop of the
#          stub ./run, or a fake one (a setsid flock holding run.<inst>.lock,
#          with a hand-written heartbeat).
#   1. WD_HUNG = max(3 * WD_TICK, 180): 180 at 10 s and 30 s, 270 at 90 s
#   2. healthy peers -> 0 restarts; a slow tick (started 120 s ago, progress
#      20 s ago) -> 0 kills; progress 170 s ago -> 0 kills
#   3. heartbeat frozen 200 s -> TERM, ROTATE_TERM_WAIT, KILL (it ignores
#      TERM), restarted from ./run under run.2.start.lock: a new pid with a
#      fresh heartbeat; the lock file is the same inode (never removed);
#      a second judge right after starts nothing
#   4. three real loops: healthy for 3 ticks -> 0 restarts (control); kill -9
#      instance 2 -> a peer restarts it within a few ticks, exactly once
#   5. the crontab starter do_spl_wd_inst_start: all 3 dead -> 3 started and
#      starter.last written; all 3 alive -> 0 started (control); code/good
#      is preferred over ./run when it is there (control: absent -> ./run)
#   6. disk full (the heartbeat write hits /dev/full): 0 peer kills, ONE
#      admin alert, debounced on the next tick; control: same peers, normal
#      disk -> the hung peer is restarted
#   7. suspend: own previous tick 200 s ago -> no peer verdict; control 30 s
#   8. crontab starter lines deleted -> a watchdog restores them (and drops
#      the 093 keeper line); control: lines intact -> crontab byte-identical;
#      DRY_RUN=1 only says it would
#   9. cron dead: starter.last 400 s old -> ONE alert (debounced); control:
#      30 s old -> none
#  10. do_spl_wd_ensure_install_cron (kind start): dry run writes nothing;
#      install writes the `* * * * *` and `@reboot` lines, drops wd-ensure,
#      keeps other lines; re-install changes no byte; check; remove; 8.1
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
command -v setsid >/dev/null || { echo "FAIL: setsid is required"; exit 1; }
S="$T/spool"; D="$S/dispatch"; W="$D/wd"
mkdir -p "$T/bin" "$T/cbin" "$T/sit" "$T/tmux" "$D" "$S/peer"
printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\nSPOOL_BOX_TAG=box1\nSPOOL_DESK_BOX=box1\n' "$(id -un)" "$(id -un)" > "$S/box.env"

# ---- stubs -------------------------------------------------------------------
: > "$T/ps"; : > "$T/tmux/panes"
printf '#!/usr/bin/env bash\ncat "%s/ps"\n' "$T" > "$T/bin/ps"
printf '#!/usr/bin/env bash\n[ "$1" = list-panes ] && cat "%s/tmux/panes"\nexit 0\n' "$T" > "$T/bin/tmux"
printf '#!/usr/bin/env bash\necho "send $*" >> "%s/sent"\n' "$T" > "$T/bin/send"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/sit/s1.sh"
# ./run, as spl_lease_detach starts it: the loop checks its peers only with CHILD_PEERS=1
cat > "$T/bin/run" <<'EOF'
#!/usr/bin/env bash
do_log() { echo "$*"; }
do_require_bin() { command -v "$1" >/dev/null; }
export WD_PEERS="${CHILD_PEERS:-0}"
source "$PROJ_PATH/src/bash/run/spl-watchdog.func.sh"
"$2"
EOF
# crontab, on PATH for every call here: a file
cat > "$T/cbin/crontab" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi
cp "$1" "$FAKE_CRONTAB"
EOF
chmod +x "$T/bin/"* "$T/cbin/"* "$T/sit/"*
# the checkout the starter lines point at (8.1: a git checkout with csi-spl-orc)
SH="$T/shared"; mkdir -p "$SH/csi-spl-orc"; git init -q "$SH"
printf '#!/bin/sh\n' > "$SH/csi-spl-orc/run"; chmod +x "$SH/csi-spl-orc/run"
export T FAKE_CRONTAB="$T/crontab"
: > "$T/crontab"

wd_env=(PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" LEASE_PROC_ROOT="$T/proc"
  PATH="$T/cbin:$PATH" WD_PS_CMD="$T/bin/ps" ROTATE_TMUX="$T/bin/tmux" WD_SEND="$T/bin/send" WD_TAKEOVER_CMD=true
  WD_SITUATIONS="$T/sit" LEASE_TRANSCRIPT_CMD=true WD_RUN="$T/bin/run" ROTATE_TERM_WAIT=1 ROTATE_BOX=box1
  DESK_CRON_SRC="$SH" WD_CRON_LOG_DIR="$T/log/wd" SPL_ORG_APP=csi-spl)
# judge <inst> [VAR=v...]: one tick of instance <inst> that checks its peers, under ./run's set -E + ERR trap
judge() {
  local i="$1"; shift
  env "${wd_env[@]}" WD_INST="$i" WD_PEERS=1 LEASE_NOW="$(date +%s)" WD_TICKS=1 WD_TICK=30 DRY_RUN=0 "$@" bash -c '
    set -E; trap "echo ERR-TRAP: \$BASH_COMMAND; exit 9" ERR
    do_log() { echo "$*"; }; do_require_bin() { command -v "$1" >/dev/null; }
    source "$PROJ_PATH/src/bash/run/spl-watchdog.func.sh"
    do_spl_watchdog' 2>&1
}
# starter [VAR=v...]: the crontab starter, as the cron line runs it
starter() {
  env "${wd_env[@]}" WD_TICK=2 "$@" bash -c '
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-wd-inst-start.func.sh"
    do_spl_wd_inst_start' 2>&1
}
held() { [[ -f "$1" ]] && ! flock -n "$1" true; }
cnt() { local n; n="$(grep -c -- "$1" "$2" 2>/dev/null)"; echo "${n:-0}"; }
pidof_inst() { cat "$W/run.$1.pid" 2>/dev/null || true; }
# fake_peer <inst> <progress age> [<tick age>] [term]: a live process group
# holding run.<inst>.lock, its pid file and heartbeat; "term" = ignores TERM
fake_peer() {
  local i="$1" age="$2" tick_age="${3:-$2}" now pid ign=""
  now="$(date +%s)"; mkdir -p "$W"
  [[ "${4:-}" == term ]] && ign='trap "" TERM;'
  setsid bash -c "$ign exec flock '$W/run.$i.lock' sleep 600" </dev/null >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 50); do held "$W/run.$i.lock" && break; sleep 0.1; done
  echo "$pid" > "$W/run.$i.pid"; touch -d "@$((now - age - 10))" "$W/run.$i.pid"
  printf '{"instance": %s, "pid": %s, "ts": %s, "tick_seq": 9, "tick_phase": "agents", "last_progress_ts": %s, "progress_seq": 40, "status": "ok", "git_sha": "x"}\n' \
    "$i" "$pid" "$((now - tick_age))" "$((now - age))" > "$W/heartbeat.$i.json"
  echo "$pid" >> "$T/fakes"
}
stop_all() {  # loops that check their peers start each other again: kill until all 3 locks are free
  local i p n
  for n in $(seq 1 20); do
    for i in 1 2 3; do
      p="$(pidof_inst "$i")"
      [[ "$p" =~ ^[0-9]+$ ]] && { kill -KILL -- "-$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null; }
    done
    while read -r p; do kill -KILL -- "-$p" 2>/dev/null; done < <(cat "$T/fakes" 2>/dev/null)
    sleep 0.2
    held "$W/run.1.lock" || held "$W/run.2.lock" || held "$W/run.3.lock" || break
  done
  : > "$T/fakes"
}
reset_box() { stop_all; rm -rf "$D" "$T/sent"; mkdir -p "$D"; : > "$T/crontab"; }
trap 'stop_all; rm -rf "$T"' EXIT
wait_new() {  # wait_new <inst> <tries of 0.1 s> <old pid>: a live new pid holding the lock
  local p
  for _ in $(seq 1 "${2:-100}"); do
    p="$(pidof_inst "$1")"
    [[ -n "$p" && "$p" != "$3" ]] && kill -0 "$p" 2>/dev/null && held "$W/run.$1.lock" && return 0
    sleep 0.1
  done
  return 1
}

# ---- 1. the hung floor ---------------------------------------------------------
hf() { bash -c 'do_log() { :; }; source "$1/src/bash/run/spl-wd-peers.func.sh"; WD_TICK=$2; spl_wd_peers_conf; echo "$WD_HUNG"' _ "$PROJ_ROOT" "$1"; }
[[ "$(hf 10) $(hf 30) $(hf 90)" == "180 180 270" ]] && pass "1 WD_HUNG = max(3 * WD_TICK, 180): 180, 180, 270" || fail "1 floor: $(hf 10) $(hf 30) $(hf 90)"

# ---- 2. healthy, slow and nearly-hung peers: 0 kills ---------------------------
reset_box; fake_peer 2 10; fake_peer 3 10
f2="$(pidof_inst 2)"; f3="$(pidof_inst 3)"
out="$(judge 1)"
[[ "$(cnt RESTART "$W/peers.log") $(cnt TERM "$W/peers.log")" == "0 0" ]] && kill -0 "$f2" "$f3" 2>/dev/null &&
  pass "2 control: healthy peers (progress 10 s ago) -> 0 restarts, 0 kills" || fail "2 healthy: $out / $(cat "$W/peers.log" 2>/dev/null)"
grep -q ERR-TRAP <<<"$out" && fail "2 the ERR trap fired: $out" || pass "2 the peer tick runs clean under set -E + ERR trap"
reset_box; fake_peer 2 20 120; fake_peer 3 170
f2="$(pidof_inst 2)"; f3="$(pidof_inst 3)"
out="$(judge 1)"
[[ "$(cnt RESTART "$W/peers.log")" == 0 ]] && kill -0 "$f2" "$f3" 2>/dev/null &&
  pass "2 a slow tick (started 120 s ago, progress 20 s ago) and progress 170 s ago -> 0 kills" || fail "2 slow: $out / $(cat "$W/peers.log" 2>/dev/null)"

# ---- 3. hung peer: TERM, wait, KILL, restart -------------------------------------
reset_box; fake_peer 2 200 200 term; fake_peer 3 10
f2="$(pidof_inst 2)"; ino="$(stat -c %i "$W/run.2.lock")"
out="$(judge 1)"
wait_new 2 50 "$f2" && n2="$(pidof_inst 2)" || n2=""
! kill -0 "$f2" 2>/dev/null && [[ -n "$n2" ]] &&
  [[ "$(cnt 'TERM instance 2' "$W/peers.log") $(cnt 'KILL instance 2' "$W/peers.log") $(cnt 'RESTART instance 2 (hung)' "$W/peers.log")" == "1 1 1" ]] &&
  pass "3 heartbeat frozen 200 s: TERM, ROTATE_TERM_WAIT, KILL (it ignored TERM), restarted (new pid $n2)" ||
  fail "3 hung: old alive=$(kill -0 "$f2" 2>/dev/null && echo yes || echo no) new='$n2' out=$out log=$(cat "$W/peers.log" 2>/dev/null)"
for _ in $(seq 1 50); do jq -e --argjson p "${n2:-0}" '.pid == $p' "$W/heartbeat.2.json" >/dev/null 2>&1 && break; sleep 0.1; done
jq -e --argjson p "${n2:-0}" --argjson t "$(( $(date +%s) - 30 ))" '.pid == $p and .last_progress_ts >= $t and .instance == 2' "$W/heartbeat.2.json" >/dev/null 2>&1 &&
  pass "3 the restarted instance 2 writes a fresh heartbeat" || fail "3 heartbeat: $(cat "$W/heartbeat.2.json" 2>/dev/null)"
[[ "$(stat -c %i "$W/run.2.lock")" == "$ino" ]] && ! held "$W/run.2.start.lock" &&
  pass "3 run.2.lock is the same file (never removed); run.2.start.lock released" || fail "3 lock inode $ino -> $(stat -c %i "$W/run.2.lock")"
kill -0 "$(pidof_inst 3)" 2>/dev/null && [[ "$(cnt 'instance 3' "$W/peers.log")" == 0 ]] && pass "3 the healthy peer 3 is left alone" || fail "3 peer 3: $(cat "$W/peers.log")"
out="$(judge 1)"
[[ "$(pidof_inst 2)" == "$n2" && "$(cnt RESTART "$W/peers.log")" == 1 ]] && pass "3 a second judge right after starts nothing" || fail "3 second judge: $out / $(cat "$W/peers.log")"

# ---- 4. three real loops: kill -9 instance 2 -------------------------------------
reset_box
starter CHILD_PEERS=1 >/dev/null
ok=1; for i in 1 2 3; do wait_new "$i" 50 none || ok=0; done
(( ok )) && pass "4 the starter starts 3 loops that check their peers" || fail "4 start: $(ls "$W")"
# the first loop may start a peer the starter has not reached yet (one start lock): settle first
sleep 3; : > "$W/peers.log"
sleep 6
[[ "$(cnt RESTART "$W/peers.log")" == 0 ]] && pass "4 control: 3 healthy loops for 3 ticks -> 0 restarts" || fail "4 healthy loops: $(cat "$W/peers.log")"
p2="$(pidof_inst 2)"; t0=$(date +%s)
kill -9 "$p2"
if wait_new 2 150 "$p2"; then
  n2="$(pidof_inst 2)"; dt=$(( $(date +%s) - t0 ))
  pass "4 kill -9 instance 2: a peer restarted it in ${dt}s (tick 2 s; its sleep child held the lock until TERMed)"
else fail "4 kill -9: not restarted: $(cat "$W/peers.log" 2>/dev/null)"; n2=""
fi
sleep 3
(( $(cnt 'RESTART instance 2' "$W/peers.log") <= 1 )) && [[ "$(pidof_inst 2)" == "$n2" ]] && kill -0 "$n2" 2>/dev/null &&
  pass "4 no second restart of instance 2 (two peers, one start lock): the new pid holds 3 s on" || fail "4 restarts: $(cat "$W/peers.log") / p2=$p2 n2=$n2 now=$(pidof_inst 2) / $(grep -h 'instance 2' "$W"/run.*.out | tail -8)"

# ---- 5. the crontab starter ---------------------------------------------------------
stop_all; rm -f "$W/starter.last"
out="$(starter)"
ok=1; for i in 1 2 3; do wait_new "$i" 50 none || ok=0; done
(( ok )) && [[ "$(grep -c 'started from' <<<"$out")" == 3 && "$(cat "$W/starter.last" 2>/dev/null)" =~ ^[0-9]+$ ]] &&
  pass "5 all 3 dead: the starter starts 3 and writes starter.last" || fail "5 starter: $out"
pids="$(pidof_inst 1) $(pidof_inst 2) $(pidof_inst 3)"
out="$(starter)"
[[ "$(grep -c 'started from' <<<"$out") $(grep -c ' runs (pid' <<<"$out")" == "0 3" && "$pids" == "$(pidof_inst 1) $(pidof_inst 2) $(pidof_inst 3)" ]] &&
  pass "5 control: all 3 alive -> the starter starts 0" || fail "5 control: $out"
[[ "$(cat "$W/starter.src")" == "$(cd "$PROJ_ROOT/.." && pwd)" ]] && pass "5 starter.src names the checkout it ran from" || fail "5 starter.src: $(cat "$W/starter.src" 2>/dev/null)"
stop_all
mkdir -p "$W/code/good/csi-spl-orc"
printf '#!/usr/bin/env bash\necho good >> "%s/good.log"\nexec "%s/bin/run" "$@"\n' "$T" "$T" > "$W/code/good/csi-spl-orc/run"
chmod +x "$W/code/good/csi-spl-orc/run"
out="$(starter WD_INSTANCES=2)"
wait_new 2 50 none && [[ "$(cnt good "$T/good.log")" == 1 && "$out" == *"started from $W/code/good/csi-spl-orc/run"* ]] &&
  pass "5 code/good is there: the instance starts from the snapshot" || fail "5 good: $out"
stop_all; rm -rf "$W/code"
out="$(starter WD_INSTANCES=2)"
wait_new 2 50 none && [[ "$(cnt good "$T/good.log")" == 1 && "$out" == *"started from $T/bin/run"* ]] &&
  pass "5 control: no code/good -> ./run" || fail "5 no good: $out"

# ---- 6. disk full -----------------------------------------------------------------
reset_box; fake_peer 2 200; fake_peer 3 10
f2="$(pidof_inst 2)"
out="$(judge 1 WD_HB_SINK=/dev/full)"
kill -0 "$f2" 2>/dev/null && [[ "$(cnt RESTART "$W/peers.log") $(cnt TERM "$W/peers.log")" == "0 0" ]] &&
  pass "6 disk full (heartbeat write ENOSPC): 0 peer kills" || fail "6 disk full kills: $out / $(cat "$W/peers.log")"
[[ "$(cnt '--kind blocker' "$T/sent")" == 1 && "$(cnt 'cannot write' "$T/sent")" == 1 ]] &&
  pass "6 disk full: ONE admin alert (blocker to the orchestrator)" || fail "6 alert: $(cat "$T/sent" 2>/dev/null)"
grep -q 'HEARTBEAT instance 1 cannot write' "$D/wd.log" 2>/dev/null && pass "6 the failed heartbeat write is logged" || fail "6 wd.log: $(cat "$D/wd.log" 2>/dev/null)"
out="$(judge 1 WD_HB_SINK=/dev/full)"
[[ "$(cnt '--kind blocker' "$T/sent")" == 1 ]] && kill -0 "$f2" 2>/dev/null && pass "6 the next tick: no second alert (debounced), still 0 kills" || fail "6 debounce: $(cat "$T/sent")"
out="$(judge 1)"
wait_new 2 50 "$f2" && [[ "$(cnt 'RESTART instance 2 (hung)' "$W/peers.log")" == 1 ]] &&
  pass "6 control: the same peers on a normal disk -> the hung peer is restarted" || fail "6 control: $out / $(cat "$W/peers.log") / $(tail -5 "$W/run.2.out" 2>/dev/null)"

# ---- 7. suspend ---------------------------------------------------------------------
reset_box; fake_peer 2 200; mkdir -p "$W"; echo $(( $(date +%s) - 200 )) > "$W/last.tick.1"
f2="$(pidof_inst 2)"
out="$(judge 1)"
kill -0 "$f2" 2>/dev/null && [[ "$(cnt RESTART "$W/peers.log")" == 0 ]] && grep -q 'ticked 200s ago' "$W/peers.log" &&
  pass "7 own previous tick 200 s ago (suspend): no peer verdict, 0 kills" || fail "7 suspend: $out / $(cat "$W/peers.log" 2>/dev/null)"
echo $(( $(date +%s) - 30 )) > "$W/last.tick.1"
out="$(judge 1)"
[[ "$(cnt 'RESTART instance 2 (hung)' "$W/peers.log")" == 1 ]] && pass "7 control: previous tick 30 s ago -> the hung peer is restarted" || fail "7 control: $out / $(cat "$W/peers.log")"

# ---- 8. the crontab line restored ----------------------------------------------------
reset_box; fake_peer 2 10; fake_peer 3 10
start_line="* * * * * PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin $SH/csi-spl-orc/run -a do_spl_wd_inst_start >> $T/log/wd/starter.out 2>&1 # csi-spl:wd-start"
boot_line="@reboot PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin $SH/csi-spl-orc/run -a do_spl_wd_inst_start >> $T/log/wd/starter.out 2>&1 # csi-spl:wd-start-boot"
printf '# keep me\n0 1 * * * %s/csi-spl-orc/run -a do_x # csi-spl:x\n* * * * * %s/csi-spl-orc/run -a do_spl_wd_ensure # csi-spl:wd-ensure\n' "$SH" "$SH" > "$T/crontab"
cp "$T/crontab" "$T/crontab.0"
out="$(judge 1 DRY_RUN=1)"
cmp -s "$T/crontab" "$T/crontab.0" && grep -q 'DRY_RUN would restore the crontab starter' "$W/peers.log" &&
  pass "8 DRY_RUN=1: the watchdog only says it would restore the line" || fail "8 dry: $out / $(cat "$W/peers.log" 2>/dev/null)"
out="$(judge 1)"
[[ "$(grep -F -x -c "$start_line" "$T/crontab") $(grep -F -x -c "$boot_line" "$T/crontab") $(cnt 'wd-ensure$' "$T/crontab")" == "1 1 0" ]] &&
  [[ "$(head -2 "$T/crontab")" == "$(head -2 "$T/crontab.0")" ]] && grep -q 'CRON restored the crontab starter' "$W/peers.log" &&
  pass "8 starter lines deleted: the watchdog restores both, drops the 093 keeper line, keeps the others" ||
  fail "8 restore: $out / $(cat "$W/peers.log" 2>/dev/null) / $(cat "$T/crontab")"
cp "$T/crontab" "$T/crontab.1"; n0="$(cnt CRON "$W/peers.log")"
out="$(judge 1)"
cmp -s "$T/crontab" "$T/crontab.1" && [[ "$(cnt CRON "$W/peers.log")" == "$n0" ]] &&
  pass "8 control: lines intact -> the crontab is byte-identical, nothing done" || fail "8 control: $(diff "$T/crontab.1" "$T/crontab")"

# ---- 9. cron dead ----------------------------------------------------------------------
reset_box; fake_peer 2 10; fake_peer 3 10; cp "$T/crontab.1" "$T/crontab"
echo $(( $(date +%s) - 30 )) > "$W/starter.last"
out="$(judge 1)"
[[ "$(cnt 'crontab starter has not run' "$T/sent")" == 0 ]] && pass "9 control: the starter ran 30 s ago -> no alert" || fail "9 control: $(cat "$T/sent" 2>/dev/null)"
echo $(( $(date +%s) - 400 )) > "$W/starter.last"
out="$(judge 1)"
[[ "$(cnt 'crontab starter has not run' "$T/sent")" == 1 && "$(cnt '--kind blocker' "$T/sent")" == 1 ]] &&
  pass "9 starter.last 400 s old while the watchdogs run: ONE alert (cron dead)" || fail "9 alert: $out / $(cat "$T/sent" 2>/dev/null)"
out="$(judge 1)"
[[ "$(cnt 'crontab starter has not run' "$T/sent")" == 1 ]] && pass "9 the next tick: debounced, no second alert" || fail "9 debounce: $(cat "$T/sent")"

# ---- 10. the installer, kind start ----------------------------------------------------
stop_all
inst() { env "${wd_env[@]}" "$@" bash -c 'do_log() { echo "$*"; }; do_require_bin() { command -v "$1" >/dev/null; }
  source "$PROJ_PATH/src/bash/run/spl-wd-ensure-install-cron.func.sh"; do_spl_wd_ensure_install_cron' 2>&1; }
cp "$T/crontab.0" "$T/crontab"
out="$(inst)"; rc=$?
[[ $rc -eq 0 && "$out" == *"+$start_line"* && "$out" == *"+$boot_line"* && "$out" == *"OK 8.1 2 command line(s), 0 failing"* ]] && cmp -s "$T/crontab" "$T/crontab.0" &&
  pass "10 dry run: both starter lines in the diff, 8.1 on them, nothing written" || fail "10 dry rc=$rc: $out"
out="$(inst DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 ]] && cmp -s "$T/crontab" "$T/crontab.1" && pass "10 install = what the watchdog restored (2 lines, no wd-ensure)" || fail "10 install rc=$rc: $out / $(diff "$T/crontab.1" "$T/crontab")"
out="$(inst DRY_RUN=0)"; cmp -s "$T/crontab" "$T/crontab.1" && pass "10 a re-install changes no byte" || fail "10 reinstall: $(diff "$T/crontab.1" "$T/crontab")"
out="$(inst WD_CRON_ACTION=check)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK wd-start is installed"* ]] && pass "10 check: OK" || fail "10 check rc=$rc: $out"
out="$(inst DRY_RUN=0 CRON_REMOVE=1)"; rc=$?
[[ $rc -eq 0 && "$(cnt 'wd-start' "$T/crontab")" == 0 && "$(head -2 "$T/crontab")" == "$(head -2 "$T/crontab.0")" ]] &&
  pass "10 remove takes both starter lines out, keeps the others" || fail "10 remove rc=$rc: $(cat "$T/crontab")"
out="$(inst WD_CRON_ACTION=check)"; rc=$?
[[ $rc -eq 1 && "$out" == *"NOT installed"* ]] && pass "10 check after remove: FAIL, exit 1" || fail "10 check none rc=$rc: $out"
out="$(inst WD_ENSURE_WATCH_DRY=1)"
[[ "$out" == *"+* * * * * PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin WD_INST_DRY=1 $SH/csi-spl-orc/run -a do_spl_wd_inst_start"* ]] &&
  pass "10 observe-only: the starter lines carry WD_INST_DRY=1" || fail "10 observe: $out"
out="$(inst WD_CRON_KIND=nope)"; rc=$?
[[ $rc -eq 1 && "$out" == *"WD_CRON_KIND must be start or ensure"* ]] && pass "10 an unknown WD_CRON_KIND is refused" || fail "10 kind rc=$rc: $out"

echo
if (( fails )); then echo "wd-peer-restart: $fails FAILED"; exit 1; fi
echo "wd-peer-restart: all passed"
