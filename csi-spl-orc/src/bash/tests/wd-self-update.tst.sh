#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: watchdog self-update on desk-cron changes (spec 102 10.4.4, WD3,
#          T025) in a sandbox. The "desk-cron checkout" is a scratch git
#          repo holding this tree's watchdog code under csi-spl-orc/ with a
#          stub ./run (set -u, pipefail, set -E + an ERR trap that ends the
#          loop, as ./run does) and its own situation script; ps, tmux,
#          spool-send.sh, crontab and the restart are stubs; the 3 loops are
#          real detached processes, started by the crontab starter, checking
#          their peers. Each commit below is a real commit in that repo.
#   1. units: update.state parse (a torn line is no rollout); the sliced sleep
#      ends on the baton and on a quarantined sha (control: neither -> the
#      full sleep); prune keeps good, candidate and the running shas
#      (control: an old unused snapshot goes); WD_SELF_UPDATE=0 and the 093
#      loop (no WD_INST) never touch code/; DRY_RUN=1 only says "would";
#      quorum: a dead peer defers the rollout with ONE alert (control: all
#      alive -> no defer); the self-check tick waits for a peer's judge lock
#      (control: an ordinary tick skips); a dead instance restarts from code/good while a
#      candidate is out (never the candidate); the self-check verdict is the
#      tick's result: a correct tick past WD_UPD_CHECK_MAX (a loaded box)
#      passes, a tick with a script error fails (control), the first tick
#      after an exec measures its gap from the exec, so a slow pre-flight is
#      no resume (control: an ordinary tick from its last), a check is timed
#      from its own tick start (an older exec's T0 before its pre-flight is
#      ignored); a step TIMEOUT is retried (SPL-4434), a failed check is not,
#      the own tick and a peer time the step by the same window (since), a
#      crashed instance whose pid is gone is quarantined at once, try=08 is a
#      garbled line:
#      a green tick past the hang bound WD_UPD_STEP_MAX checks again on the
#      next tick and passes there; past it on every try (WD_UPD_STEP_TRIES)
#      it is quarantined; a script error on a slow tick is quarantined at
#      once; a check that never ends gets a second window from a peer, the
#      load in its line, and is quarantined by a peer after the last; a tick
#      a peer gave a second window ends green inside it; a boot pass (the pre-flight
#      proof tick after a boot) reads the expected seats and stats the
#      verdicts once (control: the old helpers, per registry id; SPL-1992)
#   2. bootstrap: no code/good -> instance 1 snapshots the sha it runs, good
#      := it, nothing restarts
#   3. a desk-cron commit that changes csi-spl-orc -> rolling restart
#      1 -> 2 -> 3 (EXEC lines in that order, each self-check tick green),
#      DONE in < 70 s, instance 1's check time is its own tick (not the
#      pre-flight before its exec), all 3 heartbeats on the new sha, the same 3 pids
#      (exec, not restart), never fewer than 2 live instances (sampled
#      every 0.2 s), good := new sha, no candidate, no update.state
#   4. control: a commit outside csi-spl-orc -> good moves, no EXEC
#   5. bad commit (./run exits non-zero) -> pre-flight fails, quarantined
#      (code/<sha>.bad), ONE alert, no instance execs, good unchanged; never
#      retried on later ticks
#   6. a commit that passes the pre-flight but whose watchdog code errors
#      in a loop instance -> instance 1 execs, fails its self-check tick,
#      execs back into good; instances 2 and 3 never run it; alert
#   7. a commit that crashes instance 1 right after its exec -> a peer
#      starts instance 1 again from good, which ends the rollout
#      (quarantine + alert); 2 and 3 never run it; all 3 end on good
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
for b in jq setsid git flock; do command -v "$b" >/dev/null || { echo "FAIL: $b is required"; exit 1; }; done
S="$T/spool"; D="$S/dispatch"; W="$D/wd"; LOG="$D/wd.log"
mkdir -p "$T/bin" "$T/cbin" "$T/tmux" "$D" "$S/peer" "$T/proc"
printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\nSPOOL_BOX_TAG=box1\nSPOOL_DESK_BOX=box1\n' "$(id -un)" "$(id -un)" > "$S/box.env"
# 30 = the live tick (the dev drill); 5 keeps CI short. The loops wait out
# whole ticks (a commit is seen at instance 1's next tick start), so the tick
# is most of the file's idle time (round 1 row 10, PC, n=3: 130..141 s at
# 10, 54..62 s at 5 with WD_UPD_SLICE=1 and the seat memo of the boot pass).
# At 5 the judge window (WD_TICK - 5) is 0: every instance judges c-901.
# WT, the tick the wait caps below are sized for, stays 10 at a shorter
# tick: a cap only bounds a wait, it costs nothing on green.
TICK="${WD_UPD_TEST_TICK:-5}" WT="${WD_UPD_TEST_TICK:-5}"
(( WT < 10 )) && WT=10
WAIT_S=60 WAIT_N=600

# ---- stubs -------------------------------------------------------------------
: > "$T/ps"; : > "$T/tmux/panes"
printf '#!/usr/bin/env bash\ncat "%s/ps"\n' "$T" > "$T/bin/ps"
cat > "$T/bin/tmux" <<'EOF'
#!/usr/bin/env bash
cmd="$1"; shift; tgt=""
while [ $# -gt 0 ]; do case "$1" in -t) tgt="$2"; shift 2 ;; -F) shift 2 ;; *) shift ;; esac; done
case "$cmd" in
  list-panes) cat "$T/tmux/panes" ;;
  capture-pane) cat "$T/tmux/screen.$tgt" 2>/dev/null || exit 1 ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\necho "send $*" >> "%s/sent"\n' "$T" > "$T/bin/send"
cat > "$T/cbin/crontab" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi
cp "$1" "$FAKE_CRONTAB"
EOF
chmod +x "$T/bin/"* "$T/cbin/"*
# one healthy agent: a window, a live claude process, a pane
mkdir -p "$S/c-901/inbox" "$T/proc/7001"
printf '%%1\t6001\t$1\tc-901@box1 a lane\tsh\n' >> "$T/tmux/panes"
printf '6001 1 3600 sh\n7001 6001 3600 claude\n' >> "$T/ps"
printf 'SPOOL_AGENT_ID=c-901\0' > "$T/proc/7001/environ"
printf 'working on the brief\n' > "$T/tmux/screen.%1"

