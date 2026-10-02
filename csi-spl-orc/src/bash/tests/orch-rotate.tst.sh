#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the hourly orchestrator rotation (spec 060 section 4.2, CLE-77939):
#          do_spl_orch_rotate on spl-rotate-lib.func.sh, and
#          do_spl_orch_rotate_install_cron, in a sandbox. Nothing real is
#          touched: processes live in a fake /proc (LEASE_PROC_ROOT), tmux is a
#          stub keeping panes in a file, the spawn starts a fake claude that
#          runs ONLY its seed's ack line (T-NO-MODEL), ./run, spool-send, kill
#          and the identity map are stubs. The action runs under ./run's
#          `set -E` + ERR trap, so a stray failing command fails the test.
#   1. L1 shape: dry run = PLAN lines + the handoff preview (all 9 sections),
#      nothing written, renamed or spawned
#   2. T-ORCH-GATES: disabled (env, rotate.conf), standby, absent, duplicate,
#      young, stalled (the usage-limit footer), locked
#   3. T-ORCH-HAPPY + T-ORCH-BUSY + T-ORCH-POKE-ROUTE + T-MSG-IN-FLIGHT:
#      a busy session: Escape, the handoff holds the stopped screen; old
#      window <ID>-<hhmm>Z-retiring (parses as no id), map adopts the new pid
#      before ACK, ack = result in <ID>/outbox, /exit-clean, window closed,
#      one process left, DONE note; every inbox message kept
#   4. a re-run right after: SKIP young
#   5. T-ORCH-ACK-TIMEOUT: new closed with /exit, old name + map back, old pid
#      untouched and told where its handoff is, ALERT = ask + owner DM
#   6. T-ORCH-SPAWN-FAIL: no pane / no pid: restored, FAIL spawn, ALERT
#   7. T-ORCH-EXIT-HANG: /exit-clean ignored -> TERM; TERM ignored -> KILL;
#      KILL ignored -> FAIL exit + ALERT, next run SKIP duplicate
#   8. T-ORCH-RESUME: left at ACK with its ack on disk -> finishes; left at
#      SPAWN with the new pid dead -> fails cleanly; abort (FR-091)
#   9. T-ACK-FORGED: a wrong pid, an unknown rid -> exit 3
#  10. T-CRON: dry run, exact line at :05, idempotent, check, CRON_REMOVE=1,
#      a worktree source refused, a missing tool named
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
S="$T/spool"; D="$S/dispatch"
mkdir -p "$T/bin" "$T/proc" "$T/tmux" "$D" "$S/CLE-900/inbox" "$S/CLE-900/outbox" "$S/CLE-900/archive" "$T/hold/sat-drill" "$T/mem"
TCK="$(getconf CLK_TCK)"; UP=100000
echo "$UP.00 0.00" >"$T/proc/uptime"
printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\n' "$(id -un)" "$(id -un)" >"$S/box.env"
printf 'LEASE_ORCH=CLE-900\nLEASE_ENV=prd\nLEASE_TENANT=t1\nASKS_OWNER=HUM-10\n' >"$D/lease.conf"
printf '# Satellite drill\nwaits on the owner\nNEXT: start the drill when the owner says go\n' >"$T/hold/sat-drill/notes.md"
echo x >"$T/mem/orchestrator-never-codes.md"
{ echo '{"type":"user","message":{"content":"owner: lower the budget"}}'
  echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}'
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Routed the budget ask to CLE-77925."}]}}'; } >"$T/transcript.jsonl"

