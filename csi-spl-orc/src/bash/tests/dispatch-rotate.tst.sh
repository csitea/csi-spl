#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the hourly dispatcher rotation (spec 060 section 4.3, CLE-77940):
#          do_spl_dispatch_rotate on spl-rotate-lib.func.sh, the hold in
#          spl_lease_agent_able, and do_spl_dispatch_rotate_install_cron, in a
#          sandbox. Nothing real is touched: processes live in a fake /proc
#          (LEASE_PROC_ROOT), tmux is a stub keeping panes in a file, the spawn
#          starts a fake claude that runs ONLY its seed's ACK-COMMAND line
#          (T-NO-MODEL), ./run, spool-send, kill and the identity map are
#          stubs. The action runs under ./run's `set -E` + ERR trap.
#   1. dry run: PLAN lines, nothing written, held, renamed or spawned
#   2. gates: disabled (env, rotate.conf), standby (FR-044), young, stalled
#      (FR-022), duplicate, locked, orch rotation in flight (FR-051)
#   3. T-DISP-HAPPY: HOLD (the lease names F while every M process is held,
#      T-DISP-ONE-HOLDER), the fresh M seeded + an inbox task (FR-026), ack =
#      outbox result (FR-041), /exit-clean, RELEASE (the lease back on M),
#      then REFRESH F the same way, DONE; lease.conf untouched (I8); no
#      message lost (T-MSG-IN-FLIGHT)
#   4. T-DISP-ACK-FAIL: the fresh M closed, the OLD M keeps the role and the
#      lease, the hold removed, ALERT = ask + owner DM
#   5. a failed F refresh keeps the old F, M stays fresh
#   6. T-DISP-HEAL: a missing dispatcher -> do_spl_dispatch_setup, nothing else
#   7. T-DISP-ACK-SOURCE: an ack from the old pid / a wrong rid -> exit 3
#   8. T-DISP-HOLD-STALE: the hold gate, and a hold older than
#      ROTATE_HOLD_MAX ignored with one WARN (FR-023, FR-024)
#   9. resume (FR-003) and abort (FR-091)
#  10. T-CRON: :15, idempotent, check, CRON_REMOVE=1
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
mkdir -p "$T/bin" "$T/proc" "$T/tmux" "$D/briefs" "$T/hold" "$T/mem"
TCK="$(getconf CLK_TCK)"; UP=100000
echo "$UP.00 0.00" >"$T/proc/uptime"
printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\n' "$(id -un)" "$(id -un)" >"$S/box.env"
CONF=$'LEASE_MASTER=CLE-902\nLEASE_FAILOVER=CLE-903\nLEASE_ORCH=CLE-900\nLEASE_ENV=prd\nLEASE_TENANT=t1\nASKS_OWNER=HUM-10'
for id in CLE-902 CLE-903; do echo "brief of $id: read your inbox" >"$D/briefs/brief-dispatcher-$id.md"; done

# --- stubs --------------------------------------------------------------------
# proc <pid> <id> <age-s>: a fake claude carrying SPOOL_AGENT_ID=<id>
cat >"$T/bin/proc" <<'EOF'
#!/usr/bin/env bash
d="$T/proc/$1"; mkdir -p "$d"; echo claude >"$d/comm"
printf 'SPOOL_AGENT_ID=%s\0' "$2" >"$d/environ"
echo "$1 (claude) S 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 $(( (UP - $3) * TCK ))" >"$d/stat"
printf 'Uid:\t%s\t%s\n' "$(id -u)" "$(id -u)" >"$d/status"
EOF
# tmux: panes in $T/tmux/panes as "<pane>\t<pid>\t<session>\t<name>". A
# capture with -e also draws the CLI input box (typed.<pane>; C-c empties it),
# which the RETIRE reads back before Enter (CLE-77951, orch-rotate case 11).
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
    case "${args[0]}" in *window_name*) field 4 ;; *session_id*) field 3 ;; *pane_id*) echo "$tgt" ;; esac ;;
  capture-pane) grep -q "^$tgt	" "$P" || exit 1
    if [ -f "$T/tmux/screen.$tgt" ]; then cat "$T/tmux/screen.$tgt"; else printf 'routed the t1 post\n❯ \n'; fi
    if [ "$esc" = 1 ]; then printf '────────\n❯ %s\n────────\n' "$(cat "$T/tmux/typed.$tgt" 2>/dev/null)"; fi ;;
  rename-window) awk -F'\t' -v OFS='\t' -v p="$tgt" -v n="${args[0]}" '$1 == p {$4 = n} {print}' "$P" >"$P.new" && mv "$P.new" "$P"
    echo "rename $tgt ${args[0]}" >>"$L" ;;
  send-keys) k="${args[0]}"; echo "keys $tgt $k" >>"$L"
    if [ "$lit" = 1 ]; then printf '%s' "$k" >>"$T/tmux/typed.$tgt"
    elif [ "$k" = C-u ] || [ "$k" = C-c ]; then : >"$T/tmux/typed.$tgt"
    elif [ "$k" = Enter ]; then
      if grep -q '^/exit' "$T/tmux/typed.$tgt" 2>/dev/null && [ ! -f "$T/tmux/stubborn.$tgt" ]; then rm -rf "$T/proc/$(field 2)"; fi
      : >"$T/tmux/typed.$tgt"
    fi ;;
  kill-window) awk -F'\t' -v p="$tgt" '$1 != p' "$P" >"$P.new" && mv "$P.new" "$P"; echo "kill $tgt" >>"$L" ;;
  *) echo "tmux stub: $cmd" >&2; exit 1 ;;