# ---- the desk-cron checkout --------------------------------------------------
DC="$T/desk-cron"; O="$DC/csi-spl-orc"
mkdir -p "$O/src/bash/features" "$O/lib/bash" "$O/sit"
cp -r "$PROJ_ROOT/src/bash/run" "$O/src/bash/"
cp -r "$PROJ_ROOT/src/bash/features/spawn-agents" "$PROJ_ROOT/src/bash/features/watchdog" "$O/src/bash/features/"
cp -r "$PROJ_ROOT/lib/bash/funcs" "$O/lib/bash/"
# the ./run every snapshot carries: its own code, its own situation scripts
cat > "$O/run" <<'EOF'
#!/usr/bin/env bash
set -E -u -o pipefail
trap 'echo "ERR-TRAP: $BASH_COMMAND" >&2; exit 9' ERR
do_log() { echo "$*"; }
do_require_bin() { command -v "$1" >/dev/null; }
PROJ_PATH="$(cd "$(dirname "$0")" && pwd)"
export PROJ_PATH WD_SITUATIONS="$PROJ_PATH/sit" WD_PEERS="${CHILD_PEERS:-0}"
source "$PROJ_PATH/src/bash/run/spl-watchdog.func.sh"
"$2"
EOF
printf '#!/usr/bin/env bash\n# v1\nexit 0\n' > "$O/sit/s1.sh"
chmod +x "$O/run" "$O/sit/s1.sh"
echo "the desk-cron checkout" > "$DC/README.md"
dc() { git -C "$DC" -c user.name=t -c user.email=t@example.com "$@"; }
git init -q "$DC"; dc add -A; dc commit -qm A
commit() { dc add -A; dc commit -qm "$1"; dc rev-parse HEAD; }

export T FAKE_CRONTAB="$T/crontab"
: > "$T/crontab"
wd_env=(SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" LEASE_PROC_ROOT="$T/proc" PATH="$T/cbin:$PATH"
  WD_PS_CMD="$T/bin/ps" ROTATE_TMUX="$T/bin/tmux" WD_SEND="$T/bin/send" WD_TAKEOVER_CMD=true
  LEASE_TRANSCRIPT_CMD=true WD_RUN="$O/run" ROTATE_TERM_WAIT=1 ROTATE_BOX=box1
  DESK_CRON_SRC="$DC" WD_CRON_LOG_DIR="$T/log/wd" SPL_ORG_APP=csi-spl WD_INST_START_WAIT="$WAIT_S"
  WD_SELF_UPDATE=1 WD_TICK="$TICK" WD_UPD_SLICE=1 CHILD_PEERS=1)
starter() {
  env "${wd_env[@]}" PROJ_PATH="$O" bash -c '
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-wd-inst-start.func.sh"
    do_spl_wd_inst_start' 2>&1
}
# lib <snippet>: the self-update functions of this tree in a fresh shell, WD_DIR set
lib() {
  env "${wd_env[@]}" PROJ_PATH="$PROJ_ROOT" WD_PEERS=0 SNIP="$1" "${@:2}" bash -c '
    set -E -u -o pipefail; trap "echo ERR-TRAP: \$BASH_COMMAND; exit 9" ERR
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-watchdog.func.sh"
    spl_wd_init >/dev/null || exit 1
    eval "$SNIP"' 2>&1
}
held() { [[ -f "$1" ]] && ! flock -n "$1" true; }
live() { local n=0 i; for i in 1 2 3; do held "$W/run.$i.lock" && n=$((n + 1)); done; echo "$n"; }
# on_good <seconds>: every heartbeat on SHA_C or SHA_D: after 4 the two
# carry the same csi-spl-orc, so an instance on C is on good code
on_good() {
  local i j ok
  for (( j = 0; j < $1 * 5; j++ )); do
    ok=1
    for i in 1 2 3; do [[ "$(hb_sha "$i")" == "${SHA_C:0:9}" || "$(hb_sha "$i")" == "${SHA_D:0:9}" ]] || ok=0; done
    (( ok )) && return 0
    sleep 0.2
  done
  return 1
}
# alive <n> <seconds>: n instances whose run.<inst>.pid is a live process
# (no lock probe: a probe holds a free lock for an instant, and a loop a
# peer is starting in that instant exits "already runs")
alive() {
  local i j c
  for (( j = 0; j < $2 * 5; j++ )); do
    c=0; for i in 1 2 3; do kill -0 "$(cat "$W/run.$i.pid" 2>/dev/null || echo 0)" 2>/dev/null && c=$((c + 1)); done
    (( c == $1 )) && return 0
    sleep 0.2
  done
  return 1
}
pids() { cat "$W/run.1.pid" "$W/run.2.pid" "$W/run.3.pid" 2>/dev/null | tr '\n' ' '; }
hb_sha() { jq -r '.git_sha' "$W/heartbeat.$1.json" 2>/dev/null; }
cnt() { local n; n="$(grep -cE -- "$1" "$2" 2>/dev/null)"; echo "${n:-0}"; }
link() { basename "$(readlink "$W/code/$1" 2>/dev/null)" 2>/dev/null; }
# wait_for <regex> <seconds>: a wd.log line
wait_for() {
  local i
  for (( i = 0; i < $2 * 5; i++ )); do grep -qE -- "$1" "$LOG" 2>/dev/null && return 0; sleep 0.2; done
  return 1
}
# sent_once <regex>: exactly one alert matches, once the send that follows
# the wd.log line has landed (up to 10 s)
sent_once() {
  local i
  for (( i = 0; i < 50; i++ )); do [[ "$(cnt "$1" "$T/sent")" -ge 1 ]] && break; sleep 0.2; done
  [[ "$(cnt "$1" "$T/sent")" == 1 ]]
}
# all_on <sha> <seconds>: the 3 heartbeats on <sha>
all_on() {
  local i
  for (( i = 0; i < $2 * 5; i++ )); do
    [[ "$(hb_sha 1)" == "${1:0:9}" && "$(hb_sha 2)" == "${1:0:9}" && "$(hb_sha 3)" == "${1:0:9}" ]] && return 0
    sleep 0.2
  done
  return 1
}
sandbox_pids() { grep -lzxF -- "SPOOL_ROOT=$S" /proc/[0-9]*/environ 2>/dev/null | cut -d/ -f3; }
stop_all() {
  local p
  for _ in $(seq 1 "$WAIT_N"); do
    p="$(sandbox_pids)"
    # shellcheck disable=SC2086 # one pid per word
    [[ -n "$p" ]] && kill -KILL $p 2>/dev/null
    [[ -z "$p" ]] && ! held "$W/run.1.lock" && ! held "$W/run.2.lock" && ! held "$W/run.3.lock" && break
    sleep 0.1
  done
}
trap 'stop_all; rm -rf "$T"' EXIT

