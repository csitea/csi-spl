#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-4501. do_spl_lane_rotate never rotates a role seat, also while
#          a role rotation switches it. On 2026-10-31 the master rotation
#          20261031T1115Z-master flipped lease.conf LEASE_MASTER g-002 ->
#          c-002 at 11:16:00Z (its seat switch); the lane-rotate tick at
#          11:16:15Z read the still-running g-002 as a lane and started
#          20261031T1116Z-lane-g-002 on it; both failed their ack and rolled
#          back. The sandbox of lane-rotate.tst.sh: fake /proc, tmux stub,
#          spawn stub, private SPOOL_ROOT; no real seat, lease or tmux.
#   1. a role rotation in flight on g-002 (its ctx at ACK, lease.conf
#      already flipped to c-002): the tick SKIPs g-002 with one line naming
#      the role rotation, nothing spawned on it; a plain lane of the same
#      age is rotated in the same tick (control)
#   2. the worker started for g-002 anyway (ROTATE_CMD=one): GATE SKIP
#      "role seat", exit 0, nothing spawned
#   3. red control: the same tick with spl_lane_rotate_role_inflight
#      emptied rotates g-002 (the case 1 check would catch it)
#   4. the role rotation ended (ctx FAIL) or its ctx is stale: g-002 is a
#      lane again and rotated
#   5. lease.conf names c-002, its seat runs as g-002 (the only live dir):
#      g-002 is left out; the orch lease holder on this box is left out, a
#      dispatch holder on another box is rotated here as a lane
#------------------------------------------------------------------------------
# shellcheck disable=SC2034 # rc is read inside the check strings (eval)
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
T=$(mktemp -d)
cleanup() { rm -rf "${T:?}"; }
trap cleanup EXIT
S="$T/spool"; D="$S/dispatch"
TCK="$(getconf CLK_TCK)"; UP=100000
export T S D UP TCK