esac
EOF
# spawn-window.sh <kind> <ID> <workdir> <seed> <slug> -> "<ID> <pane>"; the fake
# claude runs ONLY the seed's ACK-COMMAND line (no model: T-NO-MODEL)
cat >"$T/bin/spawn" <<'EOF'
#!/usr/bin/env bash
id="$2"; n="${id##*-}"; pid=$(( 2000 + 10#$n )); pane="%2$n"
echo "spawn $* SPAWN_REUSE_ID=${SPAWN_REUSE_ID:-}" >>"$T/spawn.log"
mode="$(cat "$T/spawn.mode.$id" 2>/dev/null || echo ok)"
[ "$mode" = nopane ] && { echo "spawn-window: no pane"; exit 4; }
printf '%s\t%s\t$0\t%s@box\n' "$pane" "$pid" "$id" >>"$T/tmux/panes"
[ "$mode" = nostart ] || "$T/bin/proc" "$pid" "$id" 0
echo '{"v":1,"msg_id":"m9","ts":"2026-10-02T05:16:00Z","from":"HUM-10","to":"CLE-902","kind":"msg","task_id":"y","body":"mid-rotation"}' >"$SPOOL_ROOT/CLE-902/inbox/m9.json"
if [ "$(cat "$T/ack.mode.$id" 2>/dev/null || echo yes)" = yes ]; then
  rid="$(grep '^ACK-COMMAND:' "$4" | grep -oE 'ROTATE_ID=[0-9A-Za-z-]+' | cut -d= -f2)"
  ( sleep 1; ROTATE_CMD=ack ROTATE_ID="$rid" ROTATE_CALLER_PID="$pid" "$T/bin/act" >>"$T/ack.out" 2>&1 ) >/dev/null 2>&1 &
fi
echo "$id $pane"
EOF
# ./run: the ask book, the lane map, the alert legs, the heal setup
cat >"$T/bin/run" <<'EOF'
#!/usr/bin/env bash
a="$2"
echo "$a ASK_KIND=${ASK_KIND:-} ASK_FROM=${ASK_FROM:-} ASK_TOPIC=${ASK_TOPIC:-} DESK_TO=${DESK_TO:-} DISPATCH_MASTER=${DISPATCH_MASTER:-}" >>"$T/run.log"
case "$a" in
  do_spl_asks_open) echo '{"asks":[]}' ;;
  do_spl_lane_map) echo '{"lanes":[]}' ;;
  do_spl_dispatch_setup) [ -d "$T/proc/203" ] || "$T/bin/proc" 203 CLE-903 0 ;;
  do_spl_ask_put|do_spl_desk_reply) exit 0 ;;
  *) exit 1 ;;
esac
EOF
# spool-send.sh: the v:1 object into <to>/inbox and <from>/outbox; logs the lease and hold at that instant
cat >"$T/bin/send" <<'EOF'
#!/usr/bin/env bash
from="" to="" kind="" task="" body=""
while [ $# -gt 0 ]; do case "$1" in --from) from="$2"; shift 2 ;; --to) to="$2"; shift 2 ;; --kind) kind="$2"; shift 2 ;;
  --task) task="$2"; shift 2 ;; --body) body="$2"; shift 2 ;; *) shift ;; esac; done
id="$(cat /proc/sys/kernel/random/uuid)"
j="$(jq -n -c --arg i "$id" --arg f "$from" --arg t "$to" --arg k "$kind" --arg ta "$task" --arg b "$body" \
  '{v:1, msg_id:$i, ts:"2026-10-02T05:15:00Z", from:$f, to:$t, kind:$k, task_id:$ta, body:$b}')"