# ---- 1. units ------------------------------------------------------------------
SHA_A="$(dc rev-parse HEAD)"
mkdir -p "$W/code"
out="$(lib "set -- $SHA_A; "'echo "sha=$1 next=2 stage=wait pid=0 since=5 start=4" > "$WD_DIR/update.state"; spl_wd_upd_state_read && echo "R $U_NEXT $U_STAGE $U_SINCE $U_START"
  echo "sha=$1 next=2 stage=wa" > "$WD_DIR/update.state"; spl_wd_upd_state_read || echo TORN; rm -f "$WD_DIR/update.state"')"
[[ "$out" == *"R 2 wait 5 4"* && "$out" == *TORN* ]] && pass "1 update.state parsed; a torn line is no rollout" || fail "1 state: $out"
# SPL-4434 N3: try=08 passed ^[0-9]+$, then broke the arithmetic ("value too
# great for base") on every peer tick; a leading zero is a garbled line now
out="$(lib "set -- $SHA_A; "'for t in 08 8 0; do echo "sha=$1 next=1 stage=exec pid=$$ since=5 start=4 try=$t" > "$WD_DIR/update.state"; spl_wd_upd_state_read && echo "T$t read $U_TRY" || echo "T$t garbled"; done; rm -f "$WD_DIR/update.state"')"
[[ "$out" == *"T08 garbled"* && "$out" == *"T8 read 8"* && "$out" == *"T0 read 0"* ]] &&
  pass "1 try=08 (a leading zero) is a garbled update.state, not an arithmetic error; try=8 and try=0 read" || fail "1 try leading zero: $out"

out="$(lib 'echo "sha=x next=2 stage=wait pid=0 since=1 start=1" > "$WD_DIR/update.state"; s=$(date +%s); spl_wd_upd_sleep 20; echo "SLEPT $(( $(date +%s) - s ))"; rm -f "$WD_DIR/update.state"' WD_INST=2 WD_UPD_SLICE=1)"
n="$(sed -n 's/.*SLEPT //p' <<<"$out")"
[[ "$n" =~ ^[0-9]+$ ]] && (( n <= 2 )) && pass "1 sliced sleep ends on the baton (${n}s of 20)" || fail "1 sleep baton: $out"
out="$(lib 'touch "$WD_DIR/code/$WD_CODE_SHA.bad"; s=$(date +%s); spl_wd_upd_sleep 20; echo "SLEPT $(( $(date +%s) - s ))"; rm -f "$WD_DIR/code/$WD_CODE_SHA.bad"' WD_INST=3 WD_UPD_SLICE=1)"
n="$(sed -n 's/.*SLEPT //p' <<<"$out")"
[[ "$n" =~ ^[0-9]+$ ]] && (( n <= 2 )) && pass "1 sliced sleep ends on a quarantined sha (${n}s of 20)" || fail "1 sleep bad: $out"
out="$(lib 'echo "sha=x next=3 stage=wait pid=0 since=1 start=1" > "$WD_DIR/update.state"; s=$(date +%s); spl_wd_upd_sleep 3; echo "SLEPT $(( $(date +%s) - s ))"; rm -f "$WD_DIR/update.state"' WD_INST=2 WD_UPD_SLICE=1)"
n="$(sed -n 's/.*SLEPT //p' <<<"$out")"
[[ "$n" =~ ^[0-9]+$ ]] && (( n >= 3 )) && pass "1 control: the baton names another instance -> the full sleep (${n}s)" || fail "1 sleep control: $out"

P1=1111111111111111111111111111111111111111 P2=2222222222222222222222222222222222222222 P3=3333333333333333333333333333333333333333 P4=4444444444444444444444444444444444444444 P5=5555555555555555555555555555555555555555
for s in $P1 $P2 $P3 $P4 $P5; do mkdir -p "$W/code/$s"; echo "$s" > "$W/code/$s/.sha"; done
touch -d '-5 hours' "$W/code/$P1"; touch -d '-4 hours' "$W/code/$P2"; touch -d '-3 hours' "$W/code/$P3"
ln -sfn "$P1" "$W/code/good"; ln -sfn "$P2" "$W/code/candidate"
printf '{"git_sha": "%s"}\n' "${P3:0:9}" > "$W/heartbeat.2.json"
out="$(lib 'spl_wd_upd_prune; ls "$WD_DIR/code"' WD_UPD_KEEP=3)"
[[ -d "$W/code/$P1" && -d "$W/code/$P2" && -d "$W/code/$P3" ]] && pass "1 prune keeps good, candidate and a running sha" || fail "1 prune keep: $out"
# 4 kept (good, candidate, running, this tree's own sha may not be a dir): P4 / P5 are the newest unused
kept=0; for s in $P4 $P5; do [[ -d "$W/code/$s" ]] && kept=$((kept + 1)); done
(( kept < 2 )) && pass "1 control: unused snapshots past WD_UPD_KEEP go ($kept of 2 left)" || fail "1 prune drop: $(ls "$W/code")"
rm -rf "$W/code" "$W/heartbeat.2.json"