# --- stubs --------------------------------------------------------------------
# proc <pid> <age-s>: a fake claude carrying SPOOL_AGENT_ID=CLE-900
cat >"$T/bin/proc" <<'EOF'
#!/usr/bin/env bash
d="$T/proc/$1"; mkdir -p "$d"; echo claude >"$d/comm"
printf 'SPOOL_AGENT_ID=CLE-900\0' >"$d/environ"
echo "$1 (claude) S 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 $(( (UP - $2) * TCK ))" >"$d/stat"
printf 'Uid:\t%s\t%s\n' "$(id -u)" "$(id -u)" >"$d/status"
EOF
# tmux: panes in $T/tmux/panes as "<pane>\t<pid>\t<session>\t<name>"
cat >"$T/bin/tmux" <<'EOF'
#!/usr/bin/env bash
P="$T/tmux/panes"; L="$T/tmux/log"
cmd="$1"; shift
tgt="" lit=0 args=()
while [ $# -gt 0 ]; do case "$1" in -t) tgt="$2"; shift 2 ;; -l) lit=1; shift ;; -a|-p|-J) shift ;; -F|-S) shift 2 ;; *) args+=("$1"); shift ;; esac; done
field() { awk -F'\t' -v p="$tgt" -v f="$1" '$1 == p {print $f}' "$P"; }
case "$cmd" in
  list-panes) awk -F'\t' '{print $2" "$1}' "$P" ;;
  display-message) grep -q "^$tgt	" "$P" || exit 1
    case "${args[0]}" in *window_name*) field 4 ;; *session_id*) field 3 ;; *pane_id*) echo "$tgt" ;; esac ;;
  capture-pane) grep -q "^$tgt	" "$P" || exit 1
    if [ -f "$T/tmux/screen.$tgt" ]; then cat "$T/tmux/screen.$tgt"; else printf 'some output\n❯ \n'; fi ;;
  rename-window) awk -F'\t' -v OFS='\t' -v p="$tgt" -v n="${args[0]}" '$1 == p {$4 = n} {print}' "$P" >"$P.new" && mv "$P.new" "$P"
    echo "rename $tgt ${args[0]}" >>"$L" ;;
  send-keys) k="${args[0]}"; echo "keys $tgt $k" >>"$L"
    if [ "$lit" = 1 ]; then printf '%s' "$k" >>"$T/tmux/typed.$tgt"
    elif [ "$k" = C-u ]; then : >"$T/tmux/typed.$tgt"
    elif [ "$k" = Escape ]; then
      [ -f "$T/tmux/escape-stops.$tgt" ] && printf 'working on the satellite drill\n  ⎿  Interrupted · What should Claude do instead?\n❯ \n' >"$T/tmux/screen.$tgt"
    elif [ "$k" = Enter ]; then
      if grep -q '^/exit' "$T/tmux/typed.$tgt" 2>/dev/null && [ ! -f "$T/tmux/stubborn.$tgt" ]; then rm -rf "$T/proc/$(field 2)"; fi
      : >"$T/tmux/typed.$tgt"
    fi ;;
  kill-window) awk -F'\t' -v p="$tgt" '$1 != p' "$P" >"$P.new" && mv "$P.new" "$P"; echo "kill $tgt" >>"$L" ;;
  *) echo "tmux stub: $cmd" >&2; exit 1 ;;
esac
EOF
# spawn-window.sh: <kind> <ID> <workdir> <seed> <slug> -> "<ID> <pane>"; the
# fake claude runs ONLY the seed's ACK-COMMAND line (no model: T-NO-MODEL)
cat >"$T/bin/spawn" <<'EOF'
#!/usr/bin/env bash
echo "spawn $* SPAWN_REUSE_ID=${SPAWN_REUSE_ID:-} SPOOL_SESSION=${SPOOL_SESSION:-}" >>"$T/spawn.log"
mode="$(cat "$T/spawn.mode" 2>/dev/null || echo ok)"
[ "$mode" = nopane ] && { echo "spawn-window: no pane"; exit 4; }
printf '%%20\t2001\t$0\t%s@box\n' "$2" >>"$T/tmux/panes"
[ "$mode" = nostart ] || "$T/bin/proc" 2001 0
# a message lands mid-rotation (T-MSG-IN-FLIGHT)
echo '{"v":1,"msg_id":"m9","ts":"2026-10-02T04:06:00Z","from":"CLE-002","to":"CLE-900","kind":"note","task_id":"x","body":"mid-rotation"}' >"$SPOOL_ROOT/CLE-900/inbox/m9.json"
if [ "$(cat "$T/ack.mode" 2>/dev/null || echo yes)" = yes ]; then
  rid="$(grep '^ACK-COMMAND:' "$4" | grep -oE 'ROTATE_ID=[0-9A-Za-z-]+' | cut -d= -f2)"
  ( sleep 1; ROTATE_CMD=ack ROTATE_ID="$rid" ROTATE_CALLER_PID=2001 "$T/bin/act" >>"$T/ack.out" 2>&1 ) >/dev/null 2>&1 &