mkdir -p "$SPOOL_ROOT/$to/inbox" "$SPOOL_ROOT/$from/outbox"
echo "$j" >"$SPOOL_ROOT/$to/inbox/$id.json"; echo "$j" >"$SPOOL_ROOT/$from/outbox/$id.json"
echo "send $from -> $to $kind $task [lease=$(cut -d' ' -f1 "$SPOOL_ROOT/dispatch/lease" 2>/dev/null) hold=$(cut -d' ' -f1 "$SPOOL_ROOT/dispatch/rotate.hold" 2>/dev/null)]: $body" >>"$T/send.log"
EOF
cat >"$T/bin/kill" <<'EOF'
#!/usr/bin/env bash
echo "kill $*" >>"$T/kill.log"
case "$1" in -TERM) [ -f "$T/proc/$2/noterm" ] && exit 0 ;; -KILL) [ -f "$T/proc/$2/nokill" ] && exit 0 ;; esac
rm -rf "$T/proc/$2"
EOF
cat >"$T/bin/ai" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  adopt) echo "adopt $2 $3" >>"$T/ai.log"; echo "$3" >"$T/ai.$2" ;;
  pane-of) p="$(cat "$T/ai.$2" 2>/dev/null)"; [ -n "$p" ] && [ -d "$T/proc/$p" ] || exit 1
    awk -F'\t' -v p="$p" '$2 == p {print $1; exit}' "$T/tmux/panes" ;;
esac
EOF
# the pane footer the lease's stall gate reads
cat >"$T/bin/footer" <<'EOF'
#!/usr/bin/env bash
printf '❯ \n'
EOF
# the action, as ./run runs it: set -E and an ERR trap that ends the run
cat >"$T/bin/act" <<'EOF'
#!/usr/bin/env bash
set -E
trap 'echo "ERRTRAP: $BASH_COMMAND (line $LINENO)"; exit 99' ERR
do_log() { echo "$*"; }
do_require_bin() { return 0; }
source "$PROJ_PATH/src/bash/run/spl-dispatch-rotate.func.sh"
do_spl_dispatch_rotate || exit $?
EOF
chmod +x "$T/bin/"*

export T UP TCK PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" SPOOL_TEST=1 SPOOL_DESK_BOX=box-desk \
  LEASE_PROC_ROOT="$T/proc" LEASE_PANE_CMD="$T/bin/footer" ROTATE_TMUX="$T/bin/tmux" ROTATE_SPAWN="$T/bin/spawn" ROTATE_RUN="$T/bin/run" \
  ROTATE_KILL="$T/bin/kill" ROTATE_SEND="$T/bin/send" ROTATE_AI="$T/bin/ai" ROTATE_HOLD_DIR="$T/hold" ROTATE_MEMORY_DIR="$T/mem" \
  ROTATE_AS_AGENT_DIRECT=1 ROTATE_POLL=1 ROTATE_IDLE_SEC=0 ROTATE_IDLE_GRACE=2 ROTATE_ESC_WAIT=1 ROTATE_START_WAIT=4 \
  ROTATE_ACK_TIMEOUT=6 ROTATE_EXIT_WAIT=2 ROTATE_TERM_WAIT=2 ROTATE_NEW_EXIT_WAIT=2 ROTATE_PROMOTE_WAIT=3 ROTATE_SETTLE=0 ROTATE_SEQ_WAIT=2

# the world: CLE-902 (pid 102, pane %2) holds the lease, CLE-903 (pid 103, pane %3) stands by, both 2 h old
world() {
  rm -rf "$T/proc/"[0-9]* "$T/tmux/"* "$T/"*.log "$T/ack.out" "$T/spawn.mode."* "$T/ack.mode."* "$T/ai."* \
    "$D"/rotate.* "$D/handoff" "$D/lease"* "$S"/CLE-90*
  echo "$CONF" >"$D/lease.conf"
  mkdir -p "$S/CLE-902/inbox" "$S/CLE-902/outbox" "$S/CLE-903/inbox" "$S/CLE-903/outbox"
  "$T/bin/proc" 102 CLE-902 7200; "$T/bin/proc" 103 CLE-903 7200
  printf '%%2\t102\t$0\tCLE-902@box > dispatcher\n%%3\t103\t$0\tCLE-903@box > dispatcher\n' >"$T/tmux/panes"
  echo "CLE-902 $(date +%s)" >"$D/lease"
  echo '{"v":1,"msg_id":"m1","ts":"2026-10-02T05:10:00Z","from":"HUM-10","to":"CLE-902","kind":"msg","task_id":"t-owner","body":"owner asks for X"}' >"$S/CLE-902/inbox/m1.json"
}
act() { env "$@" "$T/bin/act"; }
ctx() { sed -n "s/^$1=//p" "$D/rotate.dispatch.ctx" 2>/dev/null; }
holder() { cut -d' ' -f1 "$D/lease"; }