out="$(lib 'spl_wd_self_update "$(date +%s)"; ls "$WD_DIR/code" 2>/dev/null | wc -l' WD_INST=1 WD_SELF_UPDATE=0)"
[[ ! -e "$W/code/good" ]] && pass "1 WD_SELF_UPDATE=0: code/ untouched" || fail "1 off: $out"
out="$(lib 'spl_wd_self_update "$(date +%s)"' WD_INST= )"
[[ ! -e "$W/code/good" ]] && pass "1 the 093 loop (no WD_INST) never self-updates" || fail "1 093: $out"
# DRY_RUN=1: good is made (a snapshot of what runs), the rollout only "would"
SHA_B="$(echo '# v2' >> "$O/sit/s1.sh"; commit B)"
out="$(lib "WD_CODE_SHA=$SHA_A; "'spl_wd_self_update "$(date +%s)"; echo "rc=$?"' WD_INST=1 DRY_RUN=1)"
[[ "$out" == *"DRY_RUN would roll out ${SHA_B:0:9}"* && "$(link good)" == "$SHA_A" && ! -e "$W/update.state" ]] &&
  pass "1 DRY_RUN=1: good := the running sha, the rollout only 'would'" || fail "1 dry: $out / good $(link good)"
# quorum: peers 2 and 3 dead -> DEFER + ONE alert, nothing execs
: > "$T/sent"
out="$(lib "WD_CODE_SHA=$SHA_A; "'spl_wd_self_update "$(date +%s)"; spl_wd_self_update "$(date +%s)"' WD_INST=1 DRY_RUN=0)"
[[ "$(cnt "DEFER ${SHA_B:0:9}" "$LOG")" -ge 1 && "$(cnt 'waits: instance 2' "$T/sent")" == 1 && ! -e "$W/update.state" && "$out" != *EXEC* ]] &&
  pass "1 quorum: dead peers -> deferred, ONE alert (debounced), no exec" || fail "1 quorum: $out / $(cat "$T/sent")"
# a dead instance starts from code/good while a candidate is out
mkdir -p "$W/code/$SHA_B/csi-spl-orc"; ln -sfn "$SHA_B" "$W/code/candidate"
out="$(lib 'spl_wd_inst_runner "$WD_DIR"')"
[[ "$out" == "$W/code/good/csi-spl-orc/run" ]] && pass "1 a (re)started instance runs code/good, never the candidate" || fail "1 runner: $out"
# the self-check tick waits out a peer's judge lock (it must judge 1 agent);
# control: an ordinary tick skips the held agent at once
jl='if flock -n 6; then echo FREE; elif spl_wd_upd_lock_wait 6; then echo WAITED; else echo SKIPPED; fi'
flock "$W/c-901.judge.lock" sleep 2 & JH=$!; sleep 0.3
out="$(lib 'WD_UPD_EXEC=x WD_UPD_ROLE=forward; exec 6>>"$WD_DIR/c-901.judge.lock"; '"$jl")"
wait "$JH"
[[ "$out" == *WAITED* ]] && pass "1 the self-check tick waits for a peer's judge lock" || fail "1 lock wait: $out"
flock "$W/c-901.judge.lock" sleep 2 & JH=$!; sleep 0.3
out="$(lib 'exec 6>>"$WD_DIR/c-901.judge.lock"; '"$jl")"
wait "$JH"
[[ "$out" == *SKIPPED* ]] && pass "1 control: an ordinary tick skips an agent a peer judges" || fail "1 lock control: $out"
# the first tick after an exec measures its gap from the exec, not from the
# tick before the pre-flight: a slow pre-flight (a loaded box) read as a
# resume skipped every agent, and the self-check judged nothing (SPL-3332);
# control: an ordinary tick keeps its last tick start, a real gap stays a resume
gap='n=$(spl_lease_now); echo "BASE $(( n - $(spl_wd_upd_last $(( n - 60 ))) ))"'
out="$(lib 'WD_UPD_EXEC=x WD_UPD_ROLE=forward WD_UPD_T0=$(( $(spl_lease_now) - 1 )); '"$gap" LEASE_NOW=2000000000)"
[[ "$out" == *"BASE 1"* ]] && pass "1 the first tick after an exec measures its gap from the exec (1 s, not 60 s)" || fail "1 exec gap: $out"
out="$(lib "$gap" LEASE_NOW=2000000000 WD_UPD_T0=1999999999)"
[[ "$out" == *"BASE 60"* ]] && pass "1 control: an ordinary tick measures its gap from its last tick (60 s)" || fail "1 gap control: $out"
# the self-check verdict: by the tick's result, not its wall time (a loaded
# box ran correct check ticks in 24..26 s against the old 20 s limit).
# chk: instance 1's first tick on X ended AGO s after its exec; the state
# afterwards and code/X.bad say the verdict. No sleeps: T0 is set back, and
# the clock is pinned (LEASE_NOW): a second boundary between n and the
# verdict read 'green in 6s' for 5 (gate 10 run 37975966358)
X=9999999999999999999999999999999999999999
chk='export LEASE_NOW="${LEASE_NOW:-$(date +%s)}"; mkdir -p "$WD_DIR/tick.u"; echo "${ERRLINE:-}" > "$WD_DIR/tick.u/err"; echo "c-901 ok" > "$WD_DIR/tick.u/out.c-901"
  WD_INST=1; WD_CODE_SHA=$X; n=$(spl_lease_now); echo "sha=$X next=1 stage=exec pid=$$ since=$(( n - ${SINCE:-0} )) start=$n${TRY:+ try=$TRY}" > "$WD_DIR/update.state"
  WD_UPD_EXEC=$X WD_UPD_ROLE=forward WD_UPD_T0=$(( n - AGO )); spl_wd_upd_checked "$WD_DIR/tick.u" ${TSTART:+$(( n - TSTART ))}
  echo "STATE $(cat "$WD_DIR/update.state" 2>/dev/null || true)"; echo "BAD $(cat "$WD_DIR/code/$X.bad" 2>/dev/null || true)"; rm -f "$WD_DIR/code/$X.bad" "$WD_DIR/update.state"'
