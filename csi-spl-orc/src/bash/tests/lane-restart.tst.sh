#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_lane_restart (spec 063 R-L1 / R-L2, sections 6, 7.2, 7.3) in a
#          sandbox. Nothing real is touched: processes live in a fake /proc
#          (LEASE_PROC_ROOT), tmux is a stub keeping panes in a file, the lane's
#          worktree is a throwaway clone of a throwaway bare origin, and ./run,
#          spool-send, ps and the identity map are stubs. The action runs under
#          ./run's `set -E` + ERR trap, so a stray failing command fails the test.
#   1. dry run: PLAN lines + the distil printed (header with the brief, 1b
#      NOTES, 1c tried and failed = "none recorded", 2 git + spool state and
#      NO pane scrape, 4 outbox, 5 inbox, 8 session tail); nothing written,
#      no respawn
#   2. the gate: a tracked change, an unpushed commit, no process, no task
#   3. happy: distil 0640 in <hold>/<task>/<ID>.md, respawn-pane -k in the SAME
#      pane as the agent user, never --resume, the seed names the distil, the
#      perm flags, the map adopts the new pid, HUMAN OK, one restart counted,
#      one event per step; 1c lists every tried / failed line; the raw pane
#      only in <ID>.pane.txt
#   4. R-L2: at lane_restarts_before_split it refuses (exit 3), notes the
#      orchestrator "split this task", no respawn
#   5. 7.3, seat_fail_action: compact (default) -> /compact typed into the old
#      pane + a note; no claude and no old process -> "respawn from the hold
#      dir" + a note; respawn -> the old process killed, respawned once more
#      (DONE) + a note; respawn failing twice -> a note
#   6. the human check: a claude of the box user -> HUMAN FAIL + a note
#   7. LIFECYCLE_EVENTS=0: no event call
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
S="$T/spool"; D="$S/dispatch"; H="$T/hold"
mkdir -p "$T/bin" "$T/proc" "$T/tmux" "$D" "$S/c-900/inbox" "$S/c-900/outbox" "$S/c-900/archive"
TCK="$(getconf CLK_TCK)"; UP=100000
echo "$UP.00 0.00" >"$T/proc/uptime"
printf 'SPOOL_AGENT_USER=%s\n' "$(id -un)" >"$S/box.env"
printf 'LEASE_ORCH=c-001\n' >"$D/lease.conf"

# the lane's worktree: a clone of a bare origin, on its own branch, all pushed
git init -q --bare -b master "$T/origin.git"
git clone -q "$T/origin.git" "$T/wt" 2>/dev/null
g() { git -C "$T/wt" -c user.name=t -c user.email=t@example.com "$@"; }
echo a >"$T/wt/a.txt"; g add a.txt; g commit -q -m "first"; g push -q origin HEAD:master; g checkout -q -b c-900-x
{ echo '{"type":"user","message":{"content":"As your VERY FIRST action, rename. Then read your full task brief at /var/tmp/ctx-063-05-lane-restart.md and implement it."}}'
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Wrote the gate."}],"usage":{"input_tokens":10,"cache_read_input_tokens":401000,"cache_creation_input_tokens":2000}}}'
  echo '{"type":"user","message":{"content":"carry on"}}'; } >"$T/transcript.jsonl"