# --- 1. dry run --------------------------------------------------------------------------
world
act >"$T/o" 2>&1; rc=$?
n=0; for p in GATE HOLD QUIESCE HANDOFF SPAWN ACK RETIRE RELEASE REFRESH DONE; do grep -q " $p PLAN " "$T/o" && n=$((n + 1)); done
[[ $rc -eq 0 && $n == 10 ]] && grep -q ' GATE PLAN pass: CLE-902 pid 102, 7200s old, pane %2; CLE-903 pid 103' "$T/o" &&
  pass "1. dry run: one PLAN line per step" || fail "1. dry: rc=$rc n=$n $(cat "$T/o")"
[[ ! -e "$D/rotate.log" && ! -e "$D/rotate.hold" && ! -e "$D/rotate.dispatch.ctx" && ! -e "$T/spawn.log" && ! -e "$T/tmux/log" ]] &&
  pass "1. dry run: nothing written, held, renamed or spawned" || fail "1. the dry run touched something"

# --- 2. gates ---------------------------------------------------------------------------
gate() {  # <want> <label> [env...]
  local want="$1" label="$2"; shift 2
  act DRY_RUN=0 "$@" >"$T/o" 2>&1
  grep -q -- " GATE SKIP $want" "$T/o" && [[ ! -e "$T/spawn.log" && ! -e "$D/rotate.hold" ]] && pass "2. $label" || fail "2. $label: $(cat "$T/o")"
}
world; gate "disabled" "ROTATE=0: SKIP disabled" ROTATE=0
echo 'ROTATE_DISPATCH=0' >"$D/rotate.conf"; gate "disabled" "rotate.conf ROTATE_DISPATCH=0: SKIP disabled (FR-090)"; rm -f "$D/rotate.conf"
world; echo 'LEASE_FLEET=main' >>"$D/lease.conf"; echo "CLE-902@sat $(date +%s)" >"$D/lease"
gate "standby (dispatch lease: CLE-902@sat)" "another machine holds the dispatch lease: SKIP standby (FR-044)"
world; rm -rf "$T/proc/102"; "$T/bin/proc" 102 CLE-902 600; gate "young: CLE-902 pid 102 is 600s old" "a young master: SKIP young (FR-008)"
world; date +%s >"$D/rotate.dispatch.last"; gate "young: the last rotation" "a rotation less than ROTATE_MIN_AGE ago: SKIP young"
world; printf 'idle\n❯ \nUsage limit reached · resets 7:20am\n' >"$T/tmux/screen.%2"; gate "stalled Usage limit reached" "a stalled master: SKIP stalled (FR-022)"
grep -q 'send CLE-900 -> CLE-900 note dispatch-rotate .*ROTATION SKIP stalled' "$T/send.log" && pass "2. ... the orchestrator gets one note" || fail "2. stall note: $(cat "$T/send.log" 2>&1)"
world; "$T/bin/proc" 112 CLE-902 7200; gate "duplicate: CLE-902 pids 102 112" "two processes on one id: SKIP duplicate"
world; ( flock 9; sleep 3 ) 9>>"$D/rotate.dispatch.lock" & sleep 0.5; gate "locked" "the lock held: SKIP locked"; wait
# spec 061 L6: c-002 / c-003 pass the id gate (they read "no master + failover pair" before)
world; act DRY_RUN=0 LEASE_MASTER=c-002 LEASE_FAILOVER=c-003 >"$T/o" 2>&1
! grep -q 'no master + failover pair' "$T/o" && pass "2. LEASE_MASTER=c-002 LEASE_FAILOVER=c-003 pass the id gate" || fail "2. c-002/c-003: $(cat "$T/o")"
world; gate "no master + failover pair" "LEASE_MASTER=bogus: SKIP no pair" LEASE_MASTER=bogus
world; echo "20261002T0505Z-orch ACK $(date +%s)" >"$D/rotate.orch.state"; gate "orch-busy (orch rotation at ACK)" "an orch rotation in flight: wait, then SKIP orch-busy (FR-051)"
# a FAILED orch rotation ends at ALERT (the ask + the owner DM): over, not in flight
world; echo "20261002T1505Z-orch ALERT $(date +%s)" >"$D/rotate.orch.state"
act >"$T/o" 2>&1
! grep -q 'orch-busy' "$T/o" && grep -q ' GATE PLAN pass' "$T/o" &&
  pass "2. an orch rotation that ended at ALERT does not hold the dispatchers off" || fail "2. ALERT: $(cat "$T/o")"