out="$(lib "$chk" X=$X AGO=30 DRY_RUN=1 WD_UPD_CHECK_MAX=20 WD_UPD_STEP_MAX=45)"
[[ "$out" == *"STATE sha=$X next=2 stage=wait"* ]] && grep -qx 'BAD ' <<<"$out" && grep -q "on ${X:0:9}: self-check tick green in 30s" "$LOG" &&
  pass "1 a correct self-check tick of 30 s (limit 20, a loaded box) is green: baton -> 2" || fail "1 slow green: $out"
out="$(lib "$chk" X=$X AGO=1 ERRLINE="s1.sh: line 3: nosuchcmd: command not found" DRY_RUN=1)"
[[ "$out" == *"BAD instance 1 failed its self-check tick: script errors"* ]] && grep -qx 'STATE ' <<<"$out" &&
  pass "1 control: a fast tick with a script error is red, quarantined" || fail "1 broken: $out"
# SPL-4434 (a desk box 2026-10-24..30: 4 commits quarantined at the 45 s
# step bound, one touching no watchdog code, load 49 on 16 cpus): a step
# that only TIMES OUT is retried; a failed check is not. chk2: the first
# check tick ends AGO s after the step began (since), the next one
# (re-armed by the code, not by the test) AGO2 s into its new window.
chk2='export LEASE_NOW="${LEASE_NOW:-$(date +%s)}"; mkdir -p "$WD_DIR/tick.u"; echo "${ERRLINE:-}" > "$WD_DIR/tick.u/err"; echo "c-901 ok" > "$WD_DIR/tick.u/out.c-901"
  WD_INST=1; WD_CODE_SHA=$X; n=$(spl_lease_now); echo "sha=$X next=1 stage=exec pid=$$ since=$(( n - AGO )) start=$n" > "$WD_DIR/update.state"
  WD_UPD_EXEC=$X WD_UPD_ROLE=forward; spl_wd_upd_checked "$WD_DIR/tick.u" $(( n - AGO ))
  echo "STATE1 $(cat "$WD_DIR/update.state" 2>/dev/null || true)"; echo "BAD1 $(cat "$WD_DIR/code/$X.bad" 2>/dev/null || true)"; echo "REARMED ${WD_UPD_EXEC:-none}"
  [[ -n "${WD_UPD_EXEC:-}" ]] && sed -i "s/ since=[0-9]* / since=$(( n - AGO2 )) /" "$WD_DIR/update.state" && spl_wd_upd_checked "$WD_DIR/tick.u" $(( n - AGO2 ))
  echo "STATE2 $(cat "$WD_DIR/update.state" 2>/dev/null || true)"; echo "BAD2 $(cat "$WD_DIR/code/$X.bad" 2>/dev/null || true)"; rm -f "$WD_DIR/code/$X.bad" "$WD_DIR/update.state"'
: > "$LOG"
out="$(lib "$chk2" X=$X AGO=60 AGO2=5 LEASE_NOW=2000000000 DRY_RUN=1 WD_UPD_STEP_MAX=45 WD_TICK=30 WD_UPD_LOAD1=49 WD_UPD_NPROC=16)"
[[ "$out" == *"STATE1 sha=$X next=1 stage=exec pid="*" since=2000000030 start=2000000000 try=1"* && "$out" == *"REARMED $X"* ]] && grep -qx 'BAD1 ' <<<"$out" &&
  [[ "$out" == *"STATE2 sha=$X next=2 stage=wait"* ]] && grep -qx 'BAD2 ' <<<"$out" &&
  grep -q "RETRY ${X:0:9}: instance 1: self-check step ran 60s of its 45s window (tick 60s, load 49/16 cpus), try 1 of 2" "$LOG" &&
  grep -q "on ${X:0:9}: self-check tick green in 5s" "$LOG" &&
  pass "1 a step that times out once (60 s, bound 45) is checked again, then passes: baton -> 2, no quarantine" || fail "1 timeout once: $out / $(grep UPDATE "$LOG")"
out="$(lib "$chk2" X=$X AGO=60 AGO2=100 DRY_RUN=1 WD_UPD_STEP_MAX=45 WD_UPD_LOAD1=49 WD_UPD_NPROC=16)"
[[ "$out" == *"BAD2 instance 1 failed its self-check tick: self-check step ran 100s of its 45s window (tick 100s, load 49/16 cpus), try 2 of 2"* ]] && grep -qx 'STATE2 ' <<<"$out" &&
  pass "1 a step that times out on every try is quarantined, as before" || fail "1 timeout every try: $out"
out="$(lib "$chk2" X=$X AGO=60 AGO2=5 DRY_RUN=1 WD_UPD_STEP_MAX=45 WD_UPD_STEP_TRIES=1)"
[[ "$out" == *"BAD1 instance 1 failed its self-check tick: self-check step ran 60s of its 45s window (tick 60s, load "*"try 1 of 1"* && "$out" == *"REARMED none"* ]] &&
  pass "1 control: WD_UPD_STEP_TRIES=1 -> the first timeout quarantines (the old rule)" || fail "1 tries 1: $out"
out="$(lib "$chk2" X=$X AGO=60 AGO2=5 ERRLINE="s1.sh: line 3: nosuchcmd: command not found" DRY_RUN=1 WD_UPD_STEP_MAX=45)"
[[ "$out" == *"BAD1 instance 1 failed its self-check tick: script errors"* && "$out" == *"REARMED none"* ]] &&
  pass "1 a slow tick with a script error is quarantined at once, never retried" || fail "1 slow broken: $out"
# a tick a peer already gave a second window (try=1, since = the peer's
# retry): a 60 s tick that ends 10 s into that window is green
out="$(lib "$chk" X=$X AGO=60 TRY=1 SINCE=10 DRY_RUN=1 WD_UPD_STEP_MAX=45)"
[[ "$out" == *"STATE sha=$X next=2 stage=wait"* ]] && grep -qx 'BAD ' <<<"$out" &&
  pass "1 a check tick a peer gave a second window ends green inside it (60 s tick, 10 s of 45)" || fail "1 try=1 green: $out"