reset() {
  rm -rf "${T:?}/proc" "${T:?}/tmux" "${S:?}" "${T:?}"/*.log "${T:?}"/*.out "${T:?}/ai."* "${T:?}/next" "${T:?}/wt"
  mkdir -p "$T/bin" "$T/proc" "$T/tmux" "$D" "$T/wt"
  : >"$T/tmux/panes"
  echo "$UP.00 0.00" >"$T/proc/uptime"
  printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\n' "$(id -un)" "$(id -un)" >"$S/box.env"
  conf c-002
  echo "c-001@box-desk $(date +%s)" >"$D/lease.orch"
  echo "c-003@box-b $(date +%s)" >"$D/lease"
  echo 3000 >"$T/next"
}
# conf <master>: lease.conf with that LEASE_MASTER
conf() {
  printf 'LEASE_ORCH=c-001\nLEASE_MASTER=%s\nLEASE_FAILOVER=c-003\nLEASE_FLEET=main\nLEASE_ENV=prd\nLEASE_TENANT=t1\n' "$1" >"$D/lease.conf"
}

# role_rot <phase> [age-s]: the master rotation of g-002 (seat switch to
# c-002) as do_spl_dispatch_rotate saves its ctx, lease.conf already flipped
role_rot() {
  local rid="20261031T1115Z-master"
  printf 'ROTATE_RID=%s\nROTATE_PHASE=%s\nROTATE_OLD_PID=2002\nROTATE_OLD_PANE=%%002\nROTATE_OLD_NAME=g-002@box\nROTATE_NEW_PID=\nROTATE_NEW_PANE=\nROTATE_QUIESCE=idle\nROTATE_HANDOFF=%s\nROTATE_SWITCH_FROM=g-002\nROTATE_SWITCH_TO=c-002\nROTATE_RUN_PID=\nROTATE_RUN_START=\n' \
    "$rid" "$1" "$D/handoff/$rid-g-002.md" >"$D/rotate.dispatch.ctx"
  [ -z "${2:-}" ] || touch -d "@$(( $(date +%s) - $2 ))" "$D/rotate.dispatch.ctx"
  mkdir -p "$S/c-002/lifetime"
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
# LR_FUNC: a planted copy (the red control), outside run/: the lib by its own path first
[ -z "${LR_FUNC:-}" ] || source "$PROJ_PATH/src/bash/run/spl-rotate-lib.func.sh"
source "${LR_FUNC:-$PROJ_PATH/src/bash/run/spl-lane-rotate.func.sh}"
"${ACTION:-do_spl_lane_rotate}" || exit $?
EOF
chmod +x "$T/bin/"*

export PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" SPOOL_TEST=1 SPOOL_DESK_BOX=box-desk \
  LEASE_PROC_ROOT="$T/proc" ROTATE_TMUX="$T/bin/tmux" ROTATE_SPAWN="$T/bin/spawn" ROTATE_RUN="$T/bin/run" ROTATE_KILL="$T/bin/kill" \
  ROTATE_SEND="$T/bin/send" ROTATE_AI="$T/bin/ai" ROTATE_HOLD_DIR="$T/hold" ROTATE_MEMORY_DIR="$T/mem" ROTATE_TRANSCRIPT="$T/none.jsonl" \
  ROTATE_AS_AGENT_DIRECT=1 ROTATE_POLL=1 ROTATE_IDLE_SEC=0 ROTATE_IDLE_GRACE=2 ROTATE_ESC_WAIT=2 ROTATE_START_WAIT=4 \
  ROTATE_LANE_ACK_TIMEOUT=8 ROTATE_LANE_EXIT_WAIT=2 ROTATE_TERM_WAIT=2 ROTATE_NEW_EXIT_WAIT=2 ROTATE_START_CHECK_WAIT=2 \
  ROTATE_LANE_SYNC=1 ROTATE_LANE_PROBE_CMD="echo ok probe fine" ROTATE_LANE_LOGIN_CACHE="$T/no-cache" ROTATE_BOOT_GRACE=0
unset SPOOL_AGENT_ID MCP_BOT_AGENT_ID TMUX TMUX_PANE LR_FUNC
tick() { DRY_RUN=0 "$T/bin/act" >>"$T/tick.out" 2>&1; }
n() { if [ -f "$1" ]; then grep -c -- "${2:-.}" "$1" || true; else echo 0; fi; }
spawned() { grep -q "^spawn [a-z]* $1 " "$T/spawn.log" 2>/dev/null; }

# --- 1. a role rotation in flight: the tick skips its seat --------------------------
reset; role_rot ACK; lane g-002 70; lane c-982 70
tick
check "1. role rotation in flight on g-002: nothing spawned on it" '! spawned g-002'
check "1. one clear SKIP line names the role rotation" '[ "$(n "$T/tick.out" "g-002 SKIP role seat: the role rotation 20261031T1115Z-master acts on g-002")" = 1 ]'
check "1. g-002 is neither warned nor stopped" '! grep -q "g-002" "$T/send.log" 2>/dev/null && ! grep -q "%002 /exit" "$T/tmux/log" 2>/dev/null && [ -d "$T/proc/2002" ]'
check "1. control: the plain lane of the same age is rotated in the same tick" 'spawned c-982 && grep -q "lane-c-982 DONE OK" "$D/rotate.log"'
check "1. no ERR trap" '! grep -q ERRTRAP "$T/tick.out"'

# --- 2. the worker, started anyway, refuses at its gate --------------------------------
reset; role_rot SPAWN; lane g-002 70
rc=0; ROTATE_CMD=one ID=g-002 LANE_ROTATE_PID=2002 DRY_RUN=0 "$T/bin/act" >"$T/one.out" 2>&1 || rc=$?
check "2. worker on a seat a role rotation holds: exit 0, nothing spawned" '[ "$rc" = 0 ] && ! spawned g-002 && [ -d "$T/proc/2002" ]'
check "2. worker: GATE SKIP role seat, naming the rotation" 'grep -q "lane-g-002 GATE SKIP role seat: g-002 is a role seat or a role rotation acts on it (20261031T1115Z-master)" "$D/rotate.log"'

# --- 3. red control: without the in-flight read, g-002 is rotated -----------------------
reset; role_rot ACK; lane g-002 70
sed 's/^spl_lane_rotate_role_inflight() {$/&\n  return 0/' "$PROJ_ROOT/src/bash/run/spl-lane-rotate.func.sh" >"$T/lr-red.func.sh"
check "3. red control: the planted copy differs from the real file" '! cmp -s "$T/lr-red.func.sh" "$PROJ_ROOT/src/bash/run/spl-lane-rotate.func.sh"'
LR_FUNC="$T/lr-red.func.sh" tick
check "3. red control: without the skip the same tick rotates g-002 (case 1 catches it)" 'spawned g-002 && ! grep -q "g-002 SKIP role seat" "$T/tick.out"'

# --- 4. the role rotation is over or stale: a lane again ---------------------------------------
reset; role_rot FAIL; lane g-002 70
tick
check "4. ctx FAIL, g-002 no role: rotated as a lane" 'spawned g-002 && ! grep -q "g-002 SKIP role seat" "$T/tick.out"'
reset; role_rot ACK 4000; lane g-002 70
tick
check "4. a ctx saved > ROTATE_HOLD_MAX ago: rotated as a lane" 'spawned g-002'

# --- 5. live seat and lease holders ------------------------------------------------------------
reset; lane g-002 70; lane g-907 70; lane c-908 70
echo "g-907@box-desk $(date +%s)" >"$D/lease.orch"; echo "c-908@box-b $(date +%s)" >"$D/lease"
tick
check "5. lease.conf c-002, its seat live as g-002: left out" '! spawned g-002 && ! grep -q "g-002 " "$T/tick.out"'
check "5. the orch lease holder on this box: left out" '! spawned g-907'
check "5. a dispatch holder on another box: rotated here as a lane" 'spawned c-908'

[ "$fails" -eq 0 ] && echo "ALL PASS" || echo "$fails FAILED"
exit "$fails"