# --- 3. T-DISP-HAPPY ------------------------------------------------------------------------
world; cp "$D/lease.conf" "$T/conf.before"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
rid="$(awk '$3 == "GATE" && $4 == "OK" {print $2}' "$D/rotate.log" | head -1)"; frid="${rid%-master}-failover"
[[ $rc -eq 0 && "$rid" =~ ^[0-9]{8}T[0-9]{4}Z-master$ ]] && grep -q " $rid DONE OK fresh CLE-902" "$T/o" &&
  pass "3. rotated M and F to DONE ($rid)" || fail "3. rc=$rc $(cat "$T/o") $(cat "$T/ack.out" 2>/dev/null)"
[[ -d "$T/proc/2902" && -d "$T/proc/2903" && ! -d "$T/proc/102" && ! -d "$T/proc/103" ]] &&
  pass "3. fresh CLE-902 and CLE-903 under the same ids; the old sessions are gone" || fail "3. procs: $(ls "$T/proc")"
cmp -s "$D/lease.conf" "$T/conf.before" && [[ "$(holder)" == CLE-902 && ! -e "$D/rotate.hold" ]] &&
  pass "3. lease.conf untouched (I8), the lease back on CLE-902, no hold left" || fail "3. lease=$(cat "$D/lease") conf: $(cat "$D/lease.conf")"
grep -q 'send CLE-900 -> CLE-903 note dispatch-lease \[lease=CLE-903 hold=CLE-902\]: DISPATCH LEASE: you are now ACTIVE' "$T/send.log" &&
  grep -q 'send CLE-900 -> CLE-902 note dispatch-lease \[lease=CLE-903 hold=CLE-902\]: DISPATCH LEASE: STANDBY' "$T/send.log" &&
  pass "3. T-DISP-ONE-HOLDER: F told ACTIVE and M STANDBY while the lease names F and M is held" || fail "3. holder: $(cat "$T/send.log")"
grep -q "send CLE-900 -> CLE-902 task dispatch-rotate-$rid .*ROTATION $rid: you are the fresh CLE-902@box-desk. Read $D/handoff/$rid-CLE-902.md" "$T/send.log" &&
  grep -q 'brief of CLE-902: read your inbox' "$D/handoff/$rid-CLE-902.seed.md" && grep -q "^ACK-COMMAND: .*ROTATE_CMD=ack ROTATE_ID=$rid ./run -a do_spl_dispatch_rotate" "$D/handoff/$rid-CLE-902.seed.md" &&
  pass "3. the fresh M: seeded with its brief + the ack line, the handoff as an inbox task (FR-026)" || fail "3. seed/task: $(cat "$D/handoff/$rid-CLE-902.seed.md" 2>&1)"
grep -q "send CLE-902 -> CLE-902 result dispatch-rotate-$rid .*ACK rotation $rid: CLE-902 pid 2902" "$T/send.log" &&
  grep -q "send CLE-903 -> CLE-903 result dispatch-rotate-$frid .*ACK rotation $frid: CLE-903 pid 2903" "$T/send.log" &&
  pass "3. each ack = a result in its own outbox on dispatch-rotate-<rid> (FR-041)" || fail "3. ack: $(cat "$T/send.log") $(cat "$T/ack.out")"
grep -qx "rename %2 CLE-902-${rid:9:4}Z-retiring" "$T/tmux/log" && grep -q '^keys %2 /exit-clean$' "$T/tmux/log" && grep -qx 'kill %2' "$T/tmux/log" &&
  grep -q '^keys %3 /exit-clean$' "$T/tmux/log" && grep -qx 'kill %3' "$T/tmux/log" &&
  pass "3. old windows renamed retiring, /exit-clean, closed by pane id" || fail "3. tmux: $(cat "$T/tmux/log")"
grep -qx 'adopt CLE-902 2902' "$T/ai.log" && grep -qx 'adopt CLE-903 2903' "$T/ai.log" && pass "3. the map adopts each new pid (pokes reach the new pane)" || fail "3. adopt: $(cat "$T/ai.log")"
grep -q "brief of CLE-903" "$D/handoff/$frid-CLE-903.seed.md" && grep -q " $frid REFRESH OK CLE-903 pid 103" "$T/o" &&
  pass "3. REFRESH F after M holds the lease (FR-029)" || fail "3. refresh: $(grep REFRESH "$T/o")"
phases="$(awk -v r="$rid" '$2 == r && !seen[$3]++ {printf "%s ", $3}' "$D/rotate.log")"
[[ "$phases" == "GATE HOLD QUIESCE HANDOFF SPAWN ACK RETIRE CLOSE RELEASE DONE " ]] &&
  pass "3. one log line per phase in rotate.log" || fail "3. phases: $phases"