fi
echo "$2 %20"
EOF
# ./run: the ask book, the lane map, the alert legs
cat >"$T/bin/run" <<'EOF'
#!/usr/bin/env bash
a="$2"
echo "$a ASK_KIND=${ASK_KIND:-} ASK_FROM=${ASK_FROM:-} ASK_TOPIC=${ASK_TOPIC:-} DESK_TO=${DESK_TO:-} DESK_KIND=${DESK_KIND:-}" >>"$T/run.log"
case "$a" in
  do_spl_asks_open) echo "[INFO] a log line"
    echo '{"fleet":"main","hub":"ok","asks":[{"ask_id":"aaaaaaaa-0000-4000-8000-000000000001","kind":"task","state":"open","from":"CLE-002@box-desk","topic":"87eaa57b","summary":"lower the budget","age_s":600},{"ask_id":"bbbbbbbb-0000-4000-8000-000000000002","kind":"blocker","state":"acked","acked_by":"CLE-900@box-desk","from":"CLE-77911@box-desk","topic":"sat","summary":"drill go?","age_s":7200}]}' ;;
  do_spl_lane_map) echo '{"fleet":"main","hub":"ok","lanes":[{"agent_id":"CLE-77","agent_box":"box-desk","branch":"CLE-77-x","scope":"the x lane","state":"live","age_s":300},{"agent_id":"CLE-78","agent_box":"sat","branch":"CLE-78-y","scope":"done one","state":"done"}]}' ;;
  do_spl_ask_put|do_spl_desk_reply) exit 0 ;;
  *) exit 1 ;;
esac
EOF
# spool-send.sh: the v:1 object into <to>/inbox and <from>/outbox
cat >"$T/bin/send" <<'EOF'
#!/usr/bin/env bash
from="" to="" kind="" task="" body=""
while [ $# -gt 0 ]; do case "$1" in --from) from="$2"; shift 2 ;; --to) to="$2"; shift 2 ;; --kind) kind="$2"; shift 2 ;;
  --task) task="$2"; shift 2 ;; --body) body="$2"; shift 2 ;; *) shift ;; esac; done
id="$(cat /proc/sys/kernel/random/uuid)"
j="$(jq -n -c --arg i "$id" --arg f "$from" --arg t "$to" --arg k "$kind" --arg ta "$task" --arg b "$body" \
  '{v:1, msg_id:$i, ts:"2026-10-02T04:10:00Z", from:$f, to:$t, kind:$k, task_id:$ta, body:$b}')"
mkdir -p "$SPOOL_ROOT/$to/inbox" "$SPOOL_ROOT/$from/outbox"
echo "$j" >"$SPOOL_ROOT/$to/inbox/$id.json"; echo "$j" >"$SPOOL_ROOT/$from/outbox/$id.json"
echo "send $from -> $to $kind $task: $body" >>"$T/send.log"
EOF
cat >"$T/bin/kill" <<'EOF'
#!/usr/bin/env bash
echo "kill $*" >>"$T/kill.log"
case "$1" in -TERM) [ -f "$T/proc/$2/noterm" ] && exit 0 ;; -KILL) [ -f "$T/proc/$2/nokill" ] && exit 0 ;; esac
rm -rf "$T/proc/$2"
EOF
# the identity map: adopt <ID> <PID> / pane-of <ID>
cat >"$T/bin/ai" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  adopt) echo "adopt $2 $3" >>"$T/ai.log"; echo "$3" >"$T/ai.$2" ;;
  pane-of) p="$(cat "$T/ai.$2" 2>/dev/null)"; [ -n "$p" ] && [ -d "$T/proc/$p" ] || exit 1
    awk -F'\t' -v p="$p" '$2 == p {print $1; exit}' "$T/tmux/panes" ;;
esac
EOF
# the action, as ./run runs it: set -E and an ERR trap that ends the run
cat >"$T/bin/act" <<'EOF'
#!/usr/bin/env bash
set -E
trap 'echo "ERRTRAP: $BASH_COMMAND (line $LINENO)"; exit 99' ERR
do_log() { echo "$*"; }
do_require_bin() { return 0; }
source "$PROJ_PATH/src/bash/run/spl-orch-rotate.func.sh"
do_spl_orch_rotate || exit $?
EOF
chmod +x "$T/bin/"*

export T UP TCK PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" SPOOL_TEST=1 SPOOL_DESK_BOX=box-desk \
  LEASE_PROC_ROOT="$T/proc" ROTATE_TMUX="$T/bin/tmux" ROTATE_SPAWN="$T/bin/spawn" ROTATE_RUN="$T/bin/run" ROTATE_KILL="$T/bin/kill" \
  ROTATE_SEND="$T/bin/send" ROTATE_AI="$T/bin/ai" ROTATE_HOLD_DIR="$T/hold" ROTATE_MEMORY_DIR="$T/mem" ROTATE_TRANSCRIPT="$T/transcript.jsonl" \
  ROTATE_AS_AGENT_DIRECT=1 ROTATE_POLL=1 ROTATE_IDLE_SEC=0 ROTATE_IDLE_GRACE=2 ROTATE_ESC_WAIT=2 ROTATE_START_WAIT=4 \
  ROTATE_ACK_TIMEOUT=6 ROTATE_EXIT_WAIT=2 ROTATE_TERM_WAIT=2 ROTATE_NEW_EXIT_WAIT=2