# --- stubs --------------------------------------------------------------------
cat >"$T/bin/proc" <<'EOF'
#!/usr/bin/env bash
d="$T/proc/$1"; mkdir -p "$d"; echo claude >"$d/comm"
printf 'SPOOL_AGENT_ID=%s\0' "${3:-c-900}" >"$d/environ"
echo "$1 (claude) S 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 $(( (UP - $2) * TCK ))" >"$d/stat"
printf 'Uid:\t%s\t%s\n' "$(id -u)" "$(id -u)" >"$d/status"
EOF
# tmux: panes "<pane>\t<pid>"; capture -e draws the CLI input box (typed.<pane>)
cat >"$T/bin/tmux" <<'EOF'
#!/usr/bin/env bash
P="$T/tmux/panes"; L="$T/tmux/log"
cmd="$1"; shift
tgt="" lit=0 esc=0 cwd="" args=()
while [ $# -gt 0 ]; do case "$1" in -t) tgt="$2"; shift 2 ;; -c) cwd="$2"; shift 2 ;; -l) lit=1; shift ;; -a|-p|-J|-k) shift ;; -e) esc=1; shift ;; -F|-S) shift 2 ;; *) args+=("$1"); shift ;; esac; done
case "$cmd" in
  list-panes) awk -F'\t' '{print $2" "$1}' "$P" ;;
  capture-pane) grep -q "^$tgt	" "$P" || exit 1
    printf 'working on the gate\n❯ \n'
    if [ "$esc" = 1 ]; then
      printf '────────\n'
      if [ -s "$T/tmux/typed.$tgt" ]; then awk '{print "❯ " $0}' "$T/tmux/typed.$tgt"; else printf '❯\302\240\033[2mTry "x"\033[0m\n'; fi
      printf '────────\n'
    fi ;;
  respawn-pane) printf 'respawn %s -c %s\n' "$tgt" "$cwd" >>"$L"; printf '%s' "${args[0]}" >"$T/tmux/respawn.cmd"
    mode="$(cat "$T/respawn.mode" 2>/dev/null || echo ok)"
    [ "$mode" = refuse ] && exit 1
    [ "$mode" = refuse-once ] && { echo ok >"$T/respawn.mode"; exit 1; }
    old="$(awk -F'\t' -v p="$tgt" '$1 == p {print $2}' "$P")"; rm -rf "$T/proc/$old"
    if [ "$mode" = nostart ]; then printf '%s\t3001\n' "$tgt" >"$P"
    else "$T/bin/proc" 2001 0; printf '%s\t2001\n' "$tgt" >"$P"; fi ;;
  send-keys) k="${args[0]}"; echo "keys $tgt $k" >>"$L"
    if [ "$lit" = 1 ]; then printf '%s' "$k" >>"$T/tmux/typed.$tgt"
    elif [ "$k" = C-c ]; then : >"$T/tmux/typed.$tgt"
    elif [ "$k" = Enter ]; then echo "submit $tgt $(cat "$T/tmux/typed.$tgt" 2>/dev/null)" >>"$L"; : >"$T/tmux/typed.$tgt"; fi ;;
  *) echo "tmux stub: $cmd" >&2; exit 1 ;;
esac
EOF
cat >"$T/bin/run" <<'EOF'
#!/usr/bin/env bash
echo "$2 $LIFECYCLE_EVENT $LIFECYCLE_OUTCOME $LIFECYCLE_ROLE $LIFECYCLE_AGENT $LIFECYCLE_RID" >>"$T/run.log"
EOF
cat >"$T/bin/send" <<'EOF'
#!/usr/bin/env bash
from="" to="" kind="" task="" body=""
while [ $# -gt 0 ]; do case "$1" in --from) from="$2"; shift 2 ;; --to) to="$2"; shift 2 ;; --kind) kind="$2"; shift 2 ;;
  --task) task="$2"; shift 2 ;; --body) body="$2"; shift 2 ;; *) shift ;; esac; done