# SPL-4434 N1: the tick's own bound is the peer's test (now - since >
# WD_UPD_STEP_MAX). It was WD_UPD_STEP_MAX x (try+1) from the tick start: on
# try=1 since=S a peer at S+46 quarantined while the own tick at S+60 went
# green, a race for update.lock. Now both quarantine at S+46.
out="$(lib "$chk" X=$X AGO=60 TRY=1 SINCE=46 DRY_RUN=1 WD_UPD_STEP_MAX=45 WD_UPD_LOAD1=49 WD_UPD_NPROC=16)"
[[ "$out" == *"BAD instance 1 failed its self-check tick: self-check step ran 46s of its 45s window (tick 60s, load 49/16 cpus), try 2 of 2"* ]] && grep -qx 'STATE ' <<<"$out" &&
  pass "1 the own tick and a peer agree: try=1, 46 s into the last window -> quarantined by either" || fail "1 own vs peer bound: $out"
# an older code's exec set T0 before its pre-flight (60 s back): the check
# is timed from its own tick start (5 s), green
out="$(lib "$chk" X=$X AGO=60 TSTART=5 DRY_RUN=1 WD_UPD_STEP_MAX=45)"
[[ "$out" == *"STATE sha=$X next=2 stage=wait"* ]] && grep -qx 'BAD ' <<<"$out" && grep -q "on ${X:0:9}: self-check tick green in 5s" "$LOG" &&
  pass "1 timed from the check tick's start, not a stale exec T0 (60 s back -> green in 5 s)" || fail "1 tick start: $out"
# a check that never ends: a peer gives it a second WD_UPD_STEP_MAX window
# (the load in the line), and quarantines the sha when that one ends too
# (spl_wd_upd_baton). Updated for SPL-4434: one window used to quarantine.
out="$(lib 'n=$(spl_lease_now); echo "sha=$X next=1 stage=exec pid=1 since=$(( n - 60 )) start=$(( n - 60 ))" > "$WD_DIR/update.state"
  WD_INST=2; spl_wd_self_update "$n"; echo "BAD1 $(cat "$WD_DIR/code/$X.bad" 2>/dev/null || true)"; echo "STATE1 $(cat "$WD_DIR/update.state" 2>/dev/null || true)"
  sed -i "s/ since=[0-9]* / since=$(( n - 50 )) /" "$WD_DIR/update.state"
  WD_INST=3; spl_wd_self_update "$n"; echo "BAD2 $(cat "$WD_DIR/code/$X.bad" 2>/dev/null || true)"; rm -f "$WD_DIR/code/$X.bad" "$WD_DIR/update.state"' X=$X LEASE_NOW=2000000000 DRY_RUN=1 WD_UPD_STEP_MAX=45 WD_UPD_LOAD1=49 WD_UPD_NPROC=16)"
grep -qx 'BAD1 ' <<<"$out" && [[ "$out" == *"STATE1 sha=$X next=1 stage=exec pid=1 since=2000000000 start=1999999940 try=1"* ]] &&
  grep -q "RETRY ${X:0:9}: instance 1 did not finish its self-check in 45s (load 49/16 cpus), try 1 of 2" "$LOG" &&
  pass "1 a check past the step bound: a peer gives it a second window, the load logged, no quarantine" || fail "1 hang peer retry: $out / $(grep UPDATE "$LOG" | tail -n 2)"
[[ "$out" == *"BAD2 instance 1 did not finish its self-check in 45s (load 49/16 cpus), try 2 of 2"* ]] &&
  pass "1 a hung check tick: a peer quarantines the sha after its last window" || fail "1 hang peer: $out"
# SPL-4434 N2: an instance that crashed in its check and is not restarted
# (its pid is gone) gets no timeout window: quarantined at once, inside the
# first window; control: a live pid (1) inside the window is left alone
out="$(lib 'n=$(spl_lease_now); for p in 9999999 1; do echo "sha=$X next=1 stage=exec pid=$p since=$(( n - 10 )) start=$(( n - 10 ))" > "$WD_DIR/update.state"
  WD_INST=2; spl_wd_self_update "$n"; echo "P$p BAD $(cat "$WD_DIR/code/$X.bad" 2>/dev/null || true)"; echo "P$p STATE $(cat "$WD_DIR/update.state" 2>/dev/null || true)"; rm -f "$WD_DIR/code/$X.bad" "$WD_DIR/update.state"; done' X=$X LEASE_NOW=2000000000 DRY_RUN=1 WD_UPD_STEP_MAX=45)"
[[ "$out" == *"P9999999 BAD instance 1 died during its self-check (pid 9999999 is gone)"* ]] && grep -qx 'P9999999 STATE ' <<<"$out" &&
  grep -qx 'P1 BAD ' <<<"$out" && [[ "$out" == *"P1 STATE sha=$X next=1 stage=exec pid=1 since=1999999990"* ]] &&
  pass "1 a crashed, not restarted instance (pid gone) is quarantined by a peer at once; a live one waits its window" || fail "1 dead pid: $out"
rm -rf "$W" "$LOG" "$T/sent"; dc reset -q --hard "$SHA_A"

# SPL-1992 (a desk box 2026-10-15): the boot pass of the pre-flight's proof tick (a
# fresh state dir, a boot younger than WD_BOOT_RECENT) took 20+ s, and the
# live pass ~24 min: spl_wd_boot_seat re-read every agents/*.json twice per
# registry id, spl_wd_boot_snap forked a stat per verdict. 3 correct commits
# quarantined, 5 rollouts halted. Counted, not timed: one pass over 120 ids,
# 60 agents and 120 verdicts reads the expected seats once and stats once;
# the control (the old two helpers) reads them twice per id, stats per file.
# The count wrapper computes the seats once per pass and replays them: the
# calls are what is counted, and the control's 365 walks of 60 agents/*.json
# took 41..49 s of the file's 130..141 s (round 1 row 10, n=3).
BQ="$T/bq"; mkdir -p "$BQ/spool/agents" "$BQ/spool/dispatch" "$BQ/tick" "$BQ/bin"
for i in $(seq 100 219); do
  printf 'c-%s\tclaude\t%%1\t-\t20261015T000000Z\n' "$i" >> "$BQ/spool/registry.tsv"
  : > "$BQ/spool/dispatch/wd.c-$i"; touch -d '2 hours ago' "$BQ/spool/dispatch/wd.c-$i"
  (( i < 160 )) && printf '{"session_name": "c-%s@box1"}\n' "$i" > "$BQ/spool/agents/c-$i.json"