# the world: one old CLE-900 (pid 1001, 2 h old, busy) in pane %2
world() {
  rm -rf "$T/proc/"[0-9]* "$T/tmux/"* "$T/"*.log "$T/ack.out" "$T/spawn.mode" "$T/ack.mode" "$T/ai.CLE-900" \
    "$D"/rotate.* "$D/handoff" "$S/CLE-900/inbox/"* "$S/CLE-900/outbox/"*
  "$T/bin/proc" 1001 7200
  printf '%%2\t1001\t$0\tCLE-900@box sometitle\n' >"$T/tmux/panes"
  printf 'working on the satellite drill\n✻ Cogitating (12s · esc to interrupt)\n' >"$T/tmux/screen.%2"
  echo '{"v":1,"msg_id":"m1","ts":"2026-10-02T04:00:00Z","from":"CLE-002","to":"CLE-900","kind":"task","task_id":"87eaa57b","body":"route the budget ask"}' >"$S/CLE-900/inbox/m1.json"
  echo '{"v":1,"msg_id":"m2","ts":"2026-10-02T04:01:00Z","from":"CLE-900","to":"CLE-77925","kind":"task","task_id":"87eaa57b","body":"lower the budget to 155"}' >"$S/CLE-900/outbox/m2.json"
}
act() { env "$@" "$T/bin/act"; }
ctx() { sed -n "s/^$1=//p" "$D/rotate.orch.ctx" 2>/dev/null; }

# --- 1. L1: the dry run ----------------------------------------------------------------
world
act >"$T/o" 2>&1; rc=$?
n=0; for p in GATE QUIESCE HANDOFF SPAWN ACK RETIRE CLOSE; do grep -q " $p PLAN " "$T/o" && n=$((n + 1)); done
[[ $rc -eq 0 && $n == 7 ]] && grep -q ' GATE PLAN pass: CLE-900 pid 1001, 7200s old, pane %2' "$T/o" &&
  pass "1. dry run: one PLAN line per step" || fail "1. dry: rc=$rc n=$n $(grep PLAN "$T/o")"
for want in '# CLE-900@box-desk handoff, rotation [0-9T]*Z-orch' '## 2. In flight' 'working on the satellite drill' \
  'bbbbbbbb blocker from CLE-77911@box-desk, 2h, acked by CLE-900@box-desk' 'aaaaaaaa task from CLE-002@box-desk, 10m, open' \
  '-> CLE-77925 task \[87eaa57b\] lower the budget to 155' '## 5. Unread inbox: 1 message' '<- CLE-002 task \[87eaa57b\] route the budget ask' \
  'CLE-77@box-desk CLE-77-x (5m): the x lane' 'sat-drill (0h ago): Satellite drill' 'NEXT: start the drill' \
  '- user: owner: lower the budget' '- assistant: Routed the budget ask to CLE-77925.' 'orchestrator-never-codes'; do
  grep -q -- "$want" "$T/o" || fail "1. the handoff preview lacks: $want"
done
grep -q 'done one' "$T/o" && fail "1. a done lane is listed" || pass "1. the handoff carries all 9 sections (a done lane left out)"
[[ ! -e "$D/rotate.log" && ! -e "$D/rotate.orch.ctx" && ! -e "$D/handoff" && ! -e "$T/spawn.log" && ! -e "$T/tmux/log" ]] &&
  pass "1. dry run: nothing written, renamed or spawned" || fail "1. the dry run touched something"

# --- 2. T-ORCH-GATES -----------------------------------------------------------------------
gate() {  # <want> <label> [env...]
  local want="$1" label="$2"; shift 2
  act DRY_RUN=0 "$@" >"$T/o" 2>&1
  grep -q -- " GATE SKIP $want" "$T/o" && [[ ! -e "$T/spawn.log" ]] && pass "2. $label" || fail "2. $label: $(cat "$T/o")"
}
world; gate "disabled" "ROTATE=0: SKIP disabled" ROTATE=0
echo 'ROTATE_ORCH=0' >"$D/rotate.conf"; gate "disabled" "rotate.conf ROTATE_ORCH=0: SKIP disabled"; rm -f "$D/rotate.conf"
echo "CLE-900@sat $(date +%s)" >"$D/lease.orch"; gate "standby (orch lease: CLE-900@sat)" "another machine holds the orch lease: SKIP standby" LEASE_FLEET=main
echo "CLE-900@box-desk $(date +%s)" >"$D/lease.orch"; act LEASE_FLEET=main >"$T/o" 2>&1
grep -q ' GATE PLAN pass' "$T/o" && pass "2. this machine holds the orch lease: passes" || fail "2. holder: $(cat "$T/o")"; rm -f "$D/lease.orch"
world; rm -rf "$T/proc/1001"; gate "absent" "no process: SKIP absent"
world; "$T/bin/proc" 1002 7200; gate "duplicate: 2 live processes carry CLE-900 (pids 1001 1002)" "two processes: SKIP duplicate"
grep -q 'send CLE-900 -> CLE-900 note orch-rotate: ROTATION SKIP duplicate' "$T/send.log" && pass "2. ... and the orchestrator gets one note" || fail "2. dup note"
act DRY_RUN=0 >/dev/null 2>&1; [[ "$(grep -c 'SKIP duplicate' "$T/send.log")" == 1 ]] && pass "2. ... once, not every hour" || fail "2. dup note repeated"
world; rm -rf "$T/proc/1001"; "$T/bin/proc" 1001 600; gate "young: pid 1001 is 600s old" "a young session: SKIP young"
world; printf 'idle\n❯ \nUsage limit reached · resets 7:20am\n' >"$T/tmux/screen.%2"; gate "stalled Usage limit reached" "a usage-limit footer: SKIP stalled"
world; ( flock 9; sleep 3 ) 9>>"$D/rotate.orch.lock" & sleep 0.5; gate "locked" "the lock held: SKIP locked"; wait