echo "send $from -> $to $kind $task: $body" >>"$T/send.log"
EOF
cat >"$T/bin/kill" <<'EOF'
#!/usr/bin/env bash
echo "kill $*" >>"$T/kill.log"; rm -rf "$T/proc/$2"
EOF
cat >"$T/bin/ai" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$T/ai.log"
EOF
cat >"$T/bin/ps" <<'EOF'
#!/usr/bin/env bash
echo "ps $*" >>"$T/ps.log"
[ -f "$T/ps.stray" ] && printf ' 4242 /opt/human-bin/claude --resume x\n 4243 bash -c claude-launcher\n'
exit 0
EOF
# the action, as ./run runs it: set -E and an ERR trap that ends the run;
# do_spl_lifecycle_event is "present" (brief 03), its calls go to the run stub
cat >"$T/bin/act" <<'EOF'
#!/usr/bin/env bash
set -E
trap 'echo "ERRTRAP: $BASH_COMMAND (line $LINENO)"; exit 99' ERR
do_log() { echo "$*"; }
do_spl_lifecycle_event() { :; }
source "$PROJ_PATH/src/bash/run/spl-lane-restart.func.sh"
do_spl_lane_restart || exit $?
EOF
chmod +x "$T/bin/"*

export T UP TCK PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" SPOOL_TEST=1 SPOOL_DESK_BOX=box-desk SPOOL_BOX_TAG=box SPOOL_BOX_USER=human-x \
  LEASE_PROC_ROOT="$T/proc" ROTATE_TMUX="$T/bin/tmux" ROTATE_RUN="$T/bin/run" ROTATE_SEND="$T/bin/send" ROTATE_AI="$T/bin/ai" ROTATE_KILL="$T/bin/kill" \
  ROTATE_HOLD_DIR="$H" ROTATE_TRANSCRIPT="$T/transcript.jsonl" ROTATE_WORKDIR="$T/wt" ROTATE_AS_AGENT_DIRECT=1 ROTATE_POLL=1 \
  LANE_START_WAIT=3 LANE_PS="$T/bin/ps" CLAUDE_BIN=/agent/home/.local/bin/claude ID=c-900

world() {
  rm -rf "$T/proc/"[0-9]* "$T/tmux/"* "$T/"*.log "$S/c-900/NOTES.md" "$T/respawn.mode" "$T/ps.stray" "$H" "$D/lane-restart.log"
  "$T/bin/proc" 1001 7200
  printf '%%2\t1001\n' >"$T/tmux/panes"
  echo '2026-10-03T03:00Z decided restart at 400k, not compact' >"$S/c-900/NOTES.md"
  echo '{"v":1,"msg_id":"m1","ts":"2026-10-03T03:00:00Z","from":"c-001","to":"c-900","kind":"task","task_id":"t1","body":"start the gate"}' >"$S/c-900/inbox/m1.json"
  echo '{"v":1,"msg_id":"m2","ts":"2026-10-03T03:01:00Z","from":"c-900","to":"c-001","kind":"note","task_id":"t1","body":"gate written"}' >"$S/c-900/outbox/m2.json"
}
act() { env "$@" "$T/bin/act"; }
DIST="$H/ctx-063-05-lane-restart/c-900.md"

# --- 1. dry run ---------------------------------------------------------------
world
act >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q ' GATE OK c-900 pid 1001, pane %2, .* clean, task ctx-063-05-lane-restart restart 1 of 2, ctx 403k' "$T/o" &&
  grep -q " DISTIL PLAN -> $DIST (0640)" "$T/o" && grep -q " SPAWN PLAN respawn-pane -k -t %2 as $(id -un), never --resume: Read $DIST, then continue the task" "$T/o" &&
  pass "1. dry run: GATE OK + one PLAN line per step" || fail "1. rc=$rc $(cat "$T/o")"
for want in '# c-900@box-desk lane distil, restart [0-9T]*Z-c-900' 'brief: /var/tmp/ctx-063-05-lane-restart.md' 'context 403k' \
  '## 1b. NOTES' 'decided restart at 400k, not compact' '## 1c. Tried and failed' '^none recorded$' \
  '## 2. In flight: git and spool state' '- branch: c-900-x' '^    clean$' '^    none (all pushed)$' \
  'last spool message sent: 2026-10-03T03:01:00Z -> c-001 note \[t1\] gate written' \
  'last spool message received: 2026-10-03T03:00:00Z <- c-001 task \[t1\] start the gate' \
  '-> c-001 note \[t1\] gate written' '## 5. Unread inbox: 1 message' '<- c-001 task \[t1\] start the gate' \
  '- assistant: Wrote the gate.'; do
  grep -q -- "$want" "$T/o" || fail "1. the distil lacks: $want"