[[ -f "$S/CLE-902/inbox/m1.json" && -f "$S/CLE-902/inbox/m9.json" ]] && grep -q 'owner asks for X' "$D/handoff/$rid-CLE-902.md" &&
  pass "3. T-MSG-IN-FLIGHT: the inbox kept both messages, the handoff lists the unread one" || fail "3. inbox: $(ls "$S/CLE-902/inbox")"
[[ -s "$D/rotate.dispatch.last" ]] && grep -q "send CLE-900 -> CLE-900 result dispatch-rotate-$rid .*ROTATION DONE" "$T/send.log" &&
  pass "3. DONE: rotate.dispatch.last + a result note to the orchestrator (FR-030)" || fail "3. done"
! grep -q ERRTRAP "$T/o" "$T/ack.out" && pass "3. no stray failing command under the ERR trap" || fail "3. ERRTRAP: $(grep ERRTRAP "$T/o" "$T/ack.out")"
# 2026-10-02: DONE went to the log only, the ctx kept the failover's CLOSE,
# and every later run resumed that instead of rotating
[[ "$(ctx ROTATE_PHASE)" == DONE ]] && pass "3. the ctx ends at DONE" || fail "3. ctx phase: $(ctx ROTATE_PHASE)"
act DRY_RUN=0 >"$T/o" 2>&1
grep -q ' GATE SKIP young' "$T/o" && ! grep -q RESUME "$T/o" &&
  pass "3. the next run gates afresh, no RESUME" || fail "3. next run: $(cat "$T/o")"

# --- 4. T-DISP-ACK-FAIL ----------------------------------------------------------------------
world; echo no >"$T/ack.mode.CLE-902"
act DRY_RUN=0 ROTATE_ACK_TIMEOUT=2 >"$T/o" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q ' FAIL FAIL ACK: no ack within 2s' "$T/o" && [[ -d "$T/proc/102" && ! -d "$T/proc/2902" ]] &&
  pass "4. no ack: the fresh M closed, the old M (pid 102) kept" || fail "4. rc=$rc $(cat "$T/o")"
[[ "$(holder)" == CLE-902 && ! -e "$D/rotate.hold" ]] && grep -q $'^%2\t102\t$0\tCLE-902@box > dispatcher$' "$T/tmux/panes" &&
  [[ "$(tail -1 "$T/ai.log")" == "adopt CLE-902 102" ]] && pass "4. the hold removed, the lease, the window name and the map back on the old M" ||
  fail "4. lease=$(cat "$D/lease") $(cat "$T/tmux/panes")"
grep -q "^do_spl_ask_put ASK_KIND=blocker ASK_FROM=CLE-902 ASK_TOPIC=dispatch-rotate-" "$T/run.log" && grep -q '^do_spl_desk_reply .*DESK_TO=HUM-10' "$T/run.log" &&
  pass "4. ALERT: one ask + one owner DM (FR-075)" || fail "4. alert: $(cat "$T/run.log")"
[[ ! -e "$T/proc/2903" && -d "$T/proc/103" ]] && ! grep -q REFRESH "$D/rotate.log" && pass "4. no refresh after a failed master" || fail "4. refreshed anyway"

# --- 5. a failed F refresh ------------------------------------------------------------------
world; echo no >"$T/ack.mode.CLE-903"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -ne 0 && -d "$T/proc/2902" && -d "$T/proc/103" && ! -d "$T/proc/2903" && "$(holder)" == CLE-902 ]] &&
  grep -q 'DONE WAIT fresh CLE-902; the CLE-903 refresh failed' "$T/o" && grep -q "ASK_FROM=CLE-903 ASK_TOPIC=dispatch-rotate-.*-failover" "$T/run.log" &&
  pass "5. F refresh fails: the old F kept and alerted, M stays fresh" || fail "5. rc=$rc $(cat "$T/o")"

# --- 6. T-DISP-HEAL ----------------------------------------------------------------------------
world; rm -rf "$T/proc/103"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && -d "$T/proc/203" && -d "$T/proc/102" ]] && grep -q 'HEAL OK running again: CLE-903' "$T/o" &&
  grep -q 'do_spl_dispatch_setup .*DISPATCH_MASTER=CLE-902' "$T/run.log" && [[ ! -e "$T/spawn.log" && ! -e "$D/rotate.hold" ]] &&
  pass "6. a missing failover: do_spl_dispatch_setup spawns it, nothing else this run (FR-021)" || fail "6. rc=$rc $(cat "$T/o")"