done
: > "$BQ/tick/ps"; : > "$BQ/tick/agents"
printf '#!/usr/bin/env bash\necho x >> "%s/stat.n"\nexec %s "$@"\n' "$BQ" "$(command -v stat)" > "$BQ/bin/stat"; chmod +x "$BQ/bin/stat"
bq_snip='eval "orig_$(declare -f spl_wd_expected)"
  spl_wd_expected() { echo x >> "$BQ/exp.n"; [[ -f "$BQ/exp.memo" ]] || orig_spl_wd_expected > "$BQ/exp.memo"; cat "$BQ/exp.memo"; }
  eval "$OLD"; : > "$BQ/exp.n"; : > "$BQ/stat.n"; rm -f "$BQ/exp.memo"; n=$(spl_lease_now)
  PATH="$BQ/bin:$PATH" spl_wd_boot_pass "$n" "$BQ/tick" "$(( n - 600 ))" ""
  echo "EXP $(wc -l < "$BQ/exp.n") STAT $(wc -l < "$BQ/stat.n")"'
bq_old='spl_wd_boot_seat() { [[ "$1" =~ -00[1-4]$ ]] && return 0; grep -qx -- "$1" <<<"$(spl_wd_expected)"; }
  spl_wd_boot_snap() { local f m; for f in "$LEASE_DIR"/wd.[acgqm]-[0-9][0-9][0-9]; do [[ -f "$f" ]] || continue
    m="$(stat -c %Y "$f" 2>/dev/null || true)"; [[ "$m" =~ ^[0-9]+$ ]] && (( m < $1 )) && echo "$m ${f##*/wd.}"; done; return 0; }'
out="$(lib "$bq_snip" SPOOL_ROOT="$BQ/spool" BQ="$BQ" OLD=: DRY_RUN=1 WD_STATE_DIR="$BQ/wd")"
[[ "$out" == *"EXP 1 STAT 1"* && "$(cat "$BQ"/wd/boot.*.seen 2>/dev/null | wc -l)" == 120 ]] &&
  pass "1 a boot pass over 120 ids reads the expected seats once and stats the verdicts once ($out)" || fail "1 boot pass counts: $out"
