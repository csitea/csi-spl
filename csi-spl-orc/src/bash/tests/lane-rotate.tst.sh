#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the hourly rotation of every agent (do_spl_lane_rotate on
#          spl-rotate-lib.func.sh) and do_spl_agent_age_check, in a sandbox.
#          Nothing real is touched: processes live in a fake /proc
#          (LEASE_PROC_ROOT), tmux is a stub keeping panes in a file, the
#          spawn starts a fake agent that runs ONLY its seed's ack line, the
#          spool send, kill, the identity map and the login probe are stubs.
#          The action runs under ./run's `set -E` + ERR trap.
#   1. 2 healthy ticks in a row (every session young) = 0 stops, 0 notes
#   2. a lane mid-push at 50 min is warned once and DEFERred (red control:
#      the same lane without the push is rotated)
#   3. the full flow: new session in a new window, same id, same worktree,
#      ack, old /exit, old window closed, the map on the new pid, DONE
#   4. 2 ticks inside the hour = 1 rotation; a seat rotated < 60 min ago is
#      never stopped again, even with an old pid
#   5. the cap: 5 lanes past their deadline, cap 3 = 3 workers; the next tick
#      while they run = 0
#   6. a dead login = 0 rotations + 1 alert to the dispatch holder (a second
#      tick: no second alert)
#   7. the deadline: a busy lane at 58 min is rotated anyway, the handoff
#      names what was in flight
#   8. role seats: the orch seat this box rotates is left out, a standby
#      dispatcher seat is rotated; an ACCEPTED lane is left to the orchestrator
#   9. a mistral (vibe) lane is rotated with its own kind
#  10. a forged ack is refused (exit 3)
#  11. do_spl_agent_age_check: a 70-min session = exit 1 and its line; none =
#      exit 0; the tick reports it to the dispatch holder once
#  12. the manifest row and its executable cron script
#  14. a lane whose /exit opens the background-work picker: Enter on "Exit and
#      stop tasks", gone without SIGTERM
#  18. a human hold (.human-hold, future epoch) = no rotation, nothing
#      stopped (tick and worker); an expired or garbage hold = rotated
#  15. the new session's FIRST prompt carries the ACK-COMMAND (n=4 rotations
#      on 2026-10-11 never opened the seed it pointed to): the fake agent acks
#      from its first prompt only; spawn-core renders SPAWN_PROMPT_HEAD_FILE on
#      top; spawn-window forwards it into the pane
#  19. a busy child whose command spans lines (a heredoc, a bash -c script) is
#      reported as ONE line of at most 120 characters (SPL-2841)
#  20. a new pane that never starts its agent (stopped on a git login
#      prompt, SPL-2864): FAIL SPAWN names the screen, the NEW window is
#      closed, the old one keeps its name, its pid and the lane
#  21. SPL-2898 (E): the old window gone before SPAWN renames it: SPAWN SKIP
#      retired with tmux's reason, no FAIL, no note, ctx ABORT
#  22. SPL-3779: a lane whose vendor is on its limit (the lane's own watchdog
#      S2 kind=limit; for agy any a- seat's) is SKIPped before SPAWN, logged
#      with the reset, never a failure; a lane on a vendor without a limit is
#      rotated in the same tick (control); the verdict gone = rotated
#  24. SPL-3812: an a- seat's pane shows agy's quota banner (fixture
#      wd-situations/s2-agy-quota.pane, "Resets in 2h"): the agy lane is
#      SKIPped with ONE log line naming the reset, nothing spawned, no note;
#      controls: no banner, a reset already past, a c- lane = rotated
#  25. SPL-3982: a tmux call into the old pane hangs during RETIRE: each
#      call is bounded, the old pid gets SIGTERM, DONE with one session
#  26. SPL-3982: another session of the id starts after GATE in its own pane
#      (a hand restore): retired by its own pid, its window closed; control:
#      a process of the id in the NEW pane is left and counted
#  27. SPL-4358: one tick reads each vendor's limit once (a slow fake read,
#      8 claude lanes = 1 read, the tick under 8 x the read); the wd scan of
#      300 verdict files runs no awk and one stat, and still finds the limit
#------------------------------------------------------------------------------
# shellcheck disable=SC2034 # rc and M are read inside the check strings (eval)
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
T=$(mktemp -d)
cleanup() { [ -s "$T/sleepers" ] && xargs -r kill <"$T/sleepers" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
S="$T/spool"; D="$S/dispatch"
TCK="$(getconf CLK_TCK)"; UP=100000
export T S D UP TCK

reset() {
  rm -rf "$T/proc" "$T/tmux" "$S" "$T"/*.log "$T"/*.out "$T/ai."* "$T/ack.out" "$T/next" "$T/wt"
  mkdir -p "$T/bin" "$T/proc" "$T/tmux" "$D" "$T/wt"
  : >"$T/tmux/panes"
  echo "$UP.00 0.00" >"$T/proc/uptime"
  printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\n' "$(id -un)" "$(id -un)" >"$S/box.env"
  printf 'LEASE_ORCH=c-900\nLEASE_MASTER=c-902\nLEASE_FAILOVER=c-903\nLEASE_FLEET=main\nLEASE_ENV=prd\nLEASE_TENANT=t1\n' >"$D/lease.conf"
  echo "c-900@box-desk $(date +%s)" >"$D/lease.orch"
  echo "c-002@box-b $(date +%s)" >"$D/lease"
  echo 3000 >"$T/next"
}

# lane <id> <age-min> [kind] [pid] [pane]: a live agent in its own pane,
# its spool dirs, a brief and a registry row naming a clean worktree
lane() {
  local id="$1" age=$(( $2 * 60 )) kind="${3:-claude}" pid="${4:-}" pane="${5:-}" comm
  [ -n "$pid" ] || pid=$(( 2000 + ${id##*-} ))
  [ -n "$pane" ] || pane="%${id##*-}"
  mkdir -p "$S/$id/inbox" "$S/$id/outbox" "$S/$id/archive" "$S/$id/lifetime"
  printf '# Brief: the %s task\nFiles: csi-spl-orc/x.sh\n\nDo the thing.\n' "$id" >"$S/$id/lifetime/brief.md"
  wt "$id"
  printf '%s\t%s\t%s\t%s\t20261011T000000Z\tc-001\n' "$id" "$kind" "$pane" "$T/wt/$id" >>"$S/registry.tsv"
  comm=claude; [ "$kind" = mistral ] && comm="Vibe CLI"; [ "$kind" = grok ] && comm=grok; [ "$kind" = agy ] && comm=agy
  "$T/bin/proc" "$pid" "$age" "$id" "$comm" 1 "$kind --seed"
  printf '%s\t%s\t$0\t%s@box\n' "$pane" "$pid" "$id" >>"$T/tmux/panes"
  echo "$pid" >"$T/ai.$id"
}
# wt <id>: a git clone with nothing unpushed
wt() {
  [ -d "$T/origin.git" ] || { git init -q --bare -b master "$T/origin.git"
    git clone -q "$T/origin.git" "$T/seed" 2>/dev/null; git -C "$T/seed" -c user.name=t -c user.email=t@x commit -q --allow-empty -m init
    git -C "$T/seed" push -q origin HEAD:master; }
  git clone -q "$T/origin.git" "$T/wt/$1" 2>/dev/null
}

# --- stubs --------------------------------------------------------------------
mkdir -p "$T/bin"
# proc <pid> <age-s> <id> <comm> <ppid> <cmdline>
cat >"$T/bin/proc" <<'EOF'
#!/usr/bin/env bash
d="$T/proc/$1"; mkdir -p "$d"; echo "$4" >"$d/comm"
printf 'SPOOL_AGENT_ID=%s\0' "$3" >"$d/environ"
printf '%s\0' $6 >"$d/cmdline"
echo "$1 ($4) S $5 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 $(( (UP - $2) * TCK ))" >"$d/stat"
printf 'Uid:\t%s\t%s\n' "$(id -u)" "$(id -u)" >"$d/status"
EOF
# tmux: panes "<pane>\t<pid>\t<session>\t<name>"; Enter on /exit ends the pid;
# bgtasks.<pane>: /exit opens the "Background work is running" picker and only
# an Enter on it (1. Exit and stop tasks) ends the pid
cat >"$T/bin/tmux" <<'EOF'
#!/usr/bin/env bash
P="$T/tmux/panes"; L="$T/tmux/log"
cmd="$1"; shift
tgt="" lit=0 esc=0 args=()
while [ $# -gt 0 ]; do case "$1" in -t) tgt="$2"; shift 2 ;; -l) lit=1; shift ;; -a|-p|-J) shift ;; -e) esc=1; shift ;; -F|-S) shift 2 ;; *) args+=("$1"); shift ;; esac; done
field() { awk -F'\t' -v p="$tgt" -v f="$1" '$1 == p {print $f}' "$P"; }
# hang.<pane>: a capture or a keypress into it never returns (SPL-3982)
case "$cmd" in capture-pane|send-keys) [ -f "$T/tmux/hang.$tgt" ] && exec sleep 60 ;; esac
case "$cmd" in
  list-panes) awk -F'\t' '{print $2" "$1}' "$P" ;;
  display-message) grep -q "^$tgt	" "$P" || exit 1
    case "${args[0]}" in *window_name*) field 4 ;; *session_id*) field 3 ;; *pane_pid*) field 2 ;; *pane_id*) echo "$tgt" ;; esac ;;
  capture-pane) grep -q "^$tgt	" "$P" || exit 1
    if [ -f "$T/tmux/screen.$tgt" ]; then cat "$T/tmux/screen.$tgt"; else printf 'some output\n❯ \n'; fi
    if [ "$esc" = 1 ]; then
      printf '────────\n'
      if [ -s "$T/tmux/typed.$tgt" ]; then awk 'NR == 1 {print "❯ " $0; next} {print "  " $0}' "$T/tmux/typed.$tgt"
      else printf '❯\302\240\033[2mTry "how does <filepath> work?"\033[0m\n'; fi
      printf '────────\n  ⏵⏵ auto mode on\n'
    fi ;;
  rename-window) if [ -f "$T/tmux/gone.$tgt" ]; then rm -f "$T/tmux/gone.$tgt"; pid="$(field 2)"; [ -n "$pid" ] && rm -rf "${T:?}/proc/$pid"
      awk -F'\t' -v p="$tgt" '$1 != p' "$P" >"$P.new" && mv "$P.new" "$P"; fi
    grep -q "^$tgt	" "$P" || { echo "can't find pane: $tgt" >&2; exit 1; }
    awk -F'\t' -v OFS='\t' -v p="$tgt" -v n="${args[0]}" '$1 == p {$4 = n} {print}' "$P" >"$P.new" && mv "$P.new" "$P"
    echo "rename $tgt ${args[0]}" >>"$L" ;;
  send-keys) k="${args[0]}"; echo "keys $tgt $k" >>"$L"
    if [ "$lit" = 1 ]; then printf '%s' "$k" >>"$T/tmux/typed.$tgt"
    elif [ "$k" = C-c ]; then : >"$T/tmux/typed.$tgt"
    elif [ "$k" = Enter ]; then
      b="$(cat "$T/tmux/typed.$tgt" 2>/dev/null)"; echo "submit $tgt $b" >>"$L"
      if [ -f "$T/tmux/picker.$tgt" ]; then echo "picker $tgt" >>"$L"; rm -rf "$T/proc/$(field 2)"
      elif [ "$b" = /exit ] && [ -f "$T/tmux/bgtasks.$tgt" ]; then touch "$T/tmux/picker.$tgt"
        printf 'Background work is running\n❯ 1. Exit and stop tasks\n  2. Move to background and exit\n  3. Stay\n' >"$T/tmux/screen.$tgt"
      elif [ "$b" = /exit ]; then rm -rf "$T/proc/$(field 2)"; fi
      : >"$T/tmux/typed.$tgt"
    fi ;;
  kill-window) awk -F'\t' -v p="$tgt" '$1 != p' "$P" >"$P.new" && mv "$P.new" "$P"; echo "kill $tgt" >>"$L" ;;
  *) echo "tmux stub: $cmd" >&2; exit 1 ;;
esac
EOF
# spawn-window.sh: <kind> <ID> <workdir> <seed> <slug> -> "<ID> <pane>"; the
# fake agent runs ONLY the ACK-COMMAND line of its first prompt
# (SPAWN_PROMPT_HEAD_FILE, which spawn-core puts on top of the seed it points to)
cat >"$T/bin/spawn" <<'EOF'
#!/usr/bin/env bash
n="$(cat "$T/next")"; echo $((n + 1)) >"$T/next"
echo "spawn $1 $2 $3 SPAWN_REUSE_ID=${SPAWN_REUSE_ID:-} scope=${SPAWN_LANE_SCOPE:-}" >>"$T/spawn.log"
cp "$4" "$T/seed.$2"
cat "${SPAWN_PROMPT_HEAD_FILE:-/dev/null}" >"$T/prompt.$2" 2>/dev/null
cp -f "$4" "$SPOOL_ROOT/$2/lifetime/brief.md"
printf '%%%s\t%s\t$0\t%s@box\n' "$n" "$n" "$2" >>"$T/tmux/panes"
comm=claude; [ "$1" = mistral ] && comm="Vibe CLI"; [ "$1" = agy ] && comm=agy
"$T/bin/proc" "$n" 0 "$2" "$comm" 1 "$1 --seed"
# at-spawn.hang <pane>: the old pane hangs from now on; at-spawn.extra
# "<pid> <pane|NEW>": another session of the same id starts (a hand restore
# in its own pane, or a child of the new session)
[ -s "$T/at-spawn.hang" ] && touch "$T/tmux/hang.$(cat "$T/at-spawn.hang")"
if [ -s "$T/at-spawn.extra" ]; then read -r xp xpane <"$T/at-spawn.extra"
  if [ "$xpane" = NEW ]; then "$T/bin/proc" "$xp" 0 "$2" claude "$n" "claude -p"
  else "$T/bin/proc" "$xp" 0 "$2" claude 1 "claude --resume x"; printf '%s\t%s\t$0\t%s@box\n' "$xpane" "$xp" "$2" >>"$T/tmux/panes"; fi
fi
rid="$(grep '^ACK-COMMAND:' "$T/prompt.$2" | grep -oE 'ROTATE_ID=[0-9A-Za-z-]+' | cut -d= -f2)"
( sleep 1; ROTATE_CMD=ack ROTATE_ID="$rid" ID="$2" ROTATE_CALLER_PID="$n" "$T/bin/act" >>"$T/ack.out" 2>&1 ) >/dev/null 2>&1 &
echo "$2 %$n"
EOF
cat >"$T/bin/run" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$T/run.log"; exit 1
EOF
cat >"$T/bin/send" <<'EOF'
#!/usr/bin/env bash
from="" to="" kind="" task="" body=""
while [ $# -gt 0 ]; do case "$1" in --from) from="$2"; shift 2 ;; --to) to="$2"; shift 2 ;; --kind) kind="$2"; shift 2 ;;
  --task) task="$2"; shift 2 ;; --body) body="$2"; shift 2 ;; *) shift ;; esac; done
id="$(cat /proc/sys/kernel/random/uuid)"
j="$(jq -n -c --arg i "$id" --arg f "$from" --arg t "$to" --arg k "$kind" --arg ta "$task" --arg b "$body" \
  '{v:1, msg_id:$i, ts:"2026-10-11T19:00:00Z", from:$f, to:$t, kind:$k, task_id:$ta, body:$b}')"
mkdir -p "$SPOOL_ROOT/${to%@*}/inbox" "$SPOOL_ROOT/$from/outbox"
echo "$j" >"$SPOOL_ROOT/${to%@*}/inbox/$id.json"; echo "$j" >"$SPOOL_ROOT/$from/outbox/$id.json"
echo "send $from -> $to $kind $task: $body" >>"$T/send.log"
EOF
cat >"$T/bin/kill" <<'EOF'
#!/usr/bin/env bash
echo "kill $*" >>"$T/kill.log"; rm -rf "$T/proc/$2"
EOF
cat >"$T/bin/ai" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  adopt) echo "adopt $2 $3" >>"$T/ai.log"; echo "$3" >"$T/ai.$2" ;;
  pane-of) p="$(cat "$T/ai.$2" 2>/dev/null)"; [ -n "$p" ] && [ -d "$T/proc/$p" ] || exit 1
    awk -F'\t' -v p="$p" '$2 == p {print $1; exit}' "$T/tmux/panes" ;;
esac
EOF
cat >"$T/bin/worker" <<'EOF'
#!/usr/bin/env bash
echo "worker $ID $LANE_ROTATE_KIND forced=$LANE_ROTATE_FORCED" >>"$T/worker.log"
sleep 30
EOF
# the action, as ./run runs it: set -E and an ERR trap that ends the run
cat >"$T/bin/act" <<'EOF'
#!/usr/bin/env bash
set -E
trap 'echo "ERRTRAP: $BASH_COMMAND (line $LINENO)"; exit 99' ERR
do_log() { echo "$*"; }
source "$PROJ_PATH/src/bash/run/spl-lane-rotate.func.sh"
source "$PROJ_PATH/src/bash/run/spl-agent-age-check.func.sh"
"${ACTION:-do_spl_lane_rotate}" || exit $?
EOF
chmod +x "$T/bin/"*

export PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" SPOOL_TEST=1 SPOOL_DESK_BOX=box-desk \
  LEASE_PROC_ROOT="$T/proc" ROTATE_TMUX="$T/bin/tmux" ROTATE_SPAWN="$T/bin/spawn" ROTATE_RUN="$T/bin/run" ROTATE_KILL="$T/bin/kill" \
  ROTATE_SEND="$T/bin/send" ROTATE_AI="$T/bin/ai" ROTATE_HOLD_DIR="$T/hold" ROTATE_MEMORY_DIR="$T/mem" ROTATE_TRANSCRIPT="$T/none.jsonl" \
  ROTATE_AS_AGENT_DIRECT=1 ROTATE_POLL=1 ROTATE_IDLE_SEC=0 ROTATE_IDLE_GRACE=2 ROTATE_ESC_WAIT=2 ROTATE_START_WAIT=4 \
  ROTATE_LANE_ACK_TIMEOUT=8 ROTATE_LANE_EXIT_WAIT=2 ROTATE_TERM_WAIT=2 ROTATE_NEW_EXIT_WAIT=2 ROTATE_START_CHECK_WAIT=2 \
  ROTATE_LANE_SYNC=1 ROTATE_LANE_PROBE_CMD="echo ok probe fine" ROTATE_LANE_LOGIN_CACHE="$T/no-cache" ROTATE_BOOT_GRACE=0
unset SPOOL_AGENT_ID MCP_BOT_AGENT_ID TMUX TMUX_PANE
tick() { DRY_RUN="${DRY:-0}" "$T/bin/act" >>"$T/tick.out" 2>&1; }
n() { if [ -f "$1" ]; then grep -c -- "${2:-.}" "$1" || true; else echo 0; fi; }

# --- 1. two healthy ticks ---------------------------------------------------------
reset; lane c-911 10; lane m-912 20 mistral
tick; tick
check "1. two healthy ticks: 0 spawns" '[ "$(n "$T/spawn.log")" = 0 ]'
check "1. two healthy ticks: 0 stops" '[ "$(n "$T/kill.log")" = 0 ] && [ "$(n "$T/tmux/log" submit)" = 0 ]'
check "1. two healthy ticks: 0 notes" '[ "$(n "$T/send.log")" = 0 ]'
check "1. no ERR trap" '! grep -q ERRTRAP "$T/tick.out"'

# --- 2. a lane mid-push is warned once and deferred; control rotates it ----------
reset; lane c-921 50
"$T/bin/proc" 4921 1 c-921 git 2921 "git push origin HEAD:master"
tick; tick
check "2. mid-push: 0 spawns" '[ "$(n "$T/spawn.log")" = 0 ]'
check "2. mid-push: DEFER names the push" 'grep -q "c-921 DEFER not quiet: running .git push" "$T/tick.out"'
check "2. the warning asks for no reply" 'grep -q "write your state (in your worktree and commits; do not reply to this note)" "$T/send.log"'
check "2. the warning, once, exact text" '[ "$(n "$T/send.log" "-> c-921 note lane-rotate-c-921: rotation at [0-9][0-9]:[0-9][0-9]Z UTC: push what is green, write your state")" = 1 ] && [ "$(n "$T/send.log")" = 1 ]'
rm -rf "$T/proc/4921"
tick
check "2. control (no push): rotated" '[ "$(n "$T/spawn.log")" = 1 ] && grep -q "lane-c-921 DONE OK" "$D/rotate.log"'

# --- 3. the full flow (read on the rotation of 2) ---------------------------------
check "3. same id, same worktree, reuse, own kind" 'grep -q "^spawn claude c-921 $T/wt/c-921 SPAWN_REUSE_ID=1 scope=the c-921 task" "$T/spawn.log"'
check "3. seed: brief, handoff, ack, Files" 'grep -q "lifetime/brief.md" "$T/seed.c-921" && grep -q "^ACK-COMMAND: .*ROTATE_ID=[0-9]*T[0-9]*Z-lane-c-921 ID=c-921" "$T/seed.c-921" && grep -q "^Files: csi-spl-orc/x.sh" "$T/seed.c-921"'
check "3. acked as a result in the outbox" 'grep -q "\"task_id\":\"lane-rotate-.*-lane-c-921\"" "$S/c-921/outbox/"*.json && grep -q "ACK OK sent by pid 3000" "$D/rotate.log"'
check "3. old session got /exit and is gone" 'grep -q "submit %921 /exit" "$T/tmux/log" && [ ! -d "$T/proc/2921" ]'
check "3. old window closed, new one live" '! grep -q "^%921	" "$T/tmux/panes" && grep -q "^%3000	" "$T/tmux/panes"'
check "3. map on the new pid, one process" '[ "$(cat "$T/ai.c-921")" = 3000 ] && grep -q "CLOSE OK old window closed; checks: one process" "$D/rotate.log"'
check "3. handoff written" 'ls "$D/handoff/"*-lane-c-921.md >/dev/null && grep -q "## 1. In flight" "$D/handoff/"*-lane-c-921.md'
check "3. no ERR trap" '! grep -q ERRTRAP "$T/tick.out" "$S/dispatch/lane-rotate/"worker.*.out'

# --- 4. two ticks inside the hour = 1 rotation -------------------------------------
tick
check "4. second tick: still 1 rotation" '[ "$(n "$T/spawn.log")" = 1 ]'
"$T/bin/proc" 3000 4200 c-921 claude 1 "claude --seed"
tick
check "4. rotated < 60 min ago, old pid: never stopped again" '[ "$(n "$T/spawn.log")" = 1 ] && [ ! -s "$T/kill.log" ] && grep -q "c-921 DEFER rotated 0 min ago" "$T/tick.out"'

# --- 5. the cap ------------------------------------------------------------------
reset; for i in 1 2 3 4 5; do lane "c-95$i" 70; done
ROTATE_LANE_SYNC=0 ROTATE_LANE_WORKER="$T/bin/worker" tick
sleep 1
check "5. cap 3: 3 workers of 5" '[ "$(n "$T/worker.log")" = 3 ] && [ "$(n "$T/tick.out" "DEFER cap: 3 rotating")" = 2 ]'
ROTATE_LANE_SYNC=0 ROTATE_LANE_WORKER="$T/bin/worker" tick
sleep 1
check "5. next tick while 3 run: 0 more" '[ "$(n "$T/worker.log")" = 3 ]'
cat "$D/lane-rotate/run."* >"$T/sleepers" 2>/dev/null; xargs -r kill <"$T/sleepers" 2>/dev/null; : >"$T/sleepers"

# --- 6. a dead login --------------------------------------------------------------
reset; lane c-961 70
ROTATE_LANE_PROBE_CMD="echo expired Please run /login" tick
ROTATE_LANE_PROBE_CMD="echo expired Please run /login" tick
check "6. dead login: 0 rotations" '[ "$(n "$T/spawn.log")" = 0 ] && [ ! -s "$T/kill.log" ]'
check "6. dead login: 1 alert to the orch lease holder" '[ "$(n "$T/send.log" "-> c-900 note dispatch-lane-rotate: \*\*lane-rotate@box-desk\*\*: the claude login probe says .expired")" = 1 ]'

reset; lane c-962 70; echo "c-001@box-b $(date +%s)" >"$D/lease.orch"
ROTATE_LANE_PROBE_CMD="echo expired x" tick
check "6. a holder on another box is told as <id>@<box>" '[ "$(n "$T/send.log" "-> c-001@box-b note dispatch-lane-rotate")" = 1 ]'

# --- 7. the deadline ---------------------------------------------------------------
reset; lane c-971 58
"$T/bin/proc" 4971 1 c-971 git 2971 "git push origin HEAD:master"
tick
check "7. busy at 58 min: rotated anyway" 'grep -q "lane-c-971 DONE OK" "$D/rotate.log"'
check "7. the handoff names what was in flight" 'grep -q "deadline while: running .git push" "$D/handoff/"*-lane-c-971.md'

# --- 8. role seats, accepted lanes -----------------------------------------------------
reset; lane c-900 70; lane c-902 70; lane c-982 70
tick
check "8. role seats over 60 min (holder and standby): never touched" '! grep -qE "c-90[02] " "$T/tick.out" && ! grep -qE "^spawn [a-z]+ c-90[02] " "$T/spawn.log" 2>/dev/null'
check "8. control: the plain lane of the same age is rotated" 'grep -q "^spawn claude c-982 " "$T/spawn.log"'
reset; lane c-900 70; lane c-902 70; lane c-981 70
echo '{"v":1,"from":"c-002","to":"c-981","kind":"note","task_id":"t","body":"ACCEPTED: landed"}' >"$S/c-981/archive/a.json"
DRY=1 tick
check "8. an ACCEPTED lane: left to the orchestrator" 'grep -q "c-981 SKIP accepted" "$T/tick.out" && ! grep -q "c-981 PLAN rotate" "$T/tick.out"'
check "8. dry run: nothing touched" '[ "$(n "$T/spawn.log")" = 0 ] && [ "$(n "$T/send.log")" = 0 ] && [ ! -f "$D/rotate.log" ]'

# --- 9. a mistral lane -------------------------------------------------------------------
reset; lane m-991 50 mistral
tick
check "9. mistral: spawned as mistral, acked, DONE" 'grep -q "^spawn mistral m-991" "$T/spawn.log" && grep -q "lane-m-991 DONE OK" "$D/rotate.log"'
check "9. mistral: no login probe needed" '! grep -q "DEFER login" "$T/tick.out"'

# --- 10. a forged ack ----------------------------------------------------------------------
reset; lane c-990 50
printf 'ROTATE_RID=20261011T1900Z-lane-c-990\nROTATE_PHASE=ACK\nROTATE_NEW_PID=3999\n' >"$S/c-990/lifetime/rotate.lane.ctx"
rc=0; ROTATE_CMD=ack ROTATE_ID=20261011T1900Z-lane-c-990 ID=c-990 ROTATE_CALLER_PID=2990 "$T/bin/act" >"$T/forged.out" 2>&1 || rc=$?
check "10. forged ack (wrong pid): exit 3" '[ "$rc" = 3 ] && [ -z "$(ls "$S/c-990/outbox")" ]'
rc=0; ROTATE_CMD=ack ROTATE_ID=20261011T1800Z-lane-c-990 ID=c-990 ROTATE_CALLER_PID=3999 "$T/bin/act" >"$T/forged.out" 2>&1 || rc=$?
check "10. forged ack (unknown rid): exit 3" '[ "$rc" = 3 ]'

# --- 11. the age check ------------------------------------------------------------------------
reset; lane c-911 10; lane g-912 70 grok
rc=0; ACTION=do_spl_agent_age_check "$T/bin/act" >"$T/age.out" 2>&1 || rc=$?
check "11. a 70-min session: exit 1 and its line" '[ "$rc" = 1 ] && grep -q "OLD g-912@box-desk grok pid 2912 70 min" "$T/age.out" && ! grep -q "OLD c-911" "$T/age.out"'
rm -rf "$T/proc/2912"
rc=0; ACTION=do_spl_agent_age_check "$T/bin/act" >"$T/age.out" 2>&1 || rc=$?
check "11. none old: exit 0" '[ "$rc" = 0 ]'
reset; lane g-913 70 grok
"$T/bin/proc" 4913 1 g-913 git 2913 "go test ./..."
ROTATE_LANE_MAX_AGE=7200 tick; ROTATE_LANE_MAX_AGE=7200 tick
check "11. inside the grace: no report (normal ticks send nothing)" '[ "$(n "$T/send.log" "agent-age@")" = 0 ]'
ROTATE_LANE_REPORT_GRACE=0 ROTATE_LANE_MAX_AGE=7200 tick; ROTATE_LANE_REPORT_GRACE=0 ROTATE_LANE_MAX_AGE=7200 tick
check "11. past the grace: ONE note to the orch lease holder, not one a minute" '[ "$(n "$T/send.log" "-> c-900 note dispatch-lane-rotate: \*\*agent-age@box-desk\*\*: not rotated, older than 65 min: g-913@box-desk")" = 1 ] && [ "$(n "$T/send.log" "agent-age@")" = 1 ]'

# --- 13. the task brief survives rotations byte for byte; a seed brief is refused --
reset; lane c-931 50
cp "$S/c-931/lifetime/brief.md" "$T/brief.orig"
echo '{"v":1,"msg_id":"r1","ts":"2026-10-11T18:00:00Z","from":"c-931","to":"c-001","kind":"result","task_id":"dispatch-x","body":"DONE: the thing landed"}' >"$S/c-931/outbox/r1.json"
tick
check "13. first rotation: brief unchanged" 'grep -q "lane-c-931 DONE OK" "$D/rotate.log" && cmp -s "$T/brief.orig" "$S/c-931/lifetime/brief.md"'
check "13. the seed is its own file and points at the brief" 'grep -q "^# Brief: you are c-931@box-desk again" "$T/seed.c-931" && grep -q "$S/c-931/lifetime/brief.md" "$T/seed.c-931"'
check "13. a result already sent: listed in the handoff, the seed says never again" 'grep -q "DONE: the thing landed" "$D/handoff/"*-lane-c-931.md && grep -q "is NOT sent again" "$T/seed.c-931"'
"$T/bin/proc" 3000 3000 c-931 claude 1 "claude --seed"; rm -f "$S/c-931/lifetime/rotate.lane.last"
tick
check "13. second rotation: brief still byte for byte" '[ "$(n "$T/spawn.log")" = 2 ] && cmp -s "$T/brief.orig" "$S/c-931/lifetime/brief.md"'
cp "$T/seed.c-931" "$S/c-931/lifetime/brief.md"; "$T/bin/proc" 3001 3000 c-931 claude 1 "claude --seed"; rm -f "$S/c-931/lifetime/rotate.lane.last"
tick
check "13. red control: a brief that is a rotation seed is refused" '[ "$(n "$T/spawn.log")" = 2 ] && grep -q "is a rotation seed, not a task brief" "$D/rotate.log"'

# --- 14. /exit asks about background work: the picker is confirmed, no SIGTERM --
reset; lane c-941 62
touch "$T/tmux/bgtasks.%941"
ROTATE_LANE_EXIT_WAIT=20 tick
check "14. background-work picker: 'Exit and stop tasks' confirmed" 'grep -q "lane-c-941 RETIRE WAIT pid 2941: ./exit. asked about running background work" "$D/rotate.log" && grep -q "picker %941" "$T/tmux/log"'
check "14. old session gone without a signal" 'grep -q "lane-c-941 DONE OK" "$D/rotate.log" && ! grep -q "TERM 2941" "$T/kill.log" 2>/dev/null'

# --- 15. the ACK-COMMAND is in the first prompt, on top -----------------------
reset; lane c-951 50
tick
# 700: 400 + the truth rule (284 B, SPL-2097) that now leads the head
check "15. first prompt: ACK-COMMAND line, run it before anything else" 'grep -q "^ACK-COMMAND: .*ROTATE_ID=[0-9]*T[0-9]*Z-lane-c-951 ID=c-951 ./run -a do_spl_lane_rotate$" "$T/prompt.c-951" && head -c 700 "$T/prompt.c-951" | grep -q "run it before anything else"'
check "15. first prompt: the same ack as the seed, which keeps it" '[ "$(grep "^ACK-COMMAND:" "$T/prompt.c-951")" = "$(grep "^ACK-COMMAND:" "$T/seed.c-951")" ] && grep -q "$D/handoff/.*-lane-c-951.seed.md" "$T/prompt.c-951"'
check "15. acked from the first prompt alone: DONE" 'grep -q "lane-c-951 DONE OK" "$D/rotate.log"'

# --- 16. standing seat with ACCEPTED is rotated -------------------------------------
reset; lane c-961 50
echo '{"v":1,"from":"c-002","to":"c-961","kind":"note","task_id":"t","body":"ACCEPTED: landed"}' >"$S/c-961/archive/a.json"
touch "$S/c-961/lifetime/standing"
tick
check "16. standing seat with ACCEPTED: rotated" 'grep -q "lane-c-961 DONE OK" "$D/rotate.log"'
reset; lane c-962 50
echo '{"v":1,"from":"c-002","to":"c-962","kind":"note","task_id":"t","body":"ACCEPTED: landed"}' >"$S/c-962/archive/a.json"
tick
check "16. control: non-standing seat with ACCEPTED: skipped" 'grep -q "c-962 SKIP accepted" "$T/tick.out"'

# --- 17. ROTATE_CMD=one with DRY_RUN=1 writes nothing ---------------------------
reset; lane c-971 50
DRY_RUN=1 ROTATE_CMD=one ID=c-971 "$T/bin/act" >"$T/dry.out" 2>&1
check "17. ROTATE_CMD=one DRY_RUN=1: 0 spawns" '[ "$(n "$T/spawn.log")" = 0 ]'
check "17. ROTATE_CMD=one DRY_RUN=1: 0 stops" '[ "$(n "$T/kill.log")" = 0 ]'
check "17. ROTATE_CMD=one DRY_RUN=1: 0 notes" '[ "$(n "$T/send.log")" = 0 ]'
check "17. ROTATE_CMD=one DRY_RUN=1: log says DRY_RUN" 'grep -q "DRY_RUN=1: no rotation" "$T/dry.out"'
reset; lane c-972 50
DRY_RUN=0 ROTATE_CMD=one ID=c-972 "$T/bin/act" >"$T/dry.out" 2>&1
check "17. control: ROTATE_CMD=one DRY_RUN=0: rotated" 'grep -q "lane-c-972 DONE OK" "$D/rotate.log"'
# --- 18. a human hold (.human-hold, a future epoch): hands off (SPL-2431) -------
# a-424 was rotated mid-turn under a 1-year hold on 2026-10-17 19:20Z
reset; lane c-981 58; echo $(( $(date +%s) + 3600 )) >"$S/c-981/.human-hold"
tick
check "18. future hold, past its deadline: 0 spawns, 0 stops, 0 keys" '[ "$(n "$T/spawn.log")" = 0 ] && [ "$(n "$T/kill.log")" = 0 ] && [ "$(n "$T/tmux/log" submit)" = 0 ]'
check "18. future hold: one SKIP line naming the hold" 'grep -q "c-981 SKIP human hold for 60 min" "$T/tick.out"'
DRY_RUN=0 ROTATE_CMD=one ID=c-981 "$T/bin/act" >"$T/one.out" 2>&1
check "18. future hold: the worker (ROTATE_CMD=one) stops nothing either" '[ "$(n "$T/kill.log")" = 0 ] && [ "$(n "$T/spawn.log")" = 0 ] && grep -q "GATE SKIP human hold" "$D/rotate.log"'
check "18. the hold file is left as it was" '[ -s "$S/c-981/.human-hold" ]'
reset; lane c-982 50; echo $(( $(date +%s) - 60 )) >"$S/c-982/.human-hold"
tick
check "18. expired hold: rotated as today" 'grep -q "lane-c-982 DONE OK" "$D/rotate.log"'
reset; lane c-983 50; echo "soon" >"$S/c-983/.human-hold"
tick
check "18. garbage hold: rotated as today" 'grep -q "lane-c-983 DONE OK" "$D/rotate.log"'
reset; lane c-984 50
tick
check "18. control: no hold, rotated" 'grep -q "lane-c-984 DONE OK" "$D/rotate.log" && ! grep -q "c-984 SKIP human" "$T/tick.out"'
P15="$T/plan15"; mkdir -p "$P15" "$T/plain15"; echo "brief" >"$T/brief15.md"; printf 'HEAD15 run it before anything else\nACK-COMMAND: x' >"$T/head15.md"
( unset SPOOL_BOX_ENV; SPOOL_ROOT="$T/spool15" SPAWN_TEST_SANDBOX=1 SPAWN_DRY_RUN=1 SPAWN_PLAN_DIR="$P15" SPOOL_BIN=/opt/x/spool \
  SPAWN_GIT_IDENTITY='FirstName LastName <dev@example.com>' SPAWN_PROMPT_HEAD_FILE="$T/head15.md" \
  bash "$PROJ_ROOT/src/bash/features/spawn-agents/scripts/spawn-claude.sh" c-952 "$T/plain15" "$T/brief15.md" rotate >"$P15/out" 2>&1 )
# the truth rule (SPL-2097) leads every seed, ahead of a head that lacks it
check "15. spawn-core: the truth rule, then SPAWN_PROMPT_HEAD_FILE, lead prompt.txt, the seed follows" '[ "$(head -n1 "$P15/prompt.txt" 2>/dev/null)" = "$(cat "$PROJ_ROOT/src/bash/features/spawn-agents/assets/seed-truth-rule.txt")" ] && [ "$(sed -n 3p "$P15/prompt.txt" 2>/dev/null)" = "HEAD15 run it before anything else" ] && grep -q "^ACK-COMMAND: x$" "$P15/prompt.txt" && grep -q "read your full task brief at $T/brief15.md" "$P15/prompt.txt"'
# the real spawn-window starts the launcher in the pane with an env allowlist:
# the head file must be on it (a live rotation on 2026-10-11 22:25Z lost it there)
check "15. spawn-window forwards SPAWN_PROMPT_HEAD_FILE into the pane" 'sed -n "/^for v in SPOOL_ROOT /,/; do\$/p" "$PROJ_ROOT/src/bash/features/spawn-agents/scripts/spawn-window.sh" | grep -qw SPAWN_PROMPT_HEAD_FILE'

# --- 19. a multi-line busy command is one rotate.log line (SPL-2841) ----------------
# rotate.log held 166 unstamped lines 2026-10-12..22: each a line of a child's
# script, cut one by one after its "in flight: running" line
reset; mkdir -p "$T/proc/100" "$T/proc/200"
echo '100 (claude) S 1 1' >"$T/proc/100/stat"; printf 'claude\0' >"$T/proc/100/cmdline"
echo '200 (bash) S 100 1' >"$T/proc/200/stat"
printf '/bin/bash\0-c\0git push origin HEAD:master\necho two\r\necho three %0200d\0' 0 >"$T/proc/200/cmdline"
out19="$(source "$PROJ_ROOT/src/bash/run/spl-lane-rotate.func.sh"; ROTATE_LANE_BUSY_RE="git push" spl_lane_rotate_busy_child 100)"
check "19. multi-line busy child: 1 line" '[ "$(printf "%s\n" "$out19" | wc -l)" = 1 ]'
check "19. multi-line busy child: at most 120 characters, no CR" '[ "${#out19}" -le 120 ] && [[ "$out19" != *$'"'"'\r'"'"'* ]]'
check "19. multi-line busy child: the command is still named" '[[ "$out19" == "/bin/bash -c git push origin HEAD:master echo two"* ]]'

# --- 20. a new pane stuck before its agent starts: only it is closed (SPL-2864) ------
# rid 20261022T1101Z-lane-c-179: the launcher's fetch asked "Username for
# 'https://...'" in the new pane; nothing carrying the id started in 120 s
cat >"$T/bin/spawn-stuck" <<'EOF2'
#!/usr/bin/env bash
n="$(cat "$T/next")"; echo $((n + 1)) >"$T/next"
echo "spawn $1 $2 $3" >>"$T/spawn.log"
printf '%%%s\t%s\t$0\t%s@box\n' "$n" "$n" "$2" >>"$T/tmux/panes"
printf "INFO: reusing existing worktree\nUsername for 'https://git.example.invalid': \n" >"$T/tmux/screen.%$n"
echo "$2 %$n"
EOF2
chmod +x "$T/bin/spawn-stuck"
reset; lane c-991 70
ROTATE_SPAWN="$T/bin/spawn-stuck" tick
check "20. stuck new pane: FAIL SPAWN names the prompt, the old session keeps the lane" 'grep -q "FAIL FAIL SPAWN: no claude carrying c-991 started in %3000 within 4s; the pane is up, no claude process in it: .*Username for" "$D/rotate.log" && grep -q "the old session (pid 2991) keeps the lane" "$D/rotate.log"'
check "20. stuck new pane: its window closed, the old one not" 'grep -qx "kill %3000" "$T/tmux/log" && ! grep -qx "kill %991" "$T/tmux/log" && ! grep -q "^%3000	" "$T/tmux/panes"'
check "20. the old window keeps its name and its pid" 'grep -q "^%991	2991	.*	c-991@box\$" "$T/tmux/panes" && [ -d "$T/proc/2991" ] && [ "$(n "$T/kill.log")" = 0 ] && [ "$(n "$T/tmux/log" submit)" = 0 ]'

# --- 21. SPL-2898 (E): the old window is already gone when SPAWN renames it ----------
# rotation-failures-2026-10-22.md row 5: c-950, c-279, c-304 were retired 26..62 s
# before their FAIL SPAWN; the rename's stderr went to /dev/null. Now: tmux's
# reason is kept, the run ends SPAWN SKIP retired, no note to the holder.
reset; lane c-992 70; touch "$T/tmux/gone.%992"
tick
check "21. gone old window: SPAWN SKIP retired, tmux's reason kept" 'grep -q " SPAWN SKIP retired: .*can.t find pane: %992" "$D/rotate.log"'
check "21. gone old window: no FAIL, no note to the dispatch holder, nothing spawned" '! grep -q " FAIL FAIL " "$D/rotate.log" && [ "$(n "$T/send.log" "dispatch-lane-rotate")" = 0 ] && [ "$(n "$T/spawn.log")" = 0 ]'
check "21. gone old window: the lane ctx ends ABORT" 'grep -qx "ROTATE_PHASE=ABORT" "$S/c-992/lifetime/rotate.lane.ctx"'
check "21. no stray failing command under the ERR trap" '! grep -q ERRTRAP "$T/tick.out"'
# --- 22. SPL-3779: the vendor on its limit = SKIP before SPAWN, not a failure ------------
# a box on 2026-10-27, rid 20261027T0237Z-lane-a-751: agy on "Individual quota
# reached" was spawned, waited 600 s for an ack and failed, every 15 min.
reset; lane c-961 70; lane a-962 70 agy; lane m-964 70 mistral
mkdir -p "$D/wd/ctx.1/c-961" "$D/wd/ctx.1/a-963"
echo 'HIT S2 kind=limit pane: You have hit your limit' >"$D/wd/ctx.1/c-961/out.s2"
echo 'HIT S2 kind=limit pane: Individual quota reached' >"$D/wd/ctx.1/a-963/out.s2"
ROTATE_CLAUDE_BIN=/bin/true tick
check "22. claude lane on its own limit verdict: SKIP logged with the reset, no spawn" 'grep -qE "c-961 SKIP c-961: claude is on its limit until [0-9-]+T[0-9:]+Z \(c-961 S2 kind=limit" "$T/tick.out" && ! grep -q "spawn claude c-961" "$T/spawn.log"'
check "22. agy lane, another a- seat on the limit: SKIP, no spawn" 'grep -qE "a-962 SKIP a-962: agy is on its limit until [0-9-]+T[0-9:]+Z \(a-963 S2 kind=limit" "$T/tick.out" && ! grep -q "spawn agy a-962" "$T/spawn.log"'
check "22. control: the mistral lane (no limit) rotated in the same tick" 'grep -q "^spawn mistral m-964" "$T/spawn.log" && grep -q "lane-m-964 DONE OK" "$D/rotate.log"'
check "22. the skips are no failure: no FAIL, no note, no failed-rotation stamp" '! grep -qE "lane-(c-961|a-962) .*FAIL" "$D/rotate.log" && [ "$(n "$T/send.log" "dispatch-lane-rotate")" = 0 ] && [ ! -e "$S/c-961/lifetime/rotate.lane.last" ] && [ ! -e "$S/a-962/lifetime/rotate.lane.last" ]'
rm -f "$D/wd/ctx.1/c-961/out.s2" "$D/wd/ctx.1/a-963/out.s2"
ROTATE_CLAUDE_BIN=/bin/true tick
check "22. the limit gone: both lanes rotated on the next tick" 'grep -q "lane-c-961 DONE OK" "$D/rotate.log" && grep -q "lane-a-962 DONE OK" "$D/rotate.log"'
# the same for mistral, lane-mix's reader (a vendor's limit holds all its lanes)
reset; lane m-965 70 mistral; mkdir -p "$D/wd/ctx.1/m-965"
echo 'HIT S2 kind=limit pane: rate limit' >"$D/wd/ctx.1/m-965/out.s2"
tick
check "22. mistral lane on its own limit verdict (lane-mix reader): SKIP, no spawn" 'grep -qE "m-965 SKIP m-965: mistral is on its limit until [0-9-]+T[0-9:]+Z \\(m-965 S2 kind=limit" "$T/tick.out" && ! grep -q "spawn mistral m-965" "$T/spawn.log"'
check "22. no stray failing command under the ERR trap" '! grep -q ERRTRAP "$T/tick.out"'
# --- 23. SPL-3792: the agent-age notice keeps the digits of its DEFER reason ----------
# a box on 2026-10-27, notice b210a09d: "(DEFER rotation TZ-lane-a- failed min ago:
# next try after min)": the digit-free dedupe key of why.<id> was printed as the text.
reset; lane a-665 97 agy
echo "$(( $(date +%s) - 200 )) 20261027T0322Z-lane-a-665 FAIL" >"$S/a-665/lifetime/rotate.lane.last"
ROTATE_LANE_RETRY=900 ROTATE_LANE_REPORT_GRACE=0 tick; ROTATE_LANE_RETRY=900 ROTATE_LANE_REPORT_GRACE=0 tick
check "23. the notice keeps the rid, the minutes and the retry" '[ "$(n "$T/send.log" "agent-age@box-desk.*a-665@box-desk agy pid 2665 97 min (DEFER rotation 20261027T0322Z-lane-a-665 failed 3 min ago: next try after 15 min)")" = 1 ]'
check "23. the dedupe still holds: one DEFER line for two ticks" '[ "$(n "$T/tick.out" "a-665 DEFER rotation")" = 1 ] && [ "$(n "$D/lane-rotate/lane-rotate.log" "a-665 DEFER rotation")" = 1 ]'
check "23. no stray failing command under the ERR trap" '! grep -q ERRTRAP "$T/tick.out"'
# --- 24. SPL-3812: agy's quota banner on an a- pane = SKIP, not a failed ACK every 15 min ---
# a box on 2026-10-27: a-289 failed ACK at 0506Z, 0532Z, 0558Z, 0624Z while
# spl_spawn_place_agy_out printed "agy is out of quota until 2026-10-30T22:05:21Z".
QP="$TEST_DIR/fixtures/wd-situations/s2-agy-quota.pane"
banner() { mkdir -p "$D/wd/ctx.1/$1"; sed 's/Resets in [0-9hms]*\./Resets in 2h./' "$QP" >"$D/wd/ctx.1/$1/pane"; }
reset; lane a-971 70 agy; banner a-972
tick; tick
check "24. banner on an a- pane: the agy lane SKIPped, the reset named" 'grep -qE "a-971 SKIP a-971: agy is on its limit until [0-9-]+T[0-9:]+Z \(a-972 banner, Resets in 2h\)" "$T/tick.out"'
check "24. banner: ONE skip line for two ticks, nothing spawned, no note, no fail stamp" '[ "$(n "$D/lane-rotate/lane-rotate.log" "a-971 SKIP")" = 1 ] && [ "$(n "$T/spawn.log")" = 0 ] && [ "$(n "$T/send.log")" = 0 ] && [ ! -e "$S/a-971/lifetime/rotate.lane.last" ]'
reset; lane a-973 70 agy
tick
check "24. control: no banner, the agy lane rotated as before" 'grep -q "^spawn agy a-973" "$T/spawn.log" && grep -q "lane-a-973 DONE OK" "$D/rotate.log"'
reset; lane a-974 70 agy; banner a-975; touch -d "-3 hours" "$D/wd/ctx.1/a-975/pane"
tick
check "24. control: the reset is past (2h after a pane 3 h old), the agy lane rotated" '! grep -q "a-974 SKIP" "$T/tick.out" && grep -q "lane-a-974 DONE OK" "$D/rotate.log"'
reset; lane c-976 70; banner a-977
ROTATE_CLAUDE_BIN=/bin/true tick
check "24. control: a c- lane beside the agy banner rotated" 'grep -q "^spawn claude c-976" "$T/spawn.log" && grep -q "lane-c-976 DONE OK" "$D/rotate.log"'
check "24. no stray failing command under the ERR trap" '! grep -q ERRTRAP "$T/tick.out"'
# --- 25. SPL-3982: a tmux call into the old pane hangs in RETIRE: bounded, TERM by its pid --
# 20261027T1612Z-lane-c-423: RETIRE WAIT at 16:14:37Z, its next line at 16:56:43Z,
# both sessions of c-423 acting in between. Run under a hard timeout: an
# unbounded call fails this test instead of hanging the suite.
reset; lane c-251 70; echo %251 >"$T/at-spawn.hang"
DRY_RUN=0 ROTATE_LANE_TMUX_TIMEOUT=2 timeout 40 "$T/bin/act" >>"$T/tick.out" 2>&1
check "25. a hung old pane: RETIRE ends by SIGTERM of its own pid, DONE" 'grep -q "lane-c-251 RETIRE WAIT pid 2251: ./exit. never read back, no Enter: SIGTERM" "$D/rotate.log" && grep -q "^kill -TERM 2251$" "$T/kill.log" && grep -q "lane-c-251 DONE OK" "$D/rotate.log"'
check "25. a hung old pane: one session left (the new one)" '[ ! -d "$T/proc/2251" ] && [ -d "$T/proc/3000" ] && grep -q "lane-c-251 CLOSE OK old window closed; checks: one process" "$D/rotate.log"'
check "25. no ERR trap" '! grep -q ERRTRAP "$T/tick.out" "$D/lane-rotate/"worker.*.out'
rm -f "$T/at-spawn.hang"

# --- 26. SPL-3982: another session of the id starts after GATE (a hand restore) ----------
reset; lane c-252 70; echo "5252 %5252" >"$T/at-spawn.extra"
tick
check "26. the extra session in its own pane: /exit, gone, its window closed" 'grep -q "lane-c-252 RETIRE WAIT pid 5252 in %5252 also carries c-252" "$D/rotate.log" && grep -q "submit %5252 /exit" "$T/tmux/log" && [ ! -d "$T/proc/5252" ] && grep -q "^kill %5252$" "$T/tmux/log"'
check "26. one session left, the new one; the old one gone too" '[ -d "$T/proc/3000" ] && [ ! -d "$T/proc/2252" ] && grep -q "lane-c-252 CLOSE OK old window closed; checks: one process" "$D/rotate.log"'
reset; lane c-253 70; echo "5253 NEW" >"$T/at-spawn.extra"
tick
check "26. control: a process of the id inside the NEW pane is left, the check counts it" 'grep -q "lane-c-253 RETIRE WAIT pid 5253 also carries c-253, in %3000: left" "$D/rotate.log" && [ -d "$T/proc/5253" ] && [ -d "$T/proc/3000" ] && grep -q "lane-c-253 CLOSE WAIT .*processes=2" "$D/rotate.log"'
check "26. no ERR trap" '! grep -q ERRTRAP "$T/tick.out"'
rm -f "$T/at-spawn.extra"

# --- 27. SPL-4358: one tick reads each vendor's limit once, not once per lane ------------
# sat 2026-10-30: one tick held tick.lock from <=05:56Z to ~06:58Z; the
# claude limit read took 63..90 s a lane on a loaded box (n=1, a box at load 14),
# so 3 starts an hour and lanes at 177 min. A slow fake read (2 s, counted):
# 8 claude lanes past WARN = ONE read and a tick far under 8 x 2 s.
cat >"$T/bin/act-slow" <<'SLOW'
#!/usr/bin/env bash
set -E
trap 'echo "ERRTRAP: $BASH_COMMAND (line $LINENO)"; exit 99' ERR
do_log() { echo "$*"; }
source "$PROJ_PATH/src/bash/run/spl-lane-rotate.func.sh"
# the readers it sources by its own path, before it is renamed below
source "$PROJ_PATH/src/bash/run/spl-lane-mix.func.sh"
source "$PROJ_PATH/src/bash/run/spl-spawn-place.func.sh"
eval "$(declare -f spl_lane_rotate_limit | sed '1s/^spl_lane_rotate_limit/_lr_limit_real/')"
spl_lane_rotate_limit() { echo "$2" >>"$T/limit.calls"; sleep 2; _lr_limit_real "$@"; }
do_spl_lane_rotate
SLOW
chmod +x "$T/bin/act-slow"
reset; rm -f "$T/limit.calls"
for i in 1 2 3 4 5 6 7 8; do lane "c-27$i" 50; done
lane m-279 50 mistral
t0=$(date +%s); DRY_RUN=1 ROTATE_CLAUDE_BIN=/bin/true "$T/bin/act-slow" >>"$T/tick.out" 2>&1; t1=$(date +%s)
check "27. 8 claude lanes + 1 mistral: the limit read once per kind (claude 1, mistral 1)" '[ "$(n "$T/limit.calls" "^claude$")" = 1 ] && [ "$(n "$T/limit.calls" "^mistral$")" = 1 ]'
check "27. the slow read does not scale with the lanes: tick $((t1 - t0)) s < 16 s (8 x 2 s)" '(( t1 - t0 < 16 ))'
check "27. every lane still judged: 3 claude PLAN rotate + 5 DEFER cap" '[ "$(grep -cE "c-27[1-8] PLAN rotate" "$T/tick.out")" = 3 ] && [ "$(grep -cE "c-27[1-8] DEFER cap" "$T/tick.out")" = 5 ]'
check "27. no ERR trap" '! grep -q ERRTRAP "$T/tick.out"'
# the scan itself: 300 verdict files = no awk and one stat per call (it was an
# awk + a stat per file: 3,222 files = 63 s); a limit in the newest still found
rm -rf "$T/wd27"; mkdir -p "$T/cnt"
for i in $(seq 100 399); do mkdir -p "$T/wd27/ctx.1/c-$i"; : >"$T/wd27/ctx.1/c-$i/out.s2"; touch -d '2 hours ago' "$T/wd27/ctx.1/c-$i/out.s2"; done
mkdir -p "$T/wd27/ctx.1/g-400"; echo 'HIT S2 kind=limit pane: weekly limit' >"$T/wd27/ctx.1/g-400/out.s2"
echo 'HIT S2 kind=limit pane: You have hit your limit' >"$T/wd27/ctx.1/c-399/out.s2"
for t in awk stat; do printf '#!/usr/bin/env bash\necho x >>"%s/cnt/%s"\nexec %s "$@"\n' "$T" "$t" "$(command -v $t)" >"$T/cnt/$t.sh"; done
mkdir -p "$T/cntbin"; mv "$T/cnt/awk.sh" "$T/cntbin/awk"; mv "$T/cnt/stat.sh" "$T/cntbin/stat"; chmod +x "$T/cntbin/"*
scan27() { ( export SPOOL_ROOT="$S" LANE_MIX_WD_DIR="$T/wd27" ROTATE_CLAUDE_BIN=/bin/true PATH="$T/cntbin:$PATH"
  source "$PROJ_ROOT/src/bash/run/spl-rotate-lib.func.sh"; "$1" ); }
rm -f "$T/cnt/awk" "$T/cnt/stat"; o27c="$(scan27 spl_rotate_claude_out)"; c27a="$(n "$T/cnt/awk")"; c27s="$(n "$T/cnt/stat")"
check "27. claude scan of 300 files: 0 awk, 1 stat (got awk=$c27a stat=$c27s)" '[ "$c27a" = 0 ] && [ "$c27s" = 1 ]'
check "27. claude scan still finds the newest limit verdict" '[[ "$o27c" == "c-399 S2 kind=limit 0m ago: pane: You have hit your limit" ]]'
rm -f "$T/cnt/awk" "$T/cnt/stat"; o27g="$(scan27 spl_rotate_grok_out)"; c27a="$(n "$T/cnt/awk")"; c27s="$(n "$T/cnt/stat")"
check "27. grok scan of 301 files: 0 awk, 1 stat (got awk=$c27a stat=$c27s)" '[ "$c27a" = 0 ] && [ "$c27s" = 1 ]'
check "27. grok scan still finds its limit verdict" '[[ "$o27g" == "g-400 S2 kind=limit 0m ago: pane: weekly limit" ]]'

# --- 12. the cron row ----------------------------------------------------------------------------
M="$PROJ_ROOT/cnf/box-crons/box-crons.manifest"
check "12. manifest row lane-rotate, every minute" 'grep -qE "^lane-rotate +\| \* \* \* \* \* +\| src/bash/scripts/lane-rotate-cron.sh +\| lane-rotate/cron.log" "$M"'
check "12. the cron script is executable" '[ -x "$PROJ_ROOT/src/bash/scripts/lane-rotate-cron.sh" ]'

echo "lane-rotate: $fails failure(s)"
[ "$fails" = 0 ]