# --- 7. T-DISP-ACK-SOURCE ----------------------------------------------------------------------
world; echo no >"$T/ack.mode.CLE-902"
( act DRY_RUN=0 ROTATE_ACK_TIMEOUT=5 >"$T/o" 2>&1 ) & sleep 3
rid="$(ctx ROTATE_RID)"
act ROTATE_CMD=ack ROTATE_ID="$rid" ROTATE_CALLER_PID=102 >"$T/a" 2>&1; rc=$?
[[ $rc -eq 3 ]] && grep -q "caller pid '102' is not the new session 2902" "$T/a" && pass "7. an ack from the old pid: exit 3" || fail "7. pid rc=$rc $(cat "$T/a")"
act ROTATE_CMD=ack ROTATE_ID=20000101T0000Z-master ROTATE_CALLER_PID=2902 >"$T/a" 2>&1; rc=$?
[[ $rc -eq 3 ]] && pass "7. an unknown rid: exit 3" || fail "7. rid rc=$rc $(cat "$T/a")"
wait
! grep -q "result dispatch-rotate-$rid" "$T/send.log" && [[ -d "$T/proc/102" ]] && pass "7. ... nothing was sent, the old M kept" || fail "7. a forged ack counted"

# --- 8. T-DISP-HOLD-STALE ------------------------------------------------------------------------
world
able() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" LEASE_PROC_ROOT="$T/proc" LEASE_PANE_CMD="$T/bin/footer" bash -c '
    do_log() { echo "$*"; }; source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"; spl_lease_init
    echo "able=[$(spl_lease_agent_able CLE-902)] why=[$(cat "$LEASE_DIR/able.CLE-902")]"'
}
echo "CLE-902 $(date +%s) 20261002T0515Z-master" >"$D/rotate.hold"
[[ "$(able)" == "able=[] why=[held: rotation since "* ]] && pass "8. a held master is not able (renew, watch, fleet candidate skip it)" || fail "8. gate: $(able)"
echo "CLE-903 $(date +%s)" >"$D/rotate.hold"
[[ "$(able)" == "able=[102] why=[able]" ]] && pass "8. a hold on another id leaves the master able" || fail "8. other: $(able)"
echo "CLE-902 $(( $(date +%s) - 4000 )) x" >"$D/rotate.hold"; able >/dev/null
[[ "$(able)" == "able=[102] why=[able]" && "$(grep -c 'rotate.hold on CLE-902 is .* ignored' "$D/lease.log")" == 1 ]] &&
  pass "8. a hold older than ROTATE_HOLD_MAX is ignored, logged once (FR-024)" || fail "8. stale: $(able) $(cat "$D/lease.log" 2>&1)"

# --- 9. resume + abort -----------------------------------------------------------------------------
# a run killed at ACK: rebuild that state by hand (old 102 + new 2902, hold, ctx ACK)
at_ack() {
  world; echo no >"$T/ack.mode.CLE-902"
  act DRY_RUN=0 ROTATE_ACK_TIMEOUT=1 >/dev/null 2>&1
  rid="$(ctx ROTATE_RID)"
  "$T/bin/proc" 2902 CLE-902 0; printf '%%2902\t2902\t$0\tCLE-902@box\n' >>"$T/tmux/panes"; echo 2902 >"$T/ai.CLE-902"
  echo "CLE-902 $(date +%s) $rid" >"$D/rotate.hold"; echo "CLE-903 $(date +%s)" >"$D/lease"
  sed -i 's/^ROTATE_PHASE=.*/ROTATE_PHASE=ACK/; s/^ROTATE_NEW_PID=.*/ROTATE_NEW_PID=2902/; s/^ROTATE_NEW_PANE=.*/ROTATE_NEW_PANE=%2902/' "$D/rotate.dispatch.ctx"
}
at_ack
act ROTATE_CMD=abort DRY_RUN=0 >"$T/o" 2>&1
grep -q ' ABORT ABORT at ACK by hand' "$T/o" && [[ ! -d "$T/proc/2902" && -d "$T/proc/102" && ! -e "$D/rotate.hold" && "$(holder)" == CLE-902 ]] &&
  pass "9. abort (FR-091): the new one closed, the hold removed, the old M keeps the lease" || fail "9. abort: $(cat "$T/o") lease=$(cat "$D/lease")"
at_ack
"$T/bin/send" --from CLE-902 --to CLE-902 --kind result --task "dispatch-rotate-$rid" --body ack
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q " RESUME OK from ACK (old alive=1, new alive=1)" "$T/o" && [[ ! -d "$T/proc/102" && "$(holder)" == CLE-902 && ! -e "$D/rotate.hold" ]] &&
  grep -q " $rid DONE OK" "$T/o" && pass "9. resumed at ACK with its ack on disk: retired, released, refreshed, DONE (FR-003)" || fail "9. resume rc=$rc $(cat "$T/o")"