# --- 3. T-ORCH-HAPPY + BUSY + POKE-ROUTE + MSG-IN-FLIGHT ------------------------------------
world; touch "$T/tmux/escape-stops.%2"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
rid="$(ctx ROTATE_RID)"
[[ $rc -eq 0 && "$(ctx ROTATE_PHASE)" == DONE ]] && [[ "$rid" =~ ^[0-9]{8}T[0-9]{4}Z-orch$ ]] &&
  pass "3. rotated to DONE ($rid)" || fail "3. rc=$rc $(cat "$T/o") $(cat "$T/ack.out" 2>/dev/null)"
grep -q "keys %2 Escape" "$T/tmux/log" && grep -q " QUIESCE OK interrupted" "$T/o" &&
  grep -q 'Interrupted · What should Claude do instead' "$D/handoff/$rid-CLE-900.md" &&
  pass "3. T-ORCH-BUSY: Escape sent, the handoff holds the stopped screen" || fail "3. busy: $(grep QUIESCE "$T/o")"
[[ "$(stat -c %a "$D/handoff/$rid-CLE-900.md")" == 640 ]] && pass "3. handoff mode 0640" || fail "3. mode"
grep -qx "rename %2 CLE-900-${rid:9:4}Z-retiring" "$T/tmux/log" && pass "3. old window renamed CLE-900-<hhmm>Z-retiring" || fail "3. rename: $(cat "$T/tmux/log")"
( source "$PROJ_ROOT/src/bash/features/spawn-agents/lib/spool-env.inc.sh"; [[ -z "$(spool_id_of_window "CLE-900-${rid:9:4}Z-retiring")" && "$(spool_id_of_window "CLE-900@box")" == CLE-900 ]] ) &&
  pass "3. T-ORCH-POKE-ROUTE: the retiring name parses as no id" || fail "3. the retiring name parses as an id"
grep -qx 'adopt CLE-900 2001' "$T/ai.log" && grep -q " SPAWN OK new pid 2001 pane %20" "$T/o" &&
  pass "3. T-ORCH-POKE-ROUTE: the map adopts the new pid before ACK" || fail "3. adopt: $(cat "$T/ai.log" 2>/dev/null)"
grep -q "^spawn claude CLE-900 .* $D/handoff/$rid-CLE-900.seed.md rotate SPAWN_REUSE_ID=1 SPOOL_SESSION=\$0" "$T/spawn.log" &&
  grep -q "^You are the new CLE-900@box-desk, rotated at $rid. Read $D/handoff/$rid-CLE-900.md, then run" "$D/handoff/$rid-CLE-900.seed.md" &&
  pass "3. same id (SPAWN_REUSE_ID=1), same tmux session, the FR-040 rotation line" || fail "3. spawn: $(cat "$T/spawn.log")"
grep -q "send CLE-900 -> CLE-900 result orch-rotate-$rid: ACK" "$T/send.log" && grep -q " ACK OK acked by pid 2001" "$T/o" &&
  pass "3. ack = a result in CLE-900/outbox on orch-rotate-<rid>" || fail "3. ack: $(cat "$T/send.log") $(cat "$T/ack.out")"
grep -q '^keys %2 /exit-clean$' "$T/tmux/log" && [[ ! -d "$T/proc/1001" ]] && grep -qx 'kill %2' "$T/tmux/log" &&
  pass "3. old session ended with /exit-clean, its window closed by pane id" || fail "3. retire: $(cat "$T/tmux/log")"
