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
  comm=claude; [ "$kind" = mistral ] && comm="Vibe CLI"; [ "$kind" = grok ] && comm=grok
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
  rename-window) awk -F'\t' -v OFS='\t' -v p="$tgt" -v n="${args[0]}" '$1 == p {$4 = n} {print}' "$P" >"$P.new" && mv "$P.new" "$P"
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
# fake agent runs ONLY the seed's ACK-COMMAND line
cat >"$T/bin/spawn" <<'EOF'
#!/usr/bin/env bash
n="$(cat "$T/next")"; echo $((n + 1)) >"$T/next"
echo "spawn $1 $2 $3 SPAWN_REUSE_ID=${SPAWN_REUSE_ID:-} scope=${SPAWN_LANE_SCOPE:-}" >>"$T/spawn.log"
cp "$4" "$T/seed.$2"
cp -f "$4" "$SPOOL_ROOT/$2/lifetime/brief.md"
printf '%%%s\t%s\t$0\t%s@box\n' "$n" "$n" "$2" >>"$T/tmux/panes"
comm=claude; [ "$1" = mistral ] && comm="Vibe CLI"
"$T/bin/proc" "$n" 0 "$2" "$comm" 1 "$1 --seed"
rid="$(grep '^ACK-COMMAND:' "$4" | grep -oE 'ROTATE_ID=[0-9A-Za-z-]+' | cut -d= -f2)"
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

# --- 12. the cron row ----------------------------------------------------------------------------
M="$PROJ_ROOT/cnf/box-crons/box-crons.manifest"
check "12. manifest row lane-rotate, every minute" 'grep -qE "^lane-rotate +\| \* \* \* \* \* +\| src/bash/scripts/lane-rotate-cron.sh +\| lane-rotate/cron.log" "$M"'
check "12. the cron script is executable" '[ -x "$PROJ_ROOT/src/bash/scripts/lane-rotate-cron.sh" ]'

echo "lane-rotate: $fails failure(s)"
[ "$fails" = 0 ]