done
grep -q 'working on the gate' "$T/o" && fail "1. the distil carries a raw pane scrape" || pass "1. no raw pane scrape in the distil"
grep -qE '^## (3|6|6b|7)\.' "$T/o" && fail "1. a lane distil carries a role-seat section" || pass "1. the lane distil skips sections 3, 6, 6b, 7"
[[ ! -e "$H" && ! -e "$D/lane-restart.log" && ! -e "$T/tmux/log" && ! -e "$T/run.log" && ! -e "$T/send.log" ]] &&
  pass "1. dry run: nothing written, no respawn, no event" || fail "1. the dry run touched something"

# --- 2. the gate -----------------------------------------------------------------
world; echo b >>"$T/wt/a.txt"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 1 ]] && grep -q ' GATE FAIL .*1 uncommitted tracked change(s); land what is green' "$T/o" && [[ ! -e "$T/tmux/log" ]] &&
  pass "2. a tracked change: refused" || fail "2. dirty: rc=$rc $(cat "$T/o")"
g checkout -q a.txt; echo untracked >"$T/wt/u.txt"; g commit -q --allow-empty -m wip
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 1 ]] && grep -q ' GATE FAIL .*1 commit(s) not on origin/master' "$T/o" && [[ ! -e "$T/tmux/log" ]] &&
  pass "2. an unpushed commit: refused (an untracked file alone is not)" || fail "2. ahead: rc=$rc $(cat "$T/o")"
g push -q origin HEAD:master
world; rm -rf "$T/proc/1001"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 1 ]] && grep -q ' GATE FAIL no live claude carries c-900' "$T/o" && pass "2. no process: refused" || fail "2. absent: $(cat "$T/o")"
world
act DRY_RUN=0 ROTATE_TRANSCRIPT="$T/none.jsonl" >"$T/o" 2>&1; rc=$?
[[ $rc -eq 1 ]] && grep -q ' GATE FAIL no task: set LANE_TASK' "$T/o" && pass "2. no brief and no LANE_TASK: refused" || fail "2. task: $(cat "$T/o")"

# --- 3. happy -------------------------------------------------------------------
world; printf '2026-10-03T03:05Z tried a sed-only patch\n2026-10-03T03:06Z failed the sed patch: quoting broke the seed\n' >>"$S/c-900/NOTES.md"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q ' DONE OK c-900 restarted from ' "$T/o" && pass "3. restarted (DONE)" || fail "3. rc=$rc $(cat "$T/o")"
[[ -f "$DIST" && "$(stat -c %a "$DIST")" == 640 ]] && grep -q 'brief: /var/tmp/ctx-063-05-lane-restart.md' "$DIST" &&
  pass "3. the distil is $DIST, mode 0640" || fail "3. distil: $(ls -l "$H"/*/ 2>&1)"
sed -n '/^## 1c/,/^## 2/p' "$DIST" | grep -c -E 'tried a sed-only patch|failed the sed patch' | grep -x 2 >/dev/null && ! sed -n '/^## 1c/,/^## 2/p' "$DIST" | grep 'decided' >/dev/null &&
  pass "3. 1c lists every tried / failed line, nothing else" || fail "3. 1c: $(sed -n '/^## 1c/,/^## 2/p' "$DIST")"
grep -q 'working on the gate' "$H/ctx-063-05-lane-restart/c-900.pane.txt" && ! grep -q 'pane.txt' "$DIST" "$T/tmux/respawn.cmd" &&
  pass "3. the raw pane only in c-900.pane.txt, never named by the distil or the seed" || fail "3. pane.txt"