grep -q " CLOSE OK old window closed; checks: one process, lease follows pid 2001, map -> %20" "$T/o" &&
  grep -q "send CLE-900 -> CLE-900 result orch-rotate-$rid: ROTATION DONE" "$T/send.log" &&
  pass "3. CLOSE checks pass; DONE result to the new session" || fail "3. close: $(grep CLOSE "$T/o")"
[[ -f "$S/CLE-900/inbox/m1.json" && -f "$S/CLE-900/inbox/m9.json" ]] &&
  pass "3. T-MSG-IN-FLIGHT: the message before and the one during the rotation are in the inbox" || fail "3. inbox: $(ls "$S/CLE-900/inbox")"
phases="$(awk -v r="$rid" '$2 == r && !seen[$3]++ {printf "%s ", $3}' "$D/rotate.log")"
[[ "$phases" == "GATE QUIESCE HANDOFF SPAWN ACK RETIRE CLOSE DONE " ]] && read -r _ ph _ <"$D/rotate.orch.state" && [[ "$ph" == DONE ]] &&
  pass "3. one log line per phase; .state = DONE" || fail "3. phases: $phases"
! grep -q ERRTRAP "$T/o" "$T/ack.out" && pass "3. no stray failing command under the ERR trap" || fail "3. ERRTRAP: $(grep ERRTRAP "$T/o" "$T/ack.out")"

# --- 4. a re-run right after ---------------------------------------------------------------
act DRY_RUN=0 >"$T/o" 2>&1
grep -q ' GATE SKIP young: pid 2001' "$T/o" && pass "4. re-run: the new session is young" || fail "4. $(cat "$T/o")"

# --- 5. T-ORCH-ACK-TIMEOUT -------------------------------------------------------------------
world; echo no >"$T/ack.mode"
act DRY_RUN=0 ROTATE_ACK_TIMEOUT=3 >"$T/o" 2>&1; rc=$?
rid="$(ctx ROTATE_RID)"
[[ $rc -ne 0 && "$(ctx ROTATE_PHASE)" == FAIL ]] && grep -q ' FAIL FAIL ACK: no ack within 3s' "$T/o" && pass "5. no ack: FAIL ack" || fail "5. rc=$rc $(cat "$T/o")"
grep -q '^keys %20 /exit$' "$T/tmux/log" && grep -qx 'kill %20' "$T/tmux/log" && [[ ! -d "$T/proc/2001" ]] &&
  pass "5. the new session got /exit and its window closed" || fail "5. new: $(cat "$T/tmux/log")"
[[ -d "$T/proc/1001" ]] && grep -q $'^%2\t1001\t$0\tCLE-900@box sometitle$' "$T/tmux/panes" && ! grep -q 'keys %2 /exit' "$T/tmux/log" &&
  [[ "$(tail -1 "$T/ai.log")" == "adopt CLE-900 1001" ]] && pass "5. old pid untouched, its name and map entry back" || fail "5. old: $(cat "$T/tmux/panes") $(cat "$T/ai.log")"
grep -q "keys %2 Rotation $rid failed; you keep the role. Read $D/handoff/$rid-CLE-900.md" "$T/tmux/log" &&
  pass "5. the old pane is told where its handoff is" || fail "5. no line to the old pane"
grep -q "^do_spl_ask_put ASK_KIND=blocker ASK_FROM=CLE-900 ASK_TOPIC=orch-rotate-$rid" "$T/run.log" &&
  grep -q '^do_spl_desk_reply .*DESK_TO=HUM-10 DESK_KIND=blocker' "$T/run.log" && pass "5. ALERT: one ask + one owner DM" || fail "5. alert: $(cat "$T/run.log")"

# --- 6. T-ORCH-SPAWN-FAIL --------------------------------------------------------------------
world; echo nopane >"$T/spawn.mode"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q ' FAIL FAIL SPAWN: spawn printed no pane' "$T/o" && grep -q $'\tCLE-900@box sometitle$' "$T/tmux/panes" &&
  grep -q '^do_spl_ask_put' "$T/run.log" && pass "6. no pane: restored, FAIL spawn, ALERT" || fail "6. rc=$rc $(cat "$T/o")"
world; echo nostart >"$T/spawn.mode"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FAIL SPAWN: no claude carrying CLE-900 started in %20' "$T/o" && grep -qx 'kill %20' "$T/tmux/log" &&
  pass "6. no pid: the new window closed, restored" || fail "6. nostart rc=$rc $(cat "$T/o")"