# the live shape of 2026-10-02 13:15Z: a ctx left at the failover's CLOSE
# (old gone, new alive) is closed once, ends at DONE, and is not resumed again
world; "$T/bin/proc" 2903 CLE-903 0; printf '%%2903\t2903\t$0\tCLE-903@box\n' >>"$T/tmux/panes"; echo 2903 >"$T/ai.CLE-903"
rm -rf "$T/proc/103"; date +%s >"$D/rotate.dispatch.last"
printf 'ROTATE_RID=20261002T1100Z-failover\nROTATE_PHASE=CLOSE\nROTATE_OLD_PID=103\nROTATE_OLD_PANE=%%3\nROTATE_NEW_PID=2903\nROTATE_NEW_PANE=%%2903\n' >"$D/rotate.dispatch.ctx"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(ctx ROTATE_PHASE)" == DONE ]] && grep -q ' RESUME OK from CLOSE (old alive=0, new alive=1)' "$T/o" &&
  pass "9. a failover left at CLOSE: resumed once, the ctx ends at DONE" || fail "9. CLOSE resume rc=$rc phase=$(ctx ROTATE_PHASE) $(cat "$T/o")"
act DRY_RUN=0 >"$T/o" 2>&1
! grep -q RESUME "$T/o" && grep -q ' GATE ' "$T/o" &&
  pass "9. ... and the next run gates afresh" || fail "9. resumed again: $(cat "$T/o")"

# --- 10. T-CRON ---------------------------------------------------------------------------------
cat >"$T/bin/crontab" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi
cp "$1" "$FAKE_CRONTAB"
EOF
chmod +x "$T/bin/crontab"
SRC="$T/shared"; mkdir -p "$SRC/csi-spl-orc/src/bash/scripts"
cp "$PROJ_ROOT/src/bash/scripts/dispatch-rotate-cron.sh" "$SRC/csi-spl-orc/src/bash/scripts/"
printf '5 * * * * x # csi-spl:orch-rotate\n' >"$T/crontab"
cron() {
  env PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab" DESK_CRON_SRC="$SRC" ROTATE_CRON_LOG_DIR="$T/log" "$@" bash -c '
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-dispatch-rotate-install-cron.func.sh"
    do_spl_dispatch_rotate_install_cron'
}
before="$(md5sum <"$T/crontab")"
cron >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(md5sum <"$T/crontab")" == "$before" ]] && grep -q '^    +15 \* \* \* \* .*dispatch-rotate-cron.sh >> .*/cron.out 2>&1 # csi-spl:dispatch-rotate$' "$T/o" &&
  pass "10. dry run: the diff, nothing written" || fail "10. dry: rc=$rc $(cat "$T/o")"
cron DRY_RUN=0 >"$T/o" 2>&1; rc=$?
want="15 * * * * $SRC/csi-spl-orc/src/bash/scripts/dispatch-rotate-cron.sh >> $T/log/cron.out 2>&1 # csi-spl:dispatch-rotate"
[[ $rc -eq 0 ]] && grep -qxF "$want" "$T/crontab" && grep -q 'orch-rotate' "$T/crontab" &&
  pass "10. DRY_RUN=0: one exact line at :15, the orch line kept" || fail "10. install rc=$rc: $(cat "$T/crontab") $(cat "$T/o")"
cron DRY_RUN=0 >/dev/null 2>&1
[[ "$(grep -c '# csi-spl:dispatch-rotate$' "$T/crontab")" == 1 ]] && pass "10. idempotent" || fail "10. lines: $(cat "$T/crontab")"
cron ROTATE_CRON_ACTION=check >"$T/o" 2>&1 && pass "10. check passes once installed" || fail "10. check: $(cat "$T/o")"
cron CRON_REMOVE=1 DRY_RUN=0 >/dev/null 2>&1
! grep -q 'dispatch-rotate' "$T/crontab" && grep -q 'orch-rotate' "$T/crontab" && pass "10. CRON_REMOVE=1 takes only its line (FR-092)" || fail "10. remove: $(cat "$T/crontab")"
ROTATE_CRON_TOOLS=no-such-tool-x bash "$SRC/csi-spl-orc/src/bash/scripts/dispatch-rotate-cron.sh" --check-tools >"$T/o" 2>&1
[[ $? -eq 3 ]] && grep -q 'no-such-tool-x' "$T/o" && pass "10. the cron script names a missing tool (exit 3)" || fail "10. tools: $(cat "$T/o")"

echo
(( fails == 0 )) && { echo "dispatch-rotate: all passed"; exit 0; }
echo "dispatch-rotate: $fails failure(s)"; exit 1
