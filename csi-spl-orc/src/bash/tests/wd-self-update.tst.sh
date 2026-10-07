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
#      alive -> no defer); a dead instance restarts from code/good while a
#      candidate is out (never the candidate)
#   2. bootstrap: no code/good -> instance 1 snapshots the sha it runs, good
#      := it, nothing restarts
#   3. a desk-cron commit that changes csi-spl-orc -> rolling restart
#      1 -> 2 -> 3 (EXEC lines in that order, each self-check tick green),
#      DONE in < 70 s, all 3 heartbeats on the new sha, the same 3 pids
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
TICK="${WD_UPD_TEST_TICK:-10}"   # 30 = the live tick (the dev drill); 10 keeps CI short
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
  WD_SELF_UPDATE=1 WD_TICK="$TICK" CHILD_PEERS=1)
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
rm -rf "$W" "$LOG" "$T/sent"; dc reset -q --hard "$SHA_A"

# ---- 2. bootstrap ------------------------------------------------------------
starter >/dev/null
for i in 1 2 3; do for _ in $(seq 1 "$WAIT_N"); do held "$W/run.$i.lock" && break; sleep 0.1; done; done
[[ "$(live)" == 3 ]] && pass "2 the starter runs 3 loops from the checkout (no code/good yet)" || fail "2 start: live $(live)"
wait_for "good := ${SHA_A:0:9} \(first snapshot\)" $(( 2 * TICK + 10 )) && [[ "$(link good)" == "$SHA_A" && -x "$W/code/$SHA_A/csi-spl-orc/run" ]] &&
  pass "2 bootstrap: good := ${SHA_A:0:9}, the sha instance 1 runs" || fail "2 bootstrap: $(tail -n 5 "$LOG" 2>/dev/null)"
all_on "$SHA_A" $(( 2 * TICK + 10 )) && pass "2 all 3 heartbeats on ${SHA_A:0:9}" || fail "2 hb: $(hb_sha 1) $(hb_sha 2) $(hb_sha 3)"
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
wait_for "good := ${SHA_D:0:9} \(csi-spl-orc unchanged" $(( TICK + 10 )) && [[ "$(cnt "EXEC.*${SHA_D:0:9}" "$LOG")" == 0 && "$(pids)" == "$P0" ]] &&
  pass "4 control: a commit outside csi-spl-orc -> good moves, nothing execs" || fail "4 unchanged: $(tail -n 4 "$LOG")"

# ---- 5. a commit whose ./run exits non-zero ------------------------------------------
: > "$T/sent"
sed -i '2i exit 3' "$O/run"; SHA_E="$(commit E)"
wait_for "FAILED ${SHA_E:0:9}: pre-flight" $(( TICK + 15 )) && [[ -f "$W/code/$SHA_E.bad" && "$(link good)" == "$SHA_D" ]] &&
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
wait_for "FAILED ${SHA_F:0:9}: instance 1 failed its self-check tick" $(( TICK + 40 )) &&
  pass "6 instance 1 execs, its self-check tick fails (script errors)" || fail "6 check: $(tail -n 6 "$LOG")"
wait_for "instance 1: back on ${SHA_D:0:9} \(rollback\)" 30 && on_good 10 &&
  pass "6 instance 1 execs back into good ${SHA_D:0:9}; all 3 on good code" || fail "6 rollback: $(tail -n 4 "$LOG"); $(hb_sha 1) $(hb_sha 2) $(hb_sha 3)"
[[ "$(cnt "instance [23]: EXEC forward into ${SHA_F:0:9}" "$LOG")" == 0 && -f "$W/code/$SHA_F.bad" && "$(pids)" == "$P0" ]] && sent_once "commit ${SHA_F:0:9} failed" &&
  pass "6 instances 2 and 3 never ran it; quarantined; ONE alert" || fail "6 others: $(grep "${SHA_F:0:9}" "$LOG")"

# ---- 7. instance 1 crashes right after its exec ------------------------------------------
: > "$T/sent"
sed -i '/nosuchcmd_v6/d' "$O/run"
sed -i '2i [ -n "${WD_UPD_EXEC:-}" ] && [ "${WD_UPD_ROLE:-}" = forward ] && exit 4' "$O/run"; SHA_G="$(commit G)"
wait_for "FAILED ${SHA_G:0:9}: instance 1 died during its self-check" $(( 3 * TICK + 40 )) &&
  pass "7 instance 1 crashed in its check: a peer restarted it on good, the rollout ends" || fail "7 crash: $(tail -n 8 "$LOG")"
on_good $(( 2 * TICK + 10 )) && alive 3 10 && [[ -f "$W/code/$SHA_G.bad" ]] && sent_once "commit ${SHA_G:0:9} failed" &&
  pass "7 all 3 alive on good code, ${SHA_G:0:9} quarantined, ONE alert" || fail "7 after: $(hb_sha 1) $(hb_sha 2) $(hb_sha 3) pids $(pids); $(cat "$T/sent")"
[[ "$(cnt "instance [23]: EXEC forward into ${SHA_G:0:9}" "$LOG")" == 0 ]] && pass "7 instances 2 and 3 never ran it" || fail "7 others ran it"

echo "wd-self-update: $fails failure(s)"
[[ $fails -eq 0 ]]