# --- 7. T-ORCH-EXIT-HANG -----------------------------------------------------------------------
world; touch "$T/tmux/stubborn.%2" "$T/proc/1001/noterm"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q '^kill -TERM 1001$' "$T/kill.log" && grep -q '^kill -KILL 1001$' "$T/kill.log" &&
  grep -q 'RETIRE WAIT pid 1001 alive 2s after SIGTERM: SIGKILL' "$T/o" && [[ "$(ctx ROTATE_PHASE)" == DONE ]] &&
  pass "7. /exit-clean and TERM ignored: KILL, logged, DONE" || fail "7. rc=$rc $(cat "$T/o")"
world; touch "$T/tmux/stubborn.%2" "$T/proc/1001/noterm" "$T/proc/1001/nokill"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q ' RETIRE FAIL pid 1001 survived SIGKILL' "$T/o" && grep -q '^do_spl_ask_put' "$T/run.log" &&
  pass "7. KILL ignored: FAIL exit + ALERT" || fail "7. hang rc=$rc $(cat "$T/o")"
sed -i 's/^ROTATE_PHASE=.*/ROTATE_PHASE=FAIL/' "$D/rotate.orch.ctx"
act DRY_RUN=0 >"$T/o" 2>&1
grep -q ' GATE SKIP duplicate: 2 live processes carry CLE-900 (pids 1001 2001)' "$T/o" && pass "7. ... the next run: SKIP duplicate" || fail "7. next: $(cat "$T/o")"

# --- 8. T-ORCH-RESUME + abort ------------------------------------------------------------------
world; echo no >"$T/ack.mode"
act DRY_RUN=0 ROTATE_ACK_TIMEOUT=1 >/dev/null 2>&1          # leaves a FAIL; rebuild an ACK-phase rotation by hand
"$T/bin/proc" 2001 0; printf '%%20\t2001\t$0\tCLE-900@box\n' >>"$T/tmux/panes"
awk -F'\t' -v OFS='\t' '$1 == "%2" {$4 = "CLE-900-0405Z-retiring"} {print}' "$T/tmux/panes" >"$T/p" && mv "$T/p" "$T/tmux/panes"
rid="$(ctx ROTATE_RID)"
sed -i 's/^ROTATE_PHASE=.*/ROTATE_PHASE=ACK/; s/^ROTATE_NEW_PID=.*/ROTATE_NEW_PID=2001/; s/^ROTATE_NEW_PANE=.*/ROTATE_NEW_PANE=%20/' "$D/rotate.orch.ctx"
act >"$T/o" 2>&1
grep -q " RESUME PLAN from ACK" "$T/o" && pass "8. dry run names the resume" || fail "8. dry: $(cat "$T/o")"
"$T/bin/send" --from CLE-900 --to CLE-900 --kind result --task "orch-rotate-$rid" --body ack
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q " RESUME OK from ACK (old alive=1, new alive=1)" "$T/o" && [[ ! -d "$T/proc/1001" && "$(ctx ROTATE_PHASE)" == DONE ]] &&
  pass "8. resumed at ACK with its ack on disk: retired, DONE" || fail "8. rc=$rc $(cat "$T/o")"
world; echo no >"$T/ack.mode"; act DRY_RUN=0 ROTATE_ACK_TIMEOUT=1 >/dev/null 2>&1
sed -i 's/^ROTATE_PHASE=.*/ROTATE_PHASE=SPAWN/; s/^ROTATE_NEW_PID=.*/ROTATE_NEW_PID=2001/; s/^ROTATE_NEW_PANE=.*/ROTATE_NEW_PANE=%20/' "$D/rotate.orch.ctx"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -ne 0 && -d "$T/proc/1001" ]] && grep -q 'FAIL FAIL SPAWN: resumed with no live new session' "$T/o" &&
  pass "8. resumed at SPAWN with the new pid dead: fails cleanly, old kept" || fail "8. dead rc=$rc $(cat "$T/o")"
"$T/bin/proc" 2001 0; printf '%%20\t2001\t$0\tCLE-900@box\n' >>"$T/tmux/panes"
sed -i 's/^ROTATE_PHASE=.*/ROTATE_PHASE=ACK/' "$D/rotate.orch.ctx"
act ROTATE_CMD=abort DRY_RUN=0 >"$T/o" 2>&1
grep -q ' ABORT ABORT at ACK by hand' "$T/o" && [[ ! -d "$T/proc/2001" && -d "$T/proc/1001" && "$(ctx ROTATE_PHASE)" == ABORT ]] &&
  pass "8. abort (FR-091): the new one closed, the old one kept" || fail "8. abort: $(cat "$T/o")"