rm -rf "$BQ/wd"
out="$(lib "$bq_snip" SPOOL_ROOT="$BQ/spool" BQ="$BQ" OLD="$bq_old" DRY_RUN=1 WD_STATE_DIR="$BQ/wd")"
exp_n="$(sed -n 's/.*EXP \([0-9]*\) STAT \([0-9]*\).*/\1 \2/p' <<<"$out")"
[[ -n "$exp_n" ]] && (( ${exp_n% *} >= 240 && ${exp_n#* } >= 120 )) &&
  pass "1 control: the old helpers read the expected seats per id, stat per verdict ($out)" || fail "1 boot pass control: $out"
rm -rf "$BQ"

# ---- 2. bootstrap ------------------------------------------------------------
starter >/dev/null
for i in 1 2 3; do for _ in $(seq 1 "$WAIT_N"); do held "$W/run.$i.lock" && break; sleep 0.1; done; done
[[ "$(live)" == 3 ]] && pass "2 the starter runs 3 loops from the checkout (no code/good yet)" || fail "2 start: live $(live)"
wait_for "good := ${SHA_A:0:9} \(first snapshot\)" $(( 2 * WT + 10 )) && [[ "$(link good)" == "$SHA_A" && -x "$W/code/$SHA_A/csi-spl-orc/run" ]] &&
  pass "2 bootstrap: good := ${SHA_A:0:9}, the sha instance 1 runs" || fail "2 bootstrap: $(tail -n 5 "$LOG" 2>/dev/null)"
all_on "$SHA_A" $(( 2 * WT + 10 )) && pass "2 all 3 heartbeats on ${SHA_A:0:9}" || fail "2 hb: $(hb_sha 1) $(hb_sha 2) $(hb_sha 3)"
P0="$(pids)"

# ---- 3. the rolling restart ----------------------------------------------------
echo '# v3' >> "$O/sit/s1.sh"; SHA_C="$(commit C)"; t0="$(date +%s)"
: > "$T/live"
( while :; do live >> "$T/live"; sleep 0.2; done ) & SAMPLER=$!
wait_for "DONE instances 1 2 3 on ${SHA_C:0:9}" 100; t1="$(date +%s)"
kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null
grep "UPDATE" "$LOG" | sed -n '/START '"${SHA_C:0:9}"'/,$p' > "$T/roll"
cp "$T/roll" "${WD_UPD_TEST_KEEP:-/dev/null}" 2>/dev/null || true
[[ "$(cnt "DONE instances 1 2 3 on ${SHA_C:0:9}" "$LOG")" == 1 ]] && (( t1 - t0 < 70 )) &&
  pass "3 rolling restart DONE in $(( t1 - t0 ))s after the commit (< 70 s, tick ${TICK}s)" || fail "3 done: $(( t1 - t0 ))s; $(tail -n 8 "$LOG")"
# instance 1's check time runs from its exec, not from the tick start before the pre-flight
e1="$(grep -m1 'instance 1: EXEC forward' "$T/roll" | cut -c1-20)"; g1="$(grep -m1 'instance 1: instance 1 on .*self-check tick green' "$T/roll")"
took1="$(sed -n 's/.*green in \([0-9]*\)s.*/\1/p' <<<"$g1")"
wall1=$(( $(date -u -d "${g1:0:20}" +%s 2>/dev/null || echo 0) - $(date -u -d "$e1" +%s 2>/dev/null || echo 0) ))
[[ -n "$e1" && "$took1" =~ ^[0-9]+$ ]] && (( took1 <= wall1 + 1 )) &&
  pass "3 instance 1's self-check time is its own tick (${took1}s; exec -> verdict ${wall1}s)" || fail "3 took1 '$took1' wall1 '$wall1': $g1"
order="$(grep -oE 'instance [1-3]: EXEC forward' "$T/roll" | grep -oE '[1-3]' | tr -d '\n')"
[[ "$order" == 123 ]] && pass "3 EXEC order 1 -> 2 -> 3" || fail "3 order: '$order'"
[[ "$(cnt 'self-check tick green' "$T/roll")" == 3 ]] && pass "3 three green self-check ticks" || fail "3 checks: $(cat "$T/roll")"
min="$(sort -n "$T/live" | sed -n 1p)"
[[ -s "$T/live" && "$min" -ge 2 ]] && pass "3 never fewer than 2 live instances (min $min over $(wc -l < "$T/live") samples)" || fail "3 live min '$min'"
all_on "$SHA_C" 10 && pass "3 all 3 heartbeats on ${SHA_C:0:9}" || fail "3 hb: $(hb_sha 1) $(hb_sha 2) $(hb_sha 3)"
[[ "$(pids)" == "$P0" ]] && pass "3 the same 3 pids: exec in place, not a restart" || fail "3 pids: '$P0' -> '$(pids)'"
[[ "$(link good)" == "$SHA_C" && ! -e "$W/code/candidate" && ! -e "$W/update.state" ]] &&
  pass "3 good := ${SHA_C:0:9}; no candidate, no update.state" || fail "3 links: good $(link good)"
! grep -q 'ERR-TRAP' "$W"/run.*.out 2>/dev/null && pass "3 no loop hit the ERR trap" || fail "3 ERR: $(grep -h ERR-TRAP "$W"/run.*.out | sed -n 1,3p)"

# ---- 4. control: nothing under csi-spl-orc changed --------------------------------
echo more >> "$DC/README.md"; SHA_D="$(commit D)"
wait_for "good := ${SHA_D:0:9} \(csi-spl-orc unchanged" $(( WT + 10 )) && [[ "$(cnt "EXEC.*${SHA_D:0:9}" "$LOG")" == 0 && "$(pids)" == "$P0" ]] &&
  pass "4 control: a commit outside csi-spl-orc -> good moves, nothing execs" || fail "4 unchanged: $(tail -n 4 "$LOG")"

# ---- 5. a commit whose ./run exits non-zero ------------------------------------------
: > "$T/sent"
sed -i '2i exit 3' "$O/run"; SHA_E="$(commit E)"
wait_for "FAILED ${SHA_E:0:9}: pre-flight" $(( WT + 15 )) && [[ -f "$W/code/$SHA_E.bad" && "$(link good)" == "$SHA_D" ]] &&
  pass "5 bad commit: pre-flight fails, ${SHA_E:0:9} quarantined, good stays ${SHA_D:0:9}" || fail "5 preflight: $(tail -n 4 "$LOG")"
sent_once "commit ${SHA_E:0:9} failed" && pass "5 ONE admin alert names the commit" || fail "5 alert: $(cat "$T/sent")"
sleep $(( TICK + 2 ))
[[ "$(cnt "EXEC.*${SHA_E:0:9}" "$LOG")" == 0 && "$(cnt "FAILED ${SHA_E:0:9}" "$LOG")" == 1 && "$(pids)" == "$P0" ]] && alive 3 1 && sent_once "commit ${SHA_E:0:9} failed" &&
  pass "5 no instance ran it, never retried a tick later, the same 3 alive" || fail "5 after: $(tail -n 4 "$LOG")"

# ---- 6. passes the pre-flight, fails instance 1's self-check --------------------------
: > "$T/sent"
sed -i '2d' "$O/run"
# a watchdog bug that shows only in a loop instance (the pre-flight tick has no WD_INST)
sed -i '/^source /a if [ -n "${WD_INST:-}" ]; then spl_wd_run_scripts() { nosuchcmd_v6; }; fi' "$O/run"; SHA_F="$(commit F)"
wait_for "FAILED ${SHA_F:0:9}: instance 1 failed its self-check tick" $(( WT + 40 )) &&
  pass "6 instance 1 execs, its self-check tick fails (script errors)" || fail "6 check: $(tail -n 6 "$LOG")"
wait_for "instance 1: back on ${SHA_D:0:9} \(rollback\)" 30 && on_good 10 &&
  pass "6 instance 1 execs back into good ${SHA_D:0:9}; all 3 on good code" || fail "6 rollback: $(tail -n 4 "$LOG"); $(hb_sha 1) $(hb_sha 2) $(hb_sha 3)"
[[ "$(cnt "instance [23]: EXEC forward into ${SHA_F:0:9}" "$LOG")" == 0 && -f "$W/code/$SHA_F.bad" && "$(pids)" == "$P0" ]] && sent_once "commit ${SHA_F:0:9} failed" &&
  pass "6 instances 2 and 3 never ran it; quarantined; ONE alert" || fail "6 others: $(grep "${SHA_F:0:9}" "$LOG")"

# ---- 7. instance 1 crashes right after its exec ------------------------------------------
: > "$T/sent"
sed -i '/nosuchcmd_v6/d' "$O/run"
sed -i '2i [ -n "${WD_UPD_EXEC:-}" ] && [ "${WD_UPD_ROLE:-}" = forward ] && exit 4' "$O/run"; SHA_G="$(commit G)"
wait_for "FAILED ${SHA_G:0:9}: instance 1 died during its self-check" $(( 3 * WT + 40 )) &&
  pass "7 instance 1 crashed in its check: a peer restarted it on good, the rollout ends" || fail "7 crash: $(tail -n 8 "$LOG")"
on_good $(( 2 * WT + 10 )) && alive 3 10 && [[ -f "$W/code/$SHA_G.bad" ]] && sent_once "commit ${SHA_G:0:9} failed" &&
  pass "7 all 3 alive on good code, ${SHA_G:0:9} quarantined, ONE alert" || fail "7 after: $(hb_sha 1) $(hb_sha 2) $(hb_sha 3) pids $(pids); $(cat "$T/sent")"
[[ "$(cnt "instance [23]: EXEC forward into ${SHA_G:0:9}" "$LOG")" == 0 ]] && pass "7 instances 2 and 3 never ran it" || fail "7 others ran it"

echo "wd-self-update: $fails failure(s)"
[[ $fails -eq 0 ]]