grep -qx "respawn %2 -c $T/wt" "$T/tmux/log" && pass "3. respawn-pane -k in the SAME pane, cwd = the worktree" || fail "3. respawn: $(cat "$T/tmux/log")"
launch="$(grep -oE 'printf %s [A-Za-z0-9+/=]+ ' "$T/tmux/respawn.cmd" | cut -d' ' -f3 | base64 -d)"
[[ "$launch" == *"--as 'c-900' --mirror -- '/agent/home/.local/bin/claude' --name 'c-900@box' --permission-mode auto \"Read $DIST, then continue the task\""* &&
  "$launch" != *--resume* && "$(cat "$T/tmux/respawn.cmd")" == *"SPOOL_AGENT_USER='$(id -un)'"*"spool_agent_exec"* ]] &&
  pass "3. as the agent user, its claude, the perm flags, the distil seed, never --resume" || fail "3. launch: $launch | $(cat "$T/tmux/respawn.cmd")"
grep -qx 'adopt c-900 2001' "$T/ai.log" && grep -q ' SPAWN OK c-900 pid 2001 in %2' "$T/o" && pass "3. the map adopts the new pid" || fail "3. adopt"
grep -q ' HUMAN OK no claude of human-x' "$T/o" && grep -q 'ps -u human-x -o pid=,args=' "$T/ps.log" &&
  pass "3. the standing check ran on the human's login" || fail "3. human: $(cat "$T/o")"
[[ "$(grep -c . "$H/ctx-063-05-lane-restart/restarts.tsv")" == 1 ]] && pass "3. one restart counted in the hold dir" || fail "3. count"
phases="$(awk '{printf "%s ", $3}' "$D/lane-restart.log")"
[[ "$phases" == "GATE DISTIL SPAWN HUMAN DONE " ]] && pass "3. one log line per step" || fail "3. phases: $phases"
sleep 1
grep -q 'do_spl_lifecycle_event handoff ok lane c-900' "$T/run.log" && grep -q 'do_spl_lifecycle_event restart ok lane c-900' "$T/run.log" &&
  pass "3. one lifecycle event per step (handoff, restart)" || fail "3. events: $(cat "$T/run.log" 2>/dev/null)"
! grep -q ERRTRAP "$T/o" && pass "3. no stray failing command under the ERR trap" || fail "3. ERRTRAP: $(grep ERRTRAP "$T/o")"

# --- 4. R-L2 --------------------------------------------------------------------
world; mkdir -p "$H/ctx-063-05-lane-restart"; printf 'a\tc-900\tr1\t400\nb\tc-900\tr2\t410\n' >"$H/ctx-063-05-lane-restart/restarts.tsv"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 3 ]] && grep -q 'restarted 2 time(s), lane_restarts_before_split=2: split this task' "$T/o" && [[ ! -e "$T/tmux/log" ]] &&
  grep -q 'send c-001 -> c-001 note ctx-063-05-lane-restart: split this task: lane c-900@box-desk hit 2 restarts' "$T/send.log" &&
  pass "4. at lane_restarts_before_split: exit 3, no respawn, the orchestrator told to split" || fail "4. rc=$rc $(cat "$T/o") $(cat "$T/send.log" 2>/dev/null)"
world; mkdir -p "$H/ctx-063-05-lane-restart"; printf 'a\tc-900\tr1\t400\n' >"$H/ctx-063-05-lane-restart/restarts.tsv"
act DRY_RUN=0 LANE_RESTARTS_BEFORE_SPLIT=1 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 3 ]] && pass "4. LANE_RESTARTS_BEFORE_SPLIT=1 refuses the second restart" || fail "4. env: rc=$rc"