# --- 9. T-ACK-FORGED --------------------------------------------------------------------------
world; echo no >"$T/ack.mode"; act DRY_RUN=0 ROTATE_ACK_TIMEOUT=1 >/dev/null 2>&1
sed -i 's/^ROTATE_PHASE=.*/ROTATE_PHASE=ACK/; s/^ROTATE_NEW_PID=.*/ROTATE_NEW_PID=2001/' "$D/rotate.orch.ctx"
rid="$(ctx ROTATE_RID)"
act ROTATE_CMD=ack ROTATE_ID="$rid" ROTATE_CALLER_PID=1001 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 3 ]] && grep -q "caller pid '1001' is not the new session 2001" "$T/o" && pass "9. an ack from the old pid: exit 3" || fail "9. pid rc=$rc $(cat "$T/o")"
act ROTATE_CMD=ack ROTATE_ID=20000101T0000Z-orch ROTATE_CALLER_PID=2001 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 3 ]] && grep -q 'refused: not the rotation in flight' "$T/o" && pass "9. an unknown rid: exit 3" || fail "9. rid rc=$rc $(cat "$T/o")"
! grep -q "orch-rotate-$rid" "$T/send.log" 2>/dev/null && pass "9. ... and nothing was sent" || fail "9. a forged ack was sent"

# --- 10. T-CRON ----------------------------------------------------------------------------
cat >"$T/bin/crontab" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi
cp "$1" "$FAKE_CRONTAB"
EOF
chmod +x "$T/bin/crontab"
SRC="$T/shared"; mkdir -p "$SRC/csi-spl-orc/src/bash/scripts"
cp "$PROJ_ROOT/src/bash/scripts/orch-rotate-cron.sh" "$SRC/csi-spl-orc/src/bash/scripts/"
printf '*/3 * * * * other job # csi-spl:desk-reconcile\n' >"$T/crontab"
cron() {
  env PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab" DESK_CRON_SRC="$SRC" ROTATE_CRON_LOG_DIR="$T/log" "$@" bash -c '
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-orch-rotate-install-cron.func.sh"
    do_spl_orch_rotate_install_cron'
}
before="$(md5sum <"$T/crontab")"
cron >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(md5sum <"$T/crontab")" == "$before" ]] && grep -q '^    +5 \* \* \* \* .*orch-rotate-cron.sh >> .*/cron.out 2>&1 # csi-spl:orch-rotate$' "$T/o" &&
  pass "10. dry run: the diff, nothing written" || fail "10. dry: rc=$rc $(cat "$T/o")"
cron ROTATE_CRON_ACTION=check >"$T/o" 2>&1 && fail "10. check passed with no line" || pass "10. check fails while not installed"
cron DRY_RUN=0 >"$T/o" 2>&1; rc=$?
want="5 * * * * $SRC/csi-spl-orc/src/bash/scripts/orch-rotate-cron.sh >> $T/log/cron.out 2>&1 # csi-spl:orch-rotate"
[[ $rc -eq 0 ]] && grep -qxF "$want" "$T/crontab" && grep -q 'desk-reconcile' "$T/crontab" &&
  pass "10. DRY_RUN=0: one exact line at :05, the other line kept" || fail "10. install rc=$rc: $(cat "$T/crontab") $(cat "$T/o")"
cron DRY_RUN=0 >/dev/null 2>&1
[[ "$(grep -c '# csi-spl:orch-rotate$' "$T/crontab")" == 1 ]] && pass "10. idempotent" || fail "10. lines: $(cat "$T/crontab")"
cron ROTATE_CRON_ACTION=check >"$T/o" 2>&1 && pass "10. check passes once installed" || fail "10. check: $(cat "$T/o")"
cron CRON_REMOVE=1 DRY_RUN=0 >/dev/null 2>&1
! grep -q 'orch-rotate' "$T/crontab" && grep -q 'desk-reconcile' "$T/crontab" && pass "10. CRON_REMOVE=1 takes only its line" || fail "10. remove: $(cat "$T/crontab")"
mkdir -p "$T/repo-wt/X"
cron DESK_CRON_SRC="$T/repo-wt/X" >"$T/o" 2>&1 && fail "10. a worktree source accepted" || pass "10. an agent worktree is refused"
ROTATE_CRON_TOOLS=no-such-tool-x bash "$SRC/csi-spl-orc/src/bash/scripts/orch-rotate-cron.sh" --check-tools >"$T/o" 2>&1
[[ $? -eq 3 ]] && grep -q 'no-such-tool-x' "$T/o" && pass "10. the cron script names a missing tool (exit 3)" || fail "10. tools: $(cat "$T/o")"

echo
(( fails == 0 )) && { echo "orch-rotate: all passed"; exit 0; }
echo "orch-rotate: $fails failure(s)"; exit 1