# --- 5. 7.3 fallbacks -------------------------------------------------------------
world; echo refuse >"$T/respawn.mode"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 1 ]] && grep -q 'submit %2 /compact' "$T/tmux/log" && grep -q ' FALLBACK DONE seat_fail_action=compact: /compact typed into %2' "$T/o" &&
  grep -q 'send c-001 -> c-001 note ctx-063-05-lane-restart: lane restart .*: SPAWN failed (tmux refused respawn-pane on %2); seat_fail_action=compact: /compact typed' "$T/send.log" &&
  pass "5. respawn refused, seat_fail_action default compact: /compact into the old pane + a note" || fail "5. refuse: rc=$rc $(cat "$T/o") $(cat "$T/tmux/log")"
sleep 1; grep -q 'do_spl_lifecycle_event compact ok' "$T/run.log" && pass "5. ... and a compact event" || fail "5. compact event: $(cat "$T/run.log")"
world; echo nostart >"$T/respawn.mode"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 1 ]] && grep -q ' SPAWN FAIL no claude carrying c-900 started in %2 within 3s' "$T/o" && ! grep -q '/compact' "$T/tmux/log" &&
  grep -q 'SPAWN failed (no claude carrying c-900 started in %2 within 3s); seat_fail_action=compact, but the old process is gone .*respawn it from the hold dir' "$T/send.log" &&
  pass "5. no new claude: the orchestrator told to respawn from the hold dir" || fail "5. nostart: rc=$rc $(cat "$T/o")"

world; echo refuse-once >"$T/respawn.mode"
act DRY_RUN=0 SEAT_FAIL_ACTION=respawn >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'kill -TERM 1001' "$T/kill.log" && [[ "$(grep -c '^respawn %2' "$T/tmux/log")" == 2 ]] && ! grep -q /compact "$T/tmux/log" &&
  grep -q ' FALLBACK OK seat_fail_action=respawn: .*respawned from the distil (pid 2001)' "$T/o" && grep -q ' DONE OK ' "$T/o" &&
  grep -q 'seat_fail_action=respawn: the pane.s process killed, respawned' "$T/send.log" &&
  pass "5. seat_fail_action=respawn: old process killed, respawned once more, DONE + a note" || fail "5. respawn: rc=$rc $(cat "$T/o")"
world; echo nostart >"$T/respawn.mode"
act DRY_RUN=0 SEAT_FAIL_ACTION=respawn >"$T/o" 2>&1; rc=$?
[[ $rc -eq 1 ]] && grep -q 'the second respawn failed too .*close the lane and respawn it from the hold dir' "$T/send.log" &&
  pass "5. seat_fail_action=respawn failing twice: a note" || fail "5. respawn twice: rc=$rc $(cat "$T/o")"
act DRY_RUN=0 SEAT_FAIL_ACTION=bogus >"$T/o" 2>&1; rc=$?
[[ $rc -eq 1 ]] && grep -q 'FATAL SEAT_FAIL_ACTION must be compact or respawn' "$T/o" && pass "5. a bad SEAT_FAIL_ACTION is refused" || fail "5. bogus: rc=$rc"

# --- 6. the human check -------------------------------------------------------------
world; touch "$T/ps.stray"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 1 ]] && grep -q " HUMAN FAIL claude of the human's login human-x: 4242 " "$T/o" && ! grep -q 4243 "$T/o" &&
  grep -q "a claude runs as the human's login human-x (pids: 4242)" "$T/send.log" &&
  pass "6. a claude of the human's login: HUMAN FAIL + a note (a launcher shell is not counted)" || fail "6. rc=$rc $(cat "$T/o")"

# --- 7. LIFECYCLE_EVENTS=0 --------------------------------------------------------------
world
act DRY_RUN=0 LIFECYCLE_EVENTS=0 >"$T/o" 2>&1; rc=$?
sleep 1
[[ $rc -eq 0 && ! -e "$T/run.log" ]] && pass "7. LIFECYCLE_EVENTS=0: restarted, no event call" || fail "7. rc=$rc $(cat "$T/run.log" 2>/dev/null)"

echo
[[ $fails -eq 0 ]] && { echo "lane-restart: all passed"; exit 0; } || { echo "lane-restart: $fails failed"; exit 1; }
